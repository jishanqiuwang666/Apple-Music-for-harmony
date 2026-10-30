/**
 * Apple Music 缓存管理
 *
 * 策略（本 App 自定）：
 *   - 上限 3GB，超出按 LRU 清理
 *   - 支持「保留」（pinned）：被打标记的歌曲永不自动清理
 *   - 索引持久化到 Preferences（JSON），重启后仍能命中
 *   - 缓存文件放沙箱 cacheDir/apple_music/<songId>.m4a
 */
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../util/Logger';
import { AppleArtworkCache } from './AppleArtworkCache';
import { AppleDownloader, DownloadResult } from './AppleDownloader';

const TAG: string = 'AppleCache';
const PREF: string = 'apple_music_cache';
const KEY_INDEX: string = 'index_json';
/**
 * 缓存格式版本：不一致就把整个缓存清掉。
 *
 * v1 → v2：修复 HLS `#EXT-X-BYTERANGE` 省略 @offset 时偏移算成 0 的 bug，
 * 之前并行下载写出的文件可能是坏的（体积正常但内容错乱，光看大小查不出来），
 * 必须整体作废重下。
 */
// 5: 鸿蒙 7 的 FFmpeg 解复用器会校验 CENC 描述，必须把 senc/saiz/saio/sgpd/sbgp/sinf
//    就地改名为 free（见 Mp4Cleaner.blankCenc）。生成版本的变化很轻但结构不同 → 升版本清缓存。
const CACHE_SCHEMA: number = 5;
const KEY_SCHEMA: string = 'schema_version';
/** 3GB */
const MAX_BYTES: number = 3 * 1024 * 1024 * 1024;
/** 清理到上限的 90% 为止 */
const TARGET_RATIO: number = 0.9;
/** 小于这个体积的缓存文件一律视为损坏（正常单曲 0.4~15MB）。 */
const MIN_VALID_BYTES: number = 128 * 1024;

export class CacheEntry {
  songId: string = '';
  fileName: string = '';
  size: number = 0;
  lastAccess: number = 0;
  pinned: boolean = false;
}

export class CacheStats {
  count: number = 0;
  bytes: number = 0;
  limitBytes: number = MAX_BYTES;
}

export class AppleCache {
  /** 小于这个体积的缓存文件一律视为损坏（见 {@link getCachedPath}）。 */
  static readonly MIN_VALID_BYTES: number = MIN_VALID_BYTES;
  private static dir: string = '';
  private static entries: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  private static prefs: preferences.Preferences | null = null;
  private static initialized: boolean = false;

  /** 初始化：建目录 + 载入索引 */
  /** Context received at init: reused by other services in this module
   *  (e.g. AppleLibrarySync warming the playable-track cache). */
  static ctx: common.Context | undefined = undefined;

  static async init(context: common.Context): Promise<void> {
    AppleCache.ctx = context;
    AppleArtworkCache.init(context);
    if (AppleCache.initialized) {
      return;
    }
    AppleCache.dir = context.cacheDir + '/apple_music';
    try {
      fileIo.mkdirSync(AppleCache.dir, true);
    } catch (e) {
      // 已存在则忽略
    }
    AppleCache.prefs = await preferences.getPreferences(context, PREF);
    const json: string = (await AppleCache.prefs.get(KEY_INDEX, '[]')) as string;
    const schema: number = (await AppleCache.prefs.get(KEY_SCHEMA, 0)) as number;
    AppleCache.entries = AppleCache.parseIndex(json);
    if (schema !== CACHE_SCHEMA) {
      const n: number = await AppleCache.clearAll(false);
      AppleCache.entries = new Map<string, CacheEntry>();
      await AppleCache.prefs.put(KEY_SCHEMA, CACHE_SCHEMA);
      await AppleCache.prefs.flush();
      Logger.warn(TAG, `缓存格式升级 ${schema} → ${CACHE_SCHEMA}，已清空 ${n} 个旧缓存`);
    }
    AppleCache.sweepCorrupted();
    AppleCache.sweepTempFiles();
    AppleCache.initialized = true;
    const st: CacheStats = AppleCache.stats();
    Logger.info(TAG, `init: dir=${AppleCache.dir} count=${st.count} bytes=${st.bytes}`);
  }

