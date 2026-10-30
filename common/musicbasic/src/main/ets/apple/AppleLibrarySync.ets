import { AppleCache } from './AppleCache';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
/**
 * Apple Music 资料库同步
 *
 * 把用户 Apple Music 账号里的资料库（歌曲）拉下来，转成本地 RDB 的行，
 * 交给 MusicDatabase.syncAppleSongs 落库。艺人/专辑由 MusicDatabase 自动聚合。
 */
import { AppleApi, PageResult } from './AppleApi';
import { AppleDiag } from './AppleDiag';
import { AppleArtist, ApplePlaylist, AppleSong,
  AppleAlbum
} from './AppleModels';
import { MusicSongRow } from '../data/MusicSongRow';
import { ApplePlaylistRow } from '../data/ApplePlaylistRow';
import { MusicDatabase } from '../db/MusicDatabase';
import { SongApiDto } from '../api/MusicApiDtos';
import { LibrarySignal } from '../model/LibrarySignal';
import { Logger } from '../util/Logger';

const TAG: string = 'AppleLibrarySync';
/** 单页大小 */
const PAGE: number = 100;

export class SyncResult {
  ok: boolean = false;
  songs: number = 0;
  message: string = '';
}

export type SyncProgress = (percent: number, note: string) => void;

export class AppleLibrarySync {
  /** 全量同步的「新鲜期」：这段时间内且曲目总数没变，冷启动就不再全量重拉。 */
  private static readonly FULL_SYNC_MAX_AGE_MS: number = 6 * 60 * 60 * 1000;
  /** 记录上次全量同步的时间与曲目总数的 Preferences（独立于设置抽屉那份）。 */
  private static readonly SYNC_PREF: string = 'musichome_sync';
  private static readonly KEY_SYNC_AT: string = 'last_full_sync_ms';
  private static readonly KEY_SYNC_TOTAL: string = 'last_full_total';

  private static syncStore(): preferences.Preferences | undefined {
    const ctx: common.Context | undefined = AppleCache.ctx;
    if (ctx === undefined) {
      return undefined;
    }
    try {
      return preferences.getPreferencesSync(ctx, { name: AppleLibrarySync.SYNC_PREF });
    } catch (e) {
      return undefined;
    }
  }

