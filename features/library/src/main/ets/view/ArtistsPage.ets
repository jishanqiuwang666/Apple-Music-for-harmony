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
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions, ScrollEffectType, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import { AppStorageKeys, AppleApi, AppleAuthState, AppleLibrarySync, ArtistAliasTable, ArtistApiDto, ArtistFavState, getWindowInfoState, LibrarySignal, Logger, MusicAppState, MusicDatabase, MusicDbApi, GenreBuckets, MusicTransferService, SyncResult, WindowInfo } from 'musicbasic';
import { CoverPlaceholder } from './SongListItem';
import { HeroArtwork } from './HeroArtwork';
import { HeroMotion, HeroSourceRect, HeroTransitionHelper } from '../util/HeroTransition';
import { HomeBack } from '../util/HomeBack';
import { FlowLightRegistry } from '../util/FlowLightRegistry';
import { Haptics } from '../util/Haptics';
import { ArtistDetailParam } from '../util/PlaybackHelper';

const TAG = 'ArtistsPage';

/** 收藏卡片「长按拿起」判定时长（毫秒）：比系统长按略短，更容易触发。 */
const FAV_HOLD_MS: number = 260;
/** 判定长按期间允许的手指抖动（vp）：超出就当成滑动，不当拿起。 */
const FAV_HOLD_SLOP_VP: number = 12;
/**
 * 收藏横排「手动顺序」的偏好键（与 Apple 收藏缓存同一个 store）。
 *
 * 为什么要存这里而不是只存数据库：数据库的 favorite_artists 表只装**应用内收藏**，
 * 而横排里还有一批是从 Apple Music ⭐ 收藏并进来的（它们在那张表里没有行，
 * UPDATE sort_order 打空）。于是重启后 reloadFavorites 重新算出的顺序里，
 * 这批人永远按 Apple 给的顺序排 —— 用户看到的正是「重启就变回原样」。
 * 这里存的是**全量**顺序（含 Apple 来源），重启后按它重排即可。
 */
const FAV_ORDER_PREF: string = 'fav_artist_order_v1';

/**
 * 艺人列表的一行：音乐板块标题行 or 艺人行（同一个 LazyForEach 里混排）。
 * 板块由曲风归类而来（见 GenreBuckets），数据在资料库同步时随歌曲一起带回来。
 */
class ArtistListRow {
  /** true = 板块标题行。 */
  public isHeader: boolean = false;
  /** 标题行文本（板块名）。 */
  public title: string = '';
  /** 该板块的艺人数。 */
  public count: number = 0;
  /** 是否画上分割线（板块第一行不画）。 */
  public showDivider: boolean = false;
  /** 艺人行数据（标题行为空对象）。 */
  public artist: ArtistApiDto = new ArtistApiDto();
}

/** Data source feeding the artists list (rebuilds on library refresh). */
class ArtistDataSource implements IDataSource {
  private rows: ArtistListRow[] = [];
  private listeners: DataChangeListener[] = [];

  public setRows(rows: ArtistListRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ArtistListRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(): void {
    this.listeners = [];
  }
}

/** Artist list row: cover, name, counts; official press-shadow on press. */
@ComponentV2
struct ArtistRow {
  @Param artist: ArtistApiDto = new ArtistApiDto();
  @Event onOpen: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  /** Press state drives the official pressShadow (Button only). */
  @Local pressed: boolean = false;
  /** Latest window-space snapshot of the row (growth anchor for detail). */
  @Local rowRect: HeroSourceRect = new HeroSourceRect();