  /**
   * 启动时扫一遍索引，把体积异常（半截）的缓存条目清掉。
   * 这些文件是历史版本「直接 TRUNC 写目标路径」留下的，不清掉会让对应歌曲
   * 永远播不出来（命中缓存 → 文件打不开 → 也不会重新下载）。
   */
  private static sweepCorrupted(): void {
    const bad: string[] = [];
    AppleCache.entries.forEach((e: CacheEntry, songId: string) => {
      const full: string = AppleCache.dir + '/' + e.fileName;
      try {
        if (fileIo.statSync(full).size < MIN_VALID_BYTES) {
          bad.push(songId);
          try {
            fileIo.unlinkSync(full);
          } catch (err) {
            // 忽略
          }
        }
      } catch (err) {
        bad.push(songId);
      }
    });
    if (bad.length > 0) {
      for (let i = 0; i < bad.length; i++) {
        AppleCache.entries.delete(bad[i]);
      }
      AppleCache.persist();
      Logger.warn(TAG, `sweepCorrupted: 清理 ${bad.length} 个损坏缓存`);
    }
  }

  /** 清掉下载中断留下的 .part 临时文件。 */
  private static sweepTempFiles(): void {
    let children: string[] = [];
    try {
      children = fileIo.listFileSync(AppleCache.dir);
    } catch (err) {
      return;
    }
    let removed: number = 0;
    for (let i = 0; i < children.length; i++) {
      if (children[i].endsWith('.part')) {
        try {
          fileIo.unlinkSync(AppleCache.dir + '/' + children[i]);
          removed++;
        } catch (err) {
          // 忽略
        }
      }
    }
    if (removed > 0) {
      Logger.warn(TAG, `sweepTempFiles: 清理 ${removed} 个 .part`);
    }
  }

  private static parseIndex(json: string): Map<string, CacheEntry> {
    const map: Map<string, CacheEntry> = new Map<string, CacheEntry>();
    try {
      const arr: Object[] = JSON.parse(json) as Object[];
      for (let i = 0; i < arr.length; i++) {
        const o: Record<string, Object> = arr[i] as Record<string, Object>;
        const e = new CacheEntry();
        e.songId = (o['songId'] as string) ?? '';
        e.fileName = (o['fileName'] as string) ?? '';
        e.size = (o['size'] as number) ?? 0;
        e.lastAccess = (o['lastAccess'] as number) ?? 0;
        e.pinned = (o['pinned'] as boolean) ?? false;
        if (e.songId.length > 0) {
          map.set(e.songId, e);
        }
      }
    } catch (e) {
      Logger.error(TAG, 'parseIndex failed, start empty');
    }
    return map;
  }

  private static async persist(): Promise<void> {
    if (AppleCache.prefs === null) {
      return;
    }
    const arr: CacheEntry[] = [];
    AppleCache.entries.forEach((v: CacheEntry) => {
      arr.push(v);
    });
    await AppleCache.prefs.put(KEY_INDEX, JSON.stringify(arr));
    await AppleCache.prefs.flush();
  }

  /** 命中则返回本地文件绝对路径，未命中或文件损坏返回空串（会顺带刷新 LRU 时间） */
  static getCachedPath(songId: string): string {
    const e: CacheEntry | undefined = AppleCache.entries.get(songId);
    if (e === undefined) {
      return '';
    }
    const full: string = AppleCache.dir + '/' + e.fileName;
    let size: number = 0;
    try {
      size = fileIo.statSync(full).size;
    } catch (err) {
      // 文件被外部删了，清掉索引项
      AppleCache.entries.delete(songId);
      AppleCache.persist();
      return '';
    }
    if (size < AppleCache.MIN_VALID_BYTES) {
      // 半截文件（下载被中断/并发写坏）：直接作废，否则这首歌会被永久
      // 判定为「已缓存」，每次播放都拿到一个 AVPlayer 打不开的文件。
      Logger.warn(TAG, `缓存已损坏 ${songId} size=${size}，作废`);
      try {
        fileIo.unlinkSync(full);
      } catch (err2) {
        // 删不掉也无所谓，索引已经清掉
      }
      AppleCache.entries.delete(songId);
      AppleCache.persist();
      return '';
    }
    e.lastAccess = new Date().getTime();
    return full;
  }

