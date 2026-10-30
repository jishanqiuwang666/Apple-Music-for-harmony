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

import { AppStorageV2, curves, LengthMetrics } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { hdsEffect } from '@kit.UIDesignKit';
import {
  MusicAppState,
  AppStorageKeys,
  AlbumApiDto,
  AppleApi,
  AppleLibrarySync,
  ArtistFavState,
  CatalogAlbumOffer,
  CatalogFillService,
  LibrarySignal,
  Logger,
  MusicDbApi,
  SongApiDto,
  WindowUtil
} from 'musicbasic';
import { MediaService } from 'player';
import { AlbumDetailParam, ArtistDetailParam, PlaybackHelper } from '../util/PlaybackHelper';
import { formatDuration } from './SongListItem';
import { HeroArtwork } from './HeroArtwork';
import { HeroMotion, HeroSourceRect, HeroTransitionHelper } from '../util/HeroTransition';
import { AlbumListDataSource } from '../model/ListDataSources';
import { ArtistWorksCache, CachedArtistWorks } from '../util/ArtistWorksCache';
import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions,
  ScrollEffectType, TitleBarContentOptions, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';

/** 日志标签。 */
const TAG: string = 'ArtistDetail';
/**
 * 「收藏 → 自动补齐全部作品」的节流窗口（毫秒）。
 *
 * 补齐会跑「全部作品入库 + 整库同步」，非常重；以前每次进收藏艺人的主页都会跑一遍，
 * 用户感知就是「进一次转一次」。这里做会话级节流（缓存在内存里，重启 App 自然重置），
 * 6 小时等于「一次运行内每位艺人只自动补齐一次」。
 */
const FILL_THROTTLE_MS: number = 6 * 60 * 60 * 1000;

/**
 * Album card inside the artist detail: every effect lives on the cover
 * only — frosted glass (backgroundBlurStyle thickens on press), an
 * illuminated body for the parent's fixed point light (feathering rim),
 * and the official spring press-scale. The caption stays clean.
 */
@ComponentV2
export struct ArtistAlbumCard {
  @Param album: AlbumApiDto = new AlbumApiDto();
  @Event onPlay: () => void = () => {
  };
  @Event onOpenDetail: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  /** Reports the press position (window coords) to the parent light. */
  @Event onLightAt: (x: number, y: number) => void = (x: number, y: number) => {
  };
  /** Turns the parent light off on release. */
  @Event onLightOff: () => void = () => {
  };
  /** Press state thickens the glass; scale drives the spring press. */
  @Local pressed: boolean = false;
  @Local coverScale: number = 1;
  /** Latest window-space snapshot of the cover (hero source frame). */
  @Local coverRect: HeroSourceRect = new HeroSourceRect();

