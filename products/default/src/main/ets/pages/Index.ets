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

import { AppStorageV2, curves, uiObserver } from '@kit.ArkUI';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { HdsNavigation, hdsEffect, hdsMaterial } from '@kit.UIDesignKit';
import {
  AppStorageKeys,
  AppleApi,
  AppleLibrarySync,
  AppleAuthState,
  BackHandler,
  getWindowInfoState,
  AiTransConfig,
  LibrarySignal,
  Logger,
  MusicAppState,
  MusicDatabase,
  MusicDbApi,
  PlaybackIntentState,
  PlayContextKeys,
  StyleConstants,
  SyncResult,
  WindowInfo
} from 'musicbasic';
import {
  dispatchShellPlaybackIntent,
  FullPlayerSheet,
  MediaService,
  Player,
  PlayerSheetProgress
} from 'player';
import {
  AlbumsTabShell,
  AppleLoginView,
  ArtistTabShell,
  FlowLightRegistry,
  AllSongsPage,
  PlaybackHelper,
  PlaylistTabShell,
  LibrarySearchOverlay,
  SearchTabShell
} from 'library';
import { AlbumDetailParam, ArtistDetailParam, PlaylistDetailParam } from 'library';
import { HdsBarStyle, HdsTabs, HdsTabsController } from '@hms.hds.hdsBaseComponent';
import { SettingsDrawer } from '../view/SettingsDrawer';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * Default phone shell: three-section music library (Artists / Albums / All Songs)
 * and a floating mini player inside the HDS tab bar (tab bar and mini bar share
 * the official expand/collapse linkage animation). The mini player is the only
 * playback surface: tap toggles play/pause, swipe left expands it. There is no
 * full-screen playback page.
 */
@Entry
@ComponentV2
struct Index {
  /**
   * Per-tab navigation stacks. Shared NavPathStack across multiple
   * Navigations misroutes push/pop under lazy TabContent (pages landed in an
   * invisible tab and Back could not pop them), so each tab owns its stack.
   */
  @Provider('artistNavStack') artistNavStack: NavPathStack = new NavPathStack();
  @Provider('albumNavStack') albumNavStack: NavPathStack = new NavPathStack();
  @Provider('songNavStack') songNavStack: NavPathStack = new NavPathStack();
  @Provider('playlistNavStack') playlistNavStack: NavPathStack = new NavPathStack();
  @Provider('searchNavStack') searchNavStack: NavPathStack = new NavPathStack();
  /** Reactive window width / height breakpoint from the system. */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** Index of the selected bottom tab (0 = artists). */
  @Local currentTab: number = 0;
  /** 资料库统一搜索浮层是否打开（外壳上的圆形搜索按钮触发）。 */
  @Local searchOpen: boolean = false;
  /** 外壳的同步按钮是否正在同步资料库。 */
  @Local syncingLibrary: boolean = false;
  /** Shared playback and UI state (queue, mini bar, full-screen flag). */
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** External intents (e.g. tapping a song) that request starting playback. */
  @Local intentState: PlaybackIntentState =
    AppStorageV2.connect(PlaybackIntentState, AppStorageKeys.PLAYBACK_INTENT_STATE, () => new PlaybackIntentState())!;
  /** Cached window metrics (safe areas, size) for layout padding. */
  @Local windowInfo: WindowInfo = getWindowInfoState();
  /** Apple Music 登录态：控制全屏登录页的显隐。 */
  @Local authState: AppleAuthState =
    AppStorageV2.connect(AppleAuthState, AppStorageKeys.APPLE_AUTH_STATE, () => new AppleAuthState())!;
  /** Controls the HDS bar (mini bar expand / collapse). */
  @Local hdsTabsController: HdsTabsController = new HdsTabsController();
  /** 登录成功后的首次资料库同步是否已启动（只跑一次）。 */
  private loginSyncStarted: boolean = false;
  /**
   * 全 App 唯一一层流光背景的控制器。
   *
   * 之前是每个板块页面各带一层（5 个 shader），两个问题：
   * 1) 流光节点在 TabContent 里，左右切 tab 时它跟着页面一起滑 —— 用户要的是
   *    「背景不动，只有上面的 UI 和文字动」；
   * 2) 5 个全屏 shader 的创建/合成在手机发热时明显拖慢切换，还费电。
   * 现在放在 HdsTabs 外面（App 根 Stack 的第一层），切 tab、进详情页都不动它。
   */
  private uvFlowController: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();
  /**
   * 首帧之后再创建流光节点。
   *
   * shader 的第一次编译要占渲染预算，之前首页把它和页面内容一起首帧渲染，
   * 手机上表现为「首次进入某个板块先黑一下再出内容」。延后 ~260ms 创建，
   * 页面先画出来，流光再淡入。
   */
  @Local flowReady: boolean = false;
  /**
   * 当前是否深色模式（决定流光背景的配色）。
   *
   * 浅色模式用户要求（2026-09-26）：流光**更亮、去掉黑色**，只留白 + 浅蓝；
   * 深色模式保持原来的蓝灰配色。
   */
  @Local darkTheme: boolean = false;
  /**
   * 用户最近一次触摸的时间戳（被动记录，不拦截事件）。
   * 预建页面 / 后台重活都先看它：刚交互过就顺延，避免抢渲染预算。
   */
  private lastTouchAt: number = Date.now();
  /** Monotonic token so only the latest tab switch resumes flow lights. */
  private flowResumeSeq: number = 0;

  // ───────── 设置抽屉（左侧滑出） ─────────
  /** 抽屉面板的横向位移（vp）：-panelWidth 为收起，0 为展开。 */
  @Local drawerX: number = -400;
  /** 遮罩（原页面压暗）透明度。 */
  @Local drawerScrim: number = 0;
  /** 抽屉是否处于展开状态。 */
  @Local drawerOpen: boolean = false;
  /** 正在跟手拖动（拖动期间才挂载面板，收起后不占渲染）。 */
  @Local drawerDragging: boolean = false;
  /** 拖动起点：面板位移（拖动面板收起时用）。 */
  private drawerStartX: number = 0;