  build() {
    Button() {
      Row({ space: 12 }) {
        HeroArtwork({
          coverPath: this.artist.coverPath,
          seed: this.artist.name,
          symbol: $r('sys.symbol.person_crop_circle_fill_1'),
          radius: 26,
          heroWidth: 52,
          heroHeight: 52,
          heroId: HeroTransitionHelper.artistHeroId(this.artist)
        })
        Column({ space: 2 }) {
          Text(this.artist.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.library_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${this.artist.albumCount} 张专辑 · ${this.artist.songCount} 首歌曲`)
            .fontSize(13)
            .fontColor($r('app.color.library_text_secondary'))
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
      // 抽屉手势刚过去 → 吞掉这次点击（用户反馈「滑抽屉误触到下方的艺人」）
      this.onOpen(this.rowRect);
    })
  }
}

/**
 * 收藏横排里的单张卡片：与下方 ArtistRow 同一套视觉与手势 —— 毛玻璃圆形
 * 头像（共享元素，点开/退出都有头像飞入飞出）、按压弹簧缩放、点击位置快照。
 */
@ComponentV2
struct FavoriteArtistCard {
  @Param artist: ArtistApiDto = new ArtistApiDto();
  /** 正在被拖走：原卡片淡出（跟手指的是拖动浮起的那份）。 */
  @Param dimmed: boolean = false;
  /** 落点让位位移（vp）：拖动时落点及其后的卡片右移一个卡位。 */
  @Param shiftX: number = 0;
  /** 被拿起的这张：卡位收成 0（节点仍挂载，手势才不会断）。 */
  @Param collapsed: boolean = false;
  @Event onOpen: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  /**
   * 按下：页面据此起「长按拿起」计时（不用手势，见 onTouch 里的说明）。
   * 坐标是 `TouchObject.windowX/windowY` 的原值，**单位 vp**（不要再 px2vp）。
   */
  @Event onHoldStart: (cardRect: HeroSourceRect, wx: number, wy: number) => void =
    (cardRect: HeroSourceRect, wx: number, wy: number) => {
    };
  /** 手指移动（窗口坐标，单位 vp）。 */
  @Event onHoldMove: (wx: number, wy: number) => void = (wx: number, wy: number) => {
  };
  /** 抬手 / 触摸被取消：页面据此落位或放弃。 */
  @Event onHoldEnd: (cancelled: boolean) => void = (cancelled: boolean) => {
  };
  @Local pressed: boolean = false;
  @Local cardScale: number = 1;
  /** 卡片在窗口中的位置（详情页生长/缩回的锚点）。 */
  @Local cardRect: HeroSourceRect = new HeroSourceRect();

  build() {
    Column({ space: 6 }) {
      HeroArtwork({
        coverPath: this.artist.coverPath,
        seed: this.artist.name,
        symbol: $r('sys.symbol.person_crop_circle_fill_1'),
        radius: 32,
        heroWidth: 64,
        heroHeight: 64,
        heroId: HeroTransitionHelper.favoriteArtistHeroId(this.artist)
      })
      Text(this.artist.name)
        .fontSize(12)
        .fontColor($r('app.color.library_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(72)
        .textAlign(TextAlign.Center)
    }
    .width(this.collapsed ? 0 : 72)
    .clip(true)
    // 官方弹簧按压：与列表行、工具按钮同一套曲线
    .scale({ x: this.cardScale, y: this.cardScale })
    .translate({ x: this.shiftX })
    .opacity(this.collapsed ? 0 : 1)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.cardRect = HeroSourceRect.fromArea(newArea);
    })
    // 拖动排序**不用任何手势**：手势会和横向 List 的滚动/父级容器抢同一个触摸，
    // 谁抢到跟时序有关（真机体感「有时能拖、有时按不动」）。这里直接吃原始触摸事件
    // 自己做长按判定：onTouch 不参与手势竞争，触发时机完全由我们说了算。
    .onTouch((event: TouchEvent) => {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      const wx: number = touch !== undefined ? touch.windowX : 0;
      const wy: number = touch !== undefined ? touch.windowY : 0;
      if (event.type === TouchType.Down) {
        this.pressed = true;
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.cardScale = 0.92;
        });
        this.onHoldStart(this.cardRect, wx, wy);
      } else if (event.type === TouchType.Move) {
        this.onHoldMove(wx, wy);
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.cardScale = 1;
        });
        this.onHoldEnd(false);
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.cardScale = 1;
        });
        this.onHoldEnd(true);
      }
    })
    .onClick(() => {
      this.onOpen(this.cardRect);
    })
  }
}

/**
 * 拖动排序期间「浮起卡片」的跟手位移（独立可观察对象）。
 *
 * 为什么要单独一个对象：位移是**每帧都在变**的量。以前它是 ArtistsPage 的
 * @Local，指针每移动一次就重建整个页面（列表 + LazyForEach + 横排全部 diff 一遍），
 * 手指再快也追不上 —— 用户反馈的「拖动的时候头像极其不跟手」就是这个。
 * 现在只有下面那个很小的 {@link FavoriteFloatCard} 读它，每帧只重建它自己。
 */
@ObservedV2
class FavDragOffset {
  /** 相对「拿起那一刻」的位移 x（vp）。 */
  @Trace public dx: number = 0;
  /** 相对「拿起那一刻」的位移 y（vp）。 */
  @Trace public dy: number = 0;

  /** 复位（拿起/落下都要清，避免下一张卡片带着旧位移出现）。 */
  public reset(): void {
    this.dx = 0;
    this.dy = 0;
  }
}

/**
 * 跟手指的那张浮起卡片（放大 1.08、无底色无投影、只改 translate）。
 *
 * 独立成组件是为了让跟手位移只重建它自己（见 {@link FavDragOffset}）。
 */
@ComponentV2
struct FavoriteFloatCard {
  @Param artist: ArtistApiDto = new ArtistApiDto();
  @Param dragOffset: FavDragOffset = new FavDragOffset();

  build() {
    // 外层只承担「跟手位移」，内层才是卡片本体（尺寸 + 放大）：
    // 与改造前的两层结构一致，缩放不会影响位移量。
    Column() {
      Column({ space: 6 }) {
        HeroArtwork({
          coverPath: this.artist.coverPath,
          seed: this.artist.name,
          symbol: $r('sys.symbol.person_crop_circle_fill_1'),
          radius: 32,
          heroWidth: 64,
          heroHeight: 64
        })
        Text(this.artist.name)
          .fontSize(12)
          .fontColor($r('app.color.library_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(72)
          .textAlign(TextAlign.Center)
      }
      .width(72)
      .padding({ top: 6, bottom: 6 })
      // 不加底色、不加投影：深色模式下卡底色是近黑的 #1C1C1E，
      // 会在被拿起的头像后面糊出一块黑底（用户明确不接受）。
      .scale({ x: 1.08, y: 1.08 })
    }
    // 跟手位移：纯 render 变换，不触发布局重排
    .translate({ x: this.dragOffset.dx, y: this.dragOffset.dy })
  }
}

/** Artists section: import entry, empty-state guide, and artist list. */
@ComponentV2
export struct ArtistsPage {
  /** Navigation stack from the phone shell (pushes artist detail). */
  @Consumer('artistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  @Local artists: ArtistApiDto[] = [];
  /** 收藏的艺人（艺人板块顶部横排展示）。 */
  @Local favoriteArtists: ArtistApiDto[] = [];
  @Local loading: boolean = false;
  /** Apple Music 资料库同步中（工具栏同步按钮 + 进度浮层）。 */
  @Local syncing: boolean = false;
  /** Artist-name search query. */
  @Local query: string = '';
  /** 同步阶段说明（显示在进度浮层）。 */
  @Local syncPhaseText: string = '';
  /** Library-change signal: refreshes after share-imports while the page stays alive. */
  @Local librarySignal: LibrarySignal = LibrarySignal.getInstance();
  /** App 级状态：拖动收藏卡片时通知外壳让出「侧滑开抽屉」的热区。 */
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** Apple Music 登录态（未登录时空态展示「登录 Apple Music」）。 */
  @Local authState: AppleAuthState = AppleAuthState.getInstance();
  /** Window metrics: status-bar inset for the top toolbar. */
  @Local windowInfo: WindowInfo = getWindowInfoState();

  private dataSource: ArtistDataSource = new ArtistDataSource();
  /** List scroller shared with the HDS title bar (GRADIENT_BLUR sync). */
  private scroller: Scroller = new Scroller();
  /** Index of the button pressed as the point-light source (-1 = none):
   * press-down lights it, press-up extinguishes it. */
  @Local litIndex: number = -1;
  // ───────── 收藏横排的拖动排序（原始触摸自实现，不用手势） ─────────
  /** 正在拖动收藏卡片。 */
  @Local favDragging: boolean = false;
  /** 当前落点（在「收起被拖项后」的数组里的插入位置）。 */
  @Local favInsert: number = 0;
  /** 被拿起的那张原来的下标（用于收起卡位与最终换位）。 */
  @Local favOriginIndex: number = -1;
  /** 浮起卡片的基准位置（拿起那一刻，容器内坐标 vp）。 */
  @Local favFloatX: number = 0;
  @Local favFloatY: number = 0;
  /**
   * 跟手位移（独立对象）：只让浮起卡片重建，不重建整页 —— 见 {@link FavDragOffset}。
   */
  private favOffset: FavDragOffset = new FavDragOffset();
  /** 被拿起的艺人（数组不动，浮起卡片单独渲染它）。 */
  private draggingFav: ArtistApiDto = new ArtistApiDto();
  /** 横排容器在窗口中的位置（把手指的窗口坐标换算成容器内坐标）。 */
  private favRowRect: HeroSourceRect = new HeroSourceRect();
  private favCardW: number = 72;
  private favCardH: number = 86;
  /** 卡位宽 = 卡片 72 + 间距 14；横排没有左右内边距（满宽）。 */
  private readonly favSlotW: number = 86;
  private readonly favPadX: number = 0;
  /** 长按判定定时器与起点（原始触摸自己做，见 onFavHoldStart）。 */
  private holdTimerId: number = -1;
  private holdIndex: number = -1;
  private holdCardRect: HeroSourceRect = new HeroSourceRect();
  private holdStartX: number = 0;
  private holdStartY: number = 0;
  /** 拿起瞬间的手指位置（拖动位移的基准）。 */
  private dragFingerX: number = 0;
  private dragFingerY: number = 0;
  /** 兜底定时器：拖动状态卡住时自动收回。 */
  private favGuardId: number = -1;
  /** Ignores repeated row taps while the hero push transition is running. */
  @Local isOpening: boolean = false;
  /** Apple Music-style library title fade driven by the list scroll. */
  @Local titleFade: number = 1;

  aboutToAppear(): void {
    // 首屏尽快显示收藏横排：DB 一就绪就刷新，不等 Apple 同步
    this.scheduleFavoriteRefresh();
    this.refreshFavorites();
    // Apple Music 的收藏艺人：联网刷新一次（通常 1 个请求），回来后重建横排
    this.refreshAppleFavorites();
    this.refresh();
    // Cold start: this page can bootstrap before the DB finishes loading and
    // render an empty library. Refresh directly once the DB is ready (no
    // LibrarySignal — a global notify during startup knocks the HDS miniBar
    // out), deferred a frame so it never collides with the initial build.
    MusicDatabase.getInstance().whenReady(() => {
      setTimeout(() => {
        this.refresh();
      }, 50);
    });
  }

  aboutToDisappear(): void {
  }

  /** Refreshes the artist list when the library changes (e.g. share import). */
  @Monitor('librarySignal.version')
  onLibraryChanged(): void {
    this.refresh();
    // 收藏切换也会广播这个信号：顺带刷新顶部「收藏的艺人」横排。
    this.refreshFavorites();
  }

  /**
   * HDS title bar with the official GRADIENT_BLUR. The toolbar renders in
   * the top-left stackBuilder region, pushed lower (the MINI bar does not
   * clip stack content), and uses the official point-light effect: the
   * pressed button glows (pressShadow gradient) and acts as the light
   * source, the sibling buttons are illuminated bodies while pressed.
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
    return { style: style };
  }

  /** Total song count across the library (title subtitle). */
  private songCount(): number {
    return MusicDbApi.getInstance().getSongList().length;
  }

  /** Apple Music-style large library title: big bold name over a count
   * subtitle; fades out as the list scrolls under the title bar. */
  @Builder
  private LibraryTitle() {
    Column({ space: 4 }) {
      Text('艺人')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(`${this.artists.length} 位艺人 · ${this.songCount()} 首歌曲`)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .opacity(this.titleFade)
  }

  /** 音乐板块标题行（古典 / 爵士 / 流行…）。 */
  @Builder
  private SectionHeader(title: string, count: number) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(`${count}`)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 22, bottom: 4 })
  }

  /** Press state lights the search bar via the official point light. */
  @Local searchLit: boolean = false;
  /** Per-button press scale driven by the official spring curve. */
  @Local toolScales: number[] = [1, 1, 1];
  /** Search bar press scale driven by the official spring curve. */
  @Local searchScale: number = 1;

  /**
   * 手动同步 Apple Music 资料库（工具栏同步按钮）：刷新 developer token →
   * 重新拉取资料库 → 重建三个板块。同步期间显示进度浮层。
   */
  private async syncAppleLibrary(): Promise<void> {
    if (this.syncing) {
      return;
    }
    if (!AppleApi.isAuthorized()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录 Apple Music' });
      return;
    }
    this.syncing = true;
    this.syncPhaseText = '正在同步资料库…';
    try {
      await AppleApi.ensureDeveloperToken();
      const result: SyncResult = await AppleLibrarySync.syncSongs(undefined, true);
      await AppleLibrarySync.syncPlaylists();
      this.refresh();
      this.notifyLibraryChanged();
      const message = result.ok ? `资料库已同步：${result.songs} 首` : `同步失败：${result.message}`;
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.error(TAG, `syncAppleLibrary failed ${JSON.stringify(err)}`);
      this.getUIContext().getPromptAction().showToast({ message: '同步失败，请检查网络或重新登录' });
    } finally {
      this.syncing = false;
      this.syncPhaseText = '';
    }
  }

  /** Reloads artist aggregates from the library DB mirror. */
  private refresh(): void {
    this.artists = MusicDbApi.getInstance().getArtists();
    this.applyFilter();
  }

  /**
   * 艺人名搜索 + 按音乐板块分组。
   *
   * 板块顺序固定为 {@link GenreBuckets.ORDER}（流行 / 古典 / 爵士 / 摇滚…），
   * 空板块不出现；板块内部保持原有排序。
   */
  private applyFilter(): void {
    const q = this.query.trim().toLowerCase();
    const matched: ArtistApiDto[] = q === ''
      ? this.artists
      : this.artists.filter((a: ArtistApiDto) => a.name.toLowerCase().includes(q));
    const rows: ArtistListRow[] = [];
    for (let i = 0; i < GenreBuckets.ORDER.length; i++) {
      const bucket: string = GenreBuckets.ORDER[i];
      const group: ArtistApiDto[] = [];
      for (let k = 0; k < matched.length; k++) {
        const genre: string = matched[k].genre !== '' ? matched[k].genre : GenreBuckets.OTHER;
        if (genre === bucket) {
          group.push(matched[k]);
        }
      }
      if (group.length === 0) {
        continue;
      }
      const header = new ArtistListRow();
      header.isHeader = true;
      header.title = bucket;
      header.count = group.length;
      rows.push(header);
      for (let k = 0; k < group.length; k++) {
        const row = new ArtistListRow();
        row.artist = group[k];
        row.showDivider = k > 0;
        rows.push(row);
      }
    }
    this.dataSource.setRows(rows);
  }

  /**
   * 按下：起「长按拿起」计时（原始触摸自判，不用手势）。
   *
   * @param index 卡片下标
   * @param cardRect 卡片窗口矩形（vp）
   * @param wxVp 触摸窗口坐标 x（**vp**，TouchObject.windowX 原值）
   * @param wyVp 触摸窗口坐标 y（**vp**）
   */
  private onFavHoldStart(index: number, cardRect: HeroSourceRect, wxVp: number, wyVp: number): void {
    this.clearHoldTimer();
    if (this.favDragging || index < 0 || index >= this.favoriteArtists.length) {
      return;
    }
    this.holdIndex = index;
    this.holdCardRect = cardRect;
    // TouchObject.windowX/windowY **本来就是 vp**（SDK 注释 Unit: vp；API 10 起由 px 改成 vp）。
    // 这里以前又 px2vp() 了一次 → 手指走 100vp、卡片只走 100/3.25≈31vp，
    // 正是用户反馈的「拖动极其不跟手」。别再补回这个换算。
    this.holdStartX = wxVp;
    this.holdStartY = wyVp;
    this.holdTimerId = setTimeout(() => {
      this.holdTimerId = -1;
      this.beginFavDrag();
    }, FAV_HOLD_MS);
  }

  /**
   * 手指移动：还没拿起时，手指出圈就当成滑动（放弃长按）；已经拿起就跟手 + 更新落点。
   *
   * @param wxVp 触摸窗口坐标 x（**vp**，原值直传）
   * @param wyVp 触摸窗口坐标 y（**vp**）
   */
  private onFavHoldMove(wxVp: number, wyVp: number): void {
    // 单位已经是 vp，不能再 px2vp（见 onFavHoldStart 的说明）
    const x: number = wxVp;
    const y: number = wyVp;
    if (!this.favDragging) {
      if (Math.abs(x - this.holdStartX) > FAV_HOLD_SLOP_VP || Math.abs(y - this.holdStartY) > FAV_HOLD_SLOP_VP) {
        this.clearHoldTimer();
      }
      return;
    }
    // 跟手：只改独立对象里的位移（只有浮起卡片会重建），不动页面状态
    this.favOffset.dx = x - this.dragFingerX;
    this.favOffset.dy = y - this.dragFingerY;
    this.updateFavInsert(this.favFloatX + this.favOffset.dx);
  }

  /**
   * 抬手 / 触摸被取消。
   *
   * @param cancelled true 表示触摸被系统或列表取消
   */
  private onFavHoldEnd(cancelled: boolean): void {
    this.clearHoldTimer();
    if (!this.favDragging) {
      return;
    }
    if (cancelled) {
      this.cancelFavDrag();
    } else {
      this.dropFav();
    }
  }

  /** 清掉长按判定定时器。 */
  private clearHoldTimer(): void {
    if (this.holdTimerId !== -1) {
      clearTimeout(this.holdTimerId);
      this.holdTimerId = -1;
    }
  }

  /** 长按成立：进入拖动状态（数组不动，被拖那张把卡位收成 0）。 */
  private beginFavDrag(): void {
    const index: number = this.holdIndex;
    if (index < 0 || index >= this.favoriteArtists.length) {
      return;
    }
    this.favOriginIndex = index;
    this.draggingFav = this.favoriteArtists[index];
    this.favCardW = this.holdCardRect.width > 0 ? this.holdCardRect.width : 72;
    this.favCardH = this.holdCardRect.height > 0 ? this.holdCardRect.height : 86;
    this.favFloatX = this.holdCardRect.x - this.favRowRect.x;
    this.favFloatY = this.holdCardRect.y - this.favRowRect.y;
    this.favOffset.reset();
    this.dragFingerX = this.holdStartX;
    this.dragFingerY = this.holdStartY;
    this.favInsert = index;
    this.favDragging = true;
    // 通知外壳：拖动排序进行中，左侧抽屉热区让位
    this.appState.sortDragActive = true;
    Haptics.tick(40);
    this.armFavGuard();
  }

  /**
   * 按浮起卡片的左边位置推算落点（收起后数组坐标），变了就弹簧让位。
   *
   * @param leftX 浮起卡片左边（容器内坐标 vp）
   */
  private updateFavInsert(leftX: number): void {
    let slot: number = Math.round((leftX - this.favPadX) / this.favSlotW);
    const max: number = this.favoriteArtists.length - 1;
    if (slot < 0) {
      slot = 0;
    }
    if (slot > max) {
      slot = max;
    }
    if (slot !== this.favInsert) {
      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
        this.favInsert = slot;
      });
    }
  }

  /** 松手：按落点插回数组、落库（数组此时已不含被拖项，直接插即可）。 */
  private dropFav(): void {
    if (!this.favDragging) {
      return;
    }
    this.disarmFavGuard();
    const moved: ArtistApiDto = this.draggingFav;
    let slot: number = this.favInsert;
    this.favDragging = false;
    this.appState.sortDragActive = false;
    this.draggingFav = new ArtistApiDto();
    const list: ArtistApiDto[] = this.favoriteArtists.slice();
    const origin: number = this.favOriginIndex;
    if (origin >= 0 && origin < list.length) {
      list.splice(origin, 1);
    }
    if (slot < 0) {
      slot = 0;
    }
    if (slot > list.length) {
      slot = list.length;
    }
    Haptics.tick(20);
    list.splice(slot, 0, moved);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.8) }, () => {
      this.favoriteArtists = list;
    });
    this.persistFavOrder(list);
  }

  /** 手势被打断：把被拖项放回原位（顺序不变）。 */
  private cancelFavDrag(): void {
    // 拖动期间数组一直没动（只是视觉收起），所以取消只需要清状态
    this.disarmFavGuard();
    this.favDragging = false;
    this.appState.sortDragActive = false;
    this.draggingFav = new ArtistApiDto();
  }

  /** 顺序落库（重启/切 tab 回来都保持）。 */
  private persistFavOrder(list: ArtistApiDto[]): void {
    const names: string[] = [];
    for (let i = 0; i < list.length; i++) {
      names.push(list[i].name);
    }
    // ① 数据库：应用内收藏的 sort_order（reloadFavorites 会按它查）
    MusicDbApi.getInstance().setFavoriteArtistOrder(names);
    // ② Preferences：**全量**顺序（含 Apple ⭐ 收藏进来的那些，见 FAV_ORDER_PREF 注释）
    this.writeFavOrderPref(names);
    Logger.info(TAG, `收藏顺序已保存（${names.length} 位）：${names.join('、')}`);
  }

  /** 写「收藏横排手动顺序」到 Preferences。 */
  private writeFavOrderPref(names: string[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      store.putSync(FAV_ORDER_PREF, JSON.stringify(names));
      store.flush();
    } catch (e) {
    }
  }

  /** 读「收藏横排手动顺序」。 */
  private readFavOrderPref(): string[] {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return [];
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync(FAV_ORDER_PREF, '') as string;
      if (txt === '') {
        return [];
      }
      return JSON.parse(txt) as string[];
    } catch (e) {
      return [];
    }
  }

  /**
   * 按保存的手动顺序重排收藏横排；不认识的（新收藏 / 新 Apple ⭐）按原顺序排在后面。
   *
   * @param list 刚拼好的收藏列表（应用内收藏在前、Apple 收藏在后）
   * @returns 重排后的列表
   */
  private applySavedOrder(list: ArtistApiDto[]): ArtistApiDto[] {
    const order: string[] = this.readFavOrderPref();
    if (order.length === 0 || list.length < 2) {
      return list;
    }
    const out: ArtistApiDto[] = [];
    for (let i = 0; i < order.length; i++) {
      for (let k = 0; k < list.length; k++) {
        if (list[k].name === order[i]) {
          out.push(list[k]);
          break;
        }
      }
    }
    for (let k = 0; k < list.length; k++) {
      let placed: boolean = false;
      for (let i = 0; i < order.length; i++) {
        if (order[i] === list[k].name) {
          placed = true;
          break;
        }
      }
      if (!placed) {
        out.push(list[k]);
      }
    }
    return out;
  }

  /** 兜底：拖动手势被系统打断（12s 没有落下）时把状态收回来。 */
  private armFavGuard(): void {
    this.disarmFavGuard();
    this.favGuardId = setTimeout(() => {
      this.favGuardId = -1;
      if (this.favDragging) {
        this.cancelFavDrag();
      }
    }, 8000);
  }

  /** 撤掉兜底定时器。 */
  private disarmFavGuard(): void {
    if (this.favGuardId !== -1) {
      clearTimeout(this.favGuardId);
      this.favGuardId = -1;
    }
  }

  /** Pushes the refreshed library snapshot to paired devices (watch browser). */
  private notifyLibraryChanged(): void {
    MusicTransferService.getInstance().publishLibraryMeta();
  }

  /**
   * Opens the artist detail page with a shared-element hero transition:
   * the row portrait flies into the detail header (geometryTransition),
   * while the system default page transition is disabled so the two
   * animations never stack. Official recipe: pushPathByName(..., false)
   * inside animateTo.
   */
  /** 重新读取收藏的艺人（按名字从当前艺人列表里取完整 DTO）。 */
  /** 资料库一就绪就刷新收藏横排（不必等 Apple 同步，那个要几十秒）。 */
  private scheduleFavoriteRefresh(): void {
    MusicDatabase.getInstance().whenReady(() => {
      setTimeout(() => {
        this.refreshFavorites();
      }, 200);
    });
  }

  private refreshFavorites(): void {
    const all: ArtistApiDto[] = MusicDbApi.getInstance().getArtists();
    const names: string[] = MusicDbApi.getInstance().getFavoriteArtistNames();
    const out: ArtistApiDto[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < names.length; i++) {
      for (let k = 0; k < all.length; k++) {
        if (all[k].name === names[i]) {
          out.push(all[k]);
          seen.add(all[k].name);
          break;
        }
      }
    }
    // Apple Music 里「收藏（⭐）」的艺人：追加在应用内收藏之后（按名字匹配本地艺人）。
    const appleNames: string[] = this.readAppleFavNames();
    for (let i = 0; i < appleNames.length; i++) {
      const idx: number = this.matchLocalArtist(all, appleNames[i]);
      if (idx < 0) {
        continue;
      }
      const localName: string = all[idx].name;
      if (seen.has(localName)) {
        continue;
      }
      out.push(all[idx]);
      seen.add(localName);
    }
    // 手动顺序优先：重启后也从这里恢复（原来只有内存顺序，重启就丢了）
    this.favoriteArtists = this.applySavedOrder(out);
    if (appleNames.length > 0) {
      const names: string[] = [];
      for (let i = 0; i < this.favoriteArtists.length; i++) {
        names.push(this.favoriteArtists[i].name);
      }
      Logger.info('ArtistsPage',
        `收藏艺人：Apple ${appleNames.length} 位 → 合计 ${this.favoriteArtists.length} 位 [${names.join('、')}]`);
    }
  }

  /**
   * 把 Apple 收藏艺人名映射到本地艺人下标。
   *
   * Apple 的资料库艺人接口给的是目录规范名（如 "Khalil Fong"），而本地曲目表里
   * 存的是本地化名（如「方大同」）；两种口径都要能对上，所以按优先级匹配：
   *   3 完全相同 → 2 别名表互查 → 1 包含关系（较长一方 ≥ 4 字符）
   *
   * @returns 命中的本地艺人下标；没命中返回 -1。
   */
  private matchLocalArtist(all: ArtistApiDto[], appleName: string): number {
    const target: string = appleName.toLowerCase().trim();
    if (target === '') {
      return -1;
    }
    const aliasLocal: string = ArtistAliasTable.localName(appleName).toLowerCase().trim();
    let best: number = -1;
    let bestScore: number = 0;
    for (let k = 0; k < all.length; k++) {
      const n: string = all[k].name.toLowerCase().trim();
      if (n === '') {
        continue;
      }
      let score: number = 0;
      if (n === target) {
        score = 3;
      } else if (aliasLocal !== '' && n === aliasLocal) {
        score = 2;
      } else if (ArtistAliasTable.lookup(all[k].name).toLowerCase().trim() === target) {
        score = 2;
      } else if (n.length >= 4 && target.includes(n)) {
        score = 1;
      } else if (target.length >= 4 && n.includes(target)) {
        score = 1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = k;
      }
    }
    return best;
  }

  /** 读收藏艺人缓存（AppleLibrarySync.syncFavorites 或本页联网刷新写入）。 */
  private readAppleFavNames(): string[] {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return [];
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync('apple_fav_artists_v1', '') as string;
      if (txt === '') {
        return [];
      }
      return JSON.parse(txt) as string[];
    } catch (e) {
      return [];
    }
  }

  private saveAppleFavNames(names: string[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      store.putSync('apple_fav_artists_v1', JSON.stringify(names));
      // 时间戳：启动同步（比页面晚）看到刚拉过就不再重复拉一遍
      store.putSync('apple_fav_at_v1', new Date().getTime());
      store.flush();
    } catch (e) {
    }
  }

  /** 收藏缓存是否刚被启动同步刷新过（5 分钟内）：是的话页面就不用再拉一遍。 */
  private favCacheFresh(): boolean {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return false;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const at: number = store.getSync('apple_fav_at_v1', 0) as number;
      if (at <= 0) {
        return false;
      }
      return (new Date().getTime() - at) < 5 * 60 * 1000;
    } catch (e) {
      return false;
    }
  }

  /** 联网刷新 Apple 收藏艺人（带 extend=inFavorites），写回缓存后重建横排。 */
  private refreshAppleFavorites(): void {
    if (this.favCacheFresh()) {
      Logger.info('ArtistsPage', 'Apple 收藏艺人缓存新鲜，跳过联网刷新');
      return;
    }
    AppleApi.getFavoriteArtistNames(2).then((names: string[]) => {
      this.saveAppleFavNames(names);
      this.refreshFavorites();
      Logger.info('ArtistsPage', `Apple 收藏艺人刷新完成：${names.length} 位`);
    }).catch(() => {
    });
  }

  private openArtist(artist: ArtistApiDto, sourceRect: HeroSourceRect, heroId?: string): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    const param: ArtistDetailParam = {
      artistName: artist.name,
      heroId: heroId !== undefined ? heroId : HeroTransitionHelper.artistHeroId(artist),
      sourceRect: sourceRect,
      artistAvatarPath: artist.coverPath
    };
    // Empty-artist detail has no hero artwork to pair with the row, so a
    // disabled system transition would make the page appear with a hard
    // cut. Fall back to the system default transition in that case only.
    if (MusicDbApi.getInstance().getAlbumsByArtist(artist.name).length === 0) {
      // Re-enable the system default transition just for this fallback,
      // then restore the stack-wide disable after the transition window.
      this.pageIndexInfos.disableAnimation(false);
      this.pageIndexInfos.pushPathByName('ArtistDetail', param, true);
      setTimeout(() => {
        this.pageIndexInfos.disableAnimation(true);
        this.isOpening = false;
      }, HeroMotion.OPEN_GUARD_MS);
      return;
    }
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

  /** 资料库同步浮层：LoadingProgress + 阶段文案（无确定进度，Apple 接口按页拉取）。 */
  @Builder
  private SyncOverlay() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(44)
        .height(44)
        .color($r('app.color.library_accent'))
      Text(this.syncPhaseText !== '' ? this.syncPhaseText : '正在同步资料库…')
        .fontSize(15)
        .fontColor($r('app.color.library_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding(32)
    .borderRadius(16)
    .backgroundColor($r('app.color.library_card_bg'))
    .shadow({ radius: 16, color: '#33000000', offsetY: 4 })
    // Keep the sync overlay above the toolbar while syncing.
    .zIndex(3)
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
        Stack() {
          if (this.artists.length === 0 && !this.syncing) {
            // Empty state: guide the user to Apple Music.
            Column({ space: 16 }) {
              CoverPlaceholder({ seed: 'artists', radius: 32, symbol: $r('sys.symbol.person_crop_circle_fill_1') })
                .width(120)
                .height(120)
              Text($r('app.string.library_no_music'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.library_text_primary'))
              Text($r('app.string.library_no_music_hint'))
                .fontSize(14)
                .fontColor($r('app.color.library_text_secondary'))
                .textAlign(TextAlign.Center)
                .lineHeight(20)
                .padding({ left: 32, right: 32 })
              Button({ type: ButtonType.Capsule }) {
                Text(this.authState.authorized
                  ? $r('app.string.library_sync_library')
                  : $r('app.string.library_login_apple_music'))
                  .fontSize(15)
                  .fontColor(Color.White)
              }
              .height(42)
              .padding({ left: 28, right: 28 })
              .backgroundColor($r('app.color.library_accent'))
              .onClick(() => {
                if (this.authState.authorized) {
                  this.syncAppleLibrary();
                } else {
                  this.authState.openLogin();
                }
              })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            // List: native Spring edge effect provides the rubber-band
            // overscroll at both edges (official behavior, no custom code).
            List({ space: 2, scroller: this.scroller }) {
              // Spacer item: keeps the large title below the toolbar/search
              // row (which starts at 64vp and is ~48vp tall), but scrolls out
              // so rows reach the screen top.
              ListItem() {
              }.height(96)
              ListItem() {
                this.LibraryTitle()
              }
              // ── 收藏的艺人：横排卡片，点它直接进这位艺人的主页 ──
              if (this.favoriteArtists.length > 0) {
                ListItem() {
                  Column({ space: 10 }) {
                    Row({ space: 6 }) {
                      SymbolGlyph($r('sys.symbol.heart_fill'))
                        .fontSize(15)
                        .fontColor(['#FF3B30'])
                      Text('收藏的艺人')
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.library_text_primary'))
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // 拖动排序：整块横排放在 Stack 里，浮起卡片叠在最上层跟手。
                    Stack({ alignContent: Alignment.TopStart }) {
                      List({ space: 14 }) {
                        ForEach(this.favoriteArtists, (artist: ArtistApiDto, index: number) => {
                          FavoriteArtistCard({
                            artist: artist,
                            // 被拿起的这张：卡位收成 0（视觉上从队伍里抽走）
                            collapsed: this.favDragging && index === this.favOriginIndex,
                            // 落点让位：落点及其后的卡片右移一个卡位。
                            // 下标要换算成「收起后」的位置（被拖那张已不占位）。
                            shiftX: (this.favDragging && this.favInsert >= 0 &&
                              (index < this.favOriginIndex ? index : index - 1) >= this.favInsert)
                              ? this.favSlotW : 0,
                            onOpen: (rect: HeroSourceRect): void => {
                              this.openArtist(artist, rect,
                                HeroTransitionHelper.favoriteArtistHeroId(artist));
                            },
                            // 拖动排序：原始触摸三件套（按下/移动/抬起），自己做长按判定
                            onHoldStart: (rect: HeroSourceRect, wx: number, wy: number): void => {
                              this.onFavHoldStart(index, rect, wx, wy);
                            },
                            onHoldMove: (wx: number, wy: number): void => {
                              this.onFavHoldMove(wx, wy);
                            },
                            onHoldEnd: (cancelled: boolean): void => {
                              this.onFavHoldEnd(cancelled);
                            }
                          })
                        }, (artist: ArtistApiDto) => `fav-${artist.name}`)
                      }
                      // 横向 List：左右滑动是它的原生能力（比 Scroll 包 Row 稳）。
                      // 拖动排序期间禁掉它自己的滚动，否则拖动会把列表一起拽走。
                      .listDirection(Axis.Horizontal)
                      .scrollBar(BarState.Off)
                      .edgeEffect(EdgeEffect.Spring)
                      .enableScrollInteraction(!this.favDragging)
                      .height(104)
                      .width('100%')
                      // 满宽：**不留左右边距**（用户要求头像能一直顶到屏幕最左/最右）。
                      // 第一个卡位就在 x=0，滚动时卡片可以整块滑出屏幕边缘。
                      .padding({ left: 0, right: 0 })

                      // 跟手的那张（被拿起的那一份）。
                      // 位移下沉到 FavoriteFloatCard 自己的 @ObservedV2 对象里：
                      // 手指每动一次只重建这张小卡片，不重建整页（跟手的关键）。
                      if (this.favDragging) {
                        Column() {
                          FavoriteFloatCard({
                            artist: this.draggingFav,
                            dragOffset: this.favOffset
                          })
                        }
                        .position({ x: this.favFloatX, y: this.favFloatY })
                        .zIndex(20)
                        .hitTestBehavior(HitTestMode.None)
                      }
                    }
                    .width('100%')
                    .height(104)
                    .onAreaChange((oldArea: Area, newArea: Area) => {
                      // 记录横排容器在窗口中的位置：手指窗口坐标要换算成容器内坐标
                      this.favRowRect = HeroSourceRect.fromArea(newArea);
                    })
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 14 })
                }
              }
              LazyForEach(this.dataSource, (row: ArtistListRow, index: number) => {
                ListItem() {
                  if (row.isHeader) {
                    this.SectionHeader(row.title, row.count)
                  } else {
                    Column() {
                      // Row divider drawn per item (official Divider); the
                      // first artist under a section header has none.
                      if (row.showDivider) {
                        Divider()
                          .strokeWidth(0.5)
                          .color($r('app.color.library_divider'))
                      }
                      ArtistRow({
                        artist: row.artist,
                          onOpen: (sourceRect: HeroSourceRect) => {
                          this.openArtist(row.artist, sourceRect);
                        }
                      })
                    }
                  }
                }
              }, (row: ArtistListRow, index: number) =>
                row.isHeader ? `hdr-${row.title}` : `${row.artist.name}-${index}`)
            }
            // 收藏卡片拖动排序期间，主列表也不跟着滚（否则手指一动整页跑）
            .enableScrollInteraction(!this.favDragging)
            .width('100%')
            .height('100%')
            // Official dynamic-blur setup: no clipping so rows scroll under
            // the title bar, cached items keep rendering through the blur.
            .clip(false)
            .cachedCount(3, true)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            // Bottom clearance for the floating HDS bar (52vp bar + 34vp
            // bottom margin + 4vp breathing room): content stops just above
            // the bar so the last row stays fully tappable.
            .padding({ bottom: 90 })
            // Large-title fade: fully visible at top, eased out over 130vp
            // (onDidScroll reports per-frame deltas; read the cumulative
            // offset from the official Scroller instead).
            .onDidScroll((offset: number, state: ScrollState) => {
            // 滚动时让全屏流光让位（停手 220ms 自动恢复），发热降频时更顺。
            FlowLightRegistry.beginScroll();
              const y = this.scroller.currentOffset().yOffset;
              this.titleFade = Math.max(0, Math.min(1, 1 - y / 130));
            })
          }

          if (this.syncing) {
            this.SyncOverlay()
          }
        }
        .width('100%')
        .height('100%')
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
    // geometryTransition only runs between NavDestination pages; the home
    // page itself must not add a system page transition on top of it.
    .systemTransition(NavigationSystemTransitionType.NONE)
    // 首页是这条栈的第一页：系统返回默认会把它也弹掉 → 栈空 → 只剩底色
    // （深色模式下就是用户看到的「黑屏，只能重启」）。这里统一消费返回事件：
    // 抽屉开着先关抽屉，否则回桌面（音乐继续后台播放）。
    .onBackPressed((): boolean => {
      return HomeBack.handle(this.getUIContext());
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/**
 * HdsNavigation shell for the artists tab. Its home content stays blank:
 * the artists list itself is pushed immediately as the first
 * NavDestination, because geometryTransition only works between two
 * NavDestination pages (never between Navigation home content and a
 * NavDestination).
 */
@ComponentV2
export struct ArtistTabShell {
  @Consumer('artistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // All artist-tab transitions are driven by geometryTransition + the
    // detail-page growth animations, so the system default page transition
    // is disabled for the whole stack (the empty-artist fallback re-enables
    // it temporarily).
    this.pageIndexInfos.disableAnimation(true);
    if (this.pageIndexInfos.size() === 0) {
      this.pageIndexInfos.pushPathByName('ArtistHome', undefined, false);
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

/** Global builder entry for the artists home route. */
@Builder
export function ArtistHomePageBuilder(name: string, param: Object) {
  ArtistsPage()
}
