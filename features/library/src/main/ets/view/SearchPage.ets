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
 * 搜索板块（最右 tab）：只搜 Apple Music 目录（资料库以外的音乐）。
 *
 * 与其它四个板块保持同一套界面效果与动画（用户 2026-09-13 要求）：
 * - 整屏 UV 流光背景（官方 UV_BACKGROUND_FLOW_LIGHT），进 FlowLightRegistry
 *   统一暂停 / 恢复，切 tab 与转场时不吃渲染预算；
 * - 顶部 HDS GRADIENT_BLUR 标题栏 + 毛玻璃搜索条（按压弹簧回弹 + 点光源照亮）；
 * - 随滚动淡出的大标题（与专辑/艺人/歌曲/歌单页同款）；
 * - 固定点光源源点（按压缩放 + 弹簧跟随手指），卡片上只留受光面；
 * - 作品卡片点按 = hero 共享元素飞入专辑详情（官方 geometryTransition）；
 * - 长按封面 = 进入艺人主页（内容从被点的封面位置生长出来，返回时缩回封面）。
 *
 * 结构说明：搜索 tab 用 SearchTabShell（HdsNavigation 外壳）把 SearchPage
 * 作为第一个 NavDestination 压栈。这一步是必须的 —— geometryTransition 只在
 * 两个 NavDestination 之间生效，Navigation 的 home 内容与 NavDestination
 * 之间不会共享元素（专辑板块踩过这个坑，注释见 AlbumsPage）。
 */
import { AppStorageV2, curves, LengthMetrics } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions,
  ScrollEffectType, TitleBarContentOptions, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import {
  AlbumApiDto,
  AppStorageKeys,
  AppleAlbum,
  AppleApi,
  AppleArtist,
  AppleLibrarySync,
  AppleSearchResult,
  AppleSong,
  ArtistApiDto,
  CatalogAlbumOffer,
  CatalogFillService,
  LibrarySignal,
  Logger,
  MusicAppState,
  MusicDatabase,
  MusicDbApi,
  MusicSongRow,
  PlayContextKeys,
  SongApiDto
} from 'musicbasic';
import { MediaService } from 'player';
import { PlaybackHelper, AlbumDetailParam, ArtistDetailParam } from '../util/PlaybackHelper';
import { HeroMotion, HeroSourceRect, HeroTransitionHelper } from '../util/HeroTransition';
import { HomeBack } from '../util/HomeBack';
import { FlowLightRegistry } from '../util/FlowLightRegistry';
import { HeroArtwork } from './HeroArtwork';
import { PlayerDataUtil } from 'player';
import { SongListItem } from './SongListItem';
import { CatalogWorkCard } from './ArtistDetailPage';

/** 日志标签。 */
const TAG: string = 'SearchPage';

/** 搜索防抖（毫秒）。 */
const DEBOUNCE_MS: number = 450;

/**
 * 目录艺人行：视觉与手势与艺人板块的 ArtistRow 完全一致（毛玻璃圆形头像、
 * 官方 pressShadow、右箭头），点整行 = 进入艺人主页；头像就是共享元素。
 */
@ComponentV2
struct CatalogArtistRow {
  @Param artist: AppleArtist = new AppleArtist();
  @Event onOpen: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  /** Press state drives the official pressShadow (Button only). */
  @Local pressed: boolean = false;
  /** Latest window-space snapshot of the row (growth anchor for detail). */
  @Local rowRect: HeroSourceRect = new HeroSourceRect();

  /** 副标题：目录搜索不返回专辑/歌曲数时退化成一句说明。 */
  private subtitle(): string {
    if (this.artist.albumCount > 0 || this.artist.songCount > 0) {
      return `${this.artist.albumCount} 张专辑 · ${this.artist.songCount} 首歌曲`;
    }
    return 'Apple Music 目录艺人';
  }