  build() {
    Column({ space: 8 }) {
      // Cover-only button: frosted glass + illuminated body + spring scale.
      Button() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          HeroArtwork({
            coverPath: this.album.coverPath,
            seed: `${this.album.name}${this.album.artist}`,
            radius: 10,
            fillWidth: true,
            heroId: HeroTransitionHelper.albumHeroId(HeroTransitionHelper.SOURCE_ARTIST_DETAIL, this.album)
          })
          // Direct play affordance on the album cover.
          Row() {
            SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#B3000000')
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.onPlay();
          })
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(10)
        .clip(true)
      }
      .type(ButtonType.Normal)
      .stateEffect(false)
      .backgroundColor(Color.Transparent)
      .borderRadius(10)
      .padding(0)
      .width('100%')
      .aspectRatio(1)
      .scale({ x: this.coverScale, y: this.coverScale })
      // Frosted glass on the cover; pressing thickens it.
      .backgroundBlurStyle(BlurStyle.Regular, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: this.pressed ? 1 : 0.2
      })
      // Illuminated body: lit by the parent's fixed point light.
      .visualEffect(new hdsEffect.HdsEffectBuilder()
        .pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
        })
        .buildEffect())
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.coverRect = HeroSourceRect.fromArea(newArea);
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 0.94;
          });
        } else if (event.type === TouchType.Move) {
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
          this.onLightOff();
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 1;
          });
        }
      })
      .onClick(() => {
        this.onOpenDetail(this.coverRect);
      })

      // Clean caption: no effects extend below the cover.
      Column({ space: 2 }) {
        Text(this.album.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.library_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.album.songCount} 首 · ${formatDuration(this.album.totalDuration)}`)
          .fontSize(12)
          .fontColor($r('app.color.library_text_secondary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .onClick(() => {
        this.onOpenDetail(this.coverRect);
      })
    }
    .width('100%')
  }
}

/**
 * Artist detail, rebuilt exactly per the official HdsNavigation guide:
 * HdsNavDestination + titleBar GRADIENT_BLUR + bindToScrollable + a
 * Blank(138) content inset under the title bar.
 */
@ComponentV2
export struct ArtistDetailPage {
  @Consumer('artistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  /** 搜索板块导航栈（从搜索页进入时返回用它）。 */
  @Consumer('searchNavStack') searchPageIndexInfos: NavPathStack = new NavPathStack();
  /** App 级状态：维护「详情页层数」，外壳据此隐藏顶部的同步 / 搜索圆钮。 */
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  @Param artistName: string = '';
  /** 目录艺人 id（从搜索页长按菜单进来时带）：直接按 id 取作品，不猜名字。 */
  @Param catalogArtistId: string = '';
  /** 从搜索板块推入：返回时要 pop 搜索栈。 */
  @Param fromSearch: boolean = false;
  /** geometryTransition id matching the tapped artist row portrait. */
  @Param heroId: string = '';
  /** Window-space snapshot of the tapped row (growth anchor). */
  @Param sourceRect: HeroSourceRect = new HeroSourceRect();
  /** Custom avatar already loaded by the source page (transition-friendly). */
  @Param artistAvatarPath: string = '';
  @Local albums: AlbumApiDto[] = [];
  @Local songCount: number = 0;
  /** Hero portrait path: custom picked avatar over the default cover. */
  @Local heroCoverPath: string = '';
  /** Page scroller bound to the HDS title bar (blur sync). */
  private scroller: Scroller = new Scroller();
  /** Lazy data source for the album grid (official optimization). */
  private albumDataSource: AlbumListDataSource = new AlbumListDataSource();
  /** Fixed overlay point light: position follows the pressed cover (window
   * coords). The source never scrolls with the grid, so it cannot jitter. */
  @Local lightX: number = -100;
  @Local lightY: number = -100;
  @Local lightOn: boolean = false;
  /** Play-all button press scale driven by the official spring curve. */
  @Local playAllScale: number = 1;
  /** Detail hero's measured window center (growth anchor target). */
  private targetCenterY: number = 0;
  /** True once the hero position has been measured. */
  private measured: boolean = false;
  /** Initial offset from the tapped row to the hero's final position. */
  @Local growDy: number = 0;
  /** Play button growth states (start inside the tapped row). */
  @Local buttonDy: number = 0;
  @Local buttonOpacity: number = 0;
  @Local buttonScale: number = 0.96;
  /** Album grid growth states. */
  @Local gridDy: number = 0;
  @Local gridOpacity: number = 0;
  @Local gridScale: number = 0.96;
  /** Ignores repeated back presses while the pop transition is running. */
  @Local isExiting: boolean = false;
  /** 是否已收藏这位艺人（心形按钮 + 艺人板块的收藏区）。 */
  @Local isFavorite: boolean = false;
  /** 该艺人的目录 id（写 Apple 收藏要用；由 getArtistFavState 填）。 */
  private appleArtistId: string = '';
  /** 心形按钮的按压缩放（官方 spring）。 */
  @Local favScale: number = 1;
  /** 收藏后自动入库的进度提示（空 = 无提示）。 */
  @Local worksNote: string = '';
  /** 正在加入资料库的作品 id（防重复点击）。 */
  @Local workBusyId: string = '';
  /** 目录作品是否已经读完（读完但为空要给出结论，而不是一直显示「正在读取」）。 */
  @Local worksLoaded: boolean = false;
  /**
   * 正在向 Apple 目录拉「这位艺人的全部作品」（首次进入才为 true）。
   *
   * 命中 {@link ArtistWorksCache} 时**从不为 true** —— 进过的艺人立刻出内容，
   * 不会再闪一次加载动画（用户要求「进过的不要再加载」）。
   */
  @Local worksLoading: boolean = false;
  /** 本次进入页面是否已经触发过「收藏 → 全部作品入库」。 */
  private favFillStarted: boolean = false;
  /** 目录里的全部作品（专辑 / 单曲两块，来自 Apple 目录，不限于资料库）。 */
  @Local albumWorks: CatalogAlbumOffer[] = [];
  @Local singleWorks: CatalogAlbumOffer[] = [];
  @Local epWorks: CatalogAlbumOffer[] = [];

  /**
   * 读取这位艺人在 Apple 目录里的全部作品（专辑 / EP / 单曲三块）。
   *
   * **先查缓存**：进过的艺人直接用上次的结果，一个请求都不发、也不闪加载动画；
   * 没进过的才联网拉一次，成功后写缓存（失败不写，下次还能重试）。
   * 所有艺人入口（收藏横排 / 艺人列表 / 搜索结果）都走本页，所以在这一层缓存全覆盖。
   */
  private async loadWorks(): Promise<void> {
    const cached: CachedArtistWorks | undefined = ArtistWorksCache.get(this.artistName);
    if (cached !== undefined) {
      this.applyWorks(cached);
      this.worksLoaded = true;
      Logger.info(TAG, `${this.artistName}: 作品走缓存（专辑 ${cached.albumWorks.length} 张，不联网）`);
      return;
    }
    this.worksLoading = true;
    try {
      const fetched: CachedArtistWorks = await this.fetchWorks();
      ArtistWorksCache.put(this.artistName, fetched);
      this.applyWorks(fetched);
      Logger.info(TAG, `${this.artistName}: 作品已加载并缓存（专辑 ${fetched.albumWorks.length} 张 / ` +
        `EP ${fetched.epWorks.length} 张 / 单曲 ${fetched.singleWorks.length} 首）`);
    } catch (e) {
      Logger.warn(TAG, `loadWorks failed: ${(e as Error).message ?? ''}`);
    }
    this.worksLoading = false;
    this.worksLoaded = true;
  }

  /** 真正去 Apple 目录取作品（只在没有缓存时调用），结果按分块装进缓存对象。 */
  private async fetchWorks(): Promise<CachedArtistWorks> {
    const result: CachedArtistWorks = new CachedArtistWorks();
    // 本地库里是中文名时，用他的专辑名当提示词帮助 Apple 目录定位（名字语言兜底）
    const localAlbums: AlbumApiDto[] = MusicDbApi.getInstance().getAlbumsByArtist(this.artistName);
    const hint: string = localAlbums.length > 0 ? localAlbums[0].name : '';
    if (this.catalogArtistId !== '') {
      // 精确路径：直接用目录艺人 id 取全部作品（长按菜单进入时）
      const byId: CatalogAlbumOffer[] =
        await CatalogFillService.worksByArtistId(this.catalogArtistId, this.artistName);
      for (let i = 0; i < byId.length; i++) {
        const kind: string = CatalogFillService.classifyWork(byId[i]);
        if (kind === 'single') {
          result.singleWorks.push(byId[i]);
        } else if (kind === 'ep') {
          result.epWorks.push(byId[i]);
        } else {
          result.albumWorks.push(byId[i]);
        }
      }
      Logger.info(TAG, `works by catalog id ${this.catalogArtistId}: ${byId.length}`);
      return result;
    }
    // 精确锚点：这位艺人的第一首本地歌曲（云资料库 id → 曲库 id → 目录艺人），
    // 完全不依赖名字匹配，中文名/日文名/英文名都能对上。
    const localSongs: SongApiDto[] = MusicDbApi.getInstance().getSongsByArtist(this.artistName);
    const anchorUri: string = localSongs.length > 0 ? localSongs[0].src : '';
    const works: CatalogAlbumOffer[] =
      await CatalogFillService.catalogWorksByArtistName(this.artistName, hint, anchorUri);
    for (let i = 0; i < works.length; i++) {
      const kind: string = CatalogFillService.classifyWork(works[i]);
      if (kind === 'single') {
        result.singleWorks.push(works[i]);
      } else if (kind === 'ep') {
        result.epWorks.push(works[i]);
      } else {
        result.albumWorks.push(works[i]);
      }
    }
    return result;
  }

  /**
   * 把作品装到页面上。
   *
   * 用 `slice()` 而不是直接引用缓存里的数组：每次应用都是**新的数组对象**，
   * 这样「是否已在库」这类靠重绘刷新的标记才会跟着更新（同一引用不会触发重绘）。
   */
  private applyWorks(works: CachedArtistWorks): void {
    this.albumWorks = works.albumWorks.slice();
    this.epWorks = works.epWorks.slice();
    this.singleWorks = works.singleWorks.slice();
  }

  /** 该作品是否已在资料库。 */
  private workInLibrary(work: CatalogAlbumOffer): boolean {
    return MusicDbApi.getInstance().getSongsByAlbum(work.name, work.artist).length > 0;
  }

  /**
   * 本页实际压在哪个导航栈上：从搜索板块进来时压在搜索栈（不能去动艺人
   * tab 的栈，否则页面会推/弹到看不见的那个 tab 里）。
   */
  private activeStack(): NavPathStack {
    return this.fromSearch ? this.searchPageIndexInfos : this.pageIndexInfos;
  }

  /**
   * 本页作品卡片的 geometryTransition 作用域：搜索来源单独一个作用域，
   * 与搜索首页、艺人板块的卡片都不同名（同时在屏也不会配错共享元素）。
   */
  private workHeroScope(): string {
    return this.fromSearch ? HeroTransitionHelper.SOURCE_SEARCH_ARTIST
      : HeroTransitionHelper.SOURCE_ARTIST_DETAIL;
  }

  /** 是否有转场来源（共享元素 id 或点击位置快照）。 */
  private hasTransitionSource(): boolean {
    return this.heroId !== '' || (this.sourceRect.width > 0 && this.sourceRect.height > 0);
  }

  /**
   * 页面上是否有可展示的内容：本页现在以目录作品为准（艺人可能一首本地歌
   * 都没有 —— 从搜索页长按封面进来就是这种情况），所以不能再用「本地专辑
   * 数为 0」当作空页面判据（那会让收藏按钮都点不到）。
   */
  private hasContent(): boolean {
    return this.albums.length > 0 || this.albumWorks.length > 0
      || this.epWorks.length > 0 || this.singleWorks.length > 0;
  }

  /** 单张作品：已在库 → 打开专辑详情；未加入 → 先加入再同步。 */
  private async openWork(work: CatalogAlbumOffer, sourceRect?: HeroSourceRect): Promise<void> {
    if (this.workBusyId !== '') {
      return;
    }
    if (this.workInLibrary(work)) {
      const param: AlbumDetailParam = {
        albumName: work.name,
        artistName: work.artist,
        heroId: HeroTransitionHelper.catalogAlbumHeroId(this.workHeroScope(), work.name, work.artist),
        sourceRect: sourceRect !== undefined ? sourceRect : new HeroSourceRect(),
        fromArtistDetail: true,
        // 从搜索板块进来的艺人页，再开专辑详情仍要压在同一个栈上
        fromSearch: this.fromSearch
      };
      this.getUIContext().animateTo({
        duration: HeroMotion.ENTER_MS,
        curve: curves.springMotion(0.45, 0.75, 0.1)
      }, () => {
        this.activeStack().pushPathByName('AlbumDetail', param, false);
      });
      return;
    }
    // 未入库也直接进详情页：详情页会自动从 Apple 拉曲目、可直接播放，
    // 并在未入库时显示「+ 加入资料库」（不再自动入库、不再同步整库）。
    const param2: AlbumDetailParam = {
      albumName: work.name,
      artistName: work.artist,
      heroId: HeroTransitionHelper.catalogAlbumHeroId(this.workHeroScope(), work.name, work.artist),
      sourceRect: sourceRect !== undefined ? sourceRect : new HeroSourceRect(),
      fromArtistDetail: true,
      fromSearch: this.fromSearch
    };
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.activeStack().pushPathByName('AlbumDetail', param2, false);
    });
    return;
    this.workBusyId = work.id;
    this.worksNote = `正在把《${work.name}》加入资料库…`;
    const ok: boolean = await AppleApi.addCatalogAlbumToLibrary(work.id);
    this.workBusyId = '';
    if (!ok) {
      this.worksNote = '加入失败：请确认账号已登录且订阅有效';
      return;
    }
    await this.syncLibrary();
    this.worksNote = `《${work.name}》已加入资料库`;
    await this.loadWorks();
  }

  /** 重新同步资料库（歌曲 + 歌单 + 歌单曲目），并广播刷新。 */
  private async syncLibrary(): Promise<void> {
    this.worksNote = '正在同步资料库…';
    try {
      await AppleLibrarySync.syncSongs(undefined, true);
      await AppleLibrarySync.syncPlaylists();
      await AppleLibrarySync.syncAllPlaylistTracks(true);
      MediaService.getInstance().remapQueueAfterSync();
      LibrarySignal.notifyChanged();
      this.worksNote = '';
    } catch (e) {
      this.worksNote = '同步失败：' + ((e as Error).message ?? '');
    }
  }

  /**
   * 收藏动作 = 把这位艺人在 Apple 目录里的**全部作品**加入资料库
   * （只算本人主艺人，自动跳过已在库的），然后重新同步。
   */
  private async fillAllWorks(): Promise<void> {
    // 同一位艺人本次运行里已经补齐过：直接跳过（不再拉作品、不再同步整库）
    if (ArtistWorksCache.filledRecently(this.artistName, FILL_THROTTLE_MS)) {
      Logger.info(TAG, `${this.artistName}: 本次运行已自动补齐过全部作品，跳过`);
      return;
    }
    const localAlbums2: AlbumApiDto[] = MusicDbApi.getInstance().getAlbumsByArtist(this.artistName);
    const fillHint: string = localAlbums2.length > 0 ? localAlbums2[0].name : '';
    const localSongs2: SongApiDto[] = MusicDbApi.getInstance().getSongsByArtist(this.artistName);
    const fillAnchor: string = localSongs2.length > 0 ? localSongs2[0].src : '';
    // 从搜索页长按封面进来时带着目录艺人 id：直接用 id 取全部作品，比按
    // 名字猜（中文名/日文名常常猜不到）可靠得多。
    const fill: Promise<number> = this.catalogArtistId !== ''
      ? CatalogFillService.addAllForArtistId(this.catalogArtistId, this.artistName,
        (text: string) => {
          this.worksNote = text;
        })
      : CatalogFillService.addAllForArtist(this.artistName, (text: string) => {
        this.worksNote = text;
      }, fillHint, fillAnchor);
    await fill.then(async (added: number) => {
      if (added > 0) {
        this.worksNote = `正在同步资料库（新增 ${added} 张）…`;
        try {
          await AppleLibrarySync.syncSongs(undefined, true);
          await AppleLibrarySync.syncPlaylists();
          await AppleLibrarySync.syncAllPlaylistTracks(true);
          MediaService.getInstance().remapQueueAfterSync();
          LibrarySignal.notifyChanged();
        } catch (e) {
          this.worksNote = '同步失败：' + ((e as Error).message ?? '');
          return;
        }
      }
      this.worksNote = '';
      ArtistWorksCache.markFilled(this.artistName);
      // 入库后刷新作品列表，让「已在资料库 / 未加入」标记立刻更新
      await this.loadWorks();
    }).catch((e: Error) => {
      this.worksNote = '入库失败：' + e.message;
    });
  }
  /** Ignores repeated album-card taps while its push transition runs. */
  @Local isOpeningAlbum: boolean = false;

  aboutToAppear(): void {
    this.appState.detailPageDepth += 1;
    // 收藏状态 = 本地收藏表 ∪ Apple Music 的 ⭐：
    // 先用本地表 + 已落盘的 Apple 收藏缓存同步定下来（首帧就红），再用网络校准。
    this.isFavorite = MusicDbApi.getInstance().isFavoriteArtist(this.artistName);
    if (!this.isFavorite) {
      this.isFavorite = this.appleFavoriteFromCache();
    }
    this.resolveAppleFavorite();
    this.loadWorks();
    // 已收藏的艺人：进入主页自动补齐全部作品（幂等，已在库的会跳过）
    if (this.isFavorite && !this.favFillStarted) {
      this.favFillStarted = true;
      this.fillAllWorks();
    }
    this.albums = MusicDbApi.getInstance().getAlbumsByArtist(this.artistName);
    this.songCount = MusicDbApi.getInstance().getSongsByArtist(this.artistName).length;
    this.albumDataSource.setRows(this.albums);
    // 头像一律用 Apple Music 官方艺人图（用户 2026-09-14 定）：
    // 从搜索页进来时直接带目录头像；从艺人板块进来时查同步刷新的头像表。
    this.heroCoverPath = this.artistAvatarPath !== ''
      ? this.artistAvatarPath
      : MusicDbApi.getInstance().getArtistArtwork(this.artistName);
  }

  /**
   * 本地缓存的「Apple Music 收藏艺人」名单里有没有这一位（零请求、零等待）。
   * 名单由启动同步 / 艺人页刷新写进 Preferences（musichome_fav/apple_fav_artists_v1）。
   */
  private appleFavoriteFromCache(): boolean {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return false;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync('apple_fav_artists_v1', '') as string;
      if (txt === '') {
        return false;
      }
      const names: string[] = JSON.parse(txt) as string[];
      for (let i = 0; i < names.length; i++) {
        if (names[i] === this.artistName) {
          return true;
        }
      }
    } catch (e) {
    }
    return false;
  }

  /**
   * 联网校准 Apple Music 的收藏状态 + 记下目录艺人 id（点心形时写 Apple 要用）。
   * 真机实测：POST/DELETE `/v1/me/favorites?ids[artists]=…` 约 6 秒后生效。
   */
  private resolveAppleFavorite(): void {
    AppleApi.getArtistFavState(this.artistName).then((st: ArtistFavState) => {
      const local: boolean = MusicDbApi.getInstance().isFavoriteArtist(this.artistName);
      if (st.found) {
        this.appleArtistId = st.catalogId;
        // 本地收藏优先（true 不会被网络结果抹掉），否则以 Apple 侧为准
        this.isFavorite = local || st.inFavorites;
        return;
      }
      // 不在资料库里的艺人（例如从 Apple Music 搜索页进来的目录艺人）：
      // 退化成「目录搜艺人拿 id → 读目录资源上的 inFavorites」。
      AppleApi.searchArtistIdByName(this.artistName).then((cid: string) => {
        if (cid === '') {
          return;
        }
        this.appleArtistId = cid;
        AppleApi.getCatalogArtistInFavorites(cid).then((fav: boolean) => {
          this.isFavorite = MusicDbApi.getInstance().isFavoriteArtist(this.artistName) || fav;
        }).catch(() => {
        });
      }).catch(() => {
      });
    }).catch(() => {
    });
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
    this.gridDy = this.growDy;
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
        this.gridDy = 0;
        this.gridOpacity = 1;
        this.gridScale = 1;
      });
    }, HeroMotion.BODY_DELAY_MS);
  }

  /**
   * Shared-element return: content shrinks back toward the tapped row
   * while the portrait flies back via geometryTransition. pop(false) keeps
   * the system default transition off, as required by the official recipe.
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
      this.gridDy = this.growDy;
      this.gridOpacity = 0;
      this.gridScale = 0.96;
      // 按「本页压在哪条栈」弹出：从搜索板块进入时弹搜索栈。
      this.activeStack().pop(false);
    });
    return true;
  }

  /** Plays every song of the artist. */
  private playArtistAll(): void {
    PlaybackHelper.playArtistSongs(this.artistName);
  }

  /** 标题栏副标题：本地资料库优先，本地没有唱片时用 Apple 目录作品数。 */
  private subtitleText(): string {
    if (this.albums.length > 0) {
      return `${this.albums.length} 张专辑 · ${this.songCount} 首歌曲`;
    }
    const total: number = this.albumWorks.length + this.epWorks.length + this.singleWorks.length;
    if (total > 0) {
      return `${this.albumWorks.length} 张专辑 · ${this.epWorks.length} 张 EP · ${this.singleWorks.length} 首单曲`;
    }
    return this.worksLoaded ? '资料库里还没有这位艺人' : '正在读取全部作品…';
  }

  /**
   * Title bar with the official GRADIENT_BLUR (same tuned profile as the
   * artists home: transparent plates, 56vp mask spread, blur radius 16).
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
        mainTitle: this.artistName,
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

  build() {
    HdsNavDestination() {
      Stack() {
        Column() {
        if (!this.hasContent() && this.worksLoaded) {
          Column() {
            Text($r('app.string.library_empty_artist'))
              .fontSize(14)
              .fontColor($r('app.color.library_text_secondary'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            // Height 100% pins content to the Scroll top: short grids are
            // vertically centered by the Scroll otherwise, leaving a huge
            // gap above the albums on artists with few albums.
            Column() {
              // Content inset under the MINI title bar (56vp): keeps the
              // album grid at its tuned 92vp position while the header
              // itself lives inside the title bar.
              Blank().height(36)
              // Apple Music-style hero header: circular artist portrait and
              // an icon-only circular play button (same visual language as
              // the album detail page). The portrait is the shared element;
              // tapping it opens the gallery to change the avatar.
              Column({ space: 20 }) {
                Stack() {
                  HeroArtwork({
                    coverPath: this.heroCoverPath,
                    seed: this.artistName,
                    symbol: $r('sys.symbol.person_crop_circle_fill_1'),
                    radius: 80,
                    heroWidth: 160,
                    heroHeight: 160,
                    heroId: this.heroId
                  })
                }
                .width(160)
                .height(160)
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.onHeroMeasured(newArea);
                })
                // 播放全部 + 收藏（两个圆形按钮并排，视觉语言与专辑页一致）
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
                .translate({ y: this.buttonDy })
                .opacity(this.buttonOpacity)
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
                  this.playArtistAll();
                })

                // 收藏：心形按钮（实心=已收藏），点击切换并即时反馈。
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph(this.isFavorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
                    .fontSize(24)
                    .fontColor([this.isFavorite ? '#FF3B30' : $r('app.color.library_text_secondary')])
                }
                .width(52)
                .height(52)
                .padding(0)
                .backgroundColor($r('app.color.library_card_bg'))
                .scale({ x: this.favScale, y: this.favScale })
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
                  // 两边一起写：本地收藏表 + **Apple Music 自己的资料库**
                  // （真机实测：POST/DELETE /v1/me/favorites?ids[artists]=… 约 6 秒后生效）。
                  const want: boolean = !this.isFavorite;
                  MusicDbApi.getInstance().setFavoriteArtist(this.artistName, want);
                  this.isFavorite = want;
                  if (this.appleArtistId === '') {
                    // 目录 id 还没解析出来（刚进页面就点）：补一次搜索再写
                    AppleApi.getArtistFavState(this.artistName).then((st: ArtistFavState) => {
                      this.appleArtistId = st.catalogId;
                      if (this.appleArtistId !== '') {
                        AppleApi.setArtistFavorite(this.appleArtistId, want).catch(() => {
                        });
                      }
                    }).catch(() => {
                    });
                  } else {
                    AppleApi.setArtistFavorite(this.appleArtistId, want).catch(() => {
                    });
                  }
                  // Apple 侧约 6 秒后才传播完成：稍后重拉一次收藏缓存并广播，
                  // 让艺人页顶部的「收藏的艺人」横排与 Apple 保持一致。
                  setTimeout(() => {
                    AppleLibrarySync.syncFavorites(true).then(() => {
                      LibrarySignal.notifyChanged();
                    }).catch(() => {
                    });
                  }, 7000);
                  // 艺人板块是常驻 tab，不会重新执行 aboutToAppear：先广播一次让它立刻刷新
                  LibrarySignal.notifyChanged();
                  this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                    this.isFavorite = want;
                  });
                  if (want) {
                    this.favFillStarted = true;
                    this.fillAllWorks();
                  }
                })
                }
                .justifyContent(FlexAlign.Center)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 16, right: 16, bottom: 18 })
              // ── 全部作品（来自 Apple 目录，不限于资料库）──
              if (this.worksNote !== '') {
                Text(this.worksNote)
                  .fontSize(12)
                  .fontColor($r('app.color.library_text_secondary'))
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              }
              // 首次进入（没有缓存）时的加载动画；进过的艺人走缓存，这里不会出现
              if (this.worksLoading) {
                Row({ space: 10 }) {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color($r('app.color.library_accent'))
                  Text('正在加载作品…')
                    .fontSize(13)
                    .fontColor($r('app.color.library_text_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 26, bottom: 26 })
              }
              Column() {
                if (this.albumWorks.length > 0) {
                  Text(`专辑 · ${this.albumWorks.length}`)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.library_text_primary'))
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 10, bottom: 6 })
                  Grid() {
                    ForEach(this.albumWorks, (work: CatalogAlbumOffer) => {
                      GridItem() {
                        CatalogWorkCard({
                          work: work,
                          inLibrary: this.workInLibrary(work),
                          heroScope: this.workHeroScope(),
                          onOpen: (rect: HeroSourceRect): void => {
                            this.openWork(work, rect);
                          },
                          onLightAt: (x: number, y: number): void => {
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
                    }, (work: CatalogAlbumOffer) => `ga-${work.id}`)
                  }
                  .columnsTemplate('1fr 1fr')
                  .columnsGap(14)
                  .rowsGap(18)
                  .width('100%')
                  .padding({ left: 16, right: 16, bottom: 8 })
                  .scrollBar(BarState.Off)
                }
                if (this.epWorks.length > 0) {
                  Text(`EP · ${this.epWorks.length}`)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.library_text_primary'))
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 16, bottom: 6 })
                  Grid() {
                    ForEach(this.epWorks, (work: CatalogAlbumOffer) => {
                      GridItem() {
                        CatalogWorkCard({
                          work: work,
                          inLibrary: this.workInLibrary(work),
                          heroScope: this.workHeroScope(),
                          onOpen: (rect: HeroSourceRect): void => {
                            this.openWork(work, rect);
                          },
                          onLightAt: (x: number, y: number): void => {
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
                    }, (work: CatalogAlbumOffer) => `ge-${work.id}`)
                  }
                  .columnsTemplate('1fr 1fr')
                  .columnsGap(14)
                  .rowsGap(18)
                  .width('100%')
                  .padding({ left: 16, right: 16, bottom: 8 })
                  .scrollBar(BarState.Off)
                }
                if (this.singleWorks.length > 0) {
                  Text(`单曲 · ${this.singleWorks.length}`)
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.library_text_primary'))
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 16, bottom: 6 })
                  Grid() {
                    ForEach(this.singleWorks, (work: CatalogAlbumOffer) => {
                      GridItem() {
                        CatalogWorkCard({
                          work: work,
                          inLibrary: this.workInLibrary(work),
                          heroScope: this.workHeroScope(),
                          onOpen: (rect: HeroSourceRect): void => {
                            this.openWork(work, rect);
                          },
                          onLightAt: (x: number, y: number): void => {
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
                    }, (work: CatalogAlbumOffer) => `gs-${work.id}`)
                  }
                  .columnsTemplate('1fr 1fr')
                  .columnsGap(14)
                  .rowsGap(18)
                  .width('100%')
                  .padding({ left: 16, right: 16, bottom: 8 })
                  .scrollBar(BarState.Off)
                }
              }
              .width('100%')
              // 原来那套「整块从点击的艺人卡片长出来」的入场动画
              .scale({ x: this.gridScale, y: this.gridScale })
              .translate({ y: this.gridDy })
              .opacity(this.gridOpacity)
              Blank().height(16)
            }
            .width('100%')
            // minHeight: short grids fill the viewport (top-aligned), long
            // grids keep their natural height so they can scroll.
            .constraintSize({ minHeight: '100%' })
          }
          // No clipping: content keeps scrolling under the title bar into
          // the GRADIENT_BLUR mask.
          .clip(false)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          // Bottom clearance for the floating HDS bar (52vp bar + 34vp
          // bottom margin + 4vp breathing room).
          .padding({ bottom: 90 })
        }
      }
      .width('100%')
      .height('100%')

      // Fixed point-light source overlay inside the content Stack: never
      // scrolls with the grid, so it cannot jitter; position follows the
      // pressed cover (window coords — the Stack starts at window origin).
      // Official preset sourceType (SOFT = gentle, wide-ish light) driven
      // by press, instead of custom options.
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
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    // geometryTransition replaces the page transition; keep the system
    // transition for the no-album fallback where no hero pair exists.
    // 有共享元素 id 或有来源位置快照时，转场完全由 hero + 生长动画驱动，
    // 不能再叠一层系统默认过场；两者都没有（异常深链）才退回系统过场。
    .systemTransition(this.hasTransitionSource()
      ? NavigationSystemTransitionType.NONE
      : NavigationSystemTransitionType.DEFAULT)
    // System back gesture / hardware back run the same shared-element pop.
    .onBackPressed((): boolean => {
      // 返回动画统一走 animatedBack：它按 activeStack 弹出本页真正所在的栈
      // （从搜索板块进入时弹搜索栈），并先把内容缩回来。
      return this.animatedBack();
    })
    // Official window-mode handover: detail pages leave the immersive
    // full-screen layout so the HDS title bar (title + back icon) sits
    // below the status bar / camera cutout; returning to home restores
    // the immersive bleed-to-top layout.
    .onShown(() => {
      WindowUtil.getInstance().setImmersiveMode(false);
    })
    .onHidden(() => {
      WindowUtil.getInstance().setImmersiveMode(true);
    })
    // Official frosted-glass page background: the cover art blurred
    // full-bleed via generic backgroundImage + backgroundBlurStyle, so the
    // whole page (title-bar area included) reflects the cover colors.
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .backgroundImage(this.heroCoverPath, ImageRepeat.NoRepeat)
    .backgroundImageSize({ width: '100%', height: '100%' })
    .backgroundBlurStyle(BlurStyle.Regular, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
  }
}

/** Global builder entry for routing to {@link ArtistDetailPage}. */
@Builder
export function ArtistDetailPageBuilder(name: string, param: Object) {
  ArtistDetailPage({
    artistName: (param as ArtistDetailParam)?.artistName ?? '',
    heroId: (param as ArtistDetailParam)?.heroId ?? '',
    sourceRect: (param as ArtistDetailParam)?.sourceRect ?? new HeroSourceRect(),
    artistAvatarPath: (param as ArtistDetailParam)?.artistAvatarPath ?? '',
    fromSearch: (param as ArtistDetailParam)?.fromSearch ?? false,
    catalogArtistId: (param as ArtistDetailParam)?.catalogArtistId ?? ''
  })
}

/**
 * 目录作品卡片：视觉与手势完全复刻 {@link ArtistAlbumCard}（毛玻璃封面、
 * 点光源照亮、官方弹簧按压、hero 转场），只把数据源换成目录作品，
 * 并在封面左下角显示「已在资料库 / 未加入」状态。
 */
@ComponentV2
export struct CatalogWorkCard {
  @Param work: CatalogAlbumOffer = new CatalogAlbumOffer();
  /** 是否已在资料库（决定角标是播放还是加号）。 */
  @Param inLibrary: boolean = false;
  /**
   * geometryTransition 作用域前缀：同一时刻在屏的页面不能共用同一个 id，
   * 否则共享元素会配错对象。艺人页内用默认值，搜索板块传自己的作用域。
   */
  @Param heroScope: string = 'artist-detail';
  @Event onOpen: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  @Event onLightAt: (x: number, y: number) => void = (x: number, y: number) => {
  };
  @Event onLightOff: () => void = () => {
  };
  /** 角标（＋/▶）的点击：未入库=加入资料库，已入库=打开专辑详情。 */
  @Event onAdd: () => void = () => {
  };
  /** 长按封面 = 进入艺人主页（回传封面位置，目标页从它生长出来 / 缩回去）。 */
  @Event onOpenArtist: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  @Local pressed: boolean = false;
  @Local coverScale: number = 1;
  @Local coverRect: HeroSourceRect = new HeroSourceRect();

  /**
   * 卡片封面的 geometryTransition id：与专辑详情页路由参数里透传的字符串
   * 必须完全一致（作用域随调用方，避免搜索页与艺人页同时在屏时撞 id）。
   */
  private heroId(): string {
    return `${this.heroScope}-hero-${this.work.name}|${this.work.artist}`;
  }

  build() {
    Column({ space: 8 }) {
      Button() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          HeroArtwork({
            coverPath: this.work.artworkUrl,
            seed: `${this.work.name}${this.work.artist}`,
            radius: 10,
            fillWidth: true,
            heroId: this.heroId()
          })
          Row() {
            SymbolGlyph(this.inLibrary
              ? $r('sys.symbol.play_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#B3000000')
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.onAdd();
          })
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(10)
        .clip(true)
      }
      .type(ButtonType.Normal)
      .stateEffect(false)
      .backgroundColor(Color.Transparent)
      .borderRadius(10)
      .padding(0)
      .width('100%')
      .aspectRatio(1)
      .scale({ x: this.coverScale, y: this.coverScale })
      .backgroundBlurStyle(BlurStyle.Regular, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: this.pressed ? 1 : 0.2
      })
      .visualEffect(new hdsEffect.HdsEffectBuilder()
        .pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
        })
        .buildEffect())
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.coverRect = HeroSourceRect.fromArea(newArea);
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 0.94;
          });
        } else if (event.type === TouchType.Move) {
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
          this.onLightOff();
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 1;
          });
        }
      })
      .onClick(() => {
        this.onOpen(this.coverRect);
      })
      // 长按封面 = 直接进入艺人主页（不再用父容器菜单：长按落在封面 Button 上
      // 会被它自己消费，父容器的 bindContextMenu 永远不触发）
      .gesture(
        LongPressGesture({ repeat: false, duration: 400 })
          .onAction(() => {
            this.onOpenArtist(this.coverRect);
          })
      )

      Column({ space: 2 }) {
        Text(this.work.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.library_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.inLibrary ? '已在资料库' : '未加入'} · ${this.work.trackCount} 首`)
          .fontSize(12)
          .fontColor($r('app.color.library_text_secondary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .onClick(() => {
        this.onOpen(this.coverRect);
      })
    }
    .width('100%')
  }
}