  // ───────── 全屏播放页（从播放条封面上滑呼出） ─────────
  /**
   * 全屏播放页是否已挂载。
   *
   * 必须**条件挂载**（不能常驻 + 位移藏起来）：PlaybackPage 的 onAppear 会改窗口
   * 形态（全屏 + 状态栏白色），常驻会让 App 一启动就套上播放页的窗口样式。
   * 反过来也不能直接 `if (isShowPlay)` 挂载 —— 动画会打在一个马上要被卸载的
   * 节点上，渲染服务报「Failed to find animation / RSPropertyType is not exist」
   * 并整窗画黑（设置抽屉那次已经踩过）。
   * 所以是：打开时先挂载（进度 0 = 尚在屏幕下方）→ 动画 → 收起动画跑完再卸载。
   */
  @Local playerMounted: boolean = false;
  /** 系统返回请求（递增）：转给播放页，让它先把歌词页收回去。 */
  @Local backRequest: number = 0;
  /** 播放页当前是否停在歌词页（由播放页上报）。 */
  @Local lyricPageOpen: boolean = false;
  /**
   * 播放页的升起进度（0 = 还在屏幕下方，1 = 完全铺满）。
   *
   * **故意不是 @Local**：跟手时它每帧都变，做成 @Local 会让 Index（挂着整个
   * HdsTabs 壳层）每帧重建。做成 @ObservedV2 对象后只有 FullPlayerSheet 刷新。
   */
  private sheetProgress: PlayerSheetProgress = new PlayerSheetProgress();
  /** 播放条封面的中心 x（vp，窗口坐标）：全屏封面动画的起点。 */
  @Local miniCoverCx: number = -1;
  /** 播放条封面的中心 y（vp，窗口坐标）。 */
  @Local miniCoverCy: number = -1;
  /**
   * 播放条封面边长（vp）。
   *
   * 用常量而不是测量值：量到的是「封面 + 进度环」那个 58vp 的 Stack，
   * 而动画起点要的是封面本身的 48vp（与 Player.coverSideVp() 一致）。
   * 两者的**中心是同一点**，所以中心量出来、尺寸写死即可。
   */
  @Local miniCoverSize: number = 48;
  /** 升起/落下动画是否正在跑（挡住 @Monitor 与手动调用的互相重入）。 */
  private playerAnimating: boolean = false;
  /** 本次拖拽到达过的最高进度：用来判断用户有没有「拖到一半又拖回去」。 */
  private sheetMaxP: number = 0;
  /**
   * 判定「松手后弹上去」的最小进度（占整个行程的比例）。
   *
   * 0.28 —— 滑过约三成行程就展开，不需要「划得很重」。
   * 之所以能这么松，是因为「拖到一半又拖回去」不再靠这个阈值来挡，
   * 而是靠 {@link SHEET_RETREAT_RATIO} 判断「有没有回撤过」。
   */
  private static readonly SHEET_COMMIT_RATIO: number = 0.28;
  /** 判定「快速上甩」的最小速度（vp/s，向上为负）；轻扫就能达到。 */
  private static readonly SHEET_COMMIT_VELOCITY_VP: number = 420;
  /** 走「速度」这条快速通道时，至少要滑过的进度（防止原地抖一下就展开）。 */
  private static readonly SHEET_FLICK_MIN_RATIO: number = 0.15;
  /**
   * 「回撤」判定：本次拖拽到达过的最高进度，比松手时高出这么多，
   * 就认为用户中途把封面拖回去了 —— 整个流程被打断，不展开。
   */
  private static readonly SHEET_RETREAT_RATIO: number = 0.18;
  /** 手指要拖多少屏高的比例才能把播放页完全拉出来（越小越容易拉满）。 */
  private static readonly SHEET_SPAN_RATIO: number = 0.52;
  /** 播放条胶囊高度（vp）：HDS 悬浮 bar 的 barHeight，折叠/展开都一样。 */
  private static readonly BAR_HEIGHT_VP: number = 60;
  /**
   * 播放条胶囊右边距（vp）。
   *
   * **16.0**：2026-10-31 用 `uitest dumpLayout` 量的真机几何（1260×2720 px，
   * density 3.25）—— miniBar 那个 60vp 方槽的 bounds 是 `[1013,2414][1208,2609]`，
   * 即 vp `311.69..371.69`，所以右边距 = (1260−1208)/3.25 = **16.0**（原来是按 17 估的）。
   * 这 1vp 会直接挪动封面落点，收回时就是「偏左一点」的来源。
   */
  private static readonly BAR_RIGHT_MARGIN_VP: number = 16;
  /**
   * 播放条封面的圆心，相对胶囊（60vp 方槽）**左上角**的偏移（vp）。
   *
   * **29.8462（x / y 相同）**，不是 30：槽里的布局是
   * `Row(padding left 1, right 4)` + 封面外套一个 58vp 的进度环。
   * 内容盒只有 55 < 58，ArkUI 不会居中而是**靠左排**（这个坑记在项目记忆里），
   * 于是环占 `槽左+1 .. 槽左+59`（px 1016..1205），圆心 = 槽左 + 30；
   * 而封面（48）在环里居中后落在 px `1032..1188`，**光栅化后的实际圆心**
   * = 1110px = 槽左 + 29.8462。落点要和眼睛看到的那颗封面重合，就按这个数。
   *
   * 历史教训：原来把 x 写成 30.54（圆拟合）、右边距写成 17，两者叠加后
   * 落点偏左 0.31vp（≈1px）、偏下 0.14vp —— 正是用户反馈的「落地时封面
   * 稍微偏左下一点点点点」。以后这个数只能用 dumpLayout 复量，不要靠截图估。
   */
  private static readonly BAR_COVER_OFFSET_X_VP: number = 29.8462;
  /** 播放条封面圆心相对方槽顶边的偏移（vp）：与 x 同源，见上一条注释。 */
  private static readonly BAR_COVER_OFFSET_Y_VP: number = 29.8462;
  /**
   * 播放条方槽底边到屏幕底的距离（vp）。
   *
   * **34.1538** = (2720−2609)/3.25，同一份 dumpLayout 量的（槽底 px 2609）。
   * 原来是 34.17（旧版截图量的），会让落点偏低 0.02vp；更重要的是 y 也不能再
   * 用「槽高的一半」凑，必须用上面的 {@link BAR_COVER_OFFSET_Y_VP}。
   */
  private static readonly BAR_BOTTOM_MARGIN_VP: number = 34.1538;

