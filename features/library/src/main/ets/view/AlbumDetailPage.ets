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

import { preferences } from '@kit.ArkData';
import { AppStorageV2, curves, LengthMetrics } from '@kit.ArkUI';
import {
  AppStorageKeys,
  MusicAppState,
  MusicDbApi,
  Logger,
  MusicSongRow,
  MusicDatabase,
  AppleSong,
  AppleApi,
  AppleAlbum,
  AlbumFavState,
  AppleLibrarySync,
  LibrarySignal,
  PlayContextKeys,
  SongApiDto,
  WindowUtil
} from 'musicbasic';
import { PlaybackHelper } from '../util/PlaybackHelper';
import { PlayerDataUtil } from 'player';
import { SongListItem, formatDuration } from './SongListItem';
import { HeroArtwork } from './HeroArtwork';
import { HeroMotion, HeroSourceRect } from '../util/HeroTransition';
import { SongListDataSource } from '../model/ListDataSources';
import { AlbumDetailParam } from '../util/PlaybackHelper';
import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions,
  ScrollEffectType, TitleBarContentOptions, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';

/** 日志标签。 */
const TAG: string = 'AlbumDetail';

/**
 * Album detail, rebuilt exactly per the official HdsNavigation guide:
 * HdsNavDestination + titleBar GRADIENT_BLUR + bindToScrollable + a
 * Blank(138) content inset under the title bar.
 */