  /** 目标写入路径（下载器先写这里，成功后登记索引） */
  static targetPathFor(songId: string): string {
    return AppleCache.dir + '/' + AppleCache.fileNameFor(songId);
  }

  private static fileNameFor(songId: string): string {
    // 只保留安全字符
    let s: string = '';
    for (let i = 0; i < songId.length; i++) {
      const c: string = songId.charAt(i);
      if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_' || c === '-') {
        s += c;
      }
    }
    return (s.length > 0 ? s : 'song') + '.m4a';
  }

  /** 下载完成后登记（并触发清理） */
  static async put(songId: string, fileName: string, size: number): Promise<void> {
    const e = new CacheEntry();
    e.songId = songId;
    e.fileName = fileName;
    e.size = size;
    e.lastAccess = new Date().getTime();
    e.pinned = false;
    AppleCache.entries.set(songId, e);
    await AppleCache.persist();
    await AppleCache.evictIfNeeded();
  }

  /** 标记「保留」 */
  static async setPinned(songId: string, pinned: boolean): Promise<void> {
    const e: CacheEntry | undefined = AppleCache.entries.get(songId);
    if (e === undefined) {
      return;
    }
    e.pinned = pinned;
    await AppleCache.persist();
  }

  static isPinned(songId: string): boolean {
    const e: CacheEntry | undefined = AppleCache.entries.get(songId);
    return e !== undefined && e.pinned;
  }

  /** 是否已缓存 */
  static has(songId: string): boolean {
    return AppleCache.getCachedPath(songId).length > 0;
  }

  /**
   * 正在进行的「下载 + 解密」任务。
   *
   * 这是修「点了歌有时播、有时等很久都不播」的关键：预加载和播放都走
   * {@link AppleCache.ensure}，同一首歌的并发调用共享同一个 Promise
   * （single-flight），从根上避免两个下载器同时 TRUNC 写同一个文件，
   * 写出一个残缺的 m4a。
   */
  private static inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  /** 这首歌是否正在下载/预取中。 */
  static isPreloading(songId: string): boolean {
    return AppleCache.inflight.has(songId);
  }

  /**
   * 确保某首歌已经在缓存里，返回可直接交给 AVPlayer 的本地文件路径。
   *
   * Apple 音源**唯一**的取文件入口：命中缓存立即返回；有在飞的任务就复用；
   * 否则发起一次下载并在落索引后返回路径。失败时 reject，调用方负责提示。
   *
   * @param songId Apple Music 歌曲 ID
   * @param isLibrary 是否资料库歌曲（决定 webPlayback 的请求体）
   */
  static ensure(songId: string, isLibrary: boolean): Promise<string> {
    if (songId.length === 0) {
      return Promise.reject(new Error('歌曲 ID 为空'));
    }
    const hit: string = AppleCache.getCachedPath(songId);
    if (hit.length > 0) {
      return Promise.resolve(hit);
    }
    const running: Promise<string> | undefined = AppleCache.inflight.get(songId);
    if (running !== undefined) {
      Logger.info(TAG, `ensure: 复用进行中的任务 ${songId}`);
      return running;
    }
    Logger.info(TAG, `ensure: 发起下载 ${songId} isLibrary=${isLibrary}`);
    // 参数自愈：调用方（SongItemBuilder）历史上对 Apple 音源写死 isLibrary=true，
    // 而搜索页的目录歌曲并不在资料库里 —— webPlayback 用 universalLibraryId 查
    // 会拿不到资产（表现为「该歌曲没有可用的音频资源」）。这里在失败时自动换成
    // 另一种标识重试一次，调用方不需要知道这首歌是从哪来的。
    const task: Promise<string> = AppleCache.runDownload(songId, isLibrary)
      .catch((err: Error) => {
        Logger.warn(TAG, `ensure: isLibrary=${isLibrary} 失败（${err.message}），改用另一种标识重试 ${songId}`);
        return AppleCache.runDownload(songId, !isLibrary);
      });
    AppleCache.inflight.set(songId, task);
    const clear = (): void => {
      AppleCache.inflight.delete(songId);
    };
    return task.then((path: string) => {
      clear();
      return path;
    }, (err: Error) => {
      clear();
      throw err as Error;
    });
  }

  /** 真正执行一次下载 + 落索引。 */
  private static async runDownload(songId: string, isLibrary: boolean): Promise<string> {
    const fileName: string = AppleCache.fileNameFor(songId);
    const target: string = AppleCache.dir + '/' + fileName;
    const res: DownloadResult = await AppleDownloader.downloadSong(songId, isLibrary, target);
    if (!res.ok) {
      Logger.warn(TAG, `ensure: 下载失败 ${songId}: ${res.message}`);
      throw new Error(res.message.length > 0 ? res.message : '下载失败');
    }
    await AppleCache.put(songId, fileName, res.bytes);
    Logger.info(TAG, `ensure: 就绪 ${songId} (${res.bytes} bytes)`);
    return target;
  }

  /**
   * 作废某首歌的缓存（文件损坏 / 播放失败时调用），下次会自动重新下载。
   */
  static async invalidate(songId: string): Promise<void> {
    Logger.warn(TAG, `invalidate ${songId}`);
    await AppleCache.remove(songId);
  }

  /**
   * 后台预取：把一首歌提前「下载 + CENC 解密」进缓存，播放时直接命中。
   *
   * 与播放共用 {@link AppleCache.ensure}，所以「预取中用户正好点了这首歌」
   * 不会触发第二次下载。fire-and-forget，失败只记日志。
   */
  static preload(songId: string, isLibrary: boolean): Promise<void> {
    if (songId.length === 0 || AppleCache.entries.has(songId) || AppleCache.inflight.has(songId)) {
      return Promise.resolve();
    }
    Logger.info(TAG, `preload 开始: ${songId}`);
    return AppleCache.ensure(songId, isLibrary).then(() => {
      Logger.info(TAG, `preload 完成 ${songId}`);
    }).catch((err: Error) => {
      Logger.warn(TAG, `preload 失败 ${songId}: ${err.message}`);
    });
  }

  static stats(): CacheStats {
    const st = new CacheStats();
    st.count = AppleCache.entries.size;
    let total: number = 0;
    AppleCache.entries.forEach((e: CacheEntry) => {
      total += e.size;
    });
    st.bytes = total;
    return st;
  }

  /** 删除指定缓存 */
  static async remove(songId: string): Promise<void> {
    const e: CacheEntry | undefined = AppleCache.entries.get(songId);
    if (e === undefined) {
      return;
    }
    try {
      fileIo.unlinkSync(AppleCache.dir + '/' + e.fileName);
    } catch (err) {
      // 文件不存在也无所谓
    }
    AppleCache.entries.delete(songId);
    await AppleCache.persist();
  }

  /** 清空全部（保留 pinned 的） */
  static async clearAll(keepPinned: boolean = true): Promise<number> {
    const ids: string[] = [];
    AppleCache.entries.forEach((e: CacheEntry, k: string) => {
      if (!keepPinned || !e.pinned) {
        ids.push(k);
      }
    });
    for (let i = 0; i < ids.length; i++) {
      await AppleCache.remove(ids[i]);
    }
    return ids.length;
  }

  /** 超出上限则按 LRU 清理（跳过 pinned） */
  static async evictIfNeeded(): Promise<number> {
    let st: CacheStats = AppleCache.stats();
    if (st.bytes <= MAX_BYTES) {
      return 0;
    }
    const target: number = Math.floor(MAX_BYTES * TARGET_RATIO);
    const list: CacheEntry[] = [];
    AppleCache.entries.forEach((e: CacheEntry) => {
      if (!e.pinned) {
        list.push(e);
      }
    });
    list.sort((a: CacheEntry, b: CacheEntry) => a.lastAccess - b.lastAccess);
    let removed: number = 0;
    for (let i = 0; i < list.length && st.bytes > target; i++) {
      const e: CacheEntry = list[i];
      try {
        fileIo.unlinkSync(AppleCache.dir + '/' + e.fileName);
      } catch (err) {
        // 忽略
      }
      AppleCache.entries.delete(e.songId);
      st.bytes -= e.size;
      removed++;
    }
    if (removed > 0) {
      await AppleCache.persist();
      Logger.info(TAG, `evicted ${removed} files, now ${AppleCache.stats().bytes} bytes`);
    }
    return removed;
  }

  /** 缓存目录（供扫描/统计用） */
  static cacheDir(): string {
    return AppleCache.dir;
  }
}