  /** 读一次当前生效的深浅色（跟随系统时也能拿到实际值），变化时刷新流光配色。 */
  private refreshTheme(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx === undefined) {
        return;
      }
      // config.colorMode 是「当前实际生效」的深浅色（跟随系统时也准）
      const dark: boolean = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      if (dark !== this.darkTheme) {
        this.darkTheme = dark;
        Logger.info('Index', '外观模式切换为 ' + (dark ? '深色' : '浅色'));
      }
    } catch (e) {
    }
  }

  /** 初始化播放队列 + Apple 登录态。 */
  aboutToAppear() {
    this.refreshTheme();
    // 读回用户在设置里填的 AI 翻译 key（没填过就保持内置默认值）
    const bootCtx = this.getUIContext().getHostContext();
    if (bootCtx !== undefined) {
      AiTransConfig.init(bootCtx).catch(() => {
      });
    }
    // 系统返回 / 侧滑返回：把处理逻辑注册到 Ability 那级。
    // （实测本页的 onBackPress 在 HDS 壳层下收不到侧滑返回，必须兜这一层。）
    BackHandler.register((): boolean => this.handleSystemBack());
    // 诊断：启动 2s 后确认播放条封面上报的起点（封面动画全靠它）。
    setTimeout(() => {
      Logger.info('Index', '诊断 miniCover 起点 vp=(' + this.miniCoverCx.toFixed(1) + ',' +
        this.miniCoverCy.toFixed(1) + ') 屏 ' + this.screenWidthVp().toFixed(0) + 'x' +
        this.screenHeightVp().toFixed(0));
    }, 2000);
    // 队列只在「没有可恢复会话」时才用整库兜底。以前无条件写整库，
    // 会在 EntryAbility 恢复专辑队列之后把它顶掉（表现：重启后播放条是
    // 别的歌 / 播完专辑还接着放整库）。
    this.fillQueueIfEmpty();
    this.authState.refreshFromApi();
    // 把 App 层唯一那层流光交给调度台：列表滚动时它会临时暂停，停手后恢复。
    FlowLightRegistry.attach(this.uvFlowController);
    // 首帧之后再建流光（见 flowReady 注释）。
    setTimeout(() => {
      this.flowReady = true;
    }, 260);
    // 冷启动时 DB 还没加载完，getSongList() 会是空；必须等 DB ready 再判断，
    // 否则已登录用户也会被弹登录页。
    // 分批把其余板块页在后台建好。
    //
    // TabContent 默认「首次显示才创建」：第一次点某个 tab 要现建整页（列表 +
    // 标题栏 + 卡片），用户看到的是「先黑/空一下才出内容」。启动后错峰预建，
    // 既躲开首屏渲染，也躲开资料库同步那一波网络/数据库压力。
    this.preloadAllTabs();
    MusicDatabase.getInstance().whenReady(() => {      setTimeout(() => {
        this.fillQueueIfEmpty();
        // 未登录一律先给登录页（换手机 / 换账号后的「原始页面」）。
        // 用户点左上角 X 可以先跳过，去看本机已有的资料库内容。
        if (!this.authState.authorized) {
          this.authState.openLogin();
        }
        // 冷启动时 DB 还没加载完，getSongList() 会是空；必须等 DB ready 再判断，
        // 否则已登录用户也会被弹登录页。
      }, 120);
    });
  }

  /**
   * 回到前台时重新读一次深浅色：跟随系统时用户可能在系统设置里切了模式，
   * 或者从别的页面返回 —— 流光配色要跟着切（浅色 = 白 + 浅蓝）。
   */
  onPageShow(): void {
    this.refreshTheme();
  }

  /**
   * 错峰预建其余 tab 页面（官方 TabsController.preloadItems）。
   *
   * 顺序按「用户最常先点」排：搜索 → 专辑 → 歌曲/歌单；每一步都留出间隔，
   * 避免一次性四页构建把首屏和同步挤在同一拍上（发热时尤其明显）。
   */
  private preloadAllTabs(): void {
    // 2026-09 真机时间线实测（HarmonyOS 7）：原来 1500/2900/4300ms 的三批预建
    // 正好落在用户刚进 App 的那两秒，每次都整页构建 → 用户体感「打开卡一两秒」。
    // 现在改成：① 顺序按常用度（专辑 → 歌曲/歌单 → 搜索页最后，它最重也最少用）；
    //          ② 间隔拉到 4s/9s/16s；③ 每次预建前检查「用户是否刚碰过屏幕」，
    //             刚碰过就顺延 3s（最多顺延 4 次），保证预建永不和交互抢渲染。
    const plan: number[][] = [[1], [2, 3], [4]];
    const baseDelay: number = 4000;
    const step: number = 5000;
    for (let i = 0; i < plan.length; i++) {
      this.preloadBatchLater(plan[i], baseDelay + i * step, 0);
    }
  }

  /**
   * 延迟预建一批页面；若用户刚有触摸则顺延重试。
   *
   * @param batch 要预建的 tab 下标
   * @param delay 延迟毫秒
   * @param retry 已经顺延次数（超过 4 次就直接预建，避免永远不预建）
   */
  private preloadBatchLater(batch: number[], delay: number, retry: number): void {
    setTimeout(() => {
      const idleMs: number = Date.now() - this.lastTouchAt;
      if (retry < 4 && idleMs < 1200) {
        this.preloadBatchLater(batch, 3000, retry + 1);
        return;
      }
      // 预建期间让流光让位（整页构建是 CPU/GPU 双高峰）
      this.pauseFlowTemporarily(700);
      this.hdsTabsController.preloadItems(batch).then(() => {
        Logger.info('Index', 'preloadItems ok: ' + JSON.stringify(batch));
      }).catch((e: Error) => {
        Logger.warn('Index', 'preloadItems failed: ' + (e.message ?? ''));
      });
    }, delay);
  }

  /**
   * 临时停掉流光 ms 毫秒（复用切 tab 时那套「序号守卫」，避免多次暂停互相踩）。
   *
   * @param ms 暂停时长（毫秒）
   */
  private pauseFlowTemporarily(ms: number): void {
    this.uvFlowController.pause();
    this.flowResumeSeq += 1;
    const seq: number = this.flowResumeSeq;
    setTimeout(() => {
      if (seq === this.flowResumeSeq) {
        this.uvFlowController.resume();
      }
    }, ms);
  }

  /**
   * 外壳的同步按钮：重新拉取 Apple Music 资料库（歌曲 + 歌单 + 歌单曲目）。
   *
   * 以前这是各板块页自己工具栏里的按钮（艺人页 / 歌单页各一个），现在统一到外壳：
   * 这样它和右边的搜索按钮一样，切 tab 时不动、每个页面都在。
   */
  private async syncLibraryNow(): Promise<void> {
    if (this.syncingLibrary) {
      return;
    }
    this.syncingLibrary = true;
    try {
      await AppleApi.ensureDeveloperToken();
      const songs: SyncResult = await AppleLibrarySync.syncSongs(undefined, true);
      await AppleLibrarySync.syncPlaylists();
      await AppleLibrarySync.syncAllPlaylistTracks(true);
      MediaService.getInstance().remapQueueAfterSync();
      LibrarySignal.notifyChanged();
      this.getUIContext().getPromptAction().showToast({
        message: songs.ok ? `资料库已同步：${songs.songs} 首` : `同步失败：${songs.message}`
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '同步失败，请检查网络或重新登录' });
    }
    this.syncingLibrary = false;
  }

  // ───────── 资料库统一搜索结果的跳转 ─────────
  //
  // 每个板块详情页的返回逻辑都绑定在「自己那条导航栈」上，所以搜索结果不能随便
  // push 到当前 tab 的栈里 —— 必须切到该内容所属的板块，再往它的栈上推。

  /** 打开艺人主页：切到艺人板块再推详情。 */
  private openArtistFromSearch(name: string): void {
    this.searchOpen = false;
    if (name === '') {
      return;
    }
    this.hdsTabsController.changeIndex(0);
    const param: ArtistDetailParam = { artistName: name };
    this.artistNavStack.pushPathByName('ArtistDetail', param, false);
  }

  /** 打开专辑详情页：切到专辑板块再推详情。 */
  private openAlbumFromSearch(name: string, artist: string): void {
    this.searchOpen = false;
    if (name === '') {
      return;
    }
    this.hdsTabsController.changeIndex(1);
    const param: AlbumDetailParam = { albumName: name, artistName: artist };
    this.albumNavStack.pushPathByName('AlbumDetail', param, false);
  }

  /** 打开歌单详情页：切到歌单板块再推详情。 */
  private openPlaylistFromSearch(id: string, name: string): void {
    this.searchOpen = false;
    if (id === '') {
      return;
    }
    this.hdsTabsController.changeIndex(3);
    const param: PlaylistDetailParam = { playlistId: id, name: name };
    this.playlistNavStack.pushPathByName('PlaylistDetail', param, false);
  }

  /**
   * 队列兜底：只有当前队列为空时才填资料库全量。
   * 已恢复的专辑 / 歌单队列必须原样保留（用户要求「重启后接着上次的列表」）。
   */
  private fillQueueIfEmpty(): void {
    if (this.appState.playQueueIds.length > 0 || this.appState.playQueueUris.length > 0) {
      return;
    }
    const songs = MusicDbApi.getInstance().getSongList();
    if (songs.length > 0) {
      this.appState.playQueueIds = songs.map((dto) => dto.id);
      this.appState.playQueueUris = songs.map((dto) => dto.src);
    }
  }

  // ───────── 设置抽屉的尺寸与开合 ─────────

  /** 抽屉面板宽度（vp）：约 82% 屏宽，短屏略窄。 */
  private panelWidthVp(): number {
    return this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM ? 280 : 340;
  }

  /** 展开抽屉（官方 spring 回弹）。 */
  private openDrawer(): void {
    this.drawerOpen = true;
    this.appState.drawerOpen = true;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.78, 0.05) }, () => {
      this.drawerX = 0;
      this.drawerScrim = 0.45;
    });
  }

  /** 收起抽屉（回弹到屏幕外）。 */
  private closeDrawer(): void {
    this.drawerOpen = false;
    this.appState.drawerOpen = false;
    this.drawerDragging = false;
    // 抽屉里能改外观模式：收起时顺手刷新流光配色（浅色/深色两套）
    this.refreshTheme();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.86, 0.05) }, () => {
      this.drawerX = -this.panelWidthVp() - 40;
      this.drawerScrim = 0;
    });
  }

  // ───────── 全屏播放页的开合 ─────────
  //
  // 触发点：播放条（Player）封面上向上滑 —— 折叠态封面居中、展开态封面在最左，
  // 两态封面都在，所以「折叠 / 展开都能上滑呼出」（用户 2026-10-03 要求）。

  /** 屏幕高度（vp）：把播放页整页藏到屏幕下方所需的位移量。 */
  private screenHeightVp(): number {
    const hPx: number = this.windowInfo.windowSize.height;
    if (hPx > 0) {
      return this.getUIContext().px2vp(hPx);
    }
    return 800;
  }

  /** 屏幕宽度（vp）。 */
  private screenWidthVp(): number {
    const wPx: number = this.windowInfo.windowSize.width;
    if (wPx > 0) {
      return this.getUIContext().px2vp(wPx);
    }
    return 420;
  }

  /**
   * 播放条封面位置：**全部按真机布局实测出来的几何推算**。
   *
   * 为什么不信任组件上报：HDS 是用一层位移把播放条摆到右下角的，子组件拿到的
   * onAreaChange.globalPosition / getRectangleById **都不含那层平移**
   * （实测折叠态报 x=0.9vp、y=806.9vp，而真值是 311.7+29.85 = 341.54vp）。
   *
   * 实测数据（2026-10-31 `uitest dumpLayout`，1260×2720 px / density 3.25 = 387.69×836.92vp）：
   *
   * | 节点 | px bounds | vp |
   * |---|---|---|
   * | miniBar 60vp 方槽 | `[1013,2414][1208,2609]` | `x 311.69..371.69, y 742.77..802.77` |
   * | 槽里的封面（48vp） | `[1032,2433][1188,2589]` | 圆心 **(341.54, 772.62)** |
   * | 进度环（58vp） | `[1016,2417][1205,2606]` | 圆心 (341.69, 772.77) |
   *
   * 于是：右边距 = (1260−1208)/3.25 = 16.0；底边距 = (2720−2609)/3.25 = 34.1538；
   * 封面圆心相对槽左上角 = 29.8462（环 58 > Row 内容盒 55，靠左排 → 封面在环里居中后
   * 被光栅化到 px 1032..1188，圆心就是 29.8462）。**取的是封面自己的圆心，不是环心** ——
   * 用户眼睛比对的是两颗封面，不是环。
   */
  private estimateMiniCoverCxVp(): number {
    const rightEdge: number = this.screenWidthVp() - Index.BAR_RIGHT_MARGIN_VP;
    const barW: number = this.appState.miniBarExpanded
      ? this.expandedPlayerBarWidthVp() : Index.BAR_HEIGHT_VP;
    // 方槽左边缘 + 封面圆心相对左边缘的偏移（29.8462，见常量注释）
    return rightEdge - barW + Index.BAR_COVER_OFFSET_X_VP;
  }

  /**
   * 播放条封面中心 y（vp）。
   *
   * 不能再用「槽高的一半（30）」凑：封面在 58vp 的环里居中，光栅化后圆心比槽心
   * 高 0.1538vp。收起时这点差值就是「落点偏下一点点」的来源之一。
   */
  private estimateMiniCoverCyVp(): number {
    const barTop: number = this.screenHeightVp() - Index.BAR_BOTTOM_MARGIN_VP - Index.BAR_HEIGHT_VP;
    return barTop + Index.BAR_COVER_OFFSET_Y_VP;
  }

  /** 播放条胶囊左边缘 x（vp）：播放页背景就是从这个胶囊「长」出来的。 */
  private barLeftVp(): number {
    return this.screenWidthVp() - Index.BAR_RIGHT_MARGIN_VP - this.barWidthVp();
  }

  /** 播放条胶囊宽度（vp）。 */
  private barWidthVp(): number {
    return this.appState.miniBarExpanded ? this.expandedPlayerBarWidthVp() : Index.BAR_HEIGHT_VP;
  }

  /** 播放条胶囊顶边 y（vp）。 */
  private barTopVp(): number {
    return this.screenHeightVp() - Index.BAR_BOTTOM_MARGIN_VP - Index.BAR_HEIGHT_VP;
  }

  /** 手指把播放页完全拉出来所需的位移（vp）。 */
  private sheetSpanVp(): number {
    return this.screenHeightVp() * Index.SHEET_SPAN_RATIO;
  }

  /** 上滑位移（vp，向上为正）→ 升起进度 0..1。 */
  private sheetRatioOf(upVp: number): number {
    const span: number = this.sheetSpanVp();
    if (span <= 0) {
      return 0;
    }
    const r: number = upVp / span;
    return r < 0 ? 0 : (r > 1 ? 1 : r);
  }

  /** 起手越过阈值：挂载播放页（进度仍是 0，所以它还完全藏在屏幕下方）。 */
  private onSheetStart(): void {
    if (this.playerAnimating) {
      return;
    }
    // 队列为空时没有「当前歌曲」，拉出来也只是个空壳 —— 干脆不挂载。
    if (this.appState.playQueueIds.length === 0) {
      return;
    }
    // 每次开始拖拽时按当前折叠/展开状态重算封面的起点。
    // （封面的 onAreaChange 在胶囊变宽时不会触发，所以必须在这里算。）
    this.miniCoverCx = this.estimateMiniCoverCxVp();
    this.miniCoverCy = this.estimateMiniCoverCyVp();
    // 语义标记先置位：播放页内部会读它。
    this.appState.isShowPlay = true;
    this.sheetMaxP = 0;
    if (this.playerMounted) {
      return;
    }
    // 手指已经动了（>3vp）才挂载：这就是「一碰就进入可拖动状态」。
    // 注意**不能在 TouchDown 时预挂载** —— 播放页 onAppear 会切换窗口形态
    // （全屏 + 状态栏反色），那一瞬间的闪动会被感知成「页面直接弹出来了」。
    this.sheetProgress.value = 0;
    this.playerMounted = true;
  }

  /**
   * 跟手：官方 responsiveSpringMotion。
   *
   * 这条曲线是官方专门给「跟手阶段」准备的 —— 它比 springMotion 更快收敛到目标值，
   * 并且会把当前速度记下来交给离手那一次 springMotion 接住。所以「甩一下」这个
   * 动作能被完整表达（松手后还在往上冲），而不是松手瞬间僵住再重新起步。
   */
  private onSheetDrag(upVp: number): void {
    if (!this.playerMounted) {
      return;
    }
    const p: number = this.sheetRatioOf(upVp);
    // 记下本次拖拽到过的最高点，松手时用来判断「有没有回撤」。
    if (p > this.sheetMaxP) {
      this.sheetMaxP = p;
    }
    // 跟手曲线：response 越小越贴手，0.32 基本做到「手指到哪页面到哪」。
    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion(0.32, 0.9) }, () => {
      this.sheetProgress.value = p;
    });
  }

  /**
   * 松手：决定弹上去还是弹回。
   *
   * 三条判据（满足其一即展开，但都要求「没回撤过」）：
   *  1. 松手时进度 ≥ 0.28（滑过约三成行程）—— 门槛放低，不用「划得很重」；
   *  2. 明显向上甩（速度 ≤ −420vp/s）且进度 ≥ 0.15 —— 轻扫也能触发；
   *  3. 回撤过大（本次到过的最高点比松手时高 0.18 以上）→ **一律不展开**。
   *     这条专门对付「拖到一半又拖回去」：位置阈值再低也不会误触发，
   *     因为打断流程时一定有明显的回撤。
   */
  private onSheetRelease(upVp: number, velocityVp: number): void {
    if (!this.playerMounted) {
      return;
    }
    const p: number = this.sheetRatioOf(upVp);
    const retreated: boolean = this.sheetMaxP - p > Index.SHEET_RETREAT_RATIO;
    const reached: boolean = p >= Index.SHEET_COMMIT_RATIO ||
      (p >= Index.SHEET_FLICK_MIN_RATIO && velocityVp <= -Index.SHEET_COMMIT_VELOCITY_VP);
    const shouldOpen: boolean = !retreated && reached;
    this.sheetMaxP = 0;
    this.animateSheetTo(shouldOpen);
  }

  /**
   * 播放页升起 / 落下的唯一动画（官方 springMotion）。
   *
   * **参数是从官方音乐 App 的录屏里逐帧量出来的**（388×837vp，59.47fps）：
   * 卡片顶边从 750.7vp 走到 0 用了 24 帧 ≈ 0.40s，曲线是「慢起—快中—缓收」，
   * 而且**没有过冲**（顶边单调收敛）。
   *
   * response 0.45：收敛时间约 0.35~0.40s，与录屏一致（原来 0.62 明显偏慢）。
   * dampingFraction 0.9：几乎不过冲 —— **过冲只留给封面那一个元素**，
   * 卡片（背景 + 内容）用 clamp 过的进度，不受这点过冲影响。
   */
  private animateSheetTo(open: boolean): void {
    this.playerAnimating = true;
    this.getUIContext().animateTo({
      curve: curves.springMotion(0.45, 0.9, 0.06),
      onFinish: () => {
        this.playerAnimating = false;
        if (this.sheetProgress.value <= 0.001) {
          // 交还封面：收起动画已经落到底，页内那颗封面正好停在播放条那颗的
          // 圆心上（同一帧内换手，看不出接缝）。正常由播放页的 @Monitor 在
          // 进度 ≤0.0005 时换回来，这里兜底一次，防止某一帧被跳过。
          this.sheetProgress.barCoverVisible = true;
          // 卸载：PhonePlaybackPage 的 onDisAppear 会顺手把窗口形态恢复回去。
          this.playerMounted = false;
          this.appState.isShowPlay = false;
        }
      }
    }, () => {
      this.sheetProgress.value = open ? 1 : 0;
    });
  }

  /** 程序化收起（返回键走这条）。 */
  private closeFullPlayer(): void {
    if (this.playerAnimating || !this.playerMounted) {
      return;
    }
    this.animateSheetTo(false);
  }

  /**
   * 播放页**内部**（下拉超过阈值 / 点收起）把 isShowPlay 置 false 时，
   * 这里补上收起动画 —— 外部改标记也走同一条路径，才不会「标记没了页面还在」。
   */
  @Monitor('appState.isShowPlay')
  onShowPlayChanged(): void {
    if (!this.appState.isShowPlay && this.playerMounted && this.sheetProgress.value > 0.001) {
      this.closeFullPlayer();
    }
  }

  /** 播放页开着时，系统返回（含侧滑返回）= 收起播放页（而不是退出 App）。 */
  onBackPress(): boolean {
    return this.handleSystemBack();
  }

  /**
   * 返回键 / 侧滑返回的统一处理。
   *
   * 两条入口都会走到这里：页面自己的 onBackPress，以及 EntryAbility.onBackPress
   * 通过 {@link BackHandler} 转发（实测前者在 HDS 壳层下收不到侧滑返回）。
   *
   * @returns true = 已消费（不退出应用）
   */
  private handleSystemBack(): boolean {
    const open: boolean = this.playerMounted && this.sheetProgress.value > 0.01;
    Logger.info('Index', 'handleSystemBack: mounted=' + this.playerMounted +
      ' progress=' + this.sheetProgress.value.toFixed(2));
    if (open) {
      // 分层返回（与系统返回手势/返回键共用这一条链路）：
      //   歌词页 → 先回封面页；封面页 → 才收起整个播放页。
      if (this.lyricPageOpen) {
        this.backRequest++;
        return true;
      }
      // 收起动画照旧（用户要求「侧滑返回也要保留完整的退出动画」）。
      this.closeFullPlayer();
      return true;
    }
    return false;
  }

  // ───────── 设置抽屉的横滑手势 ─────────
  //
  // 这里**只挂在两条很窄的组件**上（见 build 里的抽屉把手条与面板本身），
  // 不能像以前那样挂在整个根 Stack 上：整屏 priorityGesture 会吃掉页内所有
  // 横向手势 —— 用户反馈「收藏横排左右滑不动」「长按拖动排序有 bug」，
  // 根因就是它把 Pan 抢走了。

  /** 抽屉横滑起手。 */
  private drawerPanStart(event: GestureEvent): void {
    // 面板靠位移移出屏幕时，它的手势仍可能被外面的横滑命中（用户实测：
    // 在底部播放条上右滑切歌，把面板「跟手拖了出来」）。收起状态下直接忽略。
    if (!this.drawerOpen && !this.drawerDragging) {
      return;
    }
    const width: number = this.panelWidthVp();
    this.drawerStartX = this.drawerOpen ? this.drawerX : -width;
    this.drawerDragging = true;
  }

  /** 抽屉横滑中：跟手位移 + 遮罩渐变。 */
  private drawerPanUpdate(event: GestureEvent): void {
    if (!this.drawerOpen && !this.drawerDragging) {
      return;
    }
    const width: number = this.panelWidthVp();
    const delta: number = this.getUIContext().px2vp(event.offsetX);
    let x: number = this.drawerStartX + delta;
    if (x < -width) {
      x = -width;
    }
    if (x > 0) {
      x = 0;
    }
    this.drawerX = x;
    this.drawerScrim = (x + width) / width * 0.45;
  }

  /** 抽屉横滑结束：过了面板宽度 1/4 或快速一甩就展开。 */
  private drawerPanEnd(event: GestureEvent): void {
    if (!this.drawerOpen && !this.drawerDragging) {
      return;
    }
    const width: number = this.panelWidthVp();
    const velocity: number = this.getUIContext().px2vp(event.velocityX);
    const shouldOpen: boolean = this.drawerX > -width * 0.25 || velocity > 150;
    this.drawerDragging = false;
    if (shouldOpen) {
      this.openDrawer();
    } else {
      this.closeDrawer();
    }
  }

  /** 登录页显隐变化时记一笔（诊断用）。 */
  @Monitor('authState.loginVisible')
  onLoginVisibleChanged(): void {
  }

  /**
   * Dispatches playback intents (song taps) into MediaService. The UI-open
   * callback is intentionally a no-op: there is no full-screen player page,
   * playback starts in the floating mini bar.
   */
  /**
   * 首页按返回时会把共享标记置 false（见 HomeBack）：这里补播放收起动画。
   * 常驻挂载的面板靠位移移出屏幕，所以外部改标记也要走同一条动画路径。
   */
  @Monitor('authState.authorized')
  onAuthorizedChanged(): void {
    // 登录页检测到登录态后会立刻关掉自己回到主界面，资料库同步挪到这里后台跑：
    // 同步要写 2700+ 首，以前放在关页之前，表现是「点了『我已登录』半天没反应」。
    if (this.authState.authorized && !this.loginSyncStarted) {
      // 登录页现在自己带进度把资料库拉完才关页（AppleLoginView.syncLibrary），
      // 这里只在「登录页没参与」的情况下兜底，避免同步跑两遍。
      if (this.authState.loginVisible || this.authState.loginSynced) {
        return;
      }
      this.loginSyncStarted = true;
      this.syncAfterLogin();
    }
  }

  /**
   * 登录成功后的首次资料库同步（后台，不阻塞 UI）。
   *
   * 与右上角手动同步的区别：这里只跑一次，且失败只在后台记日志，不打断用户。
   */
  private async syncAfterLogin(): Promise<void> {
    try {
      await AppleApi.ensureDeveloperToken();
      await AppleApi.getAccountInfo();
      const songs: SyncResult = await AppleLibrarySync.syncSongs(undefined, true);
      await AppleLibrarySync.syncPlaylists();
      MediaService.getInstance().remapQueueAfterSync();
      LibrarySignal.notifyChanged();
      this.authState.refreshFromApi();
      Logger.info('Index', '登录后的首次资料库同步完成 songs=' + songs.songs);
    } catch (e) {
      Logger.warn('Index', '登录后的首次资料库同步失败：' + JSON.stringify(e));
    }
  }

  @Monitor('appState.drawerOpen')
  onDrawerFlagChanged(): void {
    if (this.appState.drawerOpen) {
      if (!this.drawerOpen) {
        this.openDrawer();
      }
    } else if (this.drawerOpen) {
      this.closeDrawer();
    }
  }

  @Monitor('intentState.requestVersion')
  onPlaybackIntentChanged() {
    dispatchShellPlaybackIntent(this.appState, this.intentState, () => {
    });
  }

  /**
   * Bottom inset (vp) for the floating tab bar. The HDS bar keeps a ~20vp
   * gesture-bar gap internally; 10vp extra on short SM layouts keeps the bar
   * a touch above the screen edge, 30vp on regular layouts.
   */
  private homeTabBarBottomMarginVp(): number {
    return this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
      this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD ? 14 : 34;
  }

  /**
   * Small-width breakpoint (vp) for the collapsed floating tab bar. A wider
   * side margin keeps the three-section bar visibly shorter than the screen.
   */
  private tabBarSmallWidthVp(): number {
    const wPx = this.windowInfo.windowSize.width;
    if (wPx > 0) {
      const wVp = this.getUIContext().px2vp(wPx);
      // 加长 tab 胶囊：原来 wVp-160 会在它右侧与折叠播放条之间留出约 76vp 的空隙，
      // 现在按「展开播放条同宽」取 wVp-96（与右侧圆钮两边各留约 12vp，不挨着）。
      return Math.max(wVp - 96, 250);
    }
    return 292;
  }

  /**
   * Width (vp) for the expanded mini player. The expanded player keeps its
   * previous, wider geometry so transport controls stay comfortably spaced
   * while the collapsed tab bar is narrower.
   */
  private expandedPlayerBarWidthVp(): number {
    const wPx = this.windowInfo.windowSize.width;
    if (wPx > 0) {
      return this.getUIContext().px2vp(wPx) - 96;
    }
    return 324;
  }

  /** Single bottom-tab label: icon + title, styled by selection. */
  @Builder
  private TabBarItem(index: number, title: Resource, symbol: Resource) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol)
        .fontSize(22)
        .fontWeight(FontWeight.Regular)
        .height(22)
        .fontColor([this.currentTab === index ? '#0A59F7' : $r('sys.color.icon_primary')])
        // Official bounce effect: the icon hops once when its tab becomes
        // selected (isActive flips false → true on tab change).
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), this.currentTab === index)
      Text(title)
        .fontSize(11)
        .fontColor(this.currentTab === index ? '#0A59F7' : $r('sys.color.icon_primary'))
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(16)
  }

  /** Syncs expanded/collapsed mini bar style into {@link MusicAppState.miniBarExpanded}. */
  private onMiniBarStyleChange(miniBarStyle: HdsBarStyle): void {
    if (miniBarStyle === HdsBarStyle.EXPAND) {
      this.appState.miniBarExpanded = true;
    } else {
      this.appState.miniBarExpanded = false;
    }
  }

  /** Compact mini player row shown inside the floating HDS bar. */
  @Builder
  private miniBar() {
    Column() {
      Player({
        dockAtBottom: true,
        expandedBarWidthVp: this.expandedPlayerBarWidthVp(),
        isBarExpanded: this.appState.miniBarExpanded,
        // 同一个进度容器：播放条封面据此「让位 / 换回来」，
        // 与播放页封面做交接（任何时刻屏幕上只有一枚封面）。
        sheet: this.sheetProgress,
        onExpandRequest: (): void => {
          this.hdsTabsController.applyMiniBarStyle(HdsBarStyle.EXPAND);
        },
        // 封面向上滑（折叠/展开都生效）→ 全屏播放页跟手从屏幕下方升起，
        // 松手由官方 springMotion 接住完成（或弹回去）。
        onPlayerSheetStart: (): void => {
          this.onSheetStart();
        },
        onPlayerSheetDrag: (upVp: number): void => {
          this.onSheetDrag(upVp);
        },
        onPlayerSheetRelease: (upVp: number, velocityVp: number): void => {
          this.onSheetRelease(upVp, velocityVp);
        }
      })
    }
    // 折叠态就是 bar 高度见方的圆槽（HDS 按 barHeight 给，这里给同宽保证封面居中）；
    // 展开态由外壳按 miniBarWidth 给宽度。
    .width(this.appState.miniBarExpanded ? this.expandedPlayerBarWidthVp() : 60)
    .height(60)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private ArtistsTab() {
    Column() {
      ArtistTabShell()
    }
    .width(StyleConstants.FULL_WIDTH)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
  }

  /**
   * Albums tab page: AlbumsTabShell hosts its own HdsNavigation and pushes
   * the album grid as a NavDestination so shared-element transitions work.
   */
  @Builder
  private AlbumsTab() {
    Column() {
      AlbumsTabShell()
    }
    .width(StyleConstants.FULL_WIDTH)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
  }

  /**
   * All-songs tab page: AllSongsPage hosts its own HdsNavigation (title bar
   * with official GRADIENT_BLUR), so the tab shell stays a plain container.
   */
  @Builder
  private SongsTab() {
    Column() {
      AllSongsPage()
    }
    .width(StyleConstants.FULL_WIDTH)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
  }

  /**
   * 歌单 tab 页面：Apple Music 资料库歌单（账号自己建的那些）。
   */
  @Builder
  private PlaylistsTab() {
    Column() {
      PlaylistTabShell()
    }
    .width(StyleConstants.FULL_WIDTH)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
  }

  /** 搜索板块：最右 tab，只搜 Apple Music 目录（自有导航栈 + 共享元素转场）。 */
  @Builder
  private SearchTab() {
    Column() {
      SearchTabShell()
    }
    .width(StyleConstants.FULL_WIDTH)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
  }

  /** Tab pages: artists / albums / all songs / playlists / search, each in its own Navigation. */
  @Builder
  private HomeTabsPages() {
    TabContent() {
      this.ArtistsTab()
    }
    .tabBar(this.TabBarItem(0, $r('app.string.tab_artists'), $r('sys.symbol.person_crop_circle_fill_1')))

    TabContent() {
      this.AlbumsTab()
    }
    .tabBar(this.TabBarItem(1, $r('app.string.tab_albums'), $r('sys.symbol.dot_grid_2x2')))

    TabContent() {
      this.SongsTab()
    }
    .tabBar(this.TabBarItem(2, $r('app.string.tab_all_songs'), $r('sys.symbol.music_note_list')))

    TabContent() {
      this.PlaylistsTab()
    }
    .tabBar(this.TabBarItem(3, $r('app.string.tab_playlists'), $r('sys.symbol.list_checkmask')))

    TabContent() {
      this.SearchTab()
    }
    .tabBar(this.TabBarItem(4, $r('app.string.tab_search'), $r('sys.symbol.magnifyingglass')))
  }

  /**
   * Root UI: {@link HdsTabs} outermost so the tab bar and mini player float
   * above every navigation level; each tab page hosts its own
   * {@link HdsNavigation} with its own stack. The Apple Music login page is a
   * full-screen sibling layer inside the same Stack.
   */
  build() {
    Stack() {
      // 全 App 共用的流光背景（官方 UV_BACKGROUND_FLOW_LIGHT）。
      // 放在 HdsTabs 外面：切 tab / push 详情页时它都不动，只有上层 UI 在动。
      // 配色随外观模式走：浅色 = 白 + 浅蓝（亮、无黑），深色 = 原来的蓝灰。
      if (this.flowReady) {
        // 临时测量：浅色时先在流光下面垫一层纯白，看是不是 shader 半透明透出了黑色窗口底
        if (!this.darkTheme) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.White)
        }
        if (this.darkTheme) {
          // 深色：保持原有蓝灰（用户认可，勿动；也不设 colorTarget，避免改变观感）
          Column()
            .width('100%')
            .height('100%')
            .visualEffect(new hdsEffect.HdsEffectBuilder()
              .shaderEffect({
                effectType: hdsEffect.EffectType.UV_BACKGROUND_FLOW_LIGHT,
                animation: { duration: 8000, iterations: -1, autoPlay: true },
                controller: this.uvFlowController,
                params: {
                  colorSource: ['#317AF7', '#8A8E96']
                }
              })
              .buildEffect())
        } else {
          // 浅色：白 ↔ 浅蓝 之间流动。
          // 关键：**必须同时给 colorTarget** —— 只给 colorSource 时流光会向默认色过渡，
          // 浅色下整体发灰发暗（用户反馈"颜色太深"）。两套色都自己给，就只剩白与浅蓝。
          Column()
            .width('100%')
            .height('100%')
            .visualEffect(new hdsEffect.HdsEffectBuilder()
              .shaderEffect({
                effectType: hdsEffect.EffectType.UV_BACKGROUND_FLOW_LIGHT,
                animation: { duration: 8000, iterations: -1, autoPlay: true },
                controller: this.uvFlowController,
                params: {
                  colorSource: ['#FFFFFF', '#A8CDFF'],
                  colorTarget: ['#A8CDFF', '#FFFFFF']
                }
              })
              .buildEffect())
          // 浅色专用：流光上面再盖一层半透明白纱。
          // 原因（真机测出来）：UV 流光 shader 自身带一层灰 —— 即使把色值全设成纯白，
          // 背景亮度也只有 0.52；垫白底座也只到 0.67。浅色主题必须靠这层白纱把灰压掉，
          // 同时保留流光的淡蓝流动（白纱越不透明越亮、流光越淡）。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#B3FFFFFF')
            .hitTestBehavior(HitTestMode.None)
        }
      }
      this.Shell()
      // 抽屉入口已改为外壳顶部左上角的圆钮（见下方工具栏），
      // 原来的左缘常驻把手 + 侧滑呼出都按用户要求下线。
      // 外壳顶部的固定圆钮（挂在 tab 容器**外面**，切 tab 时不动）：
      //   左上 = 呼出侧边抽屉（用户 2026-09-26 要求：不再用左缘侧滑，改成按钮）；
      //   右上 = 同步资料库 + 搜索资料库（同步按钮原先在左上，按要求挪到右上与搜索并排）。
      // 只在「主界面」显示（用户 2026-09-14 定）：
      // - Apple Music 搜索页（第 5 个 tab）自己顶部就是搜索框，让位不显示；
      // - 艺人 / 专辑 / 歌单详情页（压在栈上的页面）也不显示，避免与详情页内容打架。
      if (this.currentTab !== 4 && this.appState.detailPageDepth === 0) {
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.dock_rectangle_portrait'))
            .fontSize(20)
            .fontColor([$r('app.color.library_text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.Thin)
        .onClick(() => {
          this.openDrawer();
        })

        // 右上：同步 + 搜索，两颗并排
        Row({ space: 10 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.syncingLibrary) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.library_text_primary'))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(20)
              .fontColor([$r('app.color.library_text_primary')])
          }
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.Thin)
        .onClick(() => {
          this.syncLibraryNow();
        })

        // Apple Music 搜索页（第 5 个 tab）自己就是搜索界面，不显示资料库搜索按钮。
        if (this.currentTab !== 4) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(20)
              .fontColor([$r('app.color.library_text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .backgroundBlurStyle(BlurStyle.Thin)
          .onClick(() => {
            this.searchOpen = true;
          })
        }
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      // 真机 dumpLayout 实测：艺人页工具栏那颗同步按钮落在 y=44~84vp（标题栏里的
      // stackBuilder 内容会被 56vp 的 MINI 栏夹一下），所以这里也用 44 才能与它
      // 完全同高（之前 64 会低 20vp）。两者尺寸同为 40×40vp。
      .padding({ left: 16, right: 16, top: 44 })
      // 与各板块页同样把内容顶到屏幕最上：不加这句，本行的起点会落在状态栏下方
      // （约 38vp），右边的搜索按钮就比左边工具栏的同步按钮矮一截（用户实测）。
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
      // 只有那颗按钮吃事件，其余区域照常透给下面的页面
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(6)
      }

      // 资料库统一搜索浮层（覆盖在 tab 之上、抽屉之下）
      if (this.searchOpen) {
        LibrarySearchOverlay({
          onClose: (): void => {
            this.searchOpen = false;
          },
          onOpenArtist: (name: string): void => {
            this.openArtistFromSearch(name);
          },
          onOpenAlbum: (name: string, artist: string): void => {
            this.openAlbumFromSearch(name, artist);
          },
          onOpenPlaylist: (id: string, name: string): void => {
            this.openPlaylistFromSearch(id, name);
          }
        })
          .zIndex(11)
      }

      // 遮罩：原页面压暗（点击任意处收起）。
      // 必须常驻挂载 —— 之前用 if 条件挂载，收起动画还在改 opacity 时节点已经被
      // 卸载，渲染服务里出现「Failed to find animation / RSPropertyType is not
      // exist」，整窗画成纯黑（真机复现）。动画不能打在会消失的节点上。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(this.drawerScrim)
        .hitTestBehavior(this.drawerScrim > 0.002 ? HitTestMode.Default : HitTestMode.None)
        .zIndex(20)
        .onClick(() => {
          this.closeDrawer();
        })
      // 侧滑开抽屉：**整屏透明触摸层** + 原始触摸自判定。
      // 为什么不用窄条：窄条依赖「手指正好落在带子里」才能命中，用户实测划不出来；
      // 整屏层保证任何起手都能收到事件，再按「起点是否在屏幕左侧区域」决定要不要拉抽屉。
      // 为什么不用手势：手势会和页内列表滚动/子元素拖动抢，谁赢看时序（老毛病）。
      // HitTestMode.Transparent：本层不画东西、不阻塞下面内容的点击与滚动。
      if (!this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .zIndex(5)
          .onTouch((event: TouchEvent) => {
            // 这一层本来就是整屏透明触摸层（Transparent，不拦子组件事件），
            // 顺手记录「用户最近触摸时间」，供预建页面/后台重活避让使用。
            // 注：抽屉的侧滑呼出已按用户要求下线（改为左上角按钮），
            // 这一层现在只承担触摸时间记录。
            this.lastTouchAt = Date.now();
          })
      }
      // 设置面板：常驻挂载，靠位移移出屏幕（理由同上）
      Column() {
        SettingsDrawer({
          onClose: (): void => {
            this.closeDrawer();
          }
        })
      }
      .width(this.panelWidthVp())
      .height('100%')
      .translate({ x: this.drawerX })
      // 收起（且没在跟手拖动）时整块面板不接受触摸：面板是靠位移移出屏幕的，
      // 命中区可能还盖在底部 tab 栏/播放条上 —— 这是「播放条右滑切歌却呼出
      // 设置面板」的直接原因。
      .hitTestBehavior(this.drawerOpen || this.drawerDragging
        ? HitTestMode.Default
        : HitTestMode.None)
      // 面板上左滑 = 收起（开着的时候手势在这里，不在那条窄带上）
      .priorityGesture(
        PanGesture(new PanGestureOptions({ direction: PanDirection.Horizontal, distance: 4 }))
          .onActionStart((event: GestureEvent): void => {
            this.drawerPanStart(event);
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.drawerPanUpdate(event);
          })
          .onActionEnd((event: GestureEvent): void => {
            this.drawerPanEnd(event);
          })
      )
      .shadow({ radius: 28, color: '#33000000', offsetX: 8 })
      .clip(true)
      .zIndex(21)
      // 登录页（全屏，覆盖在 tab 壳层之上）。
      // 注意：HdsTabs 自身带 zIndex(1)，登录层必须用更大的 zIndex，
      // 否则虽然布局在屏幕上（dumpLayout 有几何），绘制时会被压在下面。
      if (this.authState.loginVisible) {
        AppleLoginView()
          .zIndex(10)
      }
      // 全屏播放页：从播放条封面上滑呼出，跟手从屏幕下方升起。
      if (this.playerMounted) {
        FullPlayerSheet({
          progress: this.sheetProgress,
          screenHeightVp: this.screenHeightVp(),
          screenWidthVp: this.screenWidthVp(),
          miniCoverCx: this.miniCoverCx,
          miniCoverCy: this.miniCoverCy,
          miniCoverSize: this.miniCoverSize,
          // 播放条胶囊的几何：播放页背景从它「生长」成全屏
          barLeftVp: this.barLeftVp(),
          barTopVp: this.barTopVp(),
          barWidthVp: this.barWidthVp(),
          backRequest: this.backRequest,
          onLyricPageChanged: (isLyric: boolean): void => {
            this.lyricPageOpen = isLyric;
          },
          requestClose: (commit: boolean): void => {
            // 页面内的下拉手势自己算过「够不够收起」，这里只负责把弹簧跑完。
            this.animateSheetTo(!commit);
          }
        })
      }
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(StyleConstants.FULL_HEIGHT)
    // 抽屉面板与齿轮把手都必须贴在屏幕最左侧：Stack 默认是居中对齐，
    // 会把定宽的它们挪到屏幕中间（真机反馈：面板跑到中央、齿轮落在屏幕正中，
    // 加上遮罩就整屏发黑，看着像「黑屏」）。
    .alignContent(Alignment.TopStart)
  }

  /** Tab shell (both the HDS floating-bar branch and the legacy branch). */
  @Builder
  private Shell() {
    if (deviceInfo.distributionOSApiVersion >= 60100) {
      HdsTabs({ barPosition: BarPosition.End, controller: this.hdsTabsController }) {
        this.HomeTabsPages()
      }
      .barMode(BarMode.Fixed)
      .barHeight(60)
      .zIndex(1)
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .vertical(false)
      .scrollable(false)
      // Keep tab-content switching snappy: a shorter switch window avoids
      // the sluggish slide while HDS still applies its spring-like motion.
      .animationDuration(320)
      // 缓存最近切换过的 5 个 tab 页：TabContent 被销毁重建是切换卡顿的主因。
      // 页面数据刷新走 LibrarySignal，常驻不会变旧。
      .cachedMaxCount(5, TabsCacheMode.CACHE_LATEST_SWITCHED)
      // No gradient-blur mask on the bar: it read as a dark shadow over
      // the flow-light background. The floating material stays.
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
      .barFloatingStyle({
        // tab 胶囊宽度与「折叠/展开播放条」对齐（用户要求：把右侧那段空隙补掉、
        // 但不挨着）。注意手机是 MD 断点，实际吃的是 mediumWidth（之前 248，
        // 会在它右侧与播放条之间留下 ~76vp 空隙）。
        barWidth: {
          smallWidth: this.tabBarSmallWidthVp(),
          mediumWidth: 292,
          largeWidth: 336
        },
        barBottomMargin: this.homeTabBarBottomMarginVp(),
        // Transparent gradient mask: the official default mask is
        // #99000000 in dark mode, which reads as a black shadow under
        // the capsule bar. Keep the mask geometry but make it colorless.
        gradientMask: {
          maskColor: '#00000000'
        },
        // IMMERSIVE (per the official HDS floating-bar sample): the
        // ADAPTIVE material randomly dropped the miniBar's child rendering
        // (cover image / progress ring went invisible on some launches).
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        miniBar: {
          miniBarBuilder: (): void => {
            this.miniBar();
          },
          // Keep the expanded player at its previous wide geometry while
          // the collapsed tab bar is now shorter.
          miniBarWidth: {
            smallWidth: this.expandedPlayerBarWidthVp(),
            mediumWidth: 292,
            largeWidth: 336
          },
          onBarStyleChange: (miniBarStyle: HdsBarStyle): void => {
            this.onMiniBarStyleChange(miniBarStyle);
          }
        }
      })
      // Sync the selected tab at animation start (official Tabs guidance):
      // updating on onChange only fires after the slide finishes, which
      // delays the highlight + icon bounce and makes switching feel laggy.
      .onAnimationStart((index: number, targetIndex: number) => {
        this.currentTab = targetIndex;
        // Freeze all looping flow lights during the switch so the slide
        // animation keeps its render budget; resume the active one after.
        this.uvFlowController.pause();
        this.flowResumeSeq += 1;
        const seq = this.flowResumeSeq;
        setTimeout(() => {
          if (seq === this.flowResumeSeq) {
            this.uvFlowController.resume();
          }
        }, 360);
        // Dismiss the soft keyboard as soon as the switch starts.
        this.getUIContext().getFocusController().clearFocus();
      })
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
    } else {
      HdsTabs({ barPosition: BarPosition.End, controller: this.hdsTabsController }) {
        this.HomeTabsPages()
      }
      .barMode(BarMode.Fixed)
      .barHeight(60)
      .zIndex(1)
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .vertical(false)
      .scrollable(false)
      // Older-API branch: same snappy switch duration as the HDS branch.
      .animationDuration(320)
      // 缓存最近切换过的 5 个 tab 页：TabContent 被销毁重建是切换卡顿的主因。
      // 页面数据刷新走 LibrarySignal，常驻不会变旧。
      .cachedMaxCount(5, TabsCacheMode.CACHE_LATEST_SWITCHED)
      .padding({ bottom: this.windowInfo.navigationBarBottomVp })
      .onAnimationStart((index: number, targetIndex: number) => {
        this.currentTab = targetIndex;
        this.uvFlowController.pause();
        this.flowResumeSeq += 1;
        const seq = this.flowResumeSeq;
        setTimeout(() => {
          if (seq === this.flowResumeSeq) {
            this.uvFlowController.resume();
          }
        }, 360);
        // Dismiss the soft keyboard as soon as the switch starts.
        this.getUIContext().getFocusController().clearFocus();
      })
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
    }
  }
}
