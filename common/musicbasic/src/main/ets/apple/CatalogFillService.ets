/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * 「补齐曲库版本」服务。
 *
 * 背景：本地导入过的音乐被 iCloud 音乐资料库当成「上传版本」（未匹配上曲库），
 * Apple 的网页接口（也是鸿蒙端唯一可用的接口）既看不到也放不了它们 —— 资料库里
 * 只会残留一条「艺人」记录。实测受影响的有椎名林檎 / Utada / The Beatles /
 * Stevie Wonder / D'Angelo 等。
 *
 * 解法：把同一张专辑的**曲库版本**加入资料库（Apple 官方接口，
 * POST /v1/me/library?ids[albums]=...），加入后 App 就能显示与播放。
 */
import { AppleAlbum, AppleArtist, AppleSearchResult } from './AppleModels';
import { AppleApi } from './AppleApi';
import { MusicDbApi } from '../util/MusicDbApi';
import { Logger } from '../util/Logger';

const TAG = 'CatalogFill';
/** 搜索每位艺人时取回的专辑数上限。 */
const SEARCH_LIMIT = 20;

/** 资料库里「只有艺人条目、没有任何可播放曲目」的艺人。 */
export class ShellArtist {
  /** Apple 资料库艺人 id（形如 r.xxxx）。 */
  public id: string = '';
  /** 艺人名（按账号语言返回）。 */
  public name: string = '';
}

/** 可供加入资料库的曲库专辑。 */
export class CatalogAlbumOffer {
  /** 曲库专辑 id（数字形式）。 */
  public id: string = '';
  public name: string = '';
  public artist: string = '';
  public artworkUrl: string = '';
  /** 曲目数（曲库侧统计）。 */
  public trackCount: number = 0;
  /** 是否单曲（Apple 的 isSingle 标记）。 */
  public isSingle: boolean = false;
}

/** 目录艺人的 id + 规范名（Apple 侧的写法，可能与本地名不同语言）。 */
export class CatalogArtistRef {
  public id: string = '';
  public name: string = '';
}

export class CatalogFillService {
  /**
   * 专辑 id → 目录艺人（含头像）的内存缓存。
   *
   * 长按搜索结果里的封面要「立刻」进艺人主页，不能等网络：搜索一返回就在后台
   * 把前几张专辑的艺人信息预热进来（每张一次极小请求），长按时直接命中缓存。
   */
  private static albumArtistCache: Map<string, AppleArtist> = new Map();

  /**
   * 取某张专辑的主艺人（一次请求，带缓存）。
   *
   * @param albumId 目录专辑 id
   * @returns 目录艺人；取不到时返回 null
   */
  public static async albumArtistOf(albumId: string): Promise<AppleArtist | null> {
    if (albumId === '') {
      return null;
    }
    const hit: AppleArtist | undefined = CatalogFillService.albumArtistCache.get(albumId);
    if (hit !== undefined) {
      return hit;
    }
    const artist: AppleArtist | null = await AppleApi.catalogAlbumArtist(albumId);
    if (artist !== null) {
      CatalogFillService.albumArtistCache.set(albumId, artist);
    }
    return artist;
  }

  /**
   * 后台预热前 limit 张专辑的艺人信息（顺序请求，进不去就跳过）。
   *
   * @param works 当前搜索结果的专辑列表
   * @param limit 最多预热几张
   */
  public static warmAlbumArtists(works: CatalogAlbumOffer[], limit: number): void {
    CatalogFillService.warmAlbumArtistsInner(works, limit).catch((): void => {
    });
  }

  private static async warmAlbumArtistsInner(works: CatalogAlbumOffer[], limit: number): Promise<void> {
    const count: number = works.length < limit ? works.length : limit;
    for (let i = 0; i < count; i++) {
      const id: string = works[i].id;
      if (id === '' || CatalogFillService.albumArtistCache.has(id)) {
        continue;
      }
      await CatalogFillService.albumArtistOf(id);
    }
  }