  private static markFullSyncDone(total: number): void {
    const store: preferences.Preferences | undefined = AppleLibrarySync.syncStore();
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(AppleLibrarySync.KEY_SYNC_AT, new Date().getTime());
      store.putSync(AppleLibrarySync.KEY_SYNC_TOTAL, total);
      store.flush();
    } catch (e) {
    }
  }

  /** 本地「资料库歌曲」条数（内存镜像里数，零 DB 查询）。 */
  private static localLibraryCount(): number {
    const rows: MusicSongRow[] = MusicDatabase.getInstance().getSongs();
    let n: number = 0;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].isLibrary) {
        n++;
      }
    }
    return n;
  }

  /**
   * 冷启动是否可以跳过「全量重拉歌曲」。
   *
   * 全量重拉是 28 次分页请求（2800+ 首），但资料库绝大多数时候没变。
   * 这里只花 **1 个请求**问一下 Apple「曲目总数是多少」：
   *   - 距上次全量同步 < 6 小时，且总数与本地一致 ⇒ 跳过（本地 RDB 里的数据照常用）；
   *   - 总数变了（增删歌曲）、或本地没数据、或超过 6 小时 ⇒ 老老实实全量同步。
   * 用户手动点「同步」按钮时走 force 分支，永远全量。
   */
  private static async shouldSkipFullSync(): Promise<boolean> {
    const store: preferences.Preferences | undefined = AppleLibrarySync.syncStore();
    if (store === undefined) {
      return false;
    }
    try {
      const at: number = store.getSync(AppleLibrarySync.KEY_SYNC_AT, 0) as number;
      if (at <= 0) {
        return false;
      }
      const age: number = new Date().getTime() - at;
      if (age > AppleLibrarySync.FULL_SYNC_MAX_AGE_MS) {
        Logger.info(TAG, `距上次全量同步 ${Math.round(age / 60000)} 分钟，超过新鲜期，执行全量同步`);
        return false;
      }
      const local: number = AppleLibrarySync.localLibraryCount();
      if (local <= 0) {
        return false;
      }
      const probe: PageResult<AppleSong> = await AppleApi.getLibrarySongs(1, 0);
      const appleTotal: number = probe.total;
      const skip: boolean = appleTotal > 0 && appleTotal === local;
      Logger.info(TAG, `同步评估：Apple total=${appleTotal} 本地=${local} ` +
        `距上次=${Math.round(age / 60000)} 分钟 ⇒ ${skip ? '跳过全量同步' : '需要全量同步'}`);
      return skip;
    } catch (e) {
      Logger.warn(TAG, '同步评估失败，按需要全量同步处理：' + ((e as Error).message ?? ''));
      return false;
    }
  }

  /**
   * 全量同步资料库歌曲（自动分页）
   * @param onProgress 进度回调（0-100）
   * @param force 用户手动触发时传 true：跳过快照判断，永远全量重拉
   */
  static async syncSongs(onProgress?: SyncProgress, force: boolean = false): Promise<SyncResult> {
    const res = new SyncResult();
    const report: SyncProgress = onProgress ?? ((p: number, n: string) => {
    });
    try {
      await AppleApi.ensureReady();
      // 冷启动省电路径：资料库没变就不重拉（详见 shouldSkipFullSync）
      if (!force && await AppleLibrarySync.shouldSkipFullSync()) {
        report(60, '资料库无变化');
        await AppleLibrarySync.syncFavorites();
        const local: number = AppleLibrarySync.localLibraryCount();
        res.ok = true;
        res.songs = local;
        res.message = '资料库无变化，已跳过一次全量同步';
        report(100, '同步完成（未变化）');
        Logger.info(TAG, `跳过全量同步，本地 ${local} 首（仍刷新了收藏）`);
        return res;
      }
      report(2, '读取资料库');
      const t0: number = new Date().getTime();
      const all: MusicSongRow[] = [];
      // 每位艺人只记一首歌的目录 id：艺人头像是按艺人取的，2 次请求就能覆盖整库
      const avatarProbe: Map<string, string> = new Map();
      // 收藏（⭐ 专辑/艺人）只写 Preferences，与歌曲分页互不依赖 ⇒ 并发跑
      const favTask: Promise<void> = AppleLibrarySync.syncFavorites();
      // 临时诊断：catalogId（艺人头像探针要用）的覆盖率，确认砍字段后仍有值
      let cidHit: number = 0;
      let cidAll: number = 0;
      const collect = (page: PageResult<AppleSong>): number => {
        for (let i = 0; i < page.items.length; i++) {
          const song: AppleSong = page.items[i];
          all.push(AppleLibrarySync.toRow(song));
          cidAll++;
          if (song.catalogId !== '') {
            cidHit++;
          }
          if (song.catalogId !== '' && song.artistName !== ''
            && !avatarProbe.has(song.artistName)) {
            avatarProbe.set(song.artistName, song.catalogId);
          }
        }
        return page.items.length;
      };
      // 第一页：同时拿到 Apple 声明的总数（决定后面要拉几页）。
      // 页大小固定 100：真机实测 `limit=300` 会被 Apple 直接 400 拒掉（该接口上限就是 100）。
      // 仍然按**实际返回的条数**当页大小，Apple 若哪天改口径也不会漏歌。
      const REQUEST_PAGE: number = PAGE;
      let page: PageResult<AppleSong> = await AppleApi.getLibrarySongs(REQUEST_PAGE, 0);
      const declaredTotal: number = page.total;
      const pageSizeProbe: number = page.items.length;
      const pageSize: number = pageSizeProbe > 0 ? pageSizeProbe : REQUEST_PAGE;
      collect(page);
      let fetched: number = page.items.length;
      Logger.info(TAG, `分页实测：请求 ${REQUEST_PAGE} 首/页 → Apple 返回 ${pageSizeProbe} 首（total=${declaredTotal}）`);
      // 后面几页**并发**拉（一次 6 页）。
      // 以前是一页等一页：2900 首要 29 次往返，每次 1~2s ⇒ 半分钟以上；
      // 并发 6 页后往返轮数降到 1/6。
      const CONCURRENCY: number = 6;
      let nextOffset: number = fetched;
      let guard: number = 0;
      while (page.items.length === pageSize && guard < 200) {
        const offsets: number[] = [];
        for (let i = 0; i < CONCURRENCY; i++) {
          if (declaredTotal > 0 && nextOffset >= declaredTotal) {
            break;
          }
          offsets.push(nextOffset);
          nextOffset += pageSize;
        }
        if (offsets.length === 0) {
          break;
        }
        const tasks: Promise<PageResult<AppleSong>>[] = [];
        for (let i = 0; i < offsets.length; i++) {
          tasks.push(AppleApi.getLibrarySongs(pageSize, offsets[i]));
        }
        const batch: PageResult<AppleSong>[] = await Promise.all(tasks);
        let short: boolean = false;
        for (let i = 0; i < batch.length; i++) {
          const n: number = collect(batch[i]);
          fetched += n;
          if (n < pageSize) {
            short = true;
          }
        }
        page = batch[batch.length - 1];
        report(2 + Math.min(80, Math.floor(fetched / 10)), '已读取 ' + fetched + ' 首');
        if (short) {
          break;
        }
        guard += offsets.length;
      }
      const tFetch: number = new Date().getTime();
      Logger.info(TAG, `拉取完成，共 ${all.length} 首（Apple 声明 total=${declaredTotal}），` +
        `耗时 ${((tFetch - t0) / 1000).toFixed(1)}s；catalogId 覆盖 ${cidHit}/${cidAll}`);
      if (declaredTotal > 0 && all.length !== declaredTotal) {
        Logger.warn(TAG, '资料库曲目数与 Apple 声明不一致：拉取=' + all.length + ' total=' + declaredTotal);
      }
      report(85, '写入本地数据库');
      await MusicDatabase.getInstance().syncAppleSongs(all);
      const tDb: number = new Date().getTime();
      // 顺手刷新「艺人官方头像」：把上面收集到的探针歌曲批量换成主艺人
      report(92, '更新艺人头像');
      // 头像刷新只影响「艺人头像」这一项，不必卡住「同步完成」：
      // 放后台跑（与可播集合预热并行），跑完再广播一次让页面把头像补上。
      const avatarTask: Promise<void> = AppleLibrarySync.refreshArtistAvatars(avatarProbe);
      const warmTask: Promise<void> = AppleLibrarySync.warmPlayableCache(30);
      await warmTask;
      await favTask;
      const tEnd: number = new Date().getTime();
      res.ok = true;
      res.songs = all.length;
      AppleLibrarySync.markFullSyncDone(all.length);
      report(100, '同步完成，共 ' + all.length + ' 首');
      Logger.info(TAG, `同步完成: ${all.length} 首；分阶段耗时 拉取=${((tFetch - t0) / 1000).toFixed(1)}s ` +
        `写库=${((tDb - tFetch) / 1000).toFixed(1)}s 预热+收藏=${((tEnd - tDb) / 1000).toFixed(1)}s ` +
        `合计=${((tEnd - t0) / 1000).toFixed(1)}s（头像后台刷新中）`);
      avatarTask.then(() => {
        // 头像到位后再通知一次：页面刷新即可看到官方头像
        LibrarySignal.notifyChanged();
      }).catch(() => {
      });
    } catch (e) {
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : JSON.stringify(e);
      res.ok = false;
      res.message = msg;
      Logger.error(TAG, '同步失败: ' + msg);
    }
    return res;
  }

  /**
   * P4: 同步 Apple Music 的收藏（⭐ 专辑 / 艺人）。
   *
   * 收藏状态只能通过资料库资源上的 `extend=inFavorites` 读到（ratings 接口不可用），
   * 所以这里扫描资料库专辑/艺人并过滤。结果写进 Preferences store `musichome_fav`，
   * 页面冷启动先读缓存秒显、再各自刷新一次。
   * 开销：专辑按 100 张/页（上限 5 页），艺人通常 1 次请求。
   *
   * 去重：页面（专辑页/艺人页）进页面时也会拉同一份数据，谁先成功谁写时间戳
   * `apple_fav_at_v1`，另一方 5 分钟内直接跳过 —— 避免一次冷启动拉两遍。
   *
   * @param force 心形按钮改完收藏后的强制刷新走这里（true），不看时间戳
   */
  static async syncFavorites(force: boolean = false): Promise<void> {
    const ctx: common.Context | undefined = AppleCache.ctx;
    if (ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      if (!force) {
        const at: number = store.getSync('apple_fav_at_v1', 0) as number;
        if (at > 0 && (new Date().getTime() - at) < 5 * 60 * 1000) {
          Logger.info(TAG, '收藏刚刷新过（<5 分钟），跳过重复拉取');
          return;
        }
      }
      const albums: AppleAlbum[] = await AppleApi.getFavoriteAlbums(5);
      const artists: string[] = await AppleApi.getFavoriteArtistNames(2);
      store.putSync('apple_fav_albums_v1', JSON.stringify(albums));
      store.putSync('apple_fav_artists_v1', JSON.stringify(artists));
      // 时间戳：另一边看到「刚拉过」就不再自己重复拉一遍（省 4~5 个请求）
      store.putSync('apple_fav_at_v1', new Date().getTime());
      store.flush();
      Logger.info(TAG, `收藏同步完成：专辑 ${albums.length} 张、艺人 ${artists.length} 位`);
    } catch (e) {
      Logger.warn(TAG, '收藏同步失败：' + ((e as Error).message ?? ''));
    }
  }

  /**
   * P1: warm the per-album playable cache (Preferences store musichome_playable,
   * key = normalized album name | artist) so that:
   *   - album cards show the correct track count right away;
   *   - the album detail page renders the correct tracks on first paint (no flash).
   *
   * 省电要点：**只补齐还没有缓存的专辑**（`hasSync` 命中就直接跳过）。
   * 之前是每次冷启动固定拉前 maxAlbums 张专辑的曲目 —— 哪怕缓存里早就有，
   * 等于每次开 App 都白烧 30 次请求。现在缓存齐了就 0 请求。
   *
   * @param maxAlbums 单次最多补几张（未缓存的）
   */
  static async warmPlayableCache(maxAlbums: number): Promise<void> {
    const ctx: common.Context | undefined = AppleCache.ctx;
    if (ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_playable' });
      const page: PageResult<AppleAlbum> = await AppleApi.getLibraryAlbums(100, 0);
      let done: number = 0;
      let hit: number = 0;
      let missed: number = 0;
      for (let i = 0; i < page.items.length; i++) {
        const album: AppleAlbum = page.items[i];
        let nm: string = album.name.toLowerCase().trim();
        const suffixes: string[] = [' - ep', ' - single', ' - deluxe', ' (deluxe)',
          ' - deluxe edition', ' (ep)', ' (single)', ' - complete', ' (complete)'];
        for (let x = 0; x < suffixes.length; x++) {
          if (nm.endsWith(suffixes[x])) {
            nm = nm.substring(0, nm.length - suffixes[x].length).trim();
          }
        }
        const key: string = nm + '|' + album.artistName.toLowerCase().trim();
        if (store.hasSync(key)) {
          hit++;
          continue;
        }
        missed++;
        if (done >= maxAlbums) {
          continue;
        }
        try {
          const tracks: AppleSong[] = await AppleApi.getAlbumTracks(album.id, '', 100);
          if (tracks.length === 0) {
            continue;
          }
          const keys: string[] = [];
          for (let k = 0; k < tracks.length; k++) {
            keys.push((tracks[k].name + '|' + tracks[k].artistName).toLowerCase());
          }
          store.putSync(key, JSON.stringify(keys));
          done++;
        } catch (e) {
        }
      }
      store.flush();
      Logger.info(TAG, `playable cache warmed done=${done} 命中缓存=${hit} 待补=${missed}`);
    } catch (e) {
      Logger.warn(TAG, 'playable cache warm failed: ' + ((e as Error).message ?? ''));
    }
  }


  /**
   * 全量同步资料库歌单（只同步元数据，曲目在打开歌单时按需拉取）。
   * @param onProgress 进度回调
   */
  static async syncPlaylists(onProgress?: SyncProgress): Promise<SyncResult> {
    const res = new SyncResult();
    const report: SyncProgress = onProgress ?? ((p: number, n: string) => {
    });
    try {
      await AppleApi.ensureReady();
      const all: ApplePlaylistRow[] = [];
      let offset: number = 0;
      let page: PageResult<ApplePlaylist> = await AppleApi.getLibraryPlaylists(PAGE, offset);
      let guard: number = 0;
      while (page.items.length > 0 && guard < 50) {
        for (let i = 0; i < page.items.length; i++) {
          const p: ApplePlaylist = page.items[i];
          const row = new ApplePlaylistRow();
          row.id = p.id;
          row.name = p.name.length > 0 ? p.name : '未命名歌单';
          row.description = p.description;
          row.coverUrl = p.artworkUrl;
          row.trackCount = p.trackCount;
          row.isLibrary = true;
          all.push(row);
        }
        offset += page.items.length;
        report(Math.min(95, 10 + offset), '已读取 ' + offset + ' 个歌单');
        if (page.items.length < PAGE) {
          break;
        }
        page = await AppleApi.getLibraryPlaylists(PAGE, offset);
        guard++;
      }
      await MusicDatabase.getInstance().syncApplePlaylists(all);
      res.ok = true;
      res.songs = all.length;
      report(100, '歌单同步完成，共 ' + all.length + ' 个');
      Logger.info(TAG, '歌单同步完成: ' + all.length);
    } catch (e) {
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : JSON.stringify(e);
      res.ok = false;
      res.message = msg;
      Logger.error(TAG, '歌单同步失败: ' + msg);
    }
    return res;
  }

  /**
   * 把所有资料库歌单的曲目拉进本地 songs 表。
   *
   * 三个板块是「资料库 + 歌单」并集，所以不能等用户点开歌单才拉曲目 ——
   * 否则「只在歌单里、没单独加入资料库」的艺人一开始在三个板块里看不到。
   * 单个歌单失败不影响其他歌单（自动歌单「喜爱歌曲」的曲目接口固定 404）。
   */
  static async syncAllPlaylistTracks(force: boolean = false): Promise<SyncResult> {
    const res = new SyncResult();
    try {
      const lists: ApplePlaylistRow[] = MusicDatabase.getInstance().getApplePlaylists();
      // 省电路径：距上次歌单曲目同步 < 6 小时 ⇒ 跳过（每个歌单要 1~2 个请求）。
      // 说明：Apple 的 library playlists 接口不返回 trackCount（库里恒为 0），
      // 所以这里没有「总数变了没」这种准确信号，只能用新鲜期 + 手动同步兜底。
      let sum: number = 0;
      for (let i = 0; i < lists.length; i++) {
        sum += lists[i].trackCount;
      }
      const store: preferences.Preferences | undefined = AppleLibrarySync.syncStore();
      if (!force && store !== undefined && lists.length > 0) {
        const at: number = store.getSync('last_playlist_tracks_ms', 0) as number;
        if (at > 0 && (new Date().getTime() - at) < AppleLibrarySync.FULL_SYNC_MAX_AGE_MS) {
          res.ok = true;
          res.songs = 0;
          res.message = '歌单曲目 6 小时内同步过，已跳过';
          Logger.info(TAG, `歌单曲目 ${Math.round((new Date().getTime() - at) / 60000)} 分钟前同步过，跳过`);
          return res;
        }
      }
      let ok = 0;
      let failed = 0;
      for (let i = 0; i < lists.length; i++) {
        try {
          const songs: SongApiDto[] = await AppleLibrarySync.loadPlaylistSongs(lists[i].id);
          ok++;
          Logger.info(TAG, `歌单曲目同步 ${lists[i].name}: ${songs.length} 首`);
        } catch (e) {
          failed++;
          const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
          Logger.warn(TAG, `歌单曲目同步失败 ${lists[i].name}: ${msg}`);
        }
      }
      res.ok = true;
      res.songs = ok;
      res.message = `歌单曲目同步：成功 ${ok} 个，失败 ${failed} 个`;
      Logger.info(TAG, res.message);
      // 记下本次同步的曲目总数与时间，供下次冷启动判断「没变就跳过」
      if (store !== undefined && failed === 0) {
        try {
          store.putSync('last_playlist_tracks_ms', new Date().getTime());
          store.putSync('last_playlist_tracks_total', sum);
          store.flush();
        } catch (e) {
        }
      }
    } catch (e) {
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : JSON.stringify(e);
      res.ok = false;
      res.message = msg;
      Logger.error(TAG, '歌单曲目同步整体失败: ' + msg);
    }
    return res;
  }

  /**
   * 拉取某个歌单的全部曲目，并确保它们已进入本地 songs 表
   * （不在资料库里的曲目以 folder='apple_playlist'、isLibrary=false 落库；
   * 只有这样才能走现有的「按 id 播放」链路）。
   * @returns 该歌单曲目的 SongApiDto 列表（顺序与 Apple 一致）。
   */
  static async loadPlaylistSongs(playlistId: string): Promise<SongApiDto[]> {
    const rows: MusicSongRow[] = [];
    let offset: number = 0;
    let page: PageResult<AppleSong>;
    try {
      page = await AppleApi.getPlaylistTracks(playlistId, PAGE, offset);
    } catch (e) {
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
      // Apple 对部分自动歌单（如「喜爱歌曲」）不开放 tracks 接口，固定返回
      // 404 "No related resources"。这种情况给用户一句能看懂的话。
      if (msg.indexOf('404') >= 0) {
        AppleDiag.log(`loadPlaylistSongs ${playlistId}: 404（Apple 未开放该歌单曲目）`);
        throw new Error('Apple 没有开放这个歌单的曲目');
      }
      throw e as Error;
    }
    AppleDiag.log(`loadPlaylistSongs ${playlistId}: 第一页 ${page.items.length} 首`);
    let guard: number = 0;
    while (page.items.length > 0 && guard < 100) {
      for (let i = 0; i < page.items.length; i++) {
        const s: AppleSong = page.items[i];
        const row: MusicSongRow = AppleLibrarySync.toRow(s);
        // 不在资料库里的曲目：标记为非资料库，避免污染三个板块
        row.isLibrary = false;
        row.folder = 'apple_playlist';
        rows.push(row);
      }
      offset += page.items.length;
      if (page.items.length < PAGE) {
        break;
      }
      page = await AppleApi.getPlaylistTracks(playlistId, PAGE, offset);
      guard++;
    }
    const db: MusicDatabase = MusicDatabase.getInstance();
    await db.ensureSongs(rows);
    AppleDiag.log(`loadPlaylistSongs ${playlistId}: 共 ${rows.length} 首，已落库`);
    const out: SongApiDto[] = [];
    for (let i = 0; i < rows.length; i++) {
      const found: MusicSongRow | undefined = db.findSongByUri(rows[i].uri);
      if (found === undefined) {
        continue;
      }
      const dto = new SongApiDto();
      dto.id = found.id;
      dto.title = found.title;
      dto.singer = found.artist;
      dto.album = found.album;
      dto.duration = found.duration;
      dto.coverPath = found.coverPath;
      dto.src = found.uri;
      dto.trackNumber = found.trackNumber;
      out.push(dto);
    }
    Logger.info(TAG, `歌单 ${playlistId} 曲目 ${out.length} 首`);
    return out;
  }

  /**
   * 用「每位艺人一首歌」的目录 id 批量换取 Apple Music 官方艺人头像并落库。
   *
   * 资料库接口本身不返回艺人头像，但目录歌曲接口的 relationships.artists 带
   * `attributes.artwork`；一次请求可带 100 个 id，因此整库通常只要 2 次请求。
   * 每次资料库同步都会重跑，所以头像会随 Apple Music 的更新而更新。
   *
   * @param probe 艺人名 → 该艺人的一首目录歌曲 id
   */
  private static async refreshArtistAvatars(probe: Map<string, string>): Promise<void> {
    if (probe.size === 0) {
      return;
    }
    const songIds: string[] = [];
    const bySongId: Map<string, string> = new Map();
    probe.forEach((songId: string, artistName: string) => {
      songIds.push(songId);
      bySongId.set(songId, artistName);
    });
    const avatars: Map<string, string> = new Map();
    const batch: number = 100;
    for (let i = 0; i < songIds.length; i += batch) {
      const slice: string[] = songIds.slice(i, i + batch);
      const found: Map<string, AppleArtist> = await AppleApi.catalogArtistsForSongs(slice);
      found.forEach((artist: AppleArtist, songId: string) => {
        const name: string = bySongId.get(songId) ?? '';
        if (name !== '' && artist.artworkUrl !== '') {
          avatars.set(name, artist.artworkUrl);
        }
      });
    }
    if (avatars.size > 0) {
      await MusicDatabase.getInstance().syncArtistAvatars(avatars);
      Logger.info(TAG, `艺人官方头像已更新：${avatars.size} 位`);
    }
  }


  /** AppleSong → MusicSongRow（uri 用 apple:<id> 作为播放标识） */
  static toRow(s: AppleSong): MusicSongRow {
    const row = new MusicSongRow();
    row.appleId = s.id;
    row.title = s.name.length > 0 ? s.name : '未知歌曲';
    row.artist = s.artistName.length > 0 ? s.artistName : '未知艺人';
    row.album = s.albumName.length > 0 ? s.albumName : '未知专辑';
    row.duration = s.durationMs;
    row.year = s.year;
    row.uri = 'apple:' + s.id;
    row.coverUrl = s.artworkUrl;
    // coverPath 直接放 Apple 的封面 URL：ArkUI Image 原生支持 https，
    // 列表滚动时由系统的网络图片缓存兜住，不必先下载到沙盒。
    row.coverPath = s.artworkUrl;
    row.trackNumber = s.trackNumber;
    row.folder = 'apple';
    row.isLibrary = s.isLibrary;
    row.genre = s.genre;
    row.cachedPath = '';
    row.pinned = false;
    return row;
  }
}
