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

import { curves, uiMaterial } from '@kit.ArkUI';
import { Logger, StyleConstants } from 'musicbasic';
import { PlayerViewModel } from '../viewmodel/PlayerViewModel';
import { PlayerSheetProgress } from '../model/PlayerSheetProgress';
import { MiniBarProgressRing } from './MiniBarProgressRing';

/**
 * Inline mini player rendered inside the HDS floating bar (miniBarBuilder).
 * The HDS bar owns the tab-bar/mini-bar expand animation; this component only
 * draws the player content.
 *
 * IMPORTANT (verified on device): inside the HDS miniBar container,
 * - Text must carry only base attributes (fontColor/fontSize work; maxLines,
 *   textOverflow, textShadow, flexShrink and layoutWeight on Text break it);
 * - layoutWeight/Blank/SpaceBetween are inert, so the transport buttons stay
 *   directly after the labels (natural row layout).
 * Collapsed state is detected via the measured bar width (onAreaChange).
 */
@ComponentV2
export struct Player {
  /** Kept for call-site compatibility (positioning handled by the HDS bar). */
  @Param dockAtBottom: boolean = false;
  /** Host callback that expands the HDS bar (wired to HdsTabsController). */
  @Event onExpandRequest: () => void = () => {
  };
  /**
   * 上滑呼出全屏播放页：宿主回调。
   *
   * 手势挂在封面 Stack 上（折叠态封面居中、展开态封面在最左，**两态都在**），
   * 所以「从封面往上滑 → 播放页」在折叠/展开下都成立（用户 2026-10-03 要求）。
   *
   * 播放页是宿主层的兄弟节点，这里只能发信号；位移/弹簧由宿主的
   * FullPlayerSheet 完成。三个回调 = 一次拖动的完整生命周期：
   * - {@link onPlayerSheetStart}：越过起手阈值，请宿主挂载（此时进度 0，藏
   *   在屏幕下方，用户还看不见）；
   * - {@link onPlayerSheetDrag}：跟手，把上滑位移（vp）交给宿主换算成进度；
   * - {@link onPlayerSheetRelease}：松手，宿主用 springMotion 决定「弹上去」
   *   还是「弹回去」。
   */
  @Event onPlayerSheetStart: () => void = () => {
  };
  /** 跟手拖拽：手指从起手点向上滑过的距离（vp，向上为正）。 */
  @Event onPlayerSheetDrag: (upVp: number) => void = () => {
  };
  /** 松手：位移（vp，向上为正）与松手瞬间速度（vp/s，向上为负）。 */
  @Event onPlayerSheetRelease: (upVp: number, velocityVp: number) => void = () => {
  };
  /** Expanded bar width (vp) as configured via barFloatingStyle.barWidth. */
  @Param expandedBarWidthVp: number = 300;
  /**
   * Whether the HDS bar is expanded (mirrored from onBarStyleChange). Drives
   * collapsed-state layout instead of onAreaChange, which does not fire
   * reliably inside the HDS miniBar container.
   */
  @Param isBarExpanded: boolean = false;
  /**
   * 播放页的升起进度（宿主同一个引用）。
   *
   * 这里只用它的 {@link PlayerSheetProgress.barCoverVisible}：播放条这颗封面
   * 与播放页那颗是**同一枚**，拉起播放页时这颗让位、收起落回原位后再换回来。
   * 显隐由播放页按进度写入，本组件只读；opacity 不参与布局，
   * 胶囊里的排列（封面 / 歌名 / 进度环的位置）完全不变。
   */
  @Param sheet: PlayerSheetProgress = new PlayerSheetProgress();
  /** View model bridging MusicAppState and MediaService. */
  @Local playerViewModel: PlayerViewModel = new PlayerViewModel();
  /** Horizontal pan recognizer to expand the bar on left swipe. */
  private panOption: PanGestureOptions = new PanGestureOptions({ direction: PanDirection.Horizontal });
  /**
   * 垂直上滑识别器：在封面上向上滑呼出全屏播放页。
   *
   * distance 只要 3vp：用户要的是「手指一碰封面动画就得开始」，
   * 之前 8vp 的起手门槛加上宿主的挂载阈值，手感上会明显「慢半拍」。
   * 点击不受影响（点击的位移远小于 3vp，Pan 不会激活）。
   */
  private swipeUpOption: PanGestureOptions =
    new PanGestureOptions({ direction: PanDirection.Vertical, distance: 2 });
  /**
   * 封面的跟手缩放（1 = 原尺寸）。
   *
   * 手指在封面上向上滑时封面被「拉大」（最多 1.12），松手用官方 springMotion
   * 弹回 1 —— 这段跟手反馈很轻（只改一个 scale，不触发布局），
   * 但能明确告诉用户「这个方向是可以拉出东西的」。
   */
  @Local coverScale: number = 1;
  /** Cached track title; refreshed via {@link refreshTrackText}. */
  @Local titleText: string = '';
  /** Cached artist line; see {@link titleText}. */
  @Local singerText: string = '';
  /**
   * 触碰光效（与左侧 tab 栏同观感）：手指按住播放条时，条内浮起一层光——
   * 底色取 HDS 页签栏光效的官方色值（#33FFFFFF），另有一团更亮的光晕
   * {@link lightX} 跟着手指水平移动。
   */
  @Local lightOn: boolean = false;
  /** 光晕中心 x（相对播放条左边缘，vp）。 */
  @Local lightX: number = 0;
  /** 跟手光晕的尺寸（vp）：宽度覆盖约 1.5 个页签宽，高度与 bar 同高。 */
  /**
   * 按下时从 0.72 弹到 1：光从触点「生长」出来（官方按压反馈的观感）。
   * 抬手缩回去，配合 opacity 淡出。
   * 仅在本机不支持官方沉浸材质时生效（见 immersiveOk）。
   */
  @Local lightScale: number = 0.72;
  /**
   * 官方沉浸材质是否可用（API 26+ 且设备支持）。
   *
   * 可用时：播放条用官方 ImmersiveMaterial（interactive + lightEffect）——
   * 和左侧 tab 栏同一套「跟手光效」，手搓的三层光会被关掉；
   * 不可用时：回退到手搓光（保证老设备/老系统观感不丢）。
   */
  private immersiveOk: boolean = uiMaterial.isImmersiveMaterialSupported();
  /**
   * 是否使用官方沉浸材质做播放条光效。
   *
   * 2026-09-19 定论（官方 OS 行为变更说明，2026-09-03 更新）：
   * 「沉浸光感新增生效约束」——当应用 targetSdkVersion ≥ 26.0.0 时，沉浸式系统材质只在
   *  ① 弹窗类组件/接口，或
   *  ② Navigation / NavDestination 标题栏、横向 Tabs 中 barPosition=End 的底部 TabBar
   * 内生效；**在其他区域设置 systemMaterial 一律不生效**（官方原话）。
   * 我们这条底部播放条属于"其他区域" → 官方材质被系统忽略（不是代码问题）。
   * 所以这里保持 false，用下面的手搓光；将来若把播放条并入底部 TabBar 区域，可再评估打开。
   */
  private useOfficialMaterial: boolean = false;
  /** 官方沉浸材质实例（构造一次，属性里只做三元取值）。 */
  private immersiveMat: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: { color: undefined }
  });
  /** 宽而淡的外层光晕：模拟材质被点亮时的大面积扩散。 */
  private static readonly GLOW_WIDE_W: number = 208;
  private static readonly GLOW_WIDE_H: number = 60;
  /** 中心更亮的内层光核：给光晕一个「源点」。 */
  private static readonly GLOW_CORE_W: number = 104;
  private static readonly GLOW_CORE_H: number = 56;
  /** 跟手缩放的行程（vp）：滑够这么多就放到最大 1.12。 */
  private static readonly COVER_PULL_SPAN_VP: number = 60;
  /** 跟手缩放的最大值。 */
  private static readonly COVER_SCALE_MAX: number = 1.12;
  /**
   * 超过这个位移（vp）才通知宿主挂载播放页。
   *
   * 取 3vp：和手势的起手阈值一致，做到「刚一动就出动画」。
   * 早先取 12vp 是为了省掉一次全屏页构建，但代价是手感拖沓 —— 现在改成
   * 手指**碰到封面**就先让宿主把页面备好（见 onCoverPress），这里就不必再等。
   */
  private static readonly SHEET_START_VP: number = 1;
  /** 本次拖拽是否已经通知过宿主（起手只通知一次）。 */
  private dragStarted: boolean = false;

  /** True while the bar is collapsed into the circular mini bar. */
  private isCollapsed(): boolean {
    return !this.isBarExpanded;
  }

  /**
   * Cover side length in vp: 44 in both states. 52vp bar minus 44vp cover
   * leaves an even 8vp ring in either state (pixel-exact centering at this
   * device density; a 40/44 split would round asymmetrically).
   */
  private coverSideVp(): number {
    // 用户反馈「进度环看不出来」：封面从 52 收到 48，把环留到封面**外侧**。
    return 48;
  }

  /**
   * 进度环直径（vp）：比封面大 10vp（每侧 5vp），环画在封面外侧所以清晰可见；
   * 同时 58 < 60（bar 高度），环本身也不会被胶囊边裁到。
   */
  private ringSideVp(): number {
    return this.coverSideVp() + 10;
  }

  /** 文字宽度：封面右侧到条尾之间的空间（右侧已无按钮）。 */
  private textWidthVp(): number {
    // 文字起点不变；结束点延伸到播放条最右侧（只留 8vp 呼吸位）
    return this.expandedBarWidthVp - this.coverSideVp() - 8;
  }

  /** Resolves the current track title as a plain string for {@link titleText}. */
  private resolveTitle(): string {
    const track = this.playerViewModel.currentTrack();
    if (track === undefined) {
      return '';
    }
    const t = track.title;
    return typeof t === 'string' ? t : '';
  }

  /** Resolves the current artist line as a plain string for {@link singerText}. */
  private resolveSinger(): string {
    const track = this.playerViewModel.currentTrack();
    if (track === undefined) {
      return '';
    }
    const s = track.singer;
    return typeof s === 'string' ? s : '';
  }

  /**
   * 手指在播放条上的位置 → 光晕中心，并点亮/熄灭光效。
   *
   * @param event 触摸事件（x/y 相对本组件左上角，单位 vp）
   */
  private onBarTouch(event: TouchEvent): void {
    const list: TouchObject[] = event.touches;
    if (list.length > 0) {
      const t: TouchObject = list[0];
      this.lightX = t.x;
    }
    if (event.type === TouchType.Down) {
      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
        this.lightOn = true;
        this.lightScale = 1;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
        this.lightOn = false;
        this.lightScale = 0.72;
      });
    }
  }

  /** 按字符截断标题/艺人（替代 HDS 胶囊里不可用的 textOverflow）。 */
  private clamp(text: string, max: number): string {
    return text.length > max ? text.substring(0, max - 1) + '…' : text;
  }

  /**
   * Syncs the cached title/artist labels from the current track.
   *
   * 关键：解析失败（队列正在切换 / DB 刚被同步重建）时**不要把已有文字清空** ——
   * 用户看到的现象是「点暂停之后歌名整行消失」，就是因为一次失败的解析把
   * titleText 写成了空串，而 HDS 悬浮胶囊里空 Text 不会自己恢复。
   */
  private refreshTrackText(): void {
    const title: string = this.resolveTitle();
    const singer: string = this.resolveSinger();
    if (title !== '') {
      this.titleText = this.clamp(title, 22);
      this.singerText = this.clamp(singer, 26);
    } else if (this.titleText === '') {
      this.titleText = '';
      this.singerText = '';
    }
  }

  aboutToAppear(): void {
    // 诊断（低频）：确认本机是否支持官方沉浸材质 + 系统材质档位。
    // 支持 → 播放条走官方 interactive + lightEffect（与左侧 tab 栏同一套）；
    // 不支持 → 自动回退到手搓光。
    Logger.info('Player', 'useOfficial=' + this.useOfficialMaterial +
      ' immersive=' + this.immersiveOk +
      ' level=' + uiMaterial.getGlobalMaterialLevel() +
      ' state=' + uiMaterial.getMaterialInfo().state +
      ' type=' + uiMaterial.getMaterialInfo().type);
    this.refreshTrackText();
  }

  /** Keeps the cached labels in sync when the selected item changes. */
  @Monitor('playerViewModel.appState.selectIndex')
  onSelectIndexChanged(): void {
    this.refreshTrackText();
  }

  /** Keeps the cached labels in sync when playback starts (first track, index 0→0). */
  @Monitor('playerViewModel.appState.isPlay')
  onPlayStateChanged(): void {
    this.refreshTrackText();
  }

  /**
   * 封面垂直拖拽进行中：封面跟手放大 + 把位移交给宿主让播放页跟手升起。
   *
   * 这里**不用 animateTo**，直接改 @Local —— 跟手要的是 1:1 跟住手指，中间再
   * 插一条曲线只会多一帧延迟。scale 是渲染线程属性，开销可忽略。
   * （播放页那边的跟手由宿主用 responsiveSpringMotion 完成，那是官方给
   *  「跟手 → 离手」衔接准备的曲线。）
   *
   * @param offsetYVp 相对起点的竖直位移（vp，向上为负）
   */
  private coverPullUpdate(offsetYVp: number): void {
    const up: number = offsetYVp < 0 ? -offsetYVp : 0;
    const ratio: number = up >= Player.COVER_PULL_SPAN_VP ? 1 : up / Player.COVER_PULL_SPAN_VP;
    this.coverScale = 1 + (Player.COVER_SCALE_MAX - 1) * ratio;
    if (!this.dragStarted && up > Player.SHEET_START_VP) {
      this.dragStarted = true;
      this.onPlayerSheetStart();
    }
    if (this.dragStarted) {
      this.onPlayerSheetDrag(up);
    }
  }

  /**
   * 封面垂直拖拽结束：封面弹回原尺寸，并让宿主决定播放页是「弹上去」还是「弹回去」。
   *
   * 位移/速度的判定交给宿主（它才知道屏幕多高、阈值怎么定），这里只负责
   * 把干净的原始量传出去。
   *
   * @param offsetYVp 相对起点的竖直位移（vp，向上为负）
   * @param velocityYVp 松手瞬间的竖直速度（vp/s，向上为负）
   */
  private coverPullEnd(offsetYVp: number, velocityYVp: number): void {
    const up: number = offsetYVp < 0 ? -offsetYVp : 0;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86, 0.02) }, () => {
      this.coverScale = 1;
    });
    if (this.dragStarted) {
      this.dragStarted = false;
      this.onPlayerSheetRelease(up, velocityYVp);
    }
  }

  /** Resolves the progress arc color resource to a hex string for the canvas. */
  private arcColorString(): string {
    const host = this.getUIContext().getHostContext();
    if (host !== undefined) {
      try {
        const argb = host.resourceManager.getColorSync($r('app.color.mini_bar_progress').id);
        const r = (argb >> 16) & 0xFF;
        const g = (argb >> 8) & 0xFF;
        const b = argb & 0xFF;
        const a = (argb >> 24) & 0xFF;
        const toHex = (channel: number): string => {
          const hex = channel.toString(16);
          return hex.length === 1 ? `0${hex}` : hex;
        };
        return `#${toHex(a)}${toHex(r)}${toHex(g)}${toHex(b)}`;
      } catch (err) {
        // fall through to default
      }
    }
    return '#0A59F7';
  }

  /** Builds the horizontal mini player layout (HDS bar friendly). */
  build() {
    // 外层 Stack：底层是「触碰高光」，上层是真正的内容 Row。
    Stack({ alignContent: Alignment.Start }) {
      // 光效层：与可见胶囊同宽同高并裁剪（折叠态 60 见方，展开态整条）。
      // 这里复刻的是鸿蒙页签栏那种「光」——一条跟着手指水平滑动的圆角柔光带
      // （中间亮、两端淡，整体被胶囊裁切），而不是一团圆形高光。
      Stack({ alignContent: Alignment.Start }) {
        // 官方材质可用时，这层空的 Stack 只作为「材质宿主」（不画任何东西），
        // 光由系统材质自己渲染；不可用时才画下面这三层手搓光。
        if (!this.useOfficialMaterial) {
        // ① 极淡的整条底色：只在按住时出现，避免光带之外完全没变化
        Column()
          .width('100%')
          .height(60)
          .borderRadius(30)
          .backgroundColor(this.lightOn ? '#1FFFFFFF' : Color.Transparent)
        // ② 宽柔光：一层很大很淡的光晕，模拟材质被「点亮」的大面积扩散
        Column()
          .width(Player.GLOW_WIDE_W)
          .height(Player.GLOW_WIDE_H)
          .borderRadius(Player.GLOW_WIDE_H / 2)
          .radialGradient({
            center: ['50%', '50%'],
            radius: '50%',
            colors: [['#24FFFFFF', 0.0], ['#14FFFFFF', 0.45], ['#00FFFFFF', 1.0]]
          })
          .position({
            x: this.lightX - Player.GLOW_WIDE_W / 2,
            y: (60 - Player.GLOW_WIDE_H) / 2
          })
          .scale({ x: this.lightScale, y: this.lightScale })
          .opacity(this.lightOn ? 1 : 0)
        // ③ 亮光核：中心更亮更小的一块，给光晕一个「源点」
        Column()
          .width(Player.GLOW_CORE_W)
          .height(Player.GLOW_CORE_H)
          .borderRadius(Player.GLOW_CORE_H / 2)
          .radialGradient({
            center: ['50%', '50%'],
            radius: '50%',
            colors: [['#4DFFFFFF', 0.0], ['#1FFFFFFF', 0.5], ['#00FFFFFF', 1.0]]
          })
          .position({
            x: this.lightX - Player.GLOW_CORE_W / 2,
            y: (60 - Player.GLOW_CORE_H) / 2
          })
          .scale({ x: this.lightScale, y: this.lightScale })
          .opacity(this.lightOn ? 1 : 0)
        }
      }
      .width(this.isCollapsed() ? 60 : this.expandedBarWidthVp)
      .height(60)
      .borderRadius(30)
      .clip(true)
    Row({ space: 10 }) {
      // Album cover with a Canvas progress ring exactly concentric on top,
      // plus a translucent play/pause glyph while collapsed. Tapping the
      // cover toggles playback (no full-screen page).
      Stack({ alignContent: Alignment.Center }) {
        if (this.playerViewModel.songCoverPath() !== '') {
          Image(this.playerViewModel.songCoverPath())
            .width(this.coverSideVp())
            .height(this.coverSideVp())
            .borderRadius(this.coverSideVp() / 2)
            // Official cross-fade between consecutive covers (track switch).
            .contentTransition(ContentTransitionEffect.OPACITY)
            // 封面让位（见 sheet.barCoverVisible 的注释）：播放页那颗封面从
            // **同一个圆心、同一个 48vp 边长**接着长，所以这里藏掉的那一帧
            // 屏幕上并不缺东西 —— 是播放页那颗正好落在这个位置。
            .opacity(this.sheet.barCoverVisible ? 1 : 0)
        } else {
          Image(this.playerViewModel.songCover())
            .width(this.coverSideVp())
            .height(this.coverSideVp())
            .borderRadius(this.coverSideVp() / 2)
            .contentTransition(ContentTransitionEffect.OPACITY)
            .opacity(this.sheet.barCoverVisible ? 1 : 0)
        }
        // 进度环**始终留在原位**：它比封面大一圈（58 vs 48），收起时那颗封面
        // 落回来也只是盖住它的内侧，外圈那 5vp 从头到尾都在 —— 如果连它一起藏，
        // 落地那一帧环会「啪」地冒出来（以前专门修过这类跳变）。
        MiniBarProgressRing({
          progress: this.playerViewModel.appState.progress,
          total: this.playerViewModel.appState.progressMax > 0 ? this.playerViewModel.appState.progressMax : 1,
          side: this.ringSideVp(),
          arcColor: this.arcColorString()
        })
        // 折叠/展开都一样：播放/暂停画在封面上（用户 2026-09-14 定）。
        // 字形跟着封面一起让位：它正好在封面圆心，收起落地时被那颗封面完全遮住，
        // 所以「换回来」的那一刻也看不出跳变。
        if (this.playerViewModel.appState.loadingText !== '') {
            // 正在下载/解密（慢网可能十几秒）：用转圈代替播放图标，
            // 否则用户看到的是一个「点了没反应」的静止播放键。
            LoadingProgress()
              .width(18)
              .height(18)
              .color(Color.White)
              .opacity(this.sheet.barCoverVisible ? 1 : 0)
          } else {
            SymbolGlyph(this.playerViewModel.appState.isPlay ?
              $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(16)
              .fontColor([Color.White])
              .opacity(this.sheet.barCoverVisible ? 0.72 : 0)
              // Official replace effect: play/pause glyph cross-fades on toggle.
              .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE, ReplaceEffectType.CROSS_FADE),
                this.playerViewModel.appState.isPlay)
        }
      }
      // Stack 取环的尺寸：封面（48）居中在里面，环（58）在封面外侧不被裁。
      .width(this.ringSideVp())
      .height(this.ringSideVp())
      // 跟手缩放：在封面上向上滑时封面被「拉大」，松手弹回（见 coverPull*）。
      .scale({ x: this.coverScale, y: this.coverScale })
      .onClick(() => {
        this.playerViewModel.togglePlayPause();
      })
      // 向上滑 → 呼出全屏播放页。
      // ① 只认竖直方向，不会和本 Row 上的横向「左滑展开 / 左右滑切歌」抢；
      // ② 子组件手势优先于父组件手势，父 Row 的横向 Pan 也吃不掉这里的上滑；
      // ③ distance=8vp 起手，短点击不激活 Pan，上面的 onClick 照常切播放。
      .gesture(
        PanGesture(this.swipeUpOption)
          // 每次手势开始都复位：上一次手势可能被系统/边缘手势打断，
          // onActionEnd 没跑到，dragStarted 留在 true —— 那下一次拖拽就会
          // 「跳过通知宿主挂载」直接空转，表现正是「拖了却没反应」。
          .onActionStart(() => {
            this.dragStarted = false;
          })
          .onActionUpdate((event?: GestureEvent) => {
            if (event === undefined) {
              return;
            }
            this.coverPullUpdate(event.offsetY);
          })
          .onActionEnd((event?: GestureEvent) => {
            if (event !== undefined) {
              this.coverPullEnd(event.offsetY, this.getUIContext().px2vp(event.velocityY));
            }
            this.dragStarted = false;
          })
          // 被取消（例如被系统手势抢走）同样要复位，否则会留下「空转」状态。
          .onActionCancel(() => {
            this.dragStarted = false;
            this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86, 0.02) }, () => {
              this.coverScale = 1;
            });
          })
      )

      // Title over artist as a single Text with an embedded newline (nested
      // columns are unreliable inside the HDS bar). Only base attributes.
      // The fixed width fills the middle of the expanded bar; text stays
      // left-aligned so short titles read from the cover onwards.
      // Collapsed: skip the empty Text entirely — its zero width still adds
      // Row spacing, which offsets the centered cover from the circle behind.
      // 歌名只在展开态显示（折叠胶囊里封面居中，没有文字位置）。
      // 只用基础属性：maxLines / textOverflow 在这层 HDS 胶囊容器里会让
      // Text 在重建（例如播放/暂停切换触发的那次）后量不出宽度而整行消失。
      // 超长文本在 refreshTrackText 里按字符截断。
      if (!this.isCollapsed()) {
        // 一条 Text + 两个 Span：歌名大而粗、艺人小而细（展开态）。
        // 用 Span 而不是嵌套 Column：HDS 悬浮胶囊里嵌套 Column 量不出宽度会整行消失。
        Text() {
          if (this.playerViewModel.appState.loadingText !== '') {
            Span(this.playerViewModel.appState.loadingText)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          } else {
            Span(this.titleText)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Span('\n')
            Span(this.singerText)
              .fontSize(11)
              .fontWeight(FontWeight.Lighter)
              .fontColor(Color.White)
          }
        }
        .width(this.textWidthVp())
      }

    }
    .width(StyleConstants.FULL_WIDTH)
    .height(60)
    // 展开态：封面圆心落在胶囊左半圆圆心（左边距 4vp）。
    // 折叠态：胶囊被外壳加长到 collapsedBarWidthVp，必须按容器宽度算左边距
    //      才能让封面（连同进度环）真正居中 —— 这层 HDS 容器里 width/justify
    //      不可靠，padding 可靠（原来就是靠它定位的）。
    // 折叠态：HDS 给的圆形槽 = bar 高度（60vp），封面 52 → 左右各 4vp 即正中；
    // 展开态：封面圆心落在胶囊左半圆圆心（左边距 4vp）。
    .padding({ left: 1, right: 4 })
    .alignItems(VerticalAlign.Center)
    // Collapsed: only the cover is visible, center it inside the HDS circular
    // slot so cover center matches the bar background circle. Expanded: keep
    // the natural left-aligned cover -> title -> buttons order.
    .justifyContent(this.isCollapsed() ? FlexAlign.Center : FlexAlign.Start)
    // 展开态滑动切歌：右滑 = 上一首，左滑 = 下一首。
    // 折叠态保持原来的「左滑展开」。用 priorityGesture 独占横向滑动，
    // 避免和外层 HDS 的展开/收起手势互相抢。
    .gesture(
      PanGesture(this.panOption)
        .onActionEnd((event?: GestureEvent) => {
          if (event === undefined) {
            return;
          }
          const dx: number = event.offsetX;
          if (this.isCollapsed()) {
            if (dx < -10) {
              this.onExpandRequest();
            }
            return;
          }
          if (dx > 40) {
            this.playerViewModel.playPrevious();
          } else if (dx < -40) {
            this.playerViewModel.playNext();
          }
        })
    )
      // 光效宿主（触摸层）：尺寸 = 播放条可见区域，且是唯一能收到触摸的顶层节点，
      // 官方材质的「交互光」就是跟这个节点的按压状态走的。
      // Transparent：自己响应触摸，同时让下层封面/文案照常响应点击。
      Column()
        .width(this.isCollapsed() ? 60 : this.expandedBarWidthVp)
        .height(60)
        .borderRadius(30)
        .hitTestBehavior(HitTestMode.Transparent)
        // 官方材质（默认关闭，见 useOfficialMaterial 的实测说明）
        .systemMaterial(this.useOfficialMaterial && this.immersiveOk ? this.immersiveMat : undefined)
        .onTouch((event: TouchEvent) => {
          this.onBarTouch(event);
        })
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(60)
    .alignContent(Alignment.Start)
  }
}