  /**
   * 找出「资料库里有艺人条目、但一首歌都拿不到」的艺人。
   *
   * 判定方式：Apple 的 /v1/me/library/artists 列出资料库全部艺人（含上传版本），
   * 而我们的 songs 表只会有接口能返回的曲目 —— 前者有、后者没有的就是空壳艺人。
   */
  public static async listShellArtists(): Promise<ShellArtist[]> {
    const out: ShellArtist[] = [];
    try {
      // 先取「资料库专辑的艺人名」：同一批数据里，专辑接口返回的是本地化名（中文），
      // 艺人接口返回英文名，所以只按艺人名判断会把 Max Richter / Yo-Yo Ma 这类
      // 已经在库里的艺人误判成空壳，重复补专辑。用专辑侧的名字过滤掉。
      const albumArtists: Set<string> = await CatalogFillService.libraryAlbumArtistNames();
      const raw: string = await AppleApi.rawLibraryArtists(100, 0);
      const root: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined) {
        return out;
      }
      for (let i = 0; i < data.length; i++) {
        const item: Record<string, Object> = data[i] as Record<string, Object>;
        const id: string = (item['id'] as string) ?? '';
        const attrs: Record<string, Object> = (item['attributes'] as Record<string, Object>) ?? {};
        const name: string = (attrs['name'] as string) ?? '';
        if (name === '') {
          continue;
        }
        // 库里有这位艺人的曲目吗？（按名字精确匹配，接口返回的语言与我们同步时一致）
        const songs = MusicDbApi.getInstance().getSongsByArtist(name);
        if (songs.length === 0 && !albumArtists.has(name)) {
          const shell = new ShellArtist();
          shell.id = id;
          shell.name = name;
          out.push(shell);
        }
      }
      const shellNames: string[] = [];
      for (let k = 0; k < out.length; k++) {
        shellNames.push(out[k].name);
      }
      Logger.info(TAG, `shell artists=${out.length} [${shellNames.join(' ; ')}]`);
    } catch (e) {
      Logger.warn(TAG, `listShellArtists failed: ${(e as Error).message ?? ''}`);
    }
    return out;
  }

  /**
   * 查这位艺人的曲库专辑（按曲库搜索，取专辑结果）。
   * @param artistName 艺人名。
   */
  public static async listCatalogAlbums(artistName: string): Promise<CatalogAlbumOffer[]> {
    const out: CatalogAlbumOffer[] = [];
    if (artistName === '') {
      return out;
    }
    try {
      const result: AppleSearchResult = await AppleApi.search(artistName, SEARCH_LIMIT);
      const albums: AppleAlbum[] = result.albums;
      const seen: Set<string> = new Set();
      for (let i = 0; i < albums.length; i++) {
        const a: AppleAlbum = albums[i];
        if (a.id === '' || seen.has(a.id)) {
          continue;
        }
        seen.add(a.id);
        const offer = new CatalogAlbumOffer();
        offer.id = a.id;
        offer.name = a.name;
        offer.artist = a.artistName;
        offer.artworkUrl = a.artworkUrl;
        offer.trackCount = a.trackCount;
        offer.isSingle = a.isSingle;
        out.push(offer);
      }
      Logger.info(TAG, `catalog albums for ${artistName}: ${out.length}`);
    } catch (e) {
      Logger.warn(TAG, `listCatalogAlbums failed: ${(e as Error).message ?? ''}`);
    }
    return out;
  }

  /** 资料库专辑侧出现过的艺人名集合（用于排除同名不同语言造成的假阳性）。 */
  private static async libraryAlbumArtistNames(): Promise<Set<string>> {
    const names: Set<string> = new Set();
    let offset = 0;
    let guard = 0;
    try {
      while (guard < 5) {
        const raw: string = await AppleApi.rawLibraryAlbums(100, offset);
        const re = new RegExp('"artistName":"([^"]*)"', 'g');
        let m: RegExpExecArray | null = re.exec(raw);
        let count = 0;
        while (m !== null) {
          names.add(m[1]);
          m = re.exec(raw);
        }
        // 条数用 id 计数（artistName 数量≈专辑数，足够判断翻页）
        const idRe = new RegExp('"type":"library-albums"', 'g');
        let im: RegExpExecArray | null = idRe.exec(raw);
        while (im !== null) {
          count++;
          im = idRe.exec(raw);
        }
        offset += count;
        if (count < 100) {
          break;
        }
        guard++;
      }
      Logger.info(TAG, `library album artists=${names.size}`);
    } catch (e) {
      Logger.warn(TAG, `libraryAlbumArtistNames failed: ${(e as Error).message ?? ''}`);
    }
    return names;
  }

  /**
   * 一键补齐：把这几位空壳艺人的**全部曲库专辑**加入资料库。
   *
   * 流程：空壳艺人 → 目录搜索拿到曲库艺人 id → /artists/{id}/albums 分页取全部专辑
   * → 逐张 POST /v1/me/library → 返回成功加入的张数。
   *
   * @param onNote 进度回调（给设置页显示当前进度）。
   */
  public static async fillAll(onNote: (text: string) => void, onlyArtist?: string): Promise<number> {
    let artists: ShellArtist[] = await CatalogFillService.listShellArtists();
    if (onlyArtist !== undefined && onlyArtist !== '') {
      artists = artists.filter((a: ShellArtist) => a.name.indexOf(onlyArtist) >= 0);
    }
    if (artists.length === 0) {
      onNote('没有检测到需要补齐的艺人');
      return 0;
    }
    // P3（2026-09-26）：关闭“一键补齐”的自动批量入库。
    // 用户反馈「每次进艺人页都显示正在加入，且加入后并未真正入库」——即此处被自动触发。
    // 入库现只保留用户主动入口（详情页「+」、收藏艺人时的 addAllForArtist*）。
    return 0;
    // 资料库里已有的曲库专辑 id：逐个跳过，绝不重复添加（这是防误加的关键）。
    onNote('正在读取资料库已有专辑…');
    const existing: Set<string> = await AppleApi.libraryAlbumCatalogIds();
    let skipped = 0;
    let added = 0;
    let failed = 0;
    for (let i = 0; i < artists.length; i++) {
      const name: string = artists[i].name;
      onNote(`(${i + 1}/${artists.length}) 正在获取 ${name} 的专辑…`);
      const artistId: string = await CatalogFillService.catalogArtistId(name);
      if (artistId === '') {
        failed++;
        continue;
      }
      const albums: CatalogAlbumOffer[] = await CatalogFillService.catalogAlbumsOfArtist(artistId);
      onNote(`${name}：共 ${albums.length} 张专辑，开始加入…`);
      for (let k = 0; k < albums.length; k++) {
        if (existing.has(albums[k].id)) {
          skipped++;
          continue;
        }
        const ok: boolean = await AppleApi.addCatalogAlbumToLibrary(albums[k].id);
        if (ok) {
          added++;
        } else {
          failed++;
        }
        if (k % 5 === 4) {
          onNote(`${name}：已加入 ${k + 1}/${albums.length}…`);
        }
      }
    }
    onNote(`补齐完成：加入成功 ${added} 张，已在库里跳过 ${skipped} 张，失败 ${failed} 张`);
    return added;
  }

  /**
   * 查某位艺人（按名字）在目录里的全部作品。
   * 只保留「主艺人就是他本人」的条目 —— 合辑、合作专辑、客串都不算他的作品。
   */
  public static async catalogWorksByArtistName(name: string, hint?: string,
    localSongUri?: string): Promise<CatalogAlbumOffer[]> {
    // ⓪ 最优：用本地歌曲精确解析目录艺人（不依赖名字）
    if (localSongUri !== undefined && localSongUri !== '') {
      const exactId: string = await CatalogFillService.artistIdFromLocalSongUri(localSongUri);
      if (exactId !== '') {
        const exactWorks: CatalogAlbumOffer[] = await CatalogFillService.worksByArtistId(exactId, '');
        if (exactWorks.length > 0) {
          Logger.info(TAG, `works by local anchor ${name}: ${exactWorks.length} 张`);
          return exactWorks;
        }
      }
    }
    let ref: CatalogArtistRef = await CatalogFillService.catalogArtistFor(name);
    let byAlbumHint: boolean = false;
    if (ref.id === '' && hint !== undefined && hint !== '') {
      // 名字搜不到：换用该艺人的专辑名当提示词（要求专辑名精确命中）再解析一次
      ref = await CatalogFillService.catalogArtistFor(hint, true);
      byAlbumHint = ref.id !== '';
    }
    if (ref.id === '') {
      Logger.warn(TAG, `no catalog artist for ${name} (hint=${hint ?? ''})`);
      return [];
    }
    const all: CatalogAlbumOffer[] = await CatalogFillService.catalogAlbumsOfArtist(ref.id);
    // 反向校验：靠专辑名线索解析出来的艺人，其作品里必须包含那张专辑，
    // 否则说明线索对不上（会展示成别人的作品）→ 直接放弃，宁可不显示。
    if (byAlbumHint && hint !== undefined) {
      const wantAlbum: string = CatalogFillService.normalize(hint);
      let hit: boolean = false;
      for (let i = 0; i < all.length; i++) {
        if (CatalogFillService.normalize(all[i].name) === wantAlbum) {
          hit = true;
          break;
        }
      }
      if (!hit) {
        Logger.warn(TAG, `album hint not found in resolved artist, abort: ${hint}`);
        return [];
      }
    }
    // 用**目录规范名**过滤「本人主艺人」——本地名与目录名常常不同语言
    const canonical: string = ref.name !== '' ? ref.name : name;
    const lower: string = canonical.toLowerCase();
    const out: CatalogAlbumOffer[] = [];
    for (let i = 0; i < all.length; i++) {
      const a: CatalogAlbumOffer = all[i];
      if (a.artist === canonical || a.artist.toLowerCase() === lower) {
        out.push(a);
      }
    }
    Logger.info(TAG, `catalog works for ${name} (${canonical}): ${all.length} -> ${out.length}`);
    return out;
  }

  /**
   * 「单曲」判定：Apple 的 isSingle 标记并不总准（多版本 remix 单曲等常为
   * false），所以再加曲目数兜底 —— 1~2 首的条目一律算单曲，其余算专辑。
   */
  public static isSingleWork(work: CatalogAlbumOffer): boolean {
    return CatalogFillService.classifyWork(work) === 'single';
  }

  /**
   * 该作品是否已在资料库（**本地判据**：按专辑名 + 艺人能查到曲目）。
   *
   * 必须和界面卡片上显示的「已在资料库 / 未加入」用同一个判据 —— 之前这里
   * 用的是 Apple 接口返回的 catalogId 集合，两者不一致时会出现「界面显示已在库，
   * 却每次都提示要补齐、新增」的怪象。
   */
  public static inLibraryLocally(work: CatalogAlbumOffer): boolean {
    try {
      return MusicDbApi.getInstance().getSongsByAlbum(work.name, work.artist).length > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 作品三分类：'single' | 'ep' | 'album'。
   *
   * 判定顺序（名称后缀优先，因为 Apple Music 会用「- Single」「- EP」直接标注，
   * 而 isSingle 标记对多版本单曲/EP 经常不准）：
   *   ① 名称含 - Single / (Single)   → 单曲
   *   ② 名称含 - EP / (EP)           → EP
   *   ③ Apple 的 isSingle 标记        → 单曲
   *   ④ 曲目数 ≤ 2                    → 单曲
   *   ⑤ 曲目数 3~6                    → EP
   *   ⑥ 其余                          → 专辑
   */
  public static classifyWork(work: CatalogAlbumOffer): string {
    const name: string = work.name.toLowerCase();
    if (name.indexOf('- single') >= 0 || name.indexOf('(single)') >= 0 ||
      name.indexOf('– single') >= 0 || name.indexOf('— single') >= 0) {
      return 'single';
    }
    if (name.indexOf('- ep') >= 0 || name.indexOf('(ep)') >= 0 ||
      name.indexOf('– ep') >= 0 || name.indexOf('— ep') >= 0) {
      return 'ep';
    }
    if (work.isSingle) {
      return 'single';
    }
    if (work.trackCount <= 2) {
      return 'single';
    }
    if (work.trackCount <= 6) {
      return 'ep';
    }
    return 'album';
  }

  /**
   * 按**目录艺人 id** 取全部作品（搜索页用：id 来自搜索结果，精确无误，
   * 不存在「名字语言对不上」的问题）。
   */
  /**
   * 从本地歌曲 URI（apple:i.xxxx）精确解析目录艺人 id。
   * 链路：云资料库 id → 曲库 catalogId → 该曲主艺人（目录艺人 id）。
   * 全程不做名字匹配 —— 这是「中文名 vs 日文/英文名」问题的根治办法。
   */
  public static async artistIdFromLocalSongUri(uri: string): Promise<string> {
    if (uri === '' || uri.indexOf('apple:') !== 0) {
      return '';
    }
    const id: string = uri.substring('apple:'.length);
    if (id.indexOf('i.') !== 0) {
      // 已经是目录 id：直接当 catalogId 用
      return AppleApi.getCatalogSongArtistId(id);
    }
    const catalogId: string = await AppleApi.librarySongCatalogId(id);
    if (catalogId === '') {
      return '';
    }
    return AppleApi.getCatalogSongArtistId(catalogId);
  }

  public static async worksByArtistId(artistId: string, artistName: string): Promise<CatalogAlbumOffer[]> {
    const out: CatalogAlbumOffer[] = [];
    const seen: Set<string> = new Set();
    const lower: string = artistName.toLowerCase();

    // ① 先走**目录搜索**：这条链路和搜索页里能正常显示的专辑列表同源，实测可用。
    //    匹配放宽为「artistName 包含艺人名」——专辑的主艺人字段常带合作者
    //    （例如 "Max Richter, Grace Davidson, ..."）。
    if (artistName !== '') {
      try {
        const res: AppleSearchResult = await AppleApi.search(artistName, 25);
        for (let i = 0; i < res.albums.length; i++) {
          const al: AppleAlbum = res.albums[i];
          const an: string = al.artistName.toLowerCase();
          if (an === lower || an.indexOf(lower) >= 0) {
            if (al.id !== '' && !seen.has(al.id)) {
              seen.add(al.id);
              const offer = new CatalogAlbumOffer();
              offer.id = al.id;
              offer.name = al.name;
              offer.artist = al.artistName;
              offer.artworkUrl = al.artworkUrl;
              offer.trackCount = al.trackCount;
              offer.isSingle = al.isSingle;
              out.push(offer);
            }
          }
        }
      } catch (e) {
        Logger.warn(TAG, `works search failed ${artistName}: ${(e as Error).message ?? ''}`);
      }
    }

    // ② 再补 artist/{id}/albums 的分页结果（拿不到就忽略）。
    //    这条路径**不做名字过滤**：id 已经确定是这位艺人，再按名字过滤会把带
    //    合作者的专辑全部误杀（之前就是这样变成 0 张的）。
    if (artistId !== '') {
      const all: CatalogAlbumOffer[] = await CatalogFillService.catalogAlbumsOfArtist(artistId);
      for (let i = 0; i < all.length; i++) {
        if (all[i].id !== '' && !seen.has(all[i].id)) {
          seen.add(all[i].id);
          out.push(all[i]);
        }
      }
    }
    Logger.info(TAG, `worksByArtistId ${artistName} (${artistId}): ${out.length} 张`);
    return out;
  }


  /** 按目录艺人 id 把全部作品加入资料库（收藏时调用，自动去重）。 */
  public static async addAllForArtistId(artistId: string, artistName: string,
    onNote: (text: string) => void): Promise<number> {
    onNote(`正在读取《${artistName}》的目录作品…`);
    const works: CatalogAlbumOffer[] = await CatalogFillService.worksByArtistId(artistId, artistName);
    if (works.length === 0) {
      onNote(`目录里没有找到《${artistName}》的作品`);
      return 0;
    }
    onNote(`《${artistName}》共 ${works.length} 张作品，正在比对资料库…`);
    const existing: Set<string> = await AppleApi.libraryAlbumCatalogIds();
    let missing = 0;
    for (let i = 0; i < works.length; i++) {
      if (!existing.has(works[i].id) && !CatalogFillService.inLibraryLocally(works[i])) {
        missing++;
      }
    }
    if (missing === 0) {
      onNote(`《${artistName}》的全部 ${works.length} 张作品都已在资料库`);
      return 0;
    }
    onNote(`《${artistName}》需要补齐 ${missing} 张，开始加入…`);
    let added = 0;
    let skipped = 0;
    let failed = 0;
    for (let i = 0; i < works.length; i++) {
      if (existing.has(works[i].id) || CatalogFillService.inLibraryLocally(works[i])) {
        skipped++;
        continue;
      }
      const ok: boolean = await AppleApi.addCatalogAlbumToLibrary(works[i].id);
      if (ok) {
        added++;
      } else {
        failed++;
      }
      if (i % 5 === 4) {
        onNote(`《${artistName}》正在加入… ${i + 1}/${works.length}（新增 ${added}）`);
      }
    }
    if (added > 0) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 2500);
      });
    }
    onNote(`《${artistName}》完成：新增 ${added} 张，已在库 ${skipped} 张，失败 ${failed} 张`);
    return added;
  }

  /**
   * 把某位艺人的全部作品加入资料库（收藏时自动调用）。
   * @returns 实际新增张数。
   */
  public static async addAllForArtist(name: string, onNote: (text: string) => void,
    hint?: string, localSongUri?: string): Promise<number> {
    onNote(`正在读取《${name}》的目录作品…`);
    const works: CatalogAlbumOffer[] =
      await CatalogFillService.catalogWorksByArtistName(name, hint, localSongUri);
    if (works.length === 0) {
      onNote(`目录里没有找到《${name}》的作品`);
      return 0;
    }
    onNote(`《${name}》共 ${works.length} 张作品，正在比对资料库…`);
    const existing: Set<string> = await AppleApi.libraryAlbumCatalogIds();
    // 先数一遍缺多少：一张都不缺就直接收手 —— 否则每次进页面都会刷一遍
    // 「正在加入…」的进度，让用户以为在重复入库。
    let missing = 0;
    for (let i = 0; i < works.length; i++) {
      if (!existing.has(works[i].id) && !CatalogFillService.inLibraryLocally(works[i])) {
        missing++;
      }
    }
    if (missing === 0) {
      onNote(`《${name}》的全部 ${works.length} 张作品都已在资料库`);
      return 0;
    }
    onNote(`《${name}》需要补齐 ${missing} 张，开始加入…`);
    let added = 0;
    let skipped = 0;
    let failed = 0;
    for (let i = 0; i < works.length; i++) {
      if (existing.has(works[i].id) || CatalogFillService.inLibraryLocally(works[i])) {
        skipped++;
        continue;
      }
      const ok: boolean = await AppleApi.addCatalogAlbumToLibrary(works[i].id);
      if (ok) {
        added++;
      } else {
        failed++;
      }
      if (i % 5 === 4) {
        onNote(`《${name}》正在加入… ${i + 1}/${works.length}（新增 ${added}）`);
      }
    }
    if (added > 0) {
      // 给 Apple 落库留一点时间（异步受理），然后再让调用方去同步。
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 2500);
      });
    }
    onNote(`《${name}》完成：新增 ${added} 张，已在库 ${skipped} 张，失败 ${failed} 张`);
    Logger.info(TAG, `addAllForArtist ${name}: added=${added} skipped=${skipped} failed=${failed}`);
    return added;
  }

  /**
   * 按名字（或提示词）解析目录艺人。
   *
   * 兜底策略：先用名字搜艺人；搜不到就**用专辑名搜**，从命中的专辑上取
   * 主艺人名，再用那个规范名解析一次 —— 本地库里是中文名（马克思・李希特）
   * 而 Apple 目录里是英文名（Max Richter）时，靠专辑名（Sleep /
   * The Blue Notebooks）通常能命中。
   */
  /**
   * 名字归一化：去掉空格、中英文标点、中点等，只留字母数字与汉字并转小写。
   * 用于「必须精确匹配」的判定，避免把别人的作品当成这位艺人的。
   */
  private static normalize(text: string): string {
    let out: string = '';
    const lower: string = text.toLowerCase();
    for (let i = 0; i < lower.length; i++) {
      const c: string = lower.charAt(i);
      if (c === ' ' || c === '·' || c === '・' || c === '•' || c === '.' || c === ',' ||
        c === '&' || c === '-' || c === '_' || c === '(' || c === ')' || c === '/' ||
        c === '，' || c === '、' || c === '。') {
        continue;
      }
      out += c;
    }
    return out;
  }

  /**
   * 解析目录艺人。**必须精确命中**（归一化后相等）才返回 —— 以前盲取搜索
   * 结果第一位，会把名字相似的其他艺人当成他，页面就会显示别人的作品。
   *
   * 顺序：① 用名字搜艺人（要求精确匹配）→ ② 用提示词（通常是专辑名）搜，
   * 命中同名专辑后取该专辑的主艺人名，再解析一次（名字语言不同时的兜底）。
   */
  public static async catalogArtistFor(nameOrHint: string, isAlbumHint?: boolean): Promise<CatalogArtistRef> {
    const ref = new CatalogArtistRef();
    if (nameOrHint === '') {
      return ref;
    }
    const want: string = CatalogFillService.normalize(nameOrHint);
    try {
      const result: AppleSearchResult = await AppleApi.search(nameOrHint, 15);
      // ① 艺人名精确匹配
      for (let i = 0; i < result.artists.length; i++) {
        const a: AppleArtist = result.artists[i];
        if (CatalogFillService.normalize(a.name) === want) {
          ref.id = a.id;
          ref.name = a.name;
          return ref;
        }
      }
      // ② 专辑名线索：先要求专辑名精确命中，再取其主艺人
      if (isAlbumHint === true) {
        for (let i = 0; i < result.albums.length; i++) {
          const al: AppleAlbum = result.albums[i];
          if (CatalogFillService.normalize(al.name) !== want) {
            continue;
          }
          const albumArtist: string = al.artistName;
          if (albumArtist === '') {
            continue;
          }
          const again: AppleSearchResult = await AppleApi.search(albumArtist, 15);
          for (let k = 0; k < again.artists.length; k++) {
            const cand: AppleArtist = again.artists[k];
            if (CatalogFillService.normalize(cand.name) === CatalogFillService.normalize(albumArtist)) {
              ref.id = cand.id;
              ref.name = cand.name;
              Logger.info(TAG, `artist by album hint: ${nameOrHint} -> ${ref.name}`);
              return ref;
            }
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, `catalogArtistFor failed ${nameOrHint}: ${(e as Error).message ?? ''}`);
    }
    return ref;
  }

  /** 按艺人名查曲库艺人 id（取目录搜索结果里的第一位艺人）。 */
  public static async catalogArtistId(name: string): Promise<string> {
    try {
      const result: AppleSearchResult = await AppleApi.search(name, 10);
      for (let i = 0; i < result.artists.length; i++) {
        const a: AppleArtist = result.artists[i];
        if (a.name.toLowerCase() === name.toLowerCase() && a.id !== '') {
          return a.id;
        }
      }
      return result.artists.length > 0 ? result.artists[0].id : '';
    } catch (e) {
      Logger.warn(TAG, `catalogArtistId failed ${name}: ${(e as Error).message ?? ''}`);
      return '';
    }
  }

  /** 某位曲库艺人的全部专辑（分页拉全）。 */
  public static async catalogAlbumsOfArtist(artistId: string): Promise<CatalogAlbumOffer[]> {
    const out: CatalogAlbumOffer[] = [];
    const seen: Set<string> = new Set();
    let offset = 0;
    let guard = 0;
    while (guard < 5) {
      let page: AppleAlbum[] = [];
      try {
        page = await AppleApi.getCatalogArtistAlbums(artistId, 100, offset);
      } catch (e) {
        Logger.warn(TAG, `artist albums failed: ${(e as Error).message ?? ''}`);
        break;
      }
      if (page.length === 0) {
        break;
      }
      for (let i = 0; i < page.length; i++) {
        const a: AppleAlbum = page[i];
        // 全部保留：单曲也要（艺人主页要分「专辑 / 单曲」两块）。
        if (a.id === '' || seen.has(a.id)) {
          continue;
        }
        seen.add(a.id);
        const offer = new CatalogAlbumOffer();
        offer.id = a.id;
        offer.name = a.name;
        offer.artist = a.artistName;
        offer.artworkUrl = a.artworkUrl;
        offer.trackCount = a.trackCount;
        offer.isSingle = a.isSingle;
        out.push(offer);
      }
      offset += page.length;
      if (page.length < 100) {
        break;
      }
      guard++;
    }
    return out;
  }

  /**
   * 把一张曲库专辑加入资料库。
   * @param albumId 曲库专辑 id。
   * @returns 是否成功（失败时上层给用户提示）。
   */
  public static async addAlbum(albumId: string): Promise<boolean> {
    return AppleApi.addCatalogAlbumToLibrary(albumId);
  }
}