@ComponentV2
export struct AlbumDetailPage {
  /** Album-tab stack: used when pushed from the Albums tab. */
  @Consumer('albumNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  /** Artist-tab stack: used when pushed from the artist detail page. */
  @Consumer('artistNavStack') artistPageIndexInfos: NavPathStack = new NavPathStack();
  /** 搜索板块的导航栈：从搜索页推入时，返回要 pop 这个栈。 */
  @Consumer('searchNavStack') searchPageIndexInfos: NavPathStack = new NavPathStack();
  @Param albumName: string = '';
  @Param artistName: string = '';
  /** geometryTransition id matching the tapped album cover. */
  @Param heroId: string = '';
  /** Window-space snapshot of the tapped cover (growth anchor). */
  @Param sourceRect: HeroSourceRect = new HeroSourceRect();
  /** True when this page lives on the artist tab's navigation stack. */
  @Param fromArtistDetail: boolean = false;
  /** True when this page was pushed from the search tab. */
  @Param fromSearch: boolean = false;
  /** 目录专辑 id：专辑未加入资料库时用它现拉曲目（直接试听，不写入资料库）。 */
  @Param catalogAlbumId: string = '';
  /**
   * 资料库专辑 id（`l.xxxx`）：从「收藏的专辑」卡片点进来时带上，
   * 本地没有这张专辑的曲目时直接按 id 拉，不做名字匹配。
   */
  @Param libraryAlbumId: string = '';
  /**
   * 目录封面 URL：曲目还在路上时先用它撑住大图与毛玻璃背景
   * （否则推入瞬间是渐变占位图 +「0 首」= 用户说的「闪一下默认页面」）。
   */
  @Param coverUrl: string = '';

  @Local songs: SongApiDto[] = [];
  /** Local DB rows held back until the playability filter resolves
   *  (prevents showing unavailable tracks first and shrinking a second later). */
  private pendingLocalSongs: SongApiDto[] = [];
  /** 本页曲目是否来自 Apple 目录兜底（不在 songs 表里）。
   *  这种情况点击必须走内存队列（PlaybackHelper.playSongList），
   *  因为按专辑名+艺人去本地库查行是查不到的。 */
  @Local fromCatalog: boolean = false;
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** Page scroller bound to the HDS title bar (blur sync). */
  private scroller: Scroller = new Scroller();
  /** Lazy data source for the track list (official optimization). */
  private songDataSource: SongListDataSource = new SongListDataSource();
  /** Play-all button press scale driven by the official spring curve. */
  @Local playAllScale: number = 1;
  /** Detail hero's measured window center (growth anchor target). */
  private targetCenterY: number = 0;
  /** True once the hero position has been measured. */
  private measured: boolean = false;
  /** Initial offset from the tapped cover to the hero's final position. */
  @Local growDy: number = 0;
  /** Play button growth states (start inside the tapped cover). */
  @Local buttonDy: number = 0;
  @Local buttonOpacity: number = 0;
  @Local buttonScale: number = 0.96;
  /** Song list growth states. */
  @Local listDy: number = 0;
  @Local listOpacity: number = 0;
  /** Ignores repeated back presses while the pop transition runs. */
  @Local isExiting: boolean = false;
  /**
   * 「继续播放」进度：上次停在这张专辑的哪一首（空串 = 这张还没听过）。
   * 黄色按钮据此启用 / 置灰，曲目列表据此把那一首标黄。
   */
  @Local resumeUri: string = '';
  /** 黄色按钮的按压缩放（官方 spring）。 */
  @Local resumeScale: number = 1;
  /** 「加入资料库」按钮的按压缩放（与播放/继续同款）。 */
  @Local addScale: number = 1;
  /** Apple Music 里这张专辑是否已收藏（⭐）；心形按钮的实心/空心由它决定。 */
  @Local isFavorite: boolean = false;
  /** 是否已经拿到收藏状态（没拿到前不渲染心形，避免先闪一个错误状态）。 */
  @Local favReady: boolean = false;
  /** 心形按钮的按压缩放（与其它圆形按钮同款）。 */
  @Local favScale: number = 1;
  /** 收藏写入进行中：避免连点产生互相矛盾的写请求。 */
  private favBusy: boolean = false;
  /** 该专辑在 Apple 目录里的 id（未入库专辑播放与加号都用它）。 */
  @Local catalogId: string = '';
  /** 是否已在 Apple 资料库里（已入库则不显示加号）。 */
  @Local inLibrary: boolean = false;

  /** Chooses the navigation stack this page was actually pushed onto. */
  private activeStack(): NavPathStack {
    if (this.fromSearch) {
      return this.searchPageIndexInfos;
    }
    return this.fromArtistDetail ? this.artistPageIndexInfos : this.pageIndexInfos;
  }

  aboutToAppear(): void {
    this.appState.detailPageDepth += 1;
    this.songs = MusicDbApi.getInstance().getSongsByAlbum(this.albumName, this.artistName);
    this.songs = this.dedupeSongs(this.songs);
    // 「是否已在资料库」「是否已收藏」都在首帧之前**同步**定下来：
    // 本地曲目表 + 已落盘的收藏缓存就够用了，网络结果只用来校准。
    // 否则按钮区会先出「播放/继续」，过一会儿才补上「加号/心形」（用户反馈：体感差）。
    this.resolveInLibrarySync();
    this.applyCachedFavorite();
    this.songDataSource.setRows(this.songs);
    // 先用缓存同步过滤（打开过一次的专辑：零等待、零闪动）
    if (!this.applyCachedPlayable()) {
      this.filterUnplayableLocal();
    }
    // 本地没有这张专辑的曲目 -> 从 Apple（资料库/目录）拉取，避免空白页
    if (this.songs.length === 0) {
      this.loadCatalogTracks();
    } else {
      this.fromCatalog = false;
    }
    this.songDataSource.setRows(this.songs);
    this.refreshResume();
    // 本地一首都没有 + 有目录专辑 id：说明这张专辑还没加入资料库。
    // 直接拉目录曲目落库（folder=apple_catalog，与非资料库曲目同一套播放链路），
    // 于是「点封面进详情页就能看曲目并试听」，不需要先点加号入库。
    // 注意：从收藏卡片进来时带了资料库专辑 id，上一步的 loadCatalogTracks()
    // 已经按 id 拉过曲目，这里不要再走目录搜索兜底（否则会重复请求、甚至拉错版本）。
    if (this.songs.length === 0 && this.libraryAlbumId === '' && this.catalogAlbumId === '') {
      this.resolveAndLoadCatalogTracks();
    }
    // 用网络校准收藏状态（心形按钮）
    this.resolveFavoriteState();
  }

  /**
   * 同步判定这张专辑是否已经在 Apple Music 资料库里（决定要不要显示「加入资料库」加号）。
   *
   * 两个可靠信号，都是本地就能拿到的：
   *   1. 从「收藏的专辑」卡片进来 ⇒ 带了资料库专辑 id ⇒ 一定在资料库里；
   *   2. 本地曲目表里这张专辑有 **资料库来源**（`is_library=1`）的曲目 ⇒ 也在资料库里
   *      （只有从目录现拉的试听曲目才是 `apple_catalog`/is_library=0，那种才算没入库）。
   */
  private resolveInLibrarySync(): void {
    if (this.libraryAlbumId !== '') {
      this.inLibrary = true;
      return;
    }
    try {
      const rows: MusicSongRow[] =
        MusicDatabase.getInstance().getSongsByAlbum(this.albumName, this.artistName);
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].isLibrary) {
          this.inLibrary = true;
          return;
        }
      }
    } catch (e) {
    }
    this.inLibrary = false;
  }

  /**
   * 同步读收藏状态：先看本地已落盘的收藏列表（上一次同步的结果），
   * 保证心形按钮首帧就在、状态也不会来回跳；网络结果回来后再校准。
   */
  private applyCachedFavorite(): void {
    this.favReady = true;
    if (this.libraryAlbumId !== '') {
      // 从「收藏的专辑」卡片进来，必然是「已收藏」
      this.isFavorite = true;
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync('apple_fav_albums_v1', '') as string;
      if (txt === '') {
        return;
      }
      const arr: AppleAlbum[] = JSON.parse(txt) as AppleAlbum[];
      const wantName: string = this.normAlbumName(this.albumName);
      const wantArtist: string = this.artistName.toLowerCase().trim();
      for (let i = 0; i < arr.length; i++) {
        const hitName: boolean = this.normAlbumName(arr[i].name) === wantName;
        if (!hitName) {
          continue;
        }
        if (arr[i].artistName.toLowerCase().trim() === wantArtist) {
          this.isFavorite = true;
          return;
        }
      }
    } catch (e) {
    }
  }

  /**
   * 读这张专辑在 Apple Music 里的收藏状态（⭐）+ 补齐目录 id。
   *
   *  - 有资料库专辑 id（从「收藏的专辑」卡片进来）：一次请求同时拿目录 id 与 inFavorites；
   *  - 否则（本地/搜索进来）：按专辑名搜目录拿目录 id，再读目录资源上的 inFavorites。
   */
  private async resolveFavoriteState(): Promise<void> {
    try {
      if (this.libraryAlbumId !== '') {
        const st: AlbumFavState = await AppleApi.getLibraryAlbumFavState(this.libraryAlbumId);
        if (st.catalogId !== '' && this.catalogId === '') {
          this.catalogId = st.catalogId;
        }
        this.isFavorite = st.inFavorites;
        this.favReady = true;
        return;
      }
      if (this.catalogId === '') {
        const found: AppleAlbum[] = await AppleApi.searchAlbumsOnly(this.albumName, 10);
        let picked: string = '';
        const wantName: string = this.normAlbumName(this.albumName);
        const wantArtist: string = this.artistName.toLowerCase().trim();
        for (let i = 0; i < found.length; i++) {
          if (this.normAlbumName(found[i].name) === wantName
            && found[i].artistName.toLowerCase().trim() === wantArtist) {
            picked = found[i].id;
            break;
          }
        }
        if (picked === '' && found.length > 0) {
          picked = found[0].id;
        }
        if (picked === '') {
          return;
        }
        this.catalogId = picked;
      }
      this.isFavorite = await AppleApi.getCatalogAlbumInFavorites(this.catalogId);
      this.favReady = true;
    } catch (e) {
      Logger.warn(TAG, '读收藏状态失败：' + ((e as Error).message ?? ''));
    }
  }

  /**
   * 点心形：收藏 / 取消收藏（**写进 Apple Music 自己的资料库**，不只是本机显示）。
   *
   * Apple 侧写入约 6 秒后才会在两边的读取里体现（真机实测），所以这里先做
   * 乐观更新把心形切过去，写入成功后等 7 秒再拉一次收藏列表：刷新本地缓存
   * （专辑页顶部「收藏的专辑」用的就是它）并广播信号通知各页面。
   */
  private toggleFavorite(): void {
    if (this.favBusy || this.catalogId === '') {
      return;
    }
    this.favBusy = true;
    const want: boolean = !this.isFavorite;
    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
      this.isFavorite = want;
    });
    AppleApi.setAlbumFavorite(this.catalogId, want).then((ok: boolean) => {
      this.favBusy = false;
      if (!ok) {
        // 写入失败：把心形回滚，避免显示成"已改"其实没改
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.isFavorite = !want;
        });
        return;
      }
      setTimeout(() => {
        AppleLibrarySync.syncFavorites(true).then(() => {
          LibrarySignal.notifyChanged();
        }).catch(() => {
        });
      }, 7000);
    }).catch(() => {
      this.favBusy = false;
      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
        this.isFavorite = !want;
      });
    });
  }

  /** 先拿目录专辑 id（参数没带就按专辑名搜目录），再拉曲目落库。 */
  private async resolveAndLoadCatalogTracks(): Promise<void> {
    let albumId: string = this.catalogAlbumId;
    if (albumId === '') {
      try {
        const found: AppleAlbum[] = await AppleApi.searchAlbumsOnly(this.albumName, 10);
        // 记录目录 id，并判断这张专辑是否已在 Apple 资料库中（决定是否显示加号）
        if (found.length > 0) {
          const hit: AppleAlbum = found[0];
          this.catalogId = hit.id;
          const libPage = await AppleApi.getLibraryAlbums(100, 0);
          for (let i = 0; i < libPage.items.length; i++) {
            const it: AppleAlbum = libPage.items[i];
            if (it.name.toLowerCase() === this.albumName.toLowerCase() &&
              it.artistName.toLowerCase() === hit.artistName.toLowerCase()) {
              this.inLibrary = true;
              break;
            }
          }
        }
        const want: string = this.albumName.replace(' ', '').toLowerCase();
        for (let i = 0; i < found.length; i++) {
          if (found[i].name.replace(' ', '').toLowerCase() === want) {
            albumId = found[i].id;
            break;
          }
        }
        if (albumId === '' && found.length > 0) {
          albumId = found[0].id;
        }
        Logger.info(TAG, 'resolved catalog album id=' + albumId + ' for ' + this.albumName);
      } catch (e) {
        Logger.warn(TAG, 'resolve catalog album failed: ' + ((e as Error).message ?? ''));
        return;
      }
    }
    await this.loadCatalogTracksById(albumId);
  }

  /** 拉目录曲目并落库，然后刷新列表。 */
  private async loadCatalogTracks(): Promise<void> {
    // 不依赖任何前置条件：先按专辑名在资料库专辑里找（收藏专辑必来自这里），
    // 找不到再在 Apple 目录里找；然后用 getAlbumTracks 拉曲目并渲染成本页列表。
    // 这些曲目只在本页展示/播放，不写入 songs 表（不污染「全部歌曲」）。
    let libraryId: string = '';
    let catalogId: string = this.catalogAlbumId;
    const want: string = this.normAlbumName(this.albumName);
    const wantArtist: string = this.artistName.toLowerCase().trim();
    // 收藏专辑卡片会把资料库专辑 id 直接带进来（最可靠：不依赖任何名称匹配）
    if (this.libraryAlbumId !== '') {
      libraryId = this.libraryAlbumId;
    }
    try {
      if (libraryId === '') {
        const page = await AppleApi.getLibraryAlbums(100, 0);
        let nameOnly: string = '';
        for (let i = 0; i < page.items.length; i++) {
          const a: AppleAlbum = page.items[i];
          if (this.normAlbumName(a.name) !== want) {
            continue;
          }
          if (a.artistName.toLowerCase().trim() === wantArtist) {
            libraryId = a.id;
            break;
          }
          if (nameOnly === '') {
            nameOnly = a.id;
          }
        }
        if (libraryId === '' && nameOnly !== '') {
          libraryId = nameOnly;
        }
      }
    } catch (e) {
    }
    if (libraryId === '' && catalogId === '') {
      try {
        const found: AppleAlbum[] = await AppleApi.searchAlbumsOnly(this.albumName, 10);
        Logger.info(TAG, `FAVDBG catalog search '${this.albumName}' hits=${found.length}`);
        // 同名可能有多个版本/合辑：优先取「艺人名一致」的那一条，
        // 否则会取到曲目数不对的版本（用户遇到：4 首的专辑显示成 8 首）。
        const wantArtist: string = this.artistName.toLowerCase().trim();
        let picked: string = '';
        for (let i = 0; i < found.length; i++) {
          if (this.normAlbumName(found[i].name) === this.normAlbumName(this.albumName)
            && found[i].artistName.toLowerCase().trim() === wantArtist) {
            picked = found[i].id;
            break;
          }
        }
        if (picked === '') {
          picked = found[0].id;
        }
        catalogId = picked;
      } catch (e) {
      }
    }
    if (libraryId === '' && catalogId === '') {
      Logger.warn(TAG, `FAVDBG no id for '${this.albumName}'`);
      return;
    }
    try {
      const tracks: AppleSong[] = await AppleApi.getAlbumTracks(libraryId, catalogId, 100);
      Logger.info(TAG, `FAVDBG tracks lib=${libraryId} cat=${catalogId} n=${tracks.length}`);
      if (tracks.length === 0) {
        return;
      }
      const out: SongApiDto[] = [];
      // 去重：Apple 的 tracks 关系里同一首歌可能出现多条（版本/多碟），
      // 同名+同艺人只保留第一条，避免列表里出现重复项。
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < tracks.length; i++) {
        const t: AppleSong = tracks[i];
        const dedupKey: string = (t.name + '|' + t.artistName).toLowerCase();
        if (seen.has(dedupKey)) {
          continue;
        }
        seen.add(dedupKey);
        const dto = new SongApiDto();
        // id 必须唯一（列表按 id 做 key）；且必须**避开本地库的真实 id**，
        // 否则会被当成库里已有的歌、走本地播放路径并解析失败。
        // 用高位区间：既能通过 dispatch 的守卫，又一定查不到 DB 行 → 走 apple: 按源分支。
        dto.id = 900000 + i + 1;
        dto.title = t.name;
        dto.singer = t.artistName;
        dto.album = this.albumName;
        dto.duration = t.durationMs;
        dto.index = i + 1;
        // 封面：详情页头部/背景用的是 songs[0].coverPath（之前漏了，所以封面空白）
        dto.coverPath = t.artworkUrl;
        // 播放标识约定：apple:<曲目 id>（同步 Apple 歌曲时就是这条约定），
        // 写成裸 id 播放链路不认，点了不会出声。
        dto.src = 'apple:' + t.id;
        out.push(dto);
      }
      Logger.info(TAG, `FAVDBG afterDedup=${out.length}`);
      this.songs = out;
      this.fromCatalog = true;
      // 关键：列表用的是 LazyForEach(songDataSource)，只赋值 this.songs 是看不见的
      this.songDataSource.setRows(this.songs);
    } catch (e) {
      Logger.warn(TAG, `FAVDBG tracks failed: ${(e as Error).message ?? ''}`);
    }
  }

  /** 按指定目录专辑 id 拉曲目并落库。 */
  private async loadCatalogTracksById(albumId: string): Promise<void> {
    try {
      const tracks: AppleSong[] = await AppleApi.getCatalogAlbumTracks(albumId);
      if (tracks.length === 0) {
        return;
      }
      const rows: MusicSongRow[] = [];
      for (let i = 0; i < tracks.length; i++) {
        const t: AppleSong = tracks[i];
        const row = new MusicSongRow();
        row.appleId = t.id;
        row.title = t.name.length > 0 ? t.name : '未知歌曲';
        row.artist = t.artistName.length > 0 ? t.artistName : this.artistName;
        row.album = t.albumName.length > 0 ? t.albumName : this.albumName;
        row.duration = t.durationMs;
        row.year = t.year;
        row.uri = 'apple:' + t.id;
        row.coverPath = t.artworkUrl;
        row.coverUrl = t.artworkUrl;
        row.trackNumber = t.trackNumber;
        row.folder = 'apple_catalog';
        row.isLibrary = false;
        rows.push(row);
      }
      await MusicDatabase.getInstance().ensureSongs(rows);
      this.songs = MusicDbApi.getInstance().getSongsByAlbum(this.albumName, this.artistName);
    this.songs = this.dedupeSongs(this.songs);
    this.songDataSource.setRows(this.songs);
    // 先用缓存同步过滤（打开过一次的专辑：零等待、零闪动）
    if (!this.applyCachedPlayable()) {
      this.filterUnplayableLocal();
    }
    // 本地没有这张专辑的曲目 -> 从 Apple（资料库/目录）拉取，避免空白页
    if (this.songs.length === 0) {
      this.loadCatalogTracks();
    } else {
      this.fromCatalog = false;
    }
      if (this.songs.length === 0) {
        // 目录里的专辑名/艺人名与传入参数不完全一致时，退回按曲目 uri 组装
        const out: SongApiDto[] = [];
        for (let i = 0; i < rows.length; i++) {
          const dto = MusicDbApi.getInstance().getSongByUri(rows[i].uri);
          if (dto !== undefined) {
            out.push(dto);
          }
        }
        this.songs = out;
      }
      this.songDataSource.setRows(this.songs);
      Logger.info(TAG, `catalog tracks loaded: ${this.songs.length}`);
    } catch (e) {
      Logger.warn(TAG, `loadCatalogTracks failed: ${(e as Error).message ?? ''}`);
    }
  }

  /** 读取这张专辑的「继续播放」进度（黄键可用性 + 曲目黄标）。 */
  private refreshResume(): void {
    this.resumeUri = PlaybackHelper.resumeSongUri(
      PlaybackHelper.albumKey(this.albumName, this.artistName));
  }

  /** 黄色按钮：回到上次停下的那一首与位置。 */
  private continueAlbum(): void {
    if (this.resumeUri === '') {
      return;
    }
    // 传当前列表：续播的队列/索引与 playAt 完全一致（含目录专辑的临时曲目）。
    PlaybackHelper.resumeAlbum(this.albumName, this.artistName, this.songs);
  }

  aboutToDisappear(): void {
    if (this.appState.detailPageDepth > 0) {
      this.appState.detailPageDepth -= 1;
    }
  }

  /** Measures the detail hero and starts the staggered grow-in. */
  private onHeroMeasured(area: Area): void {
    if (this.measured) {
      return;
    }
    this.measured = true;
    const y = area.globalPosition.y !== undefined
      ? Number.parseFloat(area.globalPosition.y.toString())
      : 0;
    const height = Number.parseFloat(area.height.toString());
    this.targetCenterY = y + height / 2;
    // Missing/invalid route snapshot (e.g. unexpected deep link): fall back
    // to a plain fade-in instead of flying content from a bogus position.
    this.growDy = this.sourceRect.width > 0 && this.sourceRect.height > 0
      ? this.sourceRect.centerY() - this.targetCenterY
      : 0;
    this.buttonDy = this.growDy;
    this.listDy = this.growDy;
    setTimeout(() => {
      if (this.isExiting) {
        return;
      }
      this.getUIContext().animateTo({
        duration: HeroMotion.ENTER_MS,
        curve: curves.springMotion(0.45, 0.75, 0.1)
      }, () => {
        this.buttonDy = 0;
        this.buttonOpacity = 1;
        this.buttonScale = 1;
      });
    }, HeroMotion.BUTTON_DELAY_MS);
    setTimeout(() => {
      if (this.isExiting) {
        return;
      }
      this.getUIContext().animateTo({
        duration: HeroMotion.ENTER_MS,
        curve: curves.springMotion(0.45, 0.75, 0.1)
      }, () => {
        this.listDy = 0;
        this.listOpacity = 1;
      });
    }, HeroMotion.BODY_DELAY_MS);
  }

  /**
   * Shared-element return: content shrinks back toward the tapped cover
   * while the artwork flies back via geometryTransition. pop(false) keeps
   * the system default transition off, per the official recipe.
   */
  private animatedBack(): boolean {
    if (this.isExiting) {
      return true;
    }
    this.isExiting = true;
    this.getUIContext().animateTo({
      duration: HeroMotion.EXIT_MS,
      curve: Curve.Friction
    }, () => {
      this.buttonDy = this.growDy;
      this.buttonOpacity = 0;
      this.buttonScale = 0.96;
      this.listDy = this.growDy;
      this.listOpacity = 0;
      this.activeStack().pop(false);
    });
    return true;
  }

  /**
   * 标题栏副标题：曲目还没到时显示「正在读取曲目…」，避免先闪一眼「0 首」
   * （搜索页点封面进来、目录曲目还在拉取的那一瞬间）。
   */
  private subtitleText(): string {
    if (this.songs.length === 0) {
      return this.catalogAlbumId !== '' || this.coverUrl !== ''
        ? `${this.artistName} · 正在读取曲目…`
        : `${this.artistName} · 暂无曲目`;
    }
    return `${this.artistName} · ${this.songs.length} 首 · ${formatDuration(this.totalDuration())}`;
  }

  /**
   * 播放整张专辑（从第一首开始）。
   *
   * **必须带上专辑上下文**：队列来源决定了「继续播放」进度记在谁身上
   * （`PlayContextKeys.progressKey`）。原先这里没传 context，播放上下文
   * 退化成 library，`saveContextProgress()` 直接跳过 —— 于是专辑永远不记进度、
   * 下次进来也没有黄色「继续播放」（用户反馈的「专辑历史不生效、歌单正常」，
   * 歌单一直都有传 context）。顺带：本页的播放队列仍是「当前显示的列表」，
   * 与界面高亮一致。
   */
  private playAlbumAll(): void {
    PlaybackHelper.playSongList(this.songs, 0, true,
      PlayContextKeys.albumContext(this.albumName, this.artistName));
  }

  /** Plays the tapped track; the album is the queue. */
  private playAt(index: number): void {
    // 一律用「当前显示的列表」播放：本页的列表可能被去重/可播过滤裁剪过，
    // 若仍按"专辑名+艺人去库里查行"，索引会错位 —— 表现为点歌不播、当前曲目不高亮。
    PlaybackHelper.playSongList(this.songs, index, true,
      PlayContextKeys.albumContext(this.albumName, this.artistName));
  }

  /**
   * Title bar with the official GRADIENT_BLUR (same tuned profile as the
   * artist detail: transparent plates, 56vp mask spread, blur radius 16).
   * The floating header lives inside the title bar, so it always stays
   * readable above the blur mask.
   */
  private titleBarOptions(): HdsNavigationTitleBarOptions {
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(72)
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
          maskExtraHeight: 88,
          blurRadius: 16
        }
      }
    };
    const content: TitleBarContentOptions = {
      // Official HDS title bar structure: system back button (built-in
      // press/highlight feedback) + main title over subtitle, with the
      // official dynamic color behavior under GRADIENT_BLUR.
      title: {
        mainTitle: this.albumName,
        subTitle: this.subtitleText()
      },
      backIcon: {
        icon: $r('sys.symbol.chevron_left'),
        action: (): void => {
          this.animatedBack();
        }
      }
    };
    // avoidLayoutSafeArea: the official flag that makes the title bar
    // actively dodge the system safe area (status bar + camera cutout on
    // hole-punch screens like Mate 60 Pro).
    return { enableComponentSafeArea: true, avoidLayoutSafeArea: true, style: style, content: content };
  }

  /** 点加号：加入资料库（成功后就地隐藏按钮 + 通知各页刷新）。 */
  private async addToLibraryNow(): Promise<void> {
    // 目录 id 可能还没解析出来（刚进页面就点）：先补一次，再入库，避免点了没反应。
    if (this.catalogId === '') {
      try {
        const found: AppleAlbum[] = await AppleApi.searchAlbumsOnly(this.albumName, 10);
        const wantName: string = this.normAlbumName(this.albumName);
        const wantArtist: string = this.artistName.toLowerCase().trim();
        for (let i = 0; i < found.length; i++) {
          if (this.normAlbumName(found[i].name) === wantName
            && found[i].artistName.toLowerCase().trim() === wantArtist) {
            this.catalogId = found[i].id;
            break;
          }
        }
        if (this.catalogId === '' && found.length > 0) {
          this.catalogId = found[0].id;
        }
      } catch (e) {
      }
    }
    if (this.catalogId === '') {
      return;
    }
    AppleApi.addAlbumToLibrary(this.catalogId).then((ok: boolean) => {
      if (ok) {
        this.inLibrary = true;
      }
    }).catch((e: Error) => {
      Logger.warn(TAG, '入库失败: ' + (e.message ?? ''));
    });
  }

  /** Normalize album name: strip common Apple release suffixes for cross-entry matching. */
  private normAlbumName(name: string): string {
    let t: string = name.toLowerCase().trim();
    const suffixes: string[] = [' - ep', ' - single', ' - deluxe', ' (deluxe)', ' - deluxe edition',
      ' (ep)', ' (single)', ' - complete', ' (complete)'];
    for (let i = 0; i < suffixes.length; i++) {
      if (t.endsWith(suffixes[i])) {
        t = t.substring(0, t.length - suffixes[i].length).trim();
      }
    }
    return t;
  }

  /**
   * Keep only tracks that are playable in the current storefront.
   * Tracks come from the local DB; we intersect them with the album playable tracks
   * fetched from Apple (getAlbumTracks filters by attributes.playParams).
   * Runs only on the display list - the database is never modified.
   */
  private filterUnplayableLocal(): void {
    Logger.info(TAG, `ALBFILTER enter local=${this.songs.length} name=${this.albumName} artist=${this.artistName}`);
    if (this.songs.length === 0) {
      return;
    }
    const want: string = this.normAlbumName(this.albumName);
    const wantArtist: string = this.artistName.toLowerCase().trim();
    // 1) 先在资料库专辑里找（最多 200 张；找不到不代表不在库里）
    AppleApi.getLibraryAlbums(100, 0).then((page) => {
      let libId: string = '';
      for (let i = 0; i < page.items.length; i++) {
        const a = page.items[i];
        if (this.normAlbumName(a.name) === want && a.artistName.toLowerCase().trim() === wantArtist) {
          libId = a.id;
          break;
        }
      }
      if (libId !== '') {
        this.applyPlayableFilter(libId, '');
        return;
      }
      // 2) 回退：按专辑名搜目录，取「名字+艺人」一致的一条
      AppleApi.searchAlbumsOnly(this.albumName, 10).then((found: AppleAlbum[]) => {
        let catId: string = '';
        for (let i = 0; i < found.length; i++) {
          if (this.normAlbumName(found[i].name) === want
            && found[i].artistName.toLowerCase().trim() === wantArtist) {
            catId = found[i].id;
            break;
          }
        }
        if (catId === '' && found.length > 0) {
          catId = found[0].id;
        }
        if (catId !== '') {
          this.applyPlayableFilter('', catId);
        } else {
          Logger.info(TAG, 'ALBFILTER no catalog id');
        }
      }).catch((e: Error) => {
        Logger.warn(TAG, 'ALBFILTER search failed: ' + (e.message ?? ''));
      });
    }).catch((e: Error) => {
      Logger.warn(TAG, 'ALBFILTER libraryAlbums failed: ' + (e.message ?? ''));
    });
  }

  /** Intersect the local list with the album playable tracks fetched from Apple. */
  private applyPlayableFilter(libraryId: string, catalogId: string): void {
    AppleApi.getAlbumTracks(libraryId, catalogId, 100).then((tracks: AppleSong[]) => {
      if (tracks.length === 0) {
        Logger.info(TAG, 'ALBFILTER tracks empty, keep as-is');
        return;
      }
      const keep: Set<string> = new Set<string>();
      for (let i = 0; i < tracks.length; i++) {
        keep.add((tracks[i].name + '|' + tracks[i].artistName).toLowerCase());
      }
      const out: SongApiDto[] = [];
      for (let i = 0; i < this.songs.length; i++) {
        const sd: SongApiDto = this.songs[i];
        const t: string = typeof sd.title === 'string' ? sd.title : '';
        const g: string = typeof sd.singer === 'string' ? sd.singer : '';
        if (keep.has((t + '|' + g).toLowerCase())) {
          out.push(sd);
        }
      }
      const keysArr: string[] = [];
      keep.forEach((k: string) => {
        keysArr.push(k);
      });
      this.writePlayableCache(keysArr);
      Logger.info(TAG, `ALBFILTER local=${this.songs.length} playable=${keep.size} shown=${out.length}`);
      if (out.length > 0 && out.length < this.songs.length) {
        this.songs = out;
        this.songDataSource.setRows(this.songs);
      }
    }).catch(() => {
    });
  }

  /**
   * Display-level de-duplication: the library can hold the same track twice
   * (original + remaster editions resolve to one album name), which made an
   * 11-track album render 22 rows. Keeps the first occurrence of title|singer.
   */
  private dedupeSongs(list: SongApiDto[]): SongApiDto[] {
    const seen: Set<string> = new Set<string>();
    const out: SongApiDto[] = [];
    for (let i = 0; i < list.length; i++) {
      const sd: SongApiDto = list[i];
      const t: string = typeof sd.title === 'string' ? sd.title : '';
      const g: string = typeof sd.singer === 'string' ? sd.singer : '';
      const k: string = (t + '|' + g).toLowerCase();
      if (seen.has(k)) {
        continue;
      }
      seen.add(k);
      out.push(sd);
    }
    if (out.length !== list.length) {
      Logger.info(TAG, `ALBDEDUP ${list.length} -> ${out.length}`);
    }
    return out;
  }

  /** Preferences store name for per-album playable track caches. */
  private static readonly PLAYABLE_STORE: string = 'musichome_playable';

  /** Cache key: normalized album name + artist. */
  private playableKey(): string {
    return (this.normAlbumName(this.albumName) + '|' + this.artistName.toLowerCase().trim());
  }

  /** Read the cached playable key-set ('' when not cached). */
  private readPlayableCache(): string {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return '';
      }
      const store = preferences.getPreferencesSync(ctx, { name: AlbumDetailPage.PLAYABLE_STORE });
      return store.getSync(this.playableKey(), '') as string;
    } catch (e) {
      return '';
    }
  }

  /** Persist the playable key-set (JSON array of lowercased name|artist). */
  private writePlayableCache(keys: string[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: AlbumDetailPage.PLAYABLE_STORE });
      store.putSync(this.playableKey(), JSON.stringify(keys));
      store.flush();
    } catch (e) {
    }
  }

  /**
   * Apply a cached playable set synchronously (used before the network filter),
   * so the list is correct on first paint after the album has been opened once.
   */
  private applyCachedPlayable(): boolean {
    const raw: string = this.readPlayableCache();
    if (raw === '') {
      return false;
    }
    try {
      const keys: string[] = JSON.parse(raw) as string[];
      if (keys.length === 0) {
        return false;
      }
      const keep: Set<string> = new Set<string>();
      for (let i = 0; i < keys.length; i++) {
        keep.add(keys[i]);
      }
      const out: SongApiDto[] = [];
      for (let i = 0; i < this.songs.length; i++) {
        const sd: SongApiDto = this.songs[i];
        const t: string = typeof sd.title === 'string' ? sd.title : '';
        const g: string = typeof sd.singer === 'string' ? sd.singer : '';
        if (keep.has((t + '|' + g).toLowerCase())) {
          out.push(sd);
        }
      }
      if (out.length > 0 && out.length < this.songs.length) {
        this.songs = out;
        this.songDataSource.setRows(this.songs);
        Logger.info(TAG, `ALBCACHE hit ${this.songs.length}`);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
        List({ space: 2, scroller: this.scroller }) {
          // Content inset under the MINI title bar (56vp): keeps the album
          // header at its tuned position while the header itself lives
          // inside the title bar.
          ListItem() {
          }.height(36)
          // Apple Music-style hero header: centered large artwork and a
          // circular play button. The artwork is the shared element; the
          // button and track list grow out of the tapped cover with a
          // staggered spring.
          ListItem() {
            Column({ space: 20 }) {
              Stack() {
                HeroArtwork({
                  coverPath: this.songs.length > 0 ? this.songs[0].coverPath : this.coverUrl,
                  seed: `${this.albumName}${this.artistName}`,
                  radius: 16,
                  heroWidth: 210,
                  heroHeight: 210,
                  heroId: this.heroId
                })
              }
              .width(210)
              .height(210)
              .onAreaChange((oldArea: Area, newArea: Area) => {
                this.onHeroMeasured(newArea);
              })
              // 两个圆形按钮：蓝色「播放全部」（从第一首）+ 黄色「继续播放」
              // （回到上次停下的那一首与位置；这张还没听过时置灰不可点）。
              Row({ space: 16 }) {
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
                    .fontSize(26)
                    .fontColor([Color.White])
                }
                .width(52)
                .height(52)
                .padding(0)
                .backgroundColor($r('app.color.library_accent'))
                .scale({ x: this.playAllScale * this.buttonScale, y: this.playAllScale * this.buttonScale })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                      this.playAllScale = 0.92;
                    });
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                      this.playAllScale = 1;
                    });
                  }
                })
                .onClick(() => {
                  this.playAlbumAll();
                })

                // 未入库才显示：加入资料库（写操作，仅点击触发；样式/动画与上面两个按钮一致）
                // 入库与否在首帧就同步判定了（见 resolveInLibrarySync），所以按钮不会迟到；
                // 目录 id 若还没解析出来，点击时会自己补一次搜索再入库。
                if (!this.inLibrary) {
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r('sys.symbol.plus'))
                      .fontSize(24)
                      .fontColor([Color.White])
                  }
                  .width(52)
                  .height(52)
                  .padding(0)
                  .backgroundColor($r('app.color.library_text_secondary'))
                  .scale({ x: this.addScale * this.buttonScale, y: this.addScale * this.buttonScale })
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.addScale = 0.92;
                      });
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.addScale = 1;
                      });
                    }
                  })
                  .onClick(() => {
                    this.addToLibraryNow();
                  })
                }

                // 收藏：心形按钮（实心=已收藏），点击写进 Apple Music 的资料库。
                // 样式/动画与艺人详情页的心形完全一致（同尺寸、同颜色、同 spring）。
                if (this.favReady) {
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
                      .fontSize(24)
                      .fontColor([this.isFavorite ? '#FF3B30' : $r('app.color.library_text_secondary')])
                  }
                  .width(52)
                  .height(52)
                  .padding(0)
                  .backgroundColor($r('app.color.library_card_bg'))
                  .scale({ x: this.favScale * this.buttonScale, y: this.favScale * this.buttonScale })
                  .translate({ y: this.buttonDy })
                  .opacity(this.buttonOpacity)
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.favScale = 0.9;
                      });
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.favScale = 1;
                      });
                    }
                  })
                  .onClick(() => {
                    this.toggleFavorite();
                  })
                }

                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.clock_arrow_2_circlepath_fill'))
                    .fontSize(24)
                    // 黄底配深色图标：官方浅色模式下白字在黄色上对比度不足。
                    .fontColor(['#FF1A1A1A'])
                }
                .width(52)
                .height(52)
                .padding(0)
                .backgroundColor($r('app.color.library_resume'))
                .enabled(this.resumeUri !== '')
                .opacity(this.resumeUri !== '' ? 1 : 0.4)
                .scale({ x: this.resumeScale * this.buttonScale, y: this.resumeScale * this.buttonScale })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                      this.resumeScale = 0.92;
                    });
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                      this.resumeScale = 1;
                    });
                  }
                })
                .onClick(() => {
                  this.continueAlbum();
                })
              }
              .translate({ y: this.buttonDy })
              .opacity(this.buttonOpacity)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ left: 16, right: 16, bottom: 18 })
          }
          // 目录曲目还在拉取时的占位行：先给出「正在读取」的反馈，而不是
          // 一片空白（搜索页点封面进来、曲目还在路上时最常见）。
          if (this.songs.length === 0 && (this.catalogAlbumId !== '' || this.coverUrl !== '')) {
            ListItem() {
              Row({ space: 10 }) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color($r('app.color.library_accent'))
                Text('正在读取目录曲目…')
                  .fontSize(14)
                  .fontColor($r('app.color.library_text_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 18, bottom: 18 })
              .translate({ y: this.listDy })
              .opacity(this.listOpacity)
            }
          }
          LazyForEach(this.songDataSource, (song: SongApiDto, index: number) => {
            ListItem() {
              Column() {
                // Per-row divider: skips the first row so no line sits above
                // the hero header or the first song (List-level divider also
                // drew a line above the artwork — user-visible white line).
                if (index > 0) {
                  Divider()
                    .strokeWidth(0.5)
                    .color($r('app.color.library_divider'))
                }
                SongListItem({
                  song: song,
                  isCurrent: this.appState.selectIndex === index &&
                    this.appState.playQueueIds.length === this.songs.length &&
                    this.songs[index].id === this.appState.playQueueIds[this.appState.selectIndex],
                  isPlaying: this.appState.isPlay,
                  // 上次停在这里的那首：标题黄色（用户 2026-09-12 定）。
                  isResume: this.resumeUri !== '' && song.src === this.resumeUri,
                  showCover: false,
                  onTogglePlay: (): void => {
                    PlayerDataUtil.togglePlayPause(this.appState);
                  },
                  onPlay: () => {
                    this.playAt(index);
                  }
                })
              }
              // The whole track list grows out of the tapped cover as one
              // block (no per-row stagger — keeps the animation cheap).
              .translate({ y: this.listDy })
              .opacity(this.listOpacity)
            }
          }, (song: SongApiDto, index: number) => `${song.id}-${index}`)
        }
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // No clipping + cached rows: content keeps scrolling under the
        // title bar into the GRADIENT_BLUR mask without disappearing.
        .clip(false)
        .cachedCount(3, true)
        // Bottom clearance for the floating HDS bar (52vp bar + 34vp
        // bottom margin + 4vp breathing room).
        .padding({ bottom: 90 })
      }
      .width('100%')
      .height('100%')
      }
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    // geometryTransition replaces the page transition on both enter and pop.
    .systemTransition(NavigationSystemTransitionType.NONE)
    // System back gesture / hardware back run the same shared-element pop.
    .onBackPressed((): boolean => {
      return this.animatedBack();
    })
    // Official window-mode handover: detail pages leave the immersive
    // full-screen layout so the HDS title bar (title + back icon) sits
    // below the status bar / camera cutout; returning to home restores
    // the immersive bleed-to-top layout.
    .onShown(() => {
      WindowUtil.getInstance().setImmersiveMode(false);
      this.refreshResume();
    })
    .onHidden(() => {
      WindowUtil.getInstance().setImmersiveMode(true);
    })
    // Official frosted-glass page background: the cover art blurred
    // full-bleed via generic backgroundImage + backgroundBlurStyle, so the
    // whole page (title-bar area included) reflects the cover colors.
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .backgroundImage(this.songs.length > 0 ? this.songs[0].coverPath : this.coverUrl, ImageRepeat.NoRepeat)
    .backgroundImageSize({ width: '100%', height: '100%' })
    .backgroundBlurStyle(BlurStyle.Regular, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }

  private totalDuration(): number {
    let sum = 0;
    for (let i = 0; i < this.songs.length; i++) {
      sum += this.songs[i].duration;
    }
    return sum;
  }
}


/** Global builder entry for routing to {@link AlbumDetailPage}. */
@Builder
export function AlbumDetailPageBuilder(name: string, param: Object) {
  AlbumDetailPage({
    albumName: (param as AlbumDetailParam)?.albumName ?? '',
    artistName: (param as AlbumDetailParam)?.artistName ?? '',
    heroId: (param as AlbumDetailParam)?.heroId ?? '',
    sourceRect: (param as AlbumDetailParam)?.sourceRect ?? new HeroSourceRect(),
    fromArtistDetail: (param as AlbumDetailParam)?.fromArtistDetail ?? false,
    fromSearch: (param as AlbumDetailParam)?.fromSearch ?? false,
    catalogAlbumId: (param as AlbumDetailParam)?.catalogAlbumId ?? '',
    libraryAlbumId: (param as AlbumDetailParam)?.libraryAlbumId ?? '',
    coverUrl: (param as AlbumDetailParam)?.coverUrl ?? ''
  })
}