  build() {
    Button() {
      Row({ space: 12 }) {
        HeroArtwork({
          coverPath: this.artist.artworkUrl,
          seed: this.artist.name,
          symbol: $r('sys.symbol.person_crop_circle_fill_1'),
          radius: 26,
          heroWidth: 52,
          heroHeight: 52,
          heroId: HeroTransitionHelper.catalogArtistHeroId(HeroTransitionHelper.SOURCE_SEARCH,
            this.artist.id, this.artist.name)
        })
        Column({ space: 2 }) {
          Text(this.artist.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.library_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.subtitle())
            .fontSize(13)
            .fontColor($r('app.color.library_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.library_text_secondary')])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }
    // Official press-shadow recipe: Button + stateEffect off + pressShadow
    // driven by touch (down → soft white blend, up/cancel → none).
    .type(ButtonType.Normal)
    .stateEffect(false)
    .backgroundColor(Color.Transparent)
    .borderRadius(0)
    .padding(0)
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pressShadow(this.pressed
        ? hdsEffect.PressShadowType.BLEND_WHITE
        : hdsEffect.PressShadowType.NONE)
      .buildEffect())
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rowRect = HeroSourceRect.fromArea(newArea);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onOpen(this.rowRect);
    })
  }
}

/** 搜索板块页面（搜索栈的第一个 NavDestination）。 */
@ComponentV2
export struct SearchPage {
  @Consumer('searchNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  @Local query: string = '';
  @Local loading: boolean = false;
  @Local searched: boolean = false;
  @Local albums: AppleAlbum[] = [];
  /** 专辑结果的行模型（与卡片/详情页统一，避免每次重建都新建对象）。 */
  @Local albumOffers: CatalogAlbumOffer[] = [];
  @Local songs: AppleSong[] = [];
  @Local artists: AppleArtist[] = [];
  @Local note: string = '';
  /** 正在加入资料库的作品 id（防重复点击）。 */
  @Local workBusyId: string = '';
  /** 随滚动淡出的大标题（与其它板块同款）。 */
  @Local titleFade: number = 1;
  /** 搜索条按压缩放（官方 spring）。 */
  @Local searchScale: number = 1;
  /** 搜索条被按下时点亮（官方点光源）。 */
  @Local searchLit: boolean = false;
  /** 固定点光源源点：跟随按下的封面（窗口坐标，不随列表滚动 → 不会抖）。 */
  @Local lightX: number = -100;
  @Local lightY: number = -100;
  @Local lightOn: boolean = false;
  /** 转场守卫：hero / 生长动画期间忽略重复点击。 */
  @Local isOpening: boolean = false;
  /** 播放器状态：给行内的「正在播放」高亮用（与其它页面同款）。 */
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** 背景流光控制器（官方 ShaderEffectController）。 */
  private scroller: Scroller = new Scroller();
  private debounceId: number = -1;
  private lastTerm: string = '';

  aboutToAppear(): void {
  }

  aboutToDisappear(): void {
  }

  /** 输入变化：防抖后搜索。 */
  private onQueryChange(value: string): void {
    this.query = value;
    if (this.debounceId !== -1) {
      clearTimeout(this.debounceId);
    }
    this.debounceId = setTimeout(() => {
      this.runSearch();
    }, DEBOUNCE_MS);
  }

  /** 执行目录搜索。 */
  private async runSearch(): Promise<void> {
    const term: string = this.query.trim();
    if (term.length === 0) {
      this.searched = false;
      this.albums = [];
      this.albumOffers = [];
      this.songs = [];
      this.artists = [];
      this.note = '';
      return;
    }
    if (term === this.lastTerm || this.loading) {
      return;
    }
    this.lastTerm = term;
    this.loading = true;
    this.note = '';
    try {
      const result: AppleSearchResult = await AppleApi.search(term, 20);
      this.albums = result.albums;
      this.songs = result.songs;
      // 艺人单独再搜一次并合并（艺人结果不会被歌曲/专辑挤掉），
      // 然后把「名称里含搜索词」的排在前面，提升命中率。
      let artists: AppleArtist[] = result.artists;
      try {
        const extra: AppleArtist[] = await AppleApi.searchArtistsOnly(term, 25);
        const seen: Set<string> = new Set();
        const merged: AppleArtist[] = [];
        for (let i = 0; i < artists.length; i++) {
          if (!seen.has(artists[i].id)) {
            seen.add(artists[i].id);
            merged.push(artists[i]);
          }
        }
        for (let i = 0; i < extra.length; i++) {
          if (!seen.has(extra[i].id)) {
            seen.add(extra[i].id);
            merged.push(extra[i]);
          }
        }
        artists = merged;
      } catch (e) {
        // 专项搜索失败就用原结果
      }
      const lower: string = term.toLowerCase();
      const hit: AppleArtist[] = [];
      const rest: AppleArtist[] = [];
      for (let i = 0; i < artists.length; i++) {
        const n: string = artists[i].name.replace(' ', '').toLowerCase();
        if (n.indexOf(lower.replace(' ', '')) >= 0) {
          hit.push(artists[i]);
        } else {
          rest.push(artists[i]);
        }
      }
      // 「你自己的资料库」桥接：目录搜索只索引规范名（方大同 → Khalil Fong 在
      // cn 商店甚至也搜不到），但资料库搜索匹配的是 Apple 返回给你的本地化元数据，
      // 中文名能命中。命中后用本地歌曲做精确锚点解析出目录艺人，放进结果最前面。
      const seenIds: Set<string> = new Set();
      for (let i = 0; i < this.artists.length; i++) {
        seenIds.add(this.artists[i].id);
      }
      try {
        const libArtists: AppleArtist[] = await AppleApi.librarySearchArtists(term);
        const bridged: AppleArtist[] = [];
        for (let i = 0; i < libArtists.length; i++) {
          const songs: SongApiDto[] = MusicDbApi.getInstance().getSongsByArtist(libArtists[i].name);
          if (songs.length === 0) {
            continue;
          }
          const catalogArtistId: string = await CatalogFillService.artistIdFromLocalSongUri(songs[0].src);
          if (catalogArtistId === '' || seenIds.has(catalogArtistId)) {
            continue;
          }
          const ca = await AppleApi.getCatalogArtist(catalogArtistId);
          if (ca === null) {
            continue;
          }
          seenIds.add(ca.id);
          bridged.push(ca);
        }
        if (bridged.length > 0) {
          hit.unshift(...bridged);
        }
      } catch (e) {
        // 桥接失败不影响目录结果
      }
      // 最宽的一条兜底：搜索词命中「你库里已有的艺人」时，直接拿他的**专辑名**
      // 去目录搜专辑（专辑索引比艺人索引宽得多），命中的专辑并入结果并置顶。
      // 这样即使艺人索引用中文名/规范名都搜不到他，也能直接看到他的作品。
      try {
        const normTerm: string = term.replace(' ', '').toLowerCase();
        const localArtists: ArtistApiDto[] = MusicDbApi.getInstance().getArtists();
        for (let i = 0; i < localArtists.length; i++) {
          const la: ArtistApiDto = localArtists[i];
          if (la.name.replace(' ', '').toLowerCase().indexOf(normTerm) < 0) {
            continue;
          }
          const localAlbums: AlbumApiDto[] = MusicDbApi.getInstance().getAlbumsByArtist(la.name);
          const extra: AppleAlbum[] = [];
          const seenAlbumId: Set<string> = new Set();
          for (let k = 0; k < this.albums.length; k++) {
            seenAlbumId.add(this.albums[k].id);
          }
          const probeCount: number = localAlbums.length < 3 ? localAlbums.length : 3;
          for (let k = 0; k < probeCount; k++) {
            const found: AppleAlbum[] = await AppleApi.searchAlbumsOnly(localAlbums[k].name, 10);
            for (let j = 0; j < found.length; j++) {
              const al: AppleAlbum = found[j];
              if (seenAlbumId.has(al.id)) {
                continue;
              }
              const an: string = al.artistName.replace(' ', '').toLowerCase();
              const want: string = la.name.replace(' ', '').toLowerCase();
              if (an.indexOf(want) >= 0) {
                seenAlbumId.add(al.id);
                extra.push(al);
              }
            }
          }
          if (extra.length > 0) {
            this.albums = extra.concat(this.albums);
            Logger.info(TAG, `album-name bridge: ${la.name} -> ${extra.length} 张`);
            break;
          }
        }
      } catch (e) {
        Logger.warn(TAG, `album bridge failed: ${(e as Error).message ?? ''}`);
      }
      this.artists = hit.concat(rest);
      const offers: CatalogAlbumOffer[] = [];
      for (let i = 0; i < this.albums.length; i++) {
        offers.push(this.albumOffer(this.albums[i]));
      }
      this.albumOffers = offers;
      // 后台预热前几张专辑的艺人信息：长按封面进艺人主页因此不用等网络。
      CatalogFillService.warmAlbumArtists(offers, 6);
      this.searched = true;
      if (this.albums.length === 0 && this.songs.length === 0 && this.artists.length === 0) {
        this.note = '没有找到相关内容';
      }
    } catch (e) {
      this.note = '搜索失败：' + ((e as Error).message ?? '');
      this.searched = true;
    }
    this.loading = false;
  }

  /** AppleAlbum（目录搜索结果）→ CatalogAlbumOffer（卡片/详情页统一数据）。 */
  private albumOffer(a: AppleAlbum): CatalogAlbumOffer {
    const offer = new CatalogAlbumOffer();
    offer.id = a.id;
    offer.name = a.name;
    offer.artist = a.artistName;
    offer.artworkUrl = a.artworkUrl;
    offer.trackCount = a.trackCount;
    offer.isSingle = a.isSingle;
    return offer;
  }

  /** AppleSong（目录）→ 行模型（与资料库曲目共用同一个行组件）。 */
  private songDto(song: AppleSong): SongApiDto {
    const dto = new SongApiDto();
    dto.title = song.name.length > 0 ? song.name : '未知歌曲';
    dto.singer = song.artistName.length > 0 ? song.artistName : '未知艺人';
    dto.album = song.albumName;
    dto.src = 'apple:' + song.id;
    dto.duration = song.durationMs;
    dto.coverPath = song.artworkUrl;
    dto.trackNumber = song.trackNumber;
    return dto;
  }

  /** 这一首是否就是当前正在播放的那首（蓝字 + 呼吸图标）。 */
  private isCurrentSong(song: AppleSong): boolean {
    const uris: string[] = this.appState.playQueueUris;
    const idx: number = this.appState.selectIndex;
    if (idx < 0 || idx >= uris.length) {
      return false;
    }
    return uris[idx] === ('apple:' + song.id);
  }

  /** 该作品是否已在资料库。 */
  private workInLibrary(work: CatalogAlbumOffer): boolean {
    return MusicDbApi.getInstance().getSongsByAlbum(work.name, work.artist).length > 0;
  }

  /** 点封面/文字：直接打开专辑详情页（不用先加入资料库，详情页会现拉目录曲目）。 */
  private openWorkDetail(work: CatalogAlbumOffer, sourceRect?: HeroSourceRect): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    const param: AlbumDetailParam = {
      albumName: work.name,
      artistName: work.artist,
      catalogAlbumId: work.id,
      // 曲目还在路上时先用目录封面撑住大图与背景，避免闪一眼空占位图
      coverUrl: work.artworkUrl,
      heroId: HeroTransitionHelper.catalogAlbumHeroId(HeroTransitionHelper.SOURCE_SEARCH, work.name, work.artist),
      sourceRect: sourceRect !== undefined ? sourceRect : new HeroSourceRect(),
      fromSearch: true
    };
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.pageIndexInfos.pushPathByName('AlbumDetail', param, false);
    });
    setTimeout(() => {
      this.isOpening = false;
    }, HeroMotion.OPEN_GUARD_MS);
  }

  /** 加号：加入资料库（已在库则打开详情）。 */
  private async addWork(work: CatalogAlbumOffer): Promise<void> {
    if (this.workInLibrary(work)) {
      this.openWorkDetail(work);
      return;
    }
    if (this.workBusyId !== '') {
      return;
    }
    this.workBusyId = work.id;
    this.note = `正在把《${work.name}》加入资料库…`;
    const ok: boolean = await AppleApi.addCatalogAlbumToLibrary(work.id);
    this.workBusyId = '';
    if (!ok) {
      this.note = '加入失败：请确认账号已登录且订阅有效';
      return;
    }
    await this.syncAfterAdd();
    this.note = `《${work.name}》已加入资料库`;
  }

  /**
   * 长按封面 → 进入艺人主页（用专辑反查目录艺人 id，不依赖名字搜索）。
   * 没有圆形头像可以做共享元素，所以用「内容从这张封面位置生长出来 /
   * 返回时缩回这张封面」的动画（艺人页本来就支持这套 sourceRect 生长动画）。
   */
  private async openArtistOfWork(work: CatalogAlbumOffer, sourceRect: HeroSourceRect): Promise<void> {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    this.note = '正在打开艺人主页…';
    // 带缓存的解析：搜索结果一回来就在后台预热过前几张，长按通常直接命中缓存
    // （不再等网络 → 长按马上有反应）。
    const catalogArtist: AppleArtist | null = await CatalogFillService.albumArtistOf(work.id);
    if (catalogArtist === null || catalogArtist.id === '') {
      this.note = '没能定位到这位艺人（Apple 未返回其艺人信息）';
      this.isOpening = false;
      return;
    }
    this.note = '';
    const param: ArtistDetailParam = {
      artistName: work.artist,
      catalogArtistId: catalogArtist.id,
      sourceRect: sourceRect,
      // 艺人页英雄区用 Apple 目录头像（取不到才退回这张专辑封面），
      // 这样长按进来与从艺人板块进来看到的是同一张头像。
      artistAvatarPath: catalogArtist.artworkUrl !== '' ? catalogArtist.artworkUrl : work.artworkUrl,
      fromSearch: true
    };
    // 必须推到**搜索栈**：这是用户当前看的 tab 的栈，切换/返回都在这条栈上。
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.pageIndexInfos.pushPathByName('ArtistDetail', param, false);
    });
    setTimeout(() => {
      this.isOpening = false;
    }, HeroMotion.OPEN_GUARD_MS);
  }

  /** 点艺人行 → 进入艺人主页（头像作为共享元素飞入，与艺人板块同款）。 */
  private openArtistOf(artist: AppleArtist, sourceRect: HeroSourceRect): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    const param: ArtistDetailParam = {
      artistName: artist.name,
      catalogArtistId: artist.id,
      heroId: HeroTransitionHelper.catalogArtistHeroId(HeroTransitionHelper.SOURCE_SEARCH, artist.id, artist.name),
      sourceRect: sourceRect,
      artistAvatarPath: artist.artworkUrl,
      fromSearch: true
    };
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.pageIndexInfos.pushPathByName('ArtistDetail', param, false);
    });
    setTimeout(() => {
      this.isOpening = false;
    }, HeroMotion.OPEN_GUARD_MS);
  }

  /** 加入后统一重新同步。 */
  private async syncAfterAdd(): Promise<void> {
    this.note = '正在同步资料库…';
    try {
      await AppleLibrarySync.syncSongs(undefined, true);
      await AppleLibrarySync.syncPlaylists();
      await AppleLibrarySync.syncAllPlaylistTracks(true);
      MediaService.getInstance().remapQueueAfterSync();
      LibrarySignal.notifyChanged();
      this.note = '';
    } catch (e) {
      this.note = '同步失败：' + ((e as Error).message ?? '');
    }
  }

  /** 播放目录歌曲（队列 = 该歌曲所在专辑）。 */
  private async playCatalogSong(song: AppleSong): Promise<void> {
    this.note = `正在准备《${song.name}》…`;
    let tracks: AppleSong[] = [];
    const albumId: string = await AppleApi.getCatalogSongAlbumId(song.id);
    if (albumId !== '') {
      tracks = await AppleApi.getCatalogAlbumTracks(albumId);
    }
    const list: AppleSong[] = tracks.length > 0 ? tracks : [song];
    const rows: MusicSongRow[] = [];
    for (let i = 0; i < list.length; i++) {
      rows.push(SearchPage.toRow(list[i]));
    }
    await MusicDatabase.getInstance().ensureSongs(rows);
    const dtos: SongApiDto[] = [];
    const uri: string = 'apple:' + song.id;
    for (let i = 0; i < rows.length; i++) {
      const dto = MusicDbApi.getInstance().getSongByUri(rows[i].uri);
      if (dto !== undefined) {
        dtos.push(dto);
      }
    }
    if (dtos.length === 0) {
      this.note = '这首歌暂时无法播放';
      return;
    }
    let index = 0;
    for (let i = 0; i < dtos.length; i++) {
      if (dtos[i].src === uri) {
        index = i;
        break;
      }
    }
    this.note = '';
    PlaybackHelper.playSongList(dtos, index, true, PlayContextKeys.searchContext());
  }

  /** AppleSong（目录）→ 本地行。 */
  private static toRow(song: AppleSong): MusicSongRow {
    const row = new MusicSongRow();
    row.appleId = song.id;
    row.title = song.name.length > 0 ? song.name : '未知歌曲';
    row.artist = song.artistName.length > 0 ? song.artistName : '未知艺人';
    row.album = song.albumName.length > 0 ? song.albumName : '未知专辑';
    row.duration = song.durationMs;
    row.year = song.year;
    row.uri = 'apple:' + song.id;
    row.coverPath = song.artworkUrl;
    row.coverUrl = song.artworkUrl;
    row.trackNumber = song.trackNumber;
    row.folder = 'apple_catalog';
    row.isLibrary = false;
    return row;
  }

  /** 标题栏：官方 GRADIENT_BLUR + 搜索框（与其它板块同款参数）。 */
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
      stackBuilder: (): void => {
        this.SearchBar()
      }
    };
    return { style: style, content: content };
  }

  /** 顶部搜索框：毛玻璃胶囊 + 按压弹簧回弹 + 点光源照亮（与其它板块一致）。 */
  @Builder
  private SearchBar() {
    Row() {
      Row() {
        Search({ placeholder: '搜索 Apple Music', value: this.query })
          .width('100%')
          .height(42)
          // Never steal the default page focus: on tab switch the system
          // focuses the page's first focusable component — the lone Search
          // would open the keyboard by itself.
          .defaultFocus(false)
          .onChange((value: string) => {
            this.onQueryChange(value);
          })
          .onSubmit((value: string) => {
            this.query = value;
            this.lastTerm = '';
            this.runSearch();
          })
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.Thin)
      }
      .width('92%')
      .height(42)
      // Rounded to match the Search capsule so the light rim is not square.
      .borderRadius(21)
      .backgroundBlurStyle(BlurStyle.Thin)
      .scale({ x: this.searchScale, y: this.searchScale })
      .visualEffect(new hdsEffect.HdsEffectBuilder()
        .pointLight({
          sourceType: this.searchLit
            ? hdsEffect.PointLightSourceType.BRIGHT
            : hdsEffect.PointLightSourceType.NONE,
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
        })
        .buildEffect())
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.searchLit = true;
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.searchScale = 0.95;
          });
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.searchLit = false;
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.searchScale = 1;
          });
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 64 })
  }

  /** Apple Music 式大标题：随滚动淡出（与其它板块同款）。 */
  @Builder
  private LibraryTitle() {
    Column({ space: 4 }) {
      Text('搜索')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(this.searched
        ? `${this.artists.length} 位艺人 · ${this.albums.length} 张专辑 · ${this.songs.length} 首歌`
        : '搜 Apple Music 目录里的艺人、专辑与歌曲')
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .opacity(this.titleFade)
  }

  /** 区块标题。 */
  @Builder
  private SectionTitle(text: string, count: number) {
    Column({ space: 4 }) {
      Text(text)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      if (count > 0) {
        Text(`${count} 项`)
          .fontSize(13)
          .fontColor($r('app.color.library_text_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 18, bottom: 10 })
  }

  /** 目录作品卡片（卡片本身与艺人页共用，作用域用搜索板块自己的）。 */
  @Builder
  private WorkCard(work: CatalogAlbumOffer) {
    CatalogWorkCard({
      work: work,
      inLibrary: this.workInLibrary(work),
      heroScope: HeroTransitionHelper.SOURCE_SEARCH,
      onOpen: (rect: HeroSourceRect): void => {
        this.openWorkDetail(work, rect);
      },
      onAdd: (): void => {
        this.addWork(work);
      },
      onOpenArtist: (rect: HeroSourceRect): void => {
        this.openArtistOfWork(work, rect);
      },
      onLightAt: (x: number, y: number): void => {
        // 弹簧跟随手指：固定光源点滑过去，避免直接赋值造成的「抽搐」。
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.lightX = x;
          this.lightY = y;
          this.lightOn = true;
        });
      },
      onLightOff: (): void => {
        this.lightOn = false;
      }
    })
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // Default-focus anchor: a transparent 1vp box that takes the page's
        // default focus instead of the search field, so switching to this tab
        // never opens the keyboard by itself (a non-input component does not
        // summon the soft keyboard when focused).
        Column()
          .width(1)
          .height(1)
          .defaultFocus(true)
        Column() {
          Scroll(this.scroller) {
            Column() {
              // 固定高度占位：**不要用 Blank** —— Blank 在主轴上会自动填充剩余空间，
              // 结果（内容少时）它会和底部那个 Blank 一起把剩余空间瓜分掉，
              // 把「搜索」大标题活活挤到屏幕 1/3 处（真机实测 297vp）。
              // 这里用固定高度的 Column，占位就是 112vp。
              // 注意：Scroll 会把「比视口短的内容」整体居中（真机 dump 实测内容
              // 从 189vp 才开始），所以这里必须用 minHeight 把内容列撑满视口，
              // 大标题才会贴顶显示。
              Column().height(96)
              this.LibraryTitle()
              if (this.loading) {
                Row({ space: 10 }) {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color($r('app.color.library_accent'))
                  Text('正在搜索…')
                    .fontSize(14)
                    .fontColor($r('app.color.library_text_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 12, bottom: 6 })
              }
              if (this.note !== '') {
                Text(this.note)
                  .fontSize(13)
                  .fontColor($r('app.color.library_text_secondary'))
                  .padding({ left: 20, right: 20, top: 8, bottom: 6 })
              }
              if (this.artists.length > 0) {
                this.SectionTitle('艺人', this.artists.length)
                ForEach(this.artists, (artist: AppleArtist) => {
                  CatalogArtistRow({
                    artist: artist,
                    onOpen: (rect: HeroSourceRect): void => {
                      this.openArtistOf(artist, rect);
                    }
                  })
                }, (artist: AppleArtist) => `ar-${artist.id}`)
              }
              if (this.albumOffers.length > 0) {
                this.SectionTitle('专辑', this.albumOffers.length)
                Grid() {
                  ForEach(this.albumOffers, (work: CatalogAlbumOffer) => {
                    GridItem() {
                      this.WorkCard(work)
                    }
                  }, (work: CatalogAlbumOffer) => `gal-${work.id}`)
                }
                .columnsTemplate('1fr 1fr')
                .columnsGap(14)
                .rowsGap(18)
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 8 })
                .scrollBar(BarState.Off)
              }
              if (this.songs.length > 0) {
                this.SectionTitle('歌曲', this.songs.length)
                ForEach(this.songs, (song: AppleSong) => {
                  SongListItem({
                    song: this.songDto(song),
                    isCurrent: this.isCurrentSong(song),
                    isPlaying: this.appState.isPlay,
                    onTogglePlay: (): void => {
                      PlayerDataUtil.togglePlayPause(this.appState);
                    },
                    onPlay: (): void => {
                      this.playCatalogSong(song);
                    }
                  })
                }, (song: AppleSong) => `so-${song.id}`)
              }
              if (!this.searched && !this.loading && this.note === '') {
                Column({ space: 10 }) {
                  SymbolGlyph($r('sys.symbol.magnifyingglass'))
                    .fontSize(56)
                    .fontColor([$r('app.color.library_text_secondary')])
                  Text('搜索 Apple Music 目录')
                    .fontSize(16)
                    .fontColor($r('app.color.library_text_primary'))
                  Text('点封面直接打开专辑页；长按封面进入艺人主页')
                    .fontSize(13)
                    .fontColor($r('app.color.library_text_secondary'))
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .padding({ top: 60, left: 40, right: 40 })
              }
              Column().height(120)
            }
            .width('100%')
            // 撑满视口：避免 Scroll 把短内容垂直居中（见上方注释）
            .constraintSize({ minHeight: '100%' })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          // Official rubber-band overscroll, same as the other tabs.
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // No clipping: content keeps scrolling under the title bar into the
          // GRADIENT_BLUR mask without disappearing.
          .clip(false)
          // Large-title fade: fully visible at top, eased out over 130vp.
          .onDidScroll((offset: number, state: ScrollState) => {
            // 滚动时让全屏流光让位（停手 220ms 自动恢复），发热降频时更顺。
            FlowLightRegistry.beginScroll();
            const y = this.scroller.currentOffset().yOffset;
            this.titleFade = Math.max(0, Math.min(1, 1 - y / 130));
          })
        }
        .width('100%')
        .height('100%')

        // Fixed point-light source overlay inside the page Stack: never
        // scrolls with the grid, so it cannot jitter; position follows the
        // pressed cover (window coords — the Stack starts at window origin).
        Column()
          .width(2)
          .height(2)
          .position({ x: this.lightX, y: this.lightY })
          .visualEffect(new hdsEffect.HdsEffectBuilder()
            .pointLight({
              sourceType: this.lightOn
                ? hdsEffect.PointLightSourceType.BRIGHT
                : hdsEffect.PointLightSourceType.NONE
            })
            .buildEffect())
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideBackButton(true)
    .hideToolBar(true)
    .bindToScrollable([this.scroller])
    // geometryTransition replaces the page transition; keep the system
    // transition off for the whole stack (see SearchTabShell).
    .systemTransition(NavigationSystemTransitionType.NONE)
    // 搜索首页也是搜索栈的第一页：返回键不能让系统把它弹掉（栈空 = 黑屏）。
    .onBackPressed((): boolean => {
      return HomeBack.handle(this.getUIContext());
    })

    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/**
 * 搜索 tab 的外壳：把搜索页作为第一个 NavDestination 压进搜索栈。
 * 这一步是 hero 共享元素的前提（geometryTransition 只在两个 NavDestination
 * 之间生效），同时整个栈禁用系统默认过场，转场全部由 hero + 生长动画驱动。
 */
@ComponentV2
export struct SearchTabShell {
  @Consumer('searchNavStack') pageIndexInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.pageIndexInfos.disableAnimation(true);
    if (this.pageIndexInfos.size() === 0) {
      this.pageIndexInfos.pushPathByName('SearchHome', undefined, false);
    }
  }

  build() {
    HdsNavigation(this.pageIndexInfos) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
    }
    .mode(NavigationMode.Stack)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideTitleBar(true)
    .hideBackButton(true)
    .hideToolBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/** Global builder entry for the search home route. */
@Builder
export function SearchHomePageBuilder(name: string, param: Object) {
  SearchPage()
}
