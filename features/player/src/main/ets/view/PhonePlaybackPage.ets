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
 * 手机形态的全屏播放页（Apple Music 观感 + 鸿蒙官方动效规范）。
 *
 * 核心是**一个封面、三个落点**，全部由两个进度值插值出来：
 *
 * - {@link sheet}（0→1）：整页从底部升起，同时封面从「播放条封面所在的那一点」
 *   放大到屏幕中上侧；收起时原路缩回播放条（用户 2026-10-03 要求）。
 * - {@link lyrics}（0→1）：封面从中上侧缩小到歌词页左上角，右侧让出歌名/艺人；
 *   播控区淡出、歌词区淡入。
 *
 * 为什么封面**不放在**会 translate 的内容层里：
 * 内容层整页上移时，页面内所有坐标都会跟着下移，封面就再也回不到播放条那一点了。
 * 所以封面单独一层、直接用窗口坐标插值，不受整页位移影响。
 *
 * 封面交接（2026-10-31）：播放条上那颗封面与这里的封面是**同一枚**。
 * 进度一旦离开 0，就把播放条那颗藏起来（{@link PlayerSheetProgress.barCoverVisible}），
 * 屏幕上只剩这一颗从原位长大 —— 于是「播放条的封面跟着页面一起长出来」，
 * 原来那颗不会停在原地；收起时那颗一直藏着，直到这一颗落回原位（进度≈0）
 * 才换回来，所以不会出现两颗封面叠在播放条上。
 */
import { AppStorageV2, curves, promptAction, uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AVVolumePanel } from '@kit.AudioKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { hdsEffect } from '@kit.UIDesignKit';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { http } from '@kit.NetworkKit';
import {
  AppleApi,
  AppleArtworkCache,
  AppStorageKeys,
  ColorConversion,
  getWindowInfoState,
  Logger,
  SongFavState,
  StyleConstants,
  WindowInfo,
  WindowUtil
} from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';
import { MusicPlayMode } from '../model/MusicData';
import { PlayerDataUtil } from '../util/PlayerDataUtil';
import { PlayerViewModel } from '../viewmodel/PlayerViewModel';
import { PlayerSheetProgress } from '../model/PlayerSheetProgress';
import { LyricsComponent } from './LyricsComponent';
import { MediaService } from '../model/MediaService';
import { SystemVolume } from '../model/SystemVolume';

const TAG: string = 'PhonePlaybackPage';

/** 顶部栏高度（不含状态栏 / 挖孔避让）。 */
const TOP_BAR_HEIGHT_VP: number = 56;
/** 页面左右安全边距（鸿蒙规范 24vp）。 */
const EDGE_PADDING_VP: number = 24;
/** 全屏态封面的最大边长。 */
const COVER_MAX_VP: number = 320;
/** 歌词页左上角小封面的边长。 */
const COVER_SMALL_VP: number = 44;
/** 全屏态封面圆角（鸿蒙规范大图圆角）。 */
const COVER_RADIUS_VP: number = 16;
/** 歌词页小封面圆角。 */
const COVER_SMALL_RADIUS_VP: number = 8;
/** 封面与「歌名区」的间距。 */
const COVER_TITLE_GAP_VP: number = 28;
/**
 * 歌词区与「小封面行」之间的间距（vp）。
 *
 * 6 —— 官方录屏里歌词区的顶边（第一条被糊掉的歌词就在那儿）只比封面的下缘
 * 低十几 vp，留得再大就会把「活跃行上一行的残影」顶出可视区。
 */
const LYRIC_TOP_GAP_VP: number = 6;
/** 歌词左右边距（vp）：官方录屏里歌词条的墨迹从 ~33vp 开始（含字侧空 3vp）。 */
const LYRIC_EDGE_PADDING_VP: number = 32;
/**
 * 歌词模式下给整页背景压一层黑纱的不透明度。
 *
 * 官方歌词页的底色比封面页沉得多（录屏实测背景亮度只有 ~40/255），
 * 而我们的背景是「糊化封面 + 流光」的中浅色 —— 灰字（α=0.20）压在上面
 * 会糊成一片、层次全失。压一层黑纱后白字更亮、灰字出得来，
 * 整体才和官方那种「深色幕布 + 一条白字」的观感一致。
 */
const LYRIC_SCRIM_ALPHA: number = 0.20;
/**
 * 歌词页底部的紧凑播控条高度（vp）。
 *
 * Apple Music 进歌词页之后**底部仍保留一行小播控**（上一首 / 播放暂停 / 下一首），
 * 以前这里什么都没有，想暂停只能滑回封面页 —— 与官方不一致、也不好用。
 */
const LYRIC_BAR_HEIGHT_VP: number = 64;
/** 歌词页底部播控条与歌词正文之间的间距（vp）：歌词区底边会提前到这里截止渐隐。 */
const LYRIC_BAR_GAP_VP: number = 10;
/** 播放条胶囊高度（vp）：背景的起点形状就是它。 */
const BAR_HEIGHT_VP: number = 60;
/**
 * 播放条封面的圆心相对播放条方槽**左上角**的偏移（vp，x / y 同值）。
 *
 * **29.8462**，不是 30 —— 2026-10-31 用 `uitest dumpLayout` 量的真机几何
 * （mate60：1260×2720px / 3.25）：封面的 px bounds 是 `[1032,2433][1188,2589]`，
 * 圆心 (1110, 2511)px = 槽左上角 (1013, 2414)px + 29.8462vp。
 * 槽里那个 58vp 的进度环比 Row 内容盒（55）大，ArkUI 靠左排，所以封面圆心
 * 比槽心（30）高/左 0.1538vp —— 这就是「收回时落点偏左下」的半个根因。
 * （宿主 Index.ets 里的 BAR_COVER_OFFSET_X/Y_VP 是同一组数，改要一起改。）
 */
const COVER_IN_BAR_OFFSET_X_VP: number = 29.8462;
/** 同上（y）：封面圆心相对方槽顶边的偏移。 */
const COVER_IN_BAR_OFFSET_Y_VP: number = 29.8462;
/** 播放条方槽右边距（vp）：实测 (1260−1208)/3.25 = 16。兜底用，正常由宿主传入。 */
const BAR_RIGHT_MARGIN_FALLBACK_VP: number = 16;
/** 播放条方槽底边距（vp）：实测 (2720−2609)/3.25 = 34.1538。兜底用。 */
const BAR_BOTTOM_MARGIN_FALLBACK_VP: number = 34.1538;
/** 背景封面糊化半径（px）。Apple Music 的背景就是大片柔光，看不出原图轮廓。 */
const BG_BLUR: number = 60;
/**
 * 卡片材质由透明到实心所占的行程比例。
 *
 * 0.24 —— 手指刚动的一小段里，看到的是播放条那层毛玻璃在「长大」；
 * 到这个位置之后材质就完全接管了。太大（比如 0.4）会让前半段一直雾蒙蒙的，
 * 太小（比如 0.1）就谈不上过渡、又变回「直接盖住」。
 */
const MATERIAL_FADE_P: number = 0.24;
/** 手指下拉多少屏高比例就把播放页拉没了（与宿主收起的行程一致）。 */
const DISMISS_SPAN_RATIO: number = 0.62;
/** 边缘返回手势的起手热区（vp）：从左缘这么多以内起手，才算「侧滑返回」。 */
/**
 * 边缘返回的起手区（距屏幕左边缘 vp）。
 *
 * 两个边界都要照顾：
 *  · **下限 ~20vp**：最左那一窄条是系统返回手势区，系统会先把事件拿走；而播放页
 *    是覆盖层（不在导航栈里），系统拿走后又不产生返回事件 —— 于是业主从最边缘
 *    滑会「两边都没反应」。所以我们的起手判定从 8vp 起算（再往里让一点）。
 *  · **上限 96vp**：太窄的话手指很难正好落在带子里（用户实测划过 32vp 的窄带
 *    都经常落空）。96vp 是「手指自然搭在左边缘」就能命中，且离内容区还远。
 */
/**
 * 边缘返回的起手区（距屏幕左边缘 vp）。
 *
 * 36vp：手指贴着左边缘起手就能命中，同时**不会**把内容区里的正常横滑误判成返回
 * （之前放到 96 时，用户随便一划就被当成返回）。
 * 8vp 以内留给系统手势区（那里应用抢不到，抢到也会和系统打架）。
 */
const EDGE_BACK_ZONE_VP: number = 36;
/** 边缘返回跟手的行程（占屏宽比例）：滑过这么多就完全收起。 */
const EDGE_BACK_SPAN_RATIO: number = 0.55;
/** 下拉多少比例就判定「收起」。 */
const DISMISS_COMMIT_RATIO: number = 0.22;
/** 下拉收起的速度阈值（vp/s）。 */
const DISMISS_COMMIT_VELOCITY_VP: number = 900;
/** 横向滑多少屏宽比例可以切到歌词页。 */
const LYRIC_SWIPE_RATIO: number = 0.34;
/** 横向切换的速度阈值（vp/s）。 */
const LYRIC_COMMIT_VELOCITY_VP: number = 420;
/**
 * 判定「已经落回播放条」的进度阈值（换回播放条那枚封面的时刻）。
 *
 * 0.0005 —— 只差 0.2vp 的行程。**不能再放大**：换手那一刻页内封面离落点还有
 * `p × (封面行程 ~480vp)` 的距离，取 0.002 就有近 1vp（≈3px）的残差，收起末尾
 * 会看到播放条那颗从页内封面下沿露出来（"落地时闪一下"）。这和常量误差是两码事。
 */
const BAR_COVER_REST_EPS: number = 0.0005;

@ComponentV2
export struct PhonePlaybackPage {
  /** 播放页升起进度（宿主持有，引用不变，内部 @Trace 变化只重建本组件）。 */
  @Param sheet: PlayerSheetProgress = new PlayerSheetProgress();
  /** 播放条封面的中心 x（vp，窗口坐标）。 */
  @Param miniCoverCx: number = -1;
  /** 播放条封面的中心 y（vp，窗口坐标）。 */
  @Param miniCoverCy: number = -1;
  /** 播放条封面边长（vp）。 */
  @Param miniCoverSize: number = 48;
  /** 屏幕高度（vp）。 */
  @Param screenHeightVp: number = 800;
  /** 屏幕宽度（vp）。 */
  @Param screenWidthVp: number = 420;
  /** 播放条胶囊左边缘 x（vp）：播放页背景从这个位置「长」出来。 */
  @Param barLeftVp: number = 0;
  /** 播放条胶囊顶边 y（vp）。 */
  @Param barTopVp: number = 0;
  /** 播放条胶囊宽度（vp）。 */
  @Param barWidthVp: number = 60;
  /** 松手后请求宿主把整页弹到终点（true = 收起，false = 弹回展开）。 */
  @Event requestClose: (commit: boolean) => void = (): void => {};

  /** 断点（保留给歌词组件的响应式排版）。 */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** 全局播放状态。 */
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** 播放控制门面。 */
  @Local playerViewModel: PlayerViewModel = new PlayerViewModel();
  /** 窗口安全区信息。 */
  @Local windowInfo: WindowInfo = getWindowInfoState();
  /** 歌词页进度：0 = 封面页，1 = 歌词页。 */
  @Local lyrics: number = 0;
  /**
   * 系统的「返回」请求（递增）：外壳在歌词页时把返回转成「收起歌词」。
   *
   * 用递增数字而不是布尔：连续两次返回都要能各触发一次（布尔第二次没有变化，
   * @Monitor 不会触发）。
   */
  @Param backRequest: number = 0;
  /** 歌词页显隐上报（外壳据此决定返回键是「收歌词」还是「收整页」）。 */
  @Event onLyricPageChanged: (isLyric: boolean) => void = (isLyric: boolean): void => {};
  /** 是否显示歌词译文（歌词页头部右上角的「译」玻璃圆钮切换它）。 */
  @Local showTranslation: boolean = true;
  /**
   * 译文来源状态：0 = 这首没有翻译（按钮置暗）；1 = 有官方翻译；2 = AI 翻译已就绪。
   *
   * 由歌词视图在「歌词就绪 / AI 翻译完成」时上报 —— 只有它手里有完整歌词文本，
   * 才能判断有没有官方 `<translation>` 层。
   */
  @Local transState: number = 0;
  /** 「译」按钮的递增请求号：无官方翻译时点一次 +1，让歌词视图去跑 AI 翻译。 */
  @Local aiRequest: number = 0;
  /** 当前曲目在 Apple 资料库里的歌曲 id（形如 i.xxxx；非 Apple 音源为空）。 */
  @Local favLibId: string = '';
  /** 当前曲目对应的**目录**歌曲 id（收藏写入必须用它）。 */
  @Local favCatalogId: string = '';
  /** 当前曲目是否已被收藏（⭐ 实心/空心）。 */
  @Local favOn: boolean = false;
  /** 收藏请求在飞：防连点重复写。 */
  @Local favBusy: boolean = false;
  /** 播放模式（顺序 / 单曲 / 随机），驱动右上角那颗按钮。 */
  /**
   * 系统媒体音量（0~1）。**唯一音量真源**：硬件侧键、播控中心、系统音量面板
   * 的改动都会通过 `streamVolumeChange` 回灌进来（见 SystemVolume）。
   */
  @Local sysVol: number = 0.6;
  /** 交给 AVVolumePanel 的原始档位（0~maxLevel）；改它就是改系统音量。 */
  @Local volPanelLevel: number = 0;
  @Local playMode: MusicPlayMode = MusicPlayMode.ORDER;
  /** 内容落位的回弹系数（1 = 原位；展开到位时先压到 0.965 再弹回 1）。 */
  @Local contentBump: number = 1;
  /** 本次展开是否已经播过落位回弹。 */
  private bumpPlayed: boolean = false;
  /** 从封面提取的主色（已做饱和/亮度增强），驱动背景底色。 */
  @Local themeColor: string = '#3A3A3C';
  // ── 背景流光：颜色**全部由封面主色派生**。
  //    原来这层是官方 UV_BACKGROUND_FLOW_LIGHT，但它有自己的内置配色（带灰、
  //    且只给 colorSource 时会朝默认目标色过渡）—— 喂什么颜色屏幕上都是它自己
  //    那套彩色。改成「色纱 + 两团漂移光斑」，颜色完全可控，且不随内容滑动。
  @Local tintBg: string = 'rgba(58,58,60,0.46)';
  @Local blobA: string = 'rgba(96,134,255,0.34)';
  @Local blobAMid: string = 'rgba(96,134,255,0.13)';
  @Local blobB: string = 'rgba(150,180,255,0.26)';
  @Local blobBMid: string = 'rgba(150,180,255,0.10)';
  @Local blobAX: number = -140;
  @Local blobAY: number = 60;
  @Local blobBX: number = 180;
  @Local blobBY: number = 420;
  private blobFlip: number = 0;
  private blobTimer: number = 0;
  /**
   * 糊化后的封面位图，铺满整个播放页背景。
   *
   * Apple Music 的播放页背景就是「封面放大糊掉 + 上亮下暗的渐变」，
   * 不是一个纯色。纯色看起来是一块死板的色板，糊化封面才有人眼能认出的
   * 空间层次（见用户给的两张对比图）。
   */
  @Local bgImage: image.PixelMap | undefined = undefined;
  /** 流光控制器（切页 / 滚动时暂停，省渲染预算）。 */
  private flowController: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();
  /** 本次取色的序号：切歌时旧回调不许覆盖新色。 */
  private colorJobSeq: number = 0;
  /** 组件是否还活着（异步取色回调据此决定是否动 UI）。 */
  private isAlive: boolean = true;
  /** 竖向手势（下拉收起）。 */
  private verticalPan: PanGestureOptions =
    new PanGestureOptions({ direction: PanDirection.Vertical, distance: 10 });
  /** 横向手势（切歌词页）。 */
  private horizontalPan: PanGestureOptions =
    new PanGestureOptions({ direction: PanDirection.Horizontal, distance: 12 });

  /** 顶部避让高度（状态栏或挖孔，取大的那个）。 */
  private topSafeVp(): number {
    return this.windowInfo.statusBarTopVp > 0 ? this.windowInfo.statusBarTopVp : 28;
  }

  /** 底部避让高度（手势条）。 */
  private bottomSafeVp(): number {
    return this.windowInfo.navigationBarBottomVp > 0 ? this.windowInfo.navigationBarBottomVp : 24;
  }

  /** 顶部栏底边（vp）。 */
  private topBarBottomVp(): number {
    return this.topSafeVp() + TOP_BAR_HEIGHT_VP;
  }

  /** 线性插值。 */
  private lerp(a: number, b: number, t: number): number {
    return a + (b - a) * t;
  }

  /** 全屏态封面边长。 */
  private fullCoverSizeVp(): number {
    // 用户明确表态：**居中圆角方块 + 阴影**这一版更好看，所以即便官方 iOS 26
    // 是「满幅贴顶」，这里仍保留原形态（≤320vp、居中、16vp 圆角）。
    const avail: number = this.screenWidthVp - EDGE_PADDING_VP * 2;
    return Math.min(avail, COVER_MAX_VP);
  }

  /** 歌词页进度决定下的「目标封面边长」。 */
  private targetCoverSizeVp(): number {
    return this.lerp(this.fullCoverSizeVp(), COVER_SMALL_VP, this.lyrics);
  }

  /**
   * 封面几何用的进度：**只钳下界（≥0），保留上界过冲**。
   *
   * 展开到位时 `sheet.value` 会略微冲过 1，封面的那点回弹就是它带来的（用户要的）；
   * 但收起到底时弹簧同样会略微冲过 0 —— 那一刻封面会被「外推」到播放条**下方**，
   * 于是落地前最后一两帧能看见封面沉下去一点点（用户反馈的「偏下」有一半来自这里）。
   * 封面已经落在播放条上了，再往下没有意义，所以下界钳死；上界不动。
   */
  private coverP(): number {
    const p: number = this.sheet.value;
    return p < 0 ? 0 : p;
  }

  /** 封面当前边长（把「播放条 → 目标」按升起进度插值）。 */
  private coverSizeVp(): number {
    return this.lerp(this.miniCoverSize, this.targetCoverSizeVp(), this.coverP());
  }

  /** 目标封面的中心 x：全屏态居中，歌词页靠左。 */
  private targetCoverCx(): number {
    const full: number = this.screenWidthVp / 2;
    const small: number = EDGE_PADDING_VP + COVER_SMALL_VP / 2;
    return this.lerp(full, small, this.lyrics);
  }

  /** 目标封面的中心 y：全屏态在中上侧，歌词页在顶栏下方（紧贴，不留额外空隙）。 */
  private targetCoverCy(): number {
    const full: number = this.topBarBottomVp() + COVER_TITLE_GAP_VP + this.fullCoverSizeVp() / 2;
    const small: number = this.topBarBottomVp() + COVER_SMALL_VP / 2;
    return this.lerp(full, small, this.lyrics);
  }

  /** 播放条封面中心 x（vp）；宿主没给值时按实测几何兜底（右边距 17vp、偏置 30.54vp）。 */
  private miniCx(): number {
    if (this.miniCoverCx > 0) {
      return this.miniCoverCx;
    }
    return this.screenWidthVp - BAR_RIGHT_MARGIN_FALLBACK_VP - BAR_HEIGHT_VP + COVER_IN_BAR_OFFSET_X_VP;
  }

  /** 播放条封面中心 y（vp）；兜底用实测的底边距 34.1538vp 与偏移 29.8462vp。 */
  private miniCy(): number {
    if (this.miniCoverCy > 0) {
      return this.miniCoverCy;
    }
    return this.screenHeightVp - BAR_BOTTOM_MARGIN_FALLBACK_VP - BAR_HEIGHT_VP + COVER_IN_BAR_OFFSET_Y_VP;
  }

  /**
   * 内容元素的落位「回弹」（1 = 原位，触发时先压到 0.965 再弹回 1）。
   *
   * 卡片**展开到位之后**才播一次：让歌名、进度条、播控按钮轻轻「落」下来
   * —— 用户要求「播控这些元素要有回弹」。
   * 它只作用在**缩放**上（且幅度很小），不碰位移：页面本身必须一步到位，
   * 位移一旦过冲，整页看起来就像「页面自己在弹」，那是用户明确否掉的。
   */
  @Monitor('sheet.value')
  onSheetProgressChanged(): void {
    const p: number = this.sheet.value;
    // ── 封面交接：进度离开 0 → 播放条那颗让位；落回 0 → 换回去 ──
    //
    // 播放条那颗封面与本页这颗是同一枚。页面一挂载本页封面就**正好压在原位**
    // （边长 48、圆心与播放条那颗重合），所以让位那一刻两枚是重叠的、看不出接缝；
    // 之后屏幕上只剩本页这颗在长大，观感就是「播放条的封面跟着页面一起长出来」。
    // 收起时反过来：本页那颗一路缩回原位，进度到 ~0 时播放条那颗才回来，
    // 于是不会再出现「播放条上那颗 + 落回来的那颗」叠在一起。
    const atRest: boolean = p <= BAR_COVER_REST_EPS;
    if (this.sheet.barCoverVisible !== atRest) {
      this.sheet.barCoverVisible = atRest;
      // 低频日志（每次进出播放页各两条）：排障时用来确认「交接」确实发生。
      Logger.info(TAG, 'bar cover handoff: visible=' + atRest + ' p=' + p.toFixed(3));
    }
    // 进度真的开始往上走了：这时才把窗口形态切成播放页样式（全屏 + 状态栏反色）。
    // 放在这里而不是 onAppear，是为了让「手指碰上去」到「页面开始长」这一段
    // 完全没有任何视觉跳变。
    if (p > 0.02 && !this.chromeApplied) {
      this.chromeApplied = true;
      WindowUtil.getInstance().applyPlaybackWindowChrome(true);
    }
    if (p > 0.995 && !this.bumpPlayed) {
      this.bumpPlayed = true;
      // 先无动画压小，再用带过冲的弹簧弹回 1。
      this.contentBump = 0.965;
      this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.55, 0.02) }, () => {
        this.contentBump = 1;
      });
    } else if (p < 0.6 && this.bumpPlayed) {
      this.bumpPlayed = false;
      this.contentBump = 1;
    }
  }

  /**
   * 封面在**卡片坐标系**里的中心 x。
   *
   * 起点 = 播放条封面相对胶囊左上角的偏移；终点 = 终态封面的位置。
   * 因为卡片本身在移动（从胶囊位置长到全屏），封面必须在卡片坐标系里插值，
   * 屏幕上的轨迹才会是「从播放条那颗封面一路长过去」的一条连续线。
   *
   * 用未裁剪的 sheet.value（不是 bgP）：用户要求封面保留回弹，卡片不保留。
   */
  private coverLocalCx(): number {
    const start: number = this.miniCx() - this.barLeftVp;
    return this.lerp(start, this.targetCoverCx(), this.coverP());
  }

  /** 封面在卡片坐标系里的中心 y。 */
  private coverLocalCy(): number {
    const start: number = this.miniCy() - this.barTopVp;
    return this.lerp(start, this.targetCoverCy(), this.coverP());
  }

  /** 封面圆角：播放条是圆形，展开后收到规范圆角。 */
  private coverRadiusVp(): number {
    const target: number = this.lerp(COVER_RADIUS_VP, COVER_SMALL_RADIUS_VP, this.lyrics);
    return this.lerp(this.miniCoverSize / 2, target, this.coverP());
  }

  // ───────── 「一镜到底」的几何：一个会变形的卡片 ─────────
  //
  // 逐帧分析了鸿蒙官方音乐 App 的录屏之后定下的结构（388×837vp，59.47fps）：
  //
  //   卡片顶边：胶囊顶 750.7vp → 0（全程约 0.40s，慢起—快中—缓收，无过冲）
  //   卡片左右：胶囊矩形   → 全屏
  //   卡片圆角：胶囊半径   → 0
  //   封面边长：46vp       → 340vp（**与卡片进度成线性**，实测吻合）
  //   封面中心：(118,787)  → (194,291)
  //
  // 三条结论决定了这里的写法：
  //  ① **背景、内容、封面全部装在同一个卡片里**，由卡片统一裁剪。
  //     官方录屏里，动画中途能看到卡片的圆角，卡片里同时有糊化封面和内容 ——
  //     说明它们是一层容器在变形，而不是「背景先糊上来、封面再从别处冒出来」。
  //  ② **内容是按最终坐标排版、靠卡片裁出来的**。官方录屏里左上角的收起箭头、
  //     右上角的循环图标，从一开始就贴在卡片的左上/右上角，随着卡片长出来 ——
  //     这正是「子内容按终态排版 + 父容器裁剪」的表现。
  //  ③ **封面必须在卡片坐标系里插值**（不能在窗口坐标系）：卡片自己在移动，
  //     封面若用窗口坐标，两者会各走各的，看起来就是「不连贯」。

  /**
   * 卡片进度：**把过冲裁掉**。
   *
   * 用户要求「回弹只给专辑封面，播放页本身不要回弹」。sheet.value 走 springMotion，
   * 到位时会过冲（超过 1 再回落）——封面用原始值所以有回弹，
   * 卡片（背景 + 内容）用这个 clamp 过的值，到 1 就停，不会跟着弹。
   */
  private bgP(): number {
    const p: number = this.sheet.value;
    return p < 0 ? 0 : (p > 1 ? 1 : p);
  }

  /** 卡片左边缘 x（vp，窗口坐标）：0 = 胶囊左边缘，1 = 0（铺满）。 */
  private cardXVp(): number {
    return this.lerp(this.barLeftVp, 0, this.bgP());
  }

  /** 卡片顶边 y（vp）。 */
  private cardYVp(): number {
    return this.lerp(this.barTopVp, 0, this.bgP());
  }

  /** 卡片宽度（vp）。 */
  private cardWVp(): number {
    return this.lerp(this.barWidthVp, this.screenWidthVp, this.bgP());
  }

  /** 卡片高度（vp）。 */
  private cardHVp(): number {
    return this.lerp(BAR_HEIGHT_VP, this.screenHeightVp, this.bgP());
  }

  /** 卡片圆角（vp）：从「胶囊」的整圆收成直角。 */
  private cardRVp(): number {
    return this.lerp(BAR_HEIGHT_VP / 2, 0, this.bgP());
  }

  /**
   * 卡片「材质」的不透明度：0 = 完全是播放条那层半透明毛玻璃，1 = 完全是专辑的颜色。
   *
   * 为什么需要它：播放条本身就是一层毛玻璃，卡片一上来就是实心的，
   * 展开瞬间就成了「毛玻璃被一坨颜色直接糊掉」——用户反馈的割裂。
   * 让材质在前 1/4 行程里由透明渐显（收回时反过来），观感就是
   * **播放条的透明感慢慢过渡成播放页的背景色**，而不是被直接覆盖。
   *
   * 它还顺手解决了收回时的另一个问题：收起动画结尾卡片会**正好盖住**播放条的
   * 进度环和歌名，而卡片要等弹簧彻底停下（progress ≤ 0.001）才卸载 ——
   * 于是环和文字要「过一瞬间」才出现。现在材质在最后 1/4 行程里淡掉，
   * 环和文字随材质变淡渐渐透出来，卸载那一刻已经全部可见，没有跳变。
   */
  private materialAlpha(): number {
    const t: number = this.bgP() / MATERIAL_FADE_P;
    if (t <= 0) {
      return 0;
    }
    if (t >= 1) {
      return 1;
    }
    // smoothstep：两端导数为 0，不会在起止处出现「一下子亮起来」的折角。
    return t * t * (3 - 2 * t);
  }

  /**
   * 顶栏 + 歌名的淡入。
   *
   * 官方录屏里，左上角的收起箭头和歌名大约在卡片铺到 **六到八成** 时显形
   * （帧 183 / 卡片进度 0.84 时歌名已经完全清晰，而进度条还不见踪影）。
   */
  private headAlpha(): number {
    const t: number = (this.bgP() - 0.58) / 0.22;
    return t < 0 ? 0 : (t > 1 ? 1 : t);
  }

  /**
   * 进度条 + 播控的淡入。
   *
   * 比歌名更晚一档：录屏里它们要等卡片基本铺满（帧 190 之后、进度 0.95+）
   * 才落下来。顺序对了，整段才有「一层一层长出来」的层次感。
   */
  private spotAlpha(): number {
    const t: number = (this.bgP() - 0.84) / 0.16;
    return t < 0 ? 0 : (t > 1 ? 1 : t);
  }

  /** 歌词层的淡入：跟卡片进度，比顶栏稍晚。 */
  private contentAlpha(): number {
    return this.headAlpha();
  }

  /** 歌词区顶边：跟随封面底部走。 */
  private lyricsTopVp(): number {
    return this.targetCoverCy() + this.targetCoverSizeVp() / 2 + LYRIC_TOP_GAP_VP;
  }

  /**
   * 歌词空出来的顶边（vp）：顶栏 + 小封面那一行的高度。
   *
   * 歌词列表从**这一行下面**开始排，而不是从 y=0 铺到 y=0 —— 以前第一句会
   * 直接压在左上角封面和歌名上（真机截图里「时间等不了人」和「方大同」叠在一起），
   * 与 Apple Music 的层次不符。
   */
  private lyricsHeaderBottomVp(): number {
    return this.topBarBottomVp() + COVER_SMALL_VP + 12;
  }

  /** 歌词页底部播控条的顶边 y（vp）：歌词正文的渐隐到这里为止。 */
  private lyricBarTopVp(): number {
    return this.screenHeightVp - this.bottomSafeVp() - LYRIC_BAR_HEIGHT_VP;
  }

  /** 切到歌词页 / 切回封面页（Apple Music 的「点封面回来」交互）。 */
  private toggleLyrics(show: boolean): void {
    this.onLyricPageChanged(show);
    this.getUIContext().animateTo({ curve: curves.springMotion(0.5, 0.82, 0.02) }, () => {
      this.lyrics = show ? 1 : 0;
    });
  }

  /**
   * 系统返回（侧滑返回 / 返回键）落到本页时：在歌词页就回封面页。
   *
   * 只有歌词页时才消费 —— 封面页的返回应该由外壳把整页收起来（走那条已有的
   * 收起动画），本页不插手。
   */
  @Monitor('backRequest')
  onBackRequest(): void {
    if (this.backRequest <= 0) {
      return;
    }
    if (this.lyrics > 0.5) {
      this.toggleLyrics(false);
    }
  }

  /** 封面资源（优先沙盒路径，回退 Resource）。 */
  private coverSource(): string | Resource {
    const path: string = this.playerViewModel.songCoverPath();
    if (path !== '') {
      return path;
    }
    return this.playerViewModel.songCover();
  }

  /** 封面的**本地路径**（没有就是空串）：歌词页的模糊运动背景只能用路径图。 */
  private coverSourcePath(): string {
    return this.playerViewModel.songCoverPath();
  }

  /** 窗口形态是否已切到播放页样式（只有真正开始生长时才切，见 onSheetProgressChanged）。 */
  private chromeApplied: boolean = false;

  aboutToAppear(): void {
    this.applyFlowTint();
    this.startBlobMotion();
    this.isAlive = true;
    this.playMode = PlayerDataUtil.getPlayMode();
    this.refreshSongFavorite();
    // **这里刻意不改窗口形态**：挂载瞬间就 setFullScreen + 状态栏反色的话，
    // 会有一帧明显的闪动，用户感知成「手指一碰页面就弹出来了」。
    // 真正的切换挪到进度开始往上走的时候（见 onSheetProgressChanged）。
    //
    // 但系统返回手势要在这里关掉（它没有任何可见副作用）：
    // targetSdk 26 下侧滑返回只会把 App 置于后台，
    // @Entry.onBackPress 与 UIAbility.onBackPressed **都不会被回调**
    // （真机日志确认），所以边缘侧滑只能由本页自己接管（见 edgeBack*）。
    WindowUtil.getInstance().setGestureBackEnabled(false);
    // 音量跟随系统：先把播放器自身的应用级衰减归零，再读真实档位并订阅变化。
    MediaService.getInstance().followSystemVolume();
    this.syncVolumeFromSystem();
    SystemVolume.watch((ratio: number) => {
      if (!this.isAlive) {
        return;
      }
      this.sysVol = ratio;
      this.volPanelLevel = SystemVolume.level();
    });
    this.refreshThemeColor();
  }

  aboutToDisappear(): void {
    this.isAlive = false;
    this.colorJobSeq++;
    // 交还封面：本页已经不在了，播放条上那颗必须回来（否则播放条会空着）。
    // 正常收起动画在落回原位那一刻就已经换回去了，这里只是兜底。
    if (!this.sheet.barCoverVisible) {
      this.sheet.barCoverVisible = true;
    }
    // 必须恢复，否则用户会永久失去系统侧滑返回。
    WindowUtil.getInstance().setGestureBackEnabled(true);
    // 解绑系统音量监听，避免回调打到已卸载的页面上。
    SystemVolume.unwatch();
    if (this.blobTimer !== 0) {
      clearInterval(this.blobTimer);
      this.blobTimer = 0;
    }
    if (this.chromeApplied) {
      WindowUtil.getInstance().applyPlaybackWindowChrome(false);
      this.chromeApplied = false;
    }
    // 释放糊化背景位图（native 内存，不释放会随进出播放页次数累积）。
    const img: image.PixelMap | undefined = this.bgImage;
    if (img !== undefined) {
      try {
        img.release();
      } catch (e) {
        // ignore
      }
      this.bgImage = undefined;
    }
  }

  /** 切歌时重新取色。 */
  @Monitor('state.selectIndex', 'state.playQueueIds')
  onTrackChanged(): void {
    // 换歌：译文状态归零，等新歌的歌词就绪后由歌词视图重新上报
    this.transState = 0;
    this.refreshThemeColor();
    // 换歌后重新读一次 ⭐ 状态（只按资料库歌曲 id 判重，不会白跑请求）
    this.refreshSongFavorite();
  }

  /**
   * 「译」按钮是否点亮。
   *
   * 三个条件：这一首确实有译文可用（官方或 AI） + 译文开关是开的。
   * 没有译文时按钮保持暗色 —— 用户一眼能看出「这首没有翻译」，
   * 点它则是主动要求 AI 翻译（见按钮的 onClick）。
   */
  private transLit(): boolean {
    return this.showTranslation && this.transState > 0;
  }

  /** 触发取色（异步，不阻塞首帧）。 */
  private refreshThemeColor(): void {
    this.pickThemeColor().catch((e: Error) => {
      Logger.warn(TAG, '取色异常: ' + (e.message ?? ''));
    });
  }

  /**
   * 取封面主色 + 生成糊化背景。
   *
   * **封面是网络地址，不是本地文件**：Apple 的封面 URL 直接存在 `coverPath` 里
   * （AppleLibrarySync 的注释：「coverPath 直接放 Apple 的封面 URL」）。
   * 之前拿 `fileIo.openSync()` 去开一个 https 地址，必然失败 ——
   * 所以背景永远是兜底灰，用户看到的就是「没有颜色、也没有流动」。
   */
  /** hex → [r,g,b]（不合法时给一个中性蓝）。 */
  private hexToRgb(hex: string): number[] {
    let h: string = hex.trim();
    if (h.startsWith('#')) {
      h = h.substring(1);
    }
    if (h.length === 8) {
      h = h.substring(0, 6);
    }
    if (h.length !== 6) {
      return [96, 134, 255];
    }
    return [parseInt(h.substring(0, 2), 16), parseInt(h.substring(2, 4), 16),
      parseInt(h.substring(4, 6), 16)];
  }

  /** 用封面主色派生背景色纱与两团光斑的颜色（一团基色、一团亮端）。 */
  private applyFlowTint(): void {
    const c: number[] = this.hexToRgb(this.themeColor);
    const r: number = c[0];
    const g: number = c[1];
    const b: number = c[2];
    const lr: number = Math.min(255, Math.round(r + (255 - r) * 0.34));
    const lg: number = Math.min(255, Math.round(g + (255 - g) * 0.34));
    const lb: number = Math.min(255, Math.round(b + (255 - b) * 0.34));
    this.tintBg = `rgba(${r},${g},${b},0.46)`;
    this.blobA = `rgba(${r},${g},${b},0.36)`;
    this.blobAMid = `rgba(${r},${g},${b},0.14)`;
    this.blobB = `rgba(${lr},${lg},${lb},0.28)`;
    this.blobBMid = `rgba(${lr},${lg},${lb},0.11)`;
  }

  /** 两团光斑缓慢交错漂移：「背景在流动」靠它们，且是渲染变换、不触发布局。 */
  private startBlobMotion(): void {
    if (this.blobTimer !== 0) {
      return;
    }
    this.blobTimer = setInterval(() => {
      if (!this.isAlive) {
        return;
      }
      this.blobFlip = this.blobFlip === 0 ? 1 : 0;
      const dir: number = this.blobFlip === 0 ? -1 : 1;
      this.getUIContext().animateTo({ duration: 11000, curve: Curve.EaseInOut }, () => {
        this.blobAX = dir > 0 ? 70 : -170;
        this.blobAY = dir > 0 ? 90 : 350;
        this.blobBX = dir > 0 ? -100 : 200;
        this.blobBY = dir > 0 ? 620 : 380;
      });
    }, 11000);
  }

  private async pickThemeColor(): Promise<void> {
    const seq: number = ++this.colorJobSeq;
    const url: string = this.playerViewModel.songCoverPath();
    if (url.length === 0) {
      this.themeColor = '#3A3A3C';
      this.bgImage = undefined;
      return;
    }
    const buf: ArrayBuffer | undefined = await this.fetchCoverBuffer(url);
    if (buf === undefined || !this.isAlive || seq !== this.colorJobSeq) {
      return;
    }
    const source = image.createImageSource(buf);
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      pixelMap = await source.createPixelMap();
    } catch (e) {
      Logger.warn(TAG, '封面解码失败: ' + url);
      return;
    } finally {
      try {
        source.release();
      } catch (e) {
        // ignore
      }
    }
    if (pixelMap === undefined || !this.isAlive || seq !== this.colorJobSeq) {
      return;
    }
    effectKit.createColorPicker(pixelMap,
      (err: Error | undefined, picker: effectKit.ColorPicker | undefined) => {
        if (!this.isAlive || seq !== this.colorJobSeq || err !== undefined || picker === undefined) {
          return;
        }
        const c = picker.getLargestProportionColor();
        const arr = ColorConversion.dealColor(c.red, c.green, c.blue);
        const toHex = (n: number): string => {
          const v: number = Math.max(0, Math.min(255, Math.floor(n)));
          const h: string = v.toString(16);
          return h.length === 1 ? `0${h}` : h;
        };
        const raw: string = `#${toHex(arr[0])}${toHex(arr[1])}${toHex(arr[2])}`;
        this.themeColor = this.vivid(raw);
        this.applyFlowTint();
        // 同步给「背景流光」用（歌词页/其它页面直接吃这个主色）
        this.state.flowColor = this.themeColor;
        Logger.info(TAG, `主题色 ${raw} → ${this.themeColor}`);
      });
    // 糊化一份铺背景用（Apple Music 的播放页背景就是糊化封面 + 渐变）
    try {
      const effect = effectKit.createEffect(pixelMap);
      if (effect !== null) {
        effect.blur(BG_BLUR);
        const blurred = await effect.getEffectPixelMap();
        if (this.isAlive && seq === this.colorJobSeq) {
          const old: image.PixelMap | undefined = this.bgImage;
          this.bgImage = blurred;
          // 换新图后释放旧图，来回切歌不会把显存吃满。
          if (old !== undefined) {
            try {
              old.release();
            } catch (e) {
              // ignore
            }
          }
        } else {
          blurred.release();
        }
      }
    } catch (e) {
      Logger.warn(TAG, '封面糊化失败: ' + url);
    }
  }

  /**
   * 下载封面位图。
   *
   * Apple 的封面 URL 形如 `.../100x100bb.jpg`，把尺寸段换成 600x600 再下 ——
   * 糊化后的层次比小图明显得多。
   */
  private async fetchCoverBuffer(url: string): Promise<ArrayBuffer | undefined> {
    // 同步下来的 artworkUrl 通常已经是 600x600 的实地址（AppleApi.bigArtwork），
    // 但接口偶尔也会给带 `{w}x{h}` 的模板，两种都兼容一下。
    let big: string = url;
    if (big.indexOf('{w}') >= 0) {
      big = big.replace('{w}x{h}bb.', '600x600bb.');
    } else {
      big = big.replace(/\/\d+x\d+bb\./, '/600x600bb.');
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(big, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      if (resp.responseCode !== 200 || resp.result === undefined || resp.result === null) {
        Logger.warn(TAG, '封面下载失败 code=' + resp.responseCode);
        return undefined;
      }
      return resp.result as ArrayBuffer;
    } catch (e) {
      Logger.warn(TAG, '封面下载异常: ' + url);
      return undefined;
    } finally {
      req.destroy();
    }
  }

  /**
   * 让取到的主色「可看」：**加深饱和 + 提亮**。
   *
   * 直接用封面主色铺满整页的问题是：大量专辑封面偏暗（黑白/深色调），
   * 取出来的主色接近黑，整页就是一块黑 —— 用户会以为流光根本没生效。
   * 这里做两件事：
   * ① 以三通道均值为灰点向外扩张（饱和增强），让色相显出来；
   * ② 向白色混入 30%，把整体亮度抬到「有颜色又不刺眼」的区间，
   *    白色文字压在上面仍然清晰。
   */
  private vivid(hex: string): string {
    const r0: number = parseInt(hex.substring(1, 3), 16) || 0;
    const g0: number = parseInt(hex.substring(3, 5), 16) || 0;
    const b0: number = parseInt(hex.substring(5, 7), 16) || 0;
    const avg: number = (r0 + g0 + b0) / 3;
    const sat: number = 1.45;
    const liftAmt: number = 0.3;
    const f = (n0: number): string => {
      let n: number = avg + (n0 - avg) * sat;
      n = n + (255 - n) * liftAmt;
      const v: number = Math.max(0, Math.min(255, Math.round(n)));
      const h: string = v.toString(16);
      return h.length === 1 ? `0${h}` : h;
    };
    return `#${f(r0)}${f(g0)}${f(b0)}`;
  }

  /** 在主色基础上再向白混入 amount（流光的另一端）。 */
  private lift(hex: string, amount: number): string {
    const r: number = parseInt(hex.substring(1, 3), 16) || 0;
    const g: number = parseInt(hex.substring(3, 5), 16) || 0;
    const b: number = parseInt(hex.substring(5, 7), 16) || 0;
    const f = (n: number): string => {
      const v: number = Math.max(0, Math.min(255, Math.round(n + (255 - n) * amount)));
      const h: string = v.toString(16);
      return h.length === 1 ? `0${h}` : h;
    };
    return `#${f(r)}${f(g)}${f(b)}`;
  }

  /** 读沙盒里的封面文件为 ArrayBuffer。 */
  /** 播放模式 → 官方符号（repeat / repeat_1 / shuffle）。 */
  private playModeSymbol(): Resource {
    switch (this.playMode) {
      case MusicPlayMode.ORDER:
        return $r('sys.symbol.repeat');
      case MusicPlayMode.SINGLE_CYCLE:
        return $r('sys.symbol.repeat_1');
      case MusicPlayMode.RANDOM:
        return $r('sys.symbol.shuffle');
      default:
        return $r('sys.symbol.repeat');
    }
  }

  // ───────── 手势 ─────────

  /**
   * 下拉跟手：**直接改 sheet.value**（1:1 跟住手指，不插曲线）。
   *
   * 关键改动：以前下拉是改一个独立的位移量，结果「背景缩回」「封面回播放条」
   * 「内容淡出」各走各的，看着是散的。现在下拉直接退进度 —— 背景的收缩、
   * 封面的回位、内容的淡出天然同步，这就是一镜到底该有的样子。
   */
  private onDismissUpdate(offsetYVp: number): void {
    // **只认「向下拖」**。
    // 以前这里把「向上拖」也当成了 down=0，算出 p=1 后直接赋给 sheet.value ——
    // 于是「在播放页里向上滑一下」会把进度一把推到 1。
    // 如果恰好发生在刚挂载（进度还是 0）的时候，播放页就会**瞬间摊满**，
    // 表现正是用户说的「莫名其妙突然弹出来、而且没有动画」。
    if (offsetYVp <= 0) {
      return;
    }
    const span: number = this.screenHeightVp * DISMISS_SPAN_RATIO;
    const p: number = 1 - offsetYVp / span;
    this.sheet.value = p < 0 ? 0 : p;
  }

  /** 下拉松手：过阈值 / 甩得快 → 让宿主弹到收起，否则弹回展开。 */
  private onDismissEnd(offsetYVp: number, velocityVp: number): void {
    if (offsetYVp <= 0 && velocityVp <= 0) {
      // 本来就是往上滑的，不属于收起手势，什么都不做。
      return;
    }
    const down: number = offsetYVp > 0 ? offsetYVp : 0;
    const commit: boolean = down > this.screenHeightVp * DISMISS_COMMIT_RATIO ||
      velocityVp > DISMISS_COMMIT_VELOCITY_VP;
    // 进度已经跟手停在半路，交给宿主用同一条 springMotion 补完（弹到 1 或 0）。
    this.requestClose(commit);
  }

  /** 本次横向手势是否「从屏幕左缘起手」—— 是的话它是返回，不是切歌词页。 */
  private edgeBack: boolean = false;
  /** 本次竖向手势是否算「下拉收起」（只有页面已展开时起手才算）。 */
  private dismissActive: boolean = false;

  /** 横向手势起手：用「当前点 − 已滑距离」还原起点，判断是不是边缘返回。 */
  private onSwipeStart(globalXVp: number, offsetXVp: number): void {
    const startX: number = globalXVp - offsetXVp;
    // 8vp 以下留给系统返回手势区（那里抢不到，也没必要抢）
    this.edgeBack = startX >= 8 && startX <= EDGE_BACK_ZONE_VP;
  }

  /**
   * 边缘返回跟手：**直接退进度**。
   *
   * 这样背景收缩、封面缩回播放条、内容淡出天然同步 —— 和系统返回手势的观感一致，
   * 只是动画换成了我们自己那套连贯的收起动画。
   */
  private onEdgeBackUpdate(offsetXVp: number): void {
    const span: number = this.screenWidthVp * EDGE_BACK_SPAN_RATIO;
    const p: number = 1 - offsetXVp / span;
    this.sheet.value = p < 0 ? 0 : (p > 1 ? 1 : p);
  }

  /** 边缘返回松手：滑过七成或向右甩得快 → 收起，否则弹回。 */
  private onEdgeBackEnd(velocityVp: number): void {
    const commit: boolean = this.sheet.value < 0.75 || velocityVp > 500;
    this.requestClose(commit);
  }

  /** 横向跟手：responsiveSpringMotion（官方给跟手阶段准备的曲线，会记住速度）。 */
  private onSwipeUpdate(offsetXVp: number): void {
    if (this.sheet.value < 0.9) {
      return;
    }
    const span: number = this.screenWidthVp * LYRIC_SWIPE_RATIO;
    let t: number = -offsetXVp / span;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion(0.32, 0.9) }, () => {
      this.lyrics = t;
    });
  }

  /** 横向松手：springMotion 接住速度完成切换（自带回弹）。 */
  private onSwipeEnd(offsetXVp: number, velocityVp: number): void {
    if (this.sheet.value < 0.9) {
      return;
    }
    const span: number = this.screenWidthVp * LYRIC_SWIPE_RATIO;
    let t: number = -offsetXVp / span;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
    const toLyric: boolean = t > 0.5 || velocityVp < -LYRIC_COMMIT_VELOCITY_VP;
    // 注意：**不要**在这里做「任意位置右滑 = 收起整页」——
    // 那会让页面里随便一划就把播放页关掉（用户反馈的「随便左右滑动却返回了」），
    // 而且它是瞬间生效、没有跟手动画。收起只能走左边缘的 edgeBack 通道，
    // 或者系统返回键（见外壳的 handleSystemBack 分层）。

    // 与打开/收起同一条节奏（放慢一档），切歌词页不显得比整页动画更急。
    this.getUIContext().animateTo({ curve: curves.springMotion(0.55, 0.78, 0.04) }, () => {
      this.lyrics = toLyric ? 1 : 0;
    });
  }

  /**
   * 当前曲目在 Apple 资料库里的歌曲 id。
   *
   * Apple 音源的 `src` 是 `apple:<资料库歌曲id>`（形如 `apple:i.abcDEF`），
   * 别的音源（理论上已经没有）返回空串。收藏与分享都靠它。
   */
  private currentAppleLibId(): string {
    const song = this.state.getCurrentSongItem();
    if (song === undefined) {
      return '';
    }
    const src: string = song.src !== undefined ? song.src : '';
    const prefix: string = 'apple:';
    return src.startsWith(prefix) ? src.substring(prefix.length) : '';
  }

  /** 曲目文本（title/singer 可能是 Resource，这里统一转成字符串）。 */
  private textOf(v: string | Resource): string {
    if (typeof v === 'string') {
      return v;
    }
    try {
      return this.getUIContext().getHostContext()!.resourceManager.getStringSync((v as Resource).id);
    } catch (e) {
      return '';
    }
  }

  /**
   * 换歌后刷新收藏状态（目录 id + 是否已收藏）。
   *
   * 只在**资料库歌曲 id 变了**才重新请求：页面切封面/歌词、拖动进度都不会白跑请求。
   * 状态是「目录 id + inFavorites」一次请求同时拿到（`include=catalog&extend=inFavorites`）。
   */
  private refreshSongFavorite(): void {
    const libId: string = this.currentAppleLibId();
    if (libId === this.favLibId) {
      return;
    }
    this.favLibId = libId;
    this.favCatalogId = '';
    this.favOn = false;
    if (libId === '') {
      return;
    }
    AppleApi.getLibrarySongFavState(libId).then((st: SongFavState) => {
      // 期间又换歌了：这份回包已经过期，丢掉
      if (this.favLibId !== libId) {
        return;
      }
      this.favCatalogId = st.catalogId;
      this.favOn = st.inFavorites;
    }).catch((e: Error) => {
      Logger.warn(TAG, '读歌曲收藏状态失败: ' + (e.message ?? ''));
    });
  }

  /** 点 ⭐：收藏 / 取消收藏当前曲目（乐观更新，失败回滚）。 */
  private toggleSongFavorite(): void {
    if (this.favBusy) {
      return;
    }
    const libId: string = this.currentAppleLibId();
    if (libId === '') {
      this.toast('这首歌不在 Apple Music 资料库里，无法收藏');
      return;
    }
    const apply = (): void => {
      if (this.favCatalogId === '') {
        this.toast('还没拿到这首歌的资料库信息，稍后再试');
        return;
      }
      const next: boolean = !this.favOn;
      this.favBusy = true;
      // Apple 侧约 6 秒才传播到 inFavorites，所以先乐观翻转
      this.favOn = next;
      AppleApi.setSongFavorite(this.favCatalogId, next).then((ok: boolean) => {
        this.favBusy = false;
        if (!ok) {
          this.favOn = !next;
          this.toast('收藏失败，请检查网络后重试');
        }
      }).catch((e: Error) => {
        this.favBusy = false;
        this.favOn = !next;
        Logger.warn(TAG, '收藏写入失败: ' + (e.message ?? ''));
      });
    };
    if (this.favCatalogId === '') {
      AppleApi.getLibrarySongFavState(libId).then((st: SongFavState) => {
        this.favCatalogId = st.catalogId;
        this.favOn = st.inFavorites;
        apply();
      }).catch((e: Error) => {
        Logger.warn(TAG, '读歌曲目录 id 失败: ' + (e.message ?? ''));
        this.toast('收藏失败，请检查网络后重试');
      });
      return;
    }
    apply();
  }

  /**
   * 解析当前曲目的 **Apple Music 目录歌曲 id**（分享与收藏都用它）。
   *
   * 两种情况：
   *  - 目录曲目（艺人/搜索/未入库专辑的临时队列）：`src` 就是 `apple:<纯数字>`，直接可用；
   *  - 资料库曲目：`src` 是 `apple:i.xxxx`，必须再查一次 `include=catalog` 才有目录 id。
   *
   * @returns 目录歌曲 id；拿不到返回空串（调用方退化处理）
   */
  private async resolveCatalogSongId(): Promise<string> {
    const song = this.state.getCurrentSongItem();
    const src: string = song !== undefined && song.src !== undefined ? song.src : '';
    const prefix: string = 'apple:';
    if (!src.startsWith(prefix)) {
      return '';
    }
    const raw: string = src.substring(prefix.length);
    if (raw === '') {
      return '';
    }
    if (!raw.startsWith('i.')) {
      // 已经是目录 id（临时队列里的目录曲目）
      return raw;
    }
    if (this.favCatalogId !== '') {
      // 收藏流程已经查过，直接复用，省一次请求
      return this.favCatalogId;
    }
    const st: SongFavState = await AppleApi.getLibrarySongFavState(raw);
    if (st.catalogId !== '') {
      this.favCatalogId = st.catalogId;
      this.favOn = st.inFavorites;
    }
    return st.catalogId;
  }

  /**
   * 分享当前曲目 —— 复刻 Apple Music 自己的分享形态。
   *
   * 关键点：分享的是**链接**（`general.hyperlink`）而不是拼一段文字。
   * Apple Music 的歌曲页带完整 OG 卡片（og:title / og:description /
   * og:image = 1200×630 的封面大图），微信、QQ、微博收到链接后会自己去抓这些标签，
   * 于是渲染成「带封面的大卡片」——这正是 Apple Music 里分享出去的样子。
   * 如果自己把歌名艺人拼成文字发出去，对方只会看到一段纯文本，不会生成卡片。
   */
  private async shareCurrentSong(): Promise<void> {
    const title: string = this.textOf(this.playerViewModel.songTitle());
    const artist: string = this.textOf(this.playerViewModel.songSinger());
    const label: string = artist !== '' ? `${title} - ${artist}` : title;
    const mode: number = await this.askShareMode();
    if (mode < 0) {
      return;
    }
    if (mode === 1) {
      // 图片卡片：微信/朋友圈都会把封面原样显示（链接卡片要靠微信自己去抓 og，
      // 抓不到就没有封面 —— 这是用户实测后确认的唯一稳定形态）
      const path: string = await this.buildShareCard(title, artist);
      if (path === '') {
        this.toast('封面图生成失败，已改为分享链接');
        const cid: string = await this.withTimeout(this.resolveCatalogSongId(), 8000);
        this.showSharePanel(title, label, cid, await this.buildShareThumbnail());
        return;
      }
      this.showImageShare(path, label);
      return;
    }
    // 链接：有目录 id 分享链接（微信里出 og 卡片），否则退化为纯文本
    const catalogId: string = await this.withTimeout(this.resolveCatalogSongId(), 8000);
    const thumb: Uint8Array | undefined = await this.buildShareThumbnail();
    this.showSharePanel(title, label, catalogId, thumb);
  }

  /**
   * 让用户选分享形态：0=链接（微信聊天里可点），1=封面图（微信/朋友圈一定有封面）。
   *
   * 为什么必须二选一：微信的「链接卡片」封面完全由目标页面的 og:image 决定，
   * 抓不到就没有封面（实测 Apple Music 页面在微信侧就是这样）；而「图片消息」
   * 微信一定原样显示。两种各有取舍，所以让用户当场选。
   *
   * @returns 0 / 1；用户取消返回 -1。
   */
  private async askShareMode(): Promise<number> {
    try {
      const options: promptAction.ActionMenuOptions = {
        title: '分享',
        buttons: [
          { text: '分享封面图（朋友圈一定有封面）', color: '#FFFFFFFF' },
          { text: '分享链接（微信里可点开）', color: '#FFFFFFFF' }
        ]
      };
      const res: promptAction.ActionMenuSuccessResponse = await promptAction.showActionMenu(options);
      // 菜单第一项是「封面图」（1），第二项是「链接」（0）
      return res.index === 0 ? 1 : 0;
    } catch (err) {
      Logger.info(TAG, '取消分享');
      return -1;
    }
  }

  /** 歌曲的规范 Apple Music 链接（带歌名 slug，命中规范地址时零跳转）。 */
  private async shareLinkOf(title: string): Promise<string> {
    const catalogId: string = await this.withTimeout(this.resolveCatalogSongId(), 8000);
    if (catalogId === '') {
      return '';
    }
    const slug: string = title !== '' ? encodeURIComponent(title) : '';
    return slug !== ''
      ? `https://music.apple.com/cn/song/${slug}/${catalogId}`
      : `https://music.apple.com/cn/song/${catalogId}`;
  }

  /** 分享一张图片（封面卡片）。 */
  private showImageShare(path: string, label: string): void {
    try {
      const record: systemShare.SharedRecord = {
        utd: utd.UniformDataType.IMAGE,
        uri: fileUri.getUriFromPath(path),
        title: label
      };
      const controller = new systemShare.ShareController(new systemShare.SharedData(record));
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: systemShare.ShareControllerOptions = {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      };
      controller.show(ctx, options).catch((e: BusinessError) => {
        Logger.warn(TAG, `图片分享面板失败 code=${e.code} msg=${e.message ?? ''}`);
        this.toast('分享失败');
      });
      Logger.info(TAG, `分享封面图 path=${path}`);
    } catch (e) {
      Logger.warn(TAG, '图片分享失败: ' + ((e as Error).message ?? ''));
      this.toast('分享失败');
    }
  }

  /**
   * 分享卡片：封面 + 歌名/艺人 + Apple Music 标识 + 二维码。
   *
   * 为什么带二维码：图片消息在微信里「一定有封面」，但**链接会失效**（图片不可点）。
   * 把 Apple Music 链接做成二维码印在右下角，朋友长按/扫码就能听 —— 封面与可听性两者兼得。
   * （360×480vp，导出约 1170×1560px，朋友圈按原图显示）
   */
  @Builder
  shareCardBuilder() {
    Column() {
      Image(this.coverSource())
        .width(360)
        .height(360)
        .objectFit(ImageFit.Cover)
        .draggable(false)
      Row({ space: 12 }) {
        Column({ space: 6 }) {
          Text(this.textOf(this.playerViewModel.songTitle()))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.textOf(this.playerViewModel.songSinger()))
            .fontSize(15)
            .fontColor('#B3FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Blank()
          Text('Apple Music')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFFFF')
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)

        if (this.shareQrPm !== undefined) {
          Column({ space: 4 }) {
            Image(this.shareQrPm)
              .width(78)
              .height(78)
              .objectFit(ImageFit.Contain)
              .borderRadius(6)
            Text('扫码听歌')
              .fontSize(9)
              .fontColor('#8CFFFFFF')
          }
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    }
    .width(360)
    .height(480)
    .backgroundColor('#141416')
    .alignItems(HorizontalAlign.Start)
  }

  /** 二维码 PixelMap（离屏渲染卡片时直接贴图，不需要额外绘制能力）。 */
  @Local shareQrPm: image.PixelMap | undefined = undefined;

  /**
   * 生成歌曲链接的二维码（ScanKit 官方 `generateBarcode.createBarcode`）。
   *
   * 失败不影响分享：卡片退化为「封面 + 文字」，日志里留一行原因。
   */
  private async ensureShareQr(url: string): Promise<void> {
    if (this.shareQrPm !== undefined || url === '') {
      return;
    }
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: 240,
        height: 240,
        backgroundColor: 0xFFFFFF,
        margin: 1,
        level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
      };
      const pm: image.PixelMap = await generateBarcode.createBarcode(url, options);
      this.shareQrPm = pm;
      Logger.info(TAG, `分享二维码已生成 url=${url}`);
    } catch (err) {
      Logger.warn(TAG, '二维码生成失败: ' + ((err as Error).message ?? ''));
    }
  }

  /**
   * 离屏渲染分享卡片并落成 JPEG，返回文件路径。
   *
   * 用 `ComponentSnapshot.createFromBuilder`（离屏渲染）：不需要把卡片节点挂在页面上，
   * 也就不会闪一下；文字/图片全部由 ArkUI 正常排版，中文不会缺字。
   */
  private async buildShareCard(title: string, artist: string): Promise<string> {
    let pm: image.PixelMap | undefined = undefined;
    try {
      // 二维码与卡片同一次渲染：分享出去的图里就带着可扫的 Apple Music 链接
      await this.ensureShareQr(await this.shareLinkOf(title));
      const snap = this.getUIContext().getComponentSnapshot();
      pm = await snap.createFromBuilder((): void => {
        this.shareCardBuilder();
      }, 120, true);
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 92 });
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 固定文件名 + 覆盖写：不留垃圾文件，也方便自检时从沙箱取回核对
      const path: string = `${ctx.filesDir}/share_card.jpg`;
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
      } catch (e) {
        // 首次生成没有旧文件，忽略
      }
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      Logger.info(TAG, `分享卡片生成 ${title} / ${artist} size=${buf.byteLength} path=${path}`);
      return path;
    } catch (err) {
      Logger.warn(TAG, '分享卡片渲染失败: ' + ((err as Error).message ?? ''));
      return '';
    } finally {
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 给一个 Promise 加超时（网络不好时不要卡住分享按钮）。 */
  private withTimeout(task: Promise<string>, ms: number): Promise<string> {
    const timeout: Promise<string> = new Promise<string>((resolve: (v: string) => void) => {
      setTimeout(() => {
        resolve('');
      }, ms);
    });
    return Promise.race<string>([task, timeout]).catch((e: Error): string => {
      Logger.warn(TAG, 'resolveCatalogSongId 失败: ' + (e.message ?? ''));
      return '';
    });
  }

  /**
   * 生成分享面板用的封面缩略图。
   *
   * Share Kit 对 `thumbnail` 有**硬限制：图片必须小于 32KB**，超了会因为
   * want 数据过大直接拉不起面板（官方注释明写）。所以这里把封面解码成
   * 240×240 的 PixelMap 再按质量重试打包，确保落在 30KB 以内。
   *
   * 说明：这张图只用于**系统分享面板的预览**；微信/QQ 收到链接后画封面的依据
   * 仍是目标页面的 og:image，与它无关。
   */
  private async buildShareThumbnail(): Promise<Uint8Array | undefined> {
    const cover: string = this.playerViewModel.songCoverPath();
    if (cover === '') {
      return undefined;
    }
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    try {
      // 封面是 Apple 的 https 地址（`coverPath` 直接存 URL），先落到本地缓存再解码；
      // 已经是本地路径时 ensure() 会原样返回。
      const path: string = await AppleArtworkCache.ensure(cover);
      if (path === '') {
        Logger.warn(TAG, '封面下载失败，分享不带缩略图');
        return undefined;
      }
      src = image.createImageSource(path);
      pm = await src.createPixelMap({ desiredSize: { width: 240, height: 240 } });
      const packer: image.ImagePacker = image.createImagePacker();
      let buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 70 });
      if (buf.byteLength > 30000) {
        buf = await packer.packing(pm, { format: 'image/jpeg', quality: 40 });
      }
      if (buf.byteLength > 30000) {
        Logger.warn(TAG, `缩略图仍偏大 ${buf.byteLength}B，放弃使用`);
        return undefined;
      }
      return new Uint8Array(buf);
    } catch (err) {
      Logger.warn(TAG, '生成分享缩略图失败: ' + ((err as Error).message ?? ''));
      return undefined;
    } finally {
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (e) {
          // ignore
        }
      }
      if (src !== undefined) {
        try {
          src.release();
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 拉起系统分享面板：有目录 id 分享链接（微信里出封面卡片），否则退化为纯文本。 */
  private showSharePanel(title: string, label: string, catalogId: string,
    thumbnail: Uint8Array | undefined): void {
    try {
      let record: systemShare.SharedRecord;
      if (catalogId !== '') {
        // 直接拼**规范形式**（带歌名 slug）：实测 Apple 按 id 解析、slug 写错只会 301 回规范地址，
        // 所以拼上歌名既不会错，又省掉微信爬虫那一次跳转（Apple Music 自己分享的就是这个形式）。
        const slug: string = title !== '' ? encodeURIComponent(title) : '';
        const url: string = slug !== ''
          ? `https://music.apple.com/cn/song/${slug}/${catalogId}`
          : `https://music.apple.com/cn/song/${catalogId}`;
        record = {
          utd: utd.UniformDataType.HYPERLINK,
          content: url,
          title: label,
          // 描述行用「Apple Music · 艺人」，与官方面板里的两行文案一致
          description: 'Apple Music',
          thumbnail: thumbnail
        };
        Logger.info(TAG, `分享链接 song=${catalogId} title=${label} thumb=${thumbnail !== undefined}`);
      } else {
        record = {
          utd: utd.UniformDataType.PLAIN_TEXT,
          content: label
        };
        Logger.warn(TAG, '分享退化为纯文本（没有目录 id）');
      }
      const controller = new systemShare.ShareController(new systemShare.SharedData(record));
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: systemShare.ShareControllerOptions = {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      };
      controller.show(ctx, options).catch((e: BusinessError) => {
        Logger.warn(TAG, `分享面板失败 code=${e.code} msg=${e.message ?? ''}`);
        this.toast('分享失败');
      });
    } catch (e) {
      Logger.warn(TAG, '分享失败: ' + ((e as Error).message ?? ''));
      this.toast('分享失败');
    }
  }

  /** 轻提示（系统 Toast）。 */
  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 1800 });
    } catch (e) {
      Logger.warn(TAG, 'toast 失败: ' + ((e as Error).message ?? ''));
    }
  }

  /** 官方时间行不带前导零（`0:04` 而不是 `00:04`）。 */
  private static shortTime(t: string): string {
    if (t.length > 4 && t.charAt(0) === '0') {
      return t.substring(1);
    }
    return t;
  }

  /**
   * 剩余时间文案。
   *
   * 官方播放器时间行的右侧是**剩余时长**且带负号（例如 −2:26），不是总时长；
   * 用 `progressMax - progress` 算，播放器未就绪（progressMax=0）时退回总时长文案。
   */
  private remainingText(): string {
    const max: number = this.state.progressMax;
    if (!(max > 0)) {
      return `\u2212${this.state.totalTime}`;
    }
    const leftMs: number = max > this.state.progress ? max - this.state.progress : 0;
    const sec: number = Math.floor(leftMs / 1000);
    const m: number = Math.floor(sec / 60);
    const r: number = sec % 60;
    return `\u2212${m}:${r.toString().padStart(2, '0')}`;
  }

  /** 顶部栏：收起 + 更多。 */
  @Builder
  private topBar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(20)
          .fontColor([Color.White])
      }
      .width(40)
      .height(40)
      .backgroundColor('#1FFFFFFF')
      .onClick(() => {
        this.requestClose(true);
      })

    }
    .width(StyleConstants.FULL_WIDTH)
    .height(TOP_BAR_HEIGHT_VP)
    .padding({ left: EDGE_PADDING_VP - 8, right: EDGE_PADDING_VP - 8 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
  }

  /** 封面下方的歌名 / 艺人 + 右侧的 ⭐ 与分享（封面页）。 */
  @Builder
  private bigTitleBlock() {
    // 官方 iOS 26 播放页：歌名与艺人**同一字号**（约 20pt），
    // 只靠字重（Semibold / Regular）与透明度（1.0 / 0.58）区分层级；
    // 右侧两颗 36vp 玻璃圆钮（⭐ 收藏 / 分享）。
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.playerViewModel.songTitle())
          .fontSize(21)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.playerViewModel.songSinger())
          .fontSize(21)
          .fontWeight(FontWeight.Regular)
          .fontColor(Color.White)
          .opacity(0.58)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // ⭐ 收藏：已收藏是实心金星，未收藏是空心白星
      Row() {
        if (this.favOn) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(17)
            .fontColor(['#FFD60A'])
        } else {
          SymbolGlyph($r('sys.symbol.star'))
            .fontSize(17)
            .fontColor([Color.White])
        }
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.favOn ? '#26FFD60A' : '#1FFFFFFF')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleSongFavorite();
      })

      // 分享：拉起系统分享面板
      Row() {
        SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor('#1FFFFFFF')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.shareCurrentSong();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 进度条 + 时间。 */
  @Builder
  private progressBlock() {
    Column({ space: 8 }) {
      // 官方 iOS 26：轨道明显更粗（约 7pt），已播 60% 白、未播 20% 白，
      // 静止时**没有圆点**（只有拖动时才出现），所以把 block 藏掉、只留轨道。
      Slider({
        min: 0,
        max: this.state.progressMax > 0 ? this.state.progressMax : 1,
        step: 1,
        value: this.state.progress
      })
        .blockColor(Color.Transparent)
        .selectedColor('#99FFFFFF')
        .trackColor('#33FFFFFF')
        // 用户反馈「点不了」：滑块和轨道都放大了一档，并且 Block 掉父级下拉手势
        // 对这块区域的抢占（否则横向拖动会被播放页的横向切歌手势吃掉）。
        // 视觉上是「细轨道 + 小圆点」（对齐 Apple Music），但组件高度仍是 32vp、
        // 圆点也保留 16vp，手指依然好点（用户反馈过「点不了」）。
        .blockSize({ width: 12, height: 12 })
        .trackThickness(7)
        .width('100%')
        .height(28)
        .hitTestBehavior(HitTestMode.Block)
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Begin) {
            this.playerViewModel.seek(value);
          }
        })
      Row() {
        Text(PhonePlaybackPage.shortTime(this.state.currentTime))
          .fontSize(13)
          .fontColor(Color.White)
          .opacity(0.5)
        // 官方右侧是**剩余时间**（带负号，例如 −2:26），不是总时长
        Text(this.remainingText())
          .fontSize(13)
          .fontColor(Color.White)
          .opacity(0.5)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
  }

  /**
   * 音量行（官方播放页在播控与底部图标之间还有一行「喇叭 + 细滑块 + 喇叭」）。
   *
   * **这条行显示的是系统媒体音量，改的也是系统音量**（用户 2026-10-19：
   * 「播放页的音量始终与系统音量一致，不要单独调节」）：
   *
   * - 读：`SystemVolume` 按 `STREAM_USAGE_MUSIC` 读真实档位，并订阅
   *   `streamVolumeChange` —— 用侧键 / 播控中心 / 系统音量面板改音量时，这条线实时跟着走；
   * - 写：官方明确规定**应用不能直接调系统音量**，只能通过音量面板
   *   （`AVVolumePanel`）让用户调，所以滑块拖动时只是给面板的 `volumeLevel` 赋值。
   *   面板本身按 1% 不透明度铺在这一行底下（不参与命中测试），用户看到的仍是
   *   Apple Music 那条细线，改的却是系统音量；
   * - 兜底：拖动结束回读一次真实档位，万一面板没受理就立刻回弹到真实音量，
   *   滑块永远不会显示一个不存在的音量。
   */
  @Builder
  private volumeBlock() {
    Stack({ alignContent: Alignment.Center }) {
      AVVolumePanel({ volumeLevel: this.volPanelLevel })
        .width('100%')
        .height(28)
        .opacity(0.01)
        .hitTestBehavior(HitTestMode.None)
      Row() {
        SymbolGlyph($r('sys.symbol.speaker_fill'))
          .fontSize(15)
          .fontWeight(FontWeight.Regular)
          .fontColor(['#B3FFFFFF'])
        Slider({
          min: 0,
          max: 1,
          step: 0.01,
          value: this.sysVol
        })
          .blockColor(Color.Transparent)
          .selectedColor('#8CFFFFFF')
          .trackColor('#26FFFFFF')
          .blockSize({ width: 10, height: 10 })
          .trackThickness(7)
          .layoutWeight(1)
          .height(28)
          .margin({ left: 12, right: 12 })
          .onChange((value: number, mode: SliderChangeMode) => {
            // 拖到哪就把**系统**档位设到哪（应用不再持有自己的音量）
            const want: number = SystemVolume.levelOf(value);
            this.volPanelLevel = want;
            this.sysVol = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              // 音量面板写系统音量是异步的：稍等再回读一次，写日志并把滑块校正到真实档位
              setTimeout(() => {
                const got: number = SystemVolume.level();
                Logger.info(TAG, `volume drag done: want=${want} got=${got}`);
                this.syncVolumeFromSystem();
              }, 150);
            }
          })
        SymbolGlyph($r('sys.symbol.speaker_wave_3_fill'))
          .fontSize(15)
          .fontWeight(FontWeight.Regular)
          .fontColor(['#B3FFFFFF'])
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(28)
  }

  /** 把滑块与音量面板都对齐到系统当前档位（进入页面、拖动结束各调一次）。 */
  private syncVolumeFromSystem(): void {
    const level: number = SystemVolume.level();
    this.volPanelLevel = level;
    const ratio: number = SystemVolume.ratioOf(level);
    // 保留两位小数，避免 0.3333333 这类抖动把 Slider 反复重绘
    this.sysVol = Math.round(ratio * 100) / 100;
  }

  /**
   * 主播控：上一首 / 播放暂停 / 下一首。
   *
   * 用户反馈「点不了」：图标本身的可点区域只有字形那么大，手指很难命中。
   * 这里除了放大字号，还给每颗都加了 padding —— 图标的命中盒跟着 padding 一起变大。
   */
  @Builder
  private transportBlock() {
    Row() {
      SymbolGlyph($r('sys.symbol.backward_end_fill'))
        .fontSize(34)
        .fontColor([Color.White])
        .padding(12)
        .onClick(() => {
          this.playerViewModel.playPrevious();
        })
      // 官方的播放/暂停是**裸字形**（play.fill / pause.fill），不是圆底 +
      // 黑图标 —— 之前用 `*_round_triangle_fill` 是这颗圆形底的主要偏差来源。
      SymbolGlyph(this.state.isPlay ?
        $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(44)
        .fontColor([Color.White])
        .padding(10)
        .onClick(() => {
          this.playerViewModel.togglePlayPause();
        })
      SymbolGlyph($r('sys.symbol.forward_end_fill'))
        .fontSize(34)
        .fontColor([Color.White])
        .padding(12)
        .onClick(() => {
          this.playerViewModel.playNext();
        })
    }
    .width('100%')
    .height(84)
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 封面页底部左下角的「歌词」入口（对齐 Apple Music 同一位置的那颗图标）。
   *
   * 以前进歌词页只有「横向滑动」一条路（且没有任何提示），发现不了；
   * 现在给一个明确的按钮，同时也补齐了官方播放页的那一行元素。
   */
  @Builder
  private lyricsEntry() {
    Row() {
      SymbolGlyph($r('sys.symbol.lyrics_square'))
        .fontSize(26)
        .fontWeight(FontWeight.Regular)
        .fontColor([Color.White])
        .opacity(0.78)
        .padding(11)
        .onClick(() => {
          this.toggleLyrics(true);
        })
      // 官方这一行是「歌词 / 隔空播放 / 队列」三颗，中间那颗我们没有对应的功能；
      // 播放模式挪到这里（原位置在右上角，官方那一格其实是「更多」）。
      SymbolGlyph(this.playModeSymbol())
        .fontSize(25)
        .fontWeight(FontWeight.Regular)
        .fontColor([Color.White])
        .opacity(0.78)
        .padding(11)
        .onClick(() => {
          this.playMode = PlayerDataUtil.cyclePlayMode();
        })
    }
    .width('100%')
    .height(LYRIC_BAR_HEIGHT_VP)
    // 图标中心落在屏宽的 21% / 78%（官方实测位置）；命中盒 48vp 见 padding
    .padding({ left: 64, right: 64 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: this.bottomSafeVp() })
    .opacity((1 - this.lyrics) * this.spotAlpha())
    .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.None : HitTestMode.Default)
  }

  /**
   * 歌词页底部的紧凑播控（上一首 / 播放暂停 / 下一首）。
   *
   * 与封面页的大播控是**两套尺寸**：歌词页要留出阅读空间，所以按钮收小一号、
   * 位置贴底并避开手势条；点击行为完全复用 {@link PlayerViewModel}。
   */
  @Builder
  private lyricTransport() {
    Row() {
      SymbolGlyph($r('sys.symbol.backward_end_fill'))
        .fontSize(30)
        .fontColor([Color.White])
        .padding(10)
        .onClick(() => {
          this.playerViewModel.playPrevious();
        })
      SymbolGlyph(this.state.isPlay ?
        $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
        .fontSize(40)
        .fontColor([Color.White])
        .padding(8)
        .onClick(() => {
          this.playerViewModel.togglePlayPause();
        })
      SymbolGlyph($r('sys.symbol.forward_end_fill'))
        .fontSize(30)
        .fontColor([Color.White])
        .padding(10)
        .onClick(() => {
          this.playerViewModel.playNext();
        })
    }
    .width('100%')
    .height(LYRIC_BAR_HEIGHT_VP)
    .padding({ bottom: this.bottomSafeVp() > 0 ? 0 : 8 })
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: this.bottomSafeVp() })
    .opacity(this.lyrics * this.contentAlpha())
    .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.Default : HitTestMode.None)
  }

  /**
   * 歌词页的「返回封面」热区：盖在左上角小封面 + 歌名那一块上（透明、不画东西）。
   *
   * Apple Music 在歌词页里没有收起箭头，点左上角那一组（小封面/歌名）就回到播放页；
   * 这里照做，顺便解决了「进了歌词页以后箭头还在但点不动」的观感问题。
   */
  /**
   * 歌词页右上角的「译」玻璃圆钮。
   *
   * 36vp 圆、白 20%/33% 底（和收起箭头同款）；开着时字是纯白、关掉时压到 55%。
   * 只翻 `showTranslation`，歌词组件读这个状态决定要不要渲染译文行。
   */
  @Builder
  private lyricTranslationToggle() {
    Row() {
      SymbolGlyph($r('sys.symbol.translate_square'))
        .fontSize(18)
        .fontWeight(FontWeight.Regular)
        // 亮 = 正在显示译文；暗 = 这首没有译文（官方没提供，AI 也还没跑过）
        .fontColor([this.transLit() ? '#FFFFFFFF' : '#8CFFFFFF'])
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(this.transLit() ? '#33FFFFFF' : '#1FFFFFFF')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 有译文（官方或 AI）→ 纯开关；没有 → 点一下触发 AI 翻译，并顺手打开显示
      if (this.transState === 0) {
        this.showTranslation = true;
        // 3 = AI 翻译进行中：按钮先亮起来给出反馈，失败时歌词视图会回报 0 收回
        this.transState = 3;
        this.aiRequest++;
      } else {
        this.showTranslation = !this.showTranslation;
      }
    })
  }

  @Builder
  private lyricHeaderBack() {
    Row()
      .height(COVER_SMALL_VP + 16)
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleLyrics(false);
      })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ═══════════ 卡片：背景 / 内容 / 封面全装在这里 ═══════════
      //
      // 「一镜到底」的全部秘密就是这一层：它从播放条那枚胶囊的位置、尺寸、圆角
      // 一路长成整屏。所有子内容按**最终坐标**排版，被它裁出来 ——
      // 于是背景、封面、文字是同一个容器在变形，而不是几条各自为政的动画
      // （用户反馈的「先叠一层背景、封面再弹出来」就是后者）。
      Stack({ alignContent: Alignment.TopStart }) {
        // ── 材质组：底色 + 糊化封面 + 流光 + 压暗渐变 ──
        //
        // 整组一起淡入淡出（见 materialAlpha）。**必须整组一起**：
        // 它们叠出来才是「播放页的背景颜色」，分开淡会先看到一块死板的色板。
        //
        // 为什么要有这个淡入淡出：播放条自己是一层半透明毛玻璃，卡片一上来就是
        // 实心的，展开瞬间就是「毛玻璃被一坨颜色直接糊掉」——用户反馈的割裂。
        // 现在材质在前 1/4 行程里由透明渐显，观感是「播放条那层毛玻璃慢慢
        // 变成专辑的颜色」；收回时反过来，材质变淡的同时播放条的进度环和歌名
        // 渐渐透出来，所以卡片卸载时不会有「啪」地一下冒出来的那一下。
        Stack({ alignContent: Alignment.TopStart }) {
          // ① 底色：主色。任何情况下都不会是一片空。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.themeColor)

          // ② 糊化封面铺满卡片。
          //    这一层就是播放条那层「材质」本身 —— 它随卡片一起放大，
          //    观感才是「材质摊开」，而不是「另糊了一层背景」。
          //    官方录屏里，动画中途的小卡片内部正好就是一张糊得看不出轮廓的封面。
          if (this.bgImage !== undefined) {
            Image(this.bgImage)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(0.92)
          }

          // ③ 封面色纱 + 两团缓慢漂移的光斑。
          //
          //    原来是官方 `UV_BACKGROUND_FLOW_LIGHT`，但它不按给定颜色出图
          //    （内部带一层灰、且只给 colorSource 会朝默认目标色过渡）——
          //    拿封面色喂进去，屏幕上仍是它自己那套彩色，用户反馈的
          //    「粉蓝相间的默认样式」就是它 + 两团写死色斑叠加的结果。
          //    现在颜色 100% 来自封面主色，且这整组**不随内容滑动**：
          //    它在卡片最底层，歌词翻页只移动上面的元素，背景始终是同一张。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.tintBg)
          Column()
            .width(520)
            .height(520)
            .radialGradient({
              center: ['50%', '50%'],
              radius: '50%',
              colors: [
                [this.blobA, 0.0],
                [this.blobAMid, 0.45],
                ['rgba(0,0,0,0.0)', 1.0]
              ]
            })
            .blur(46)
            .translate({ x: this.blobAX, y: this.blobAY })
          Column()
            .width(520)
            .height(520)
            .radialGradient({
              center: ['50%', '50%'],
              radius: '50%',
              colors: [
                [this.blobB, 0.0],
                [this.blobBMid, 0.45],
                ['rgba(0,0,0,0.0)', 1.0]
              ]
            })
            .blur(46)
            .translate({ x: this.blobBX, y: this.blobBY })

          // ④ 上下压暗的渐变：顶部保留封面的亮色，越往下越沉。
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#00000000', 0.30], ['#59000000', 1.0]]
            })

          // ④.5 歌词模式黑纱：进歌词页时把整页压暗（淡入淡出跟 this.lyrics 走）。
          //      官方的歌词页就是「深色幕布」，不压暗的话 0.2 亮度的灰字会糊在
          //      浅色封面上（真机截图证据：背景亮度 60~95，灰字几乎看不出层次）。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#000000')
            .opacity(this.lyrics * LYRIC_SCRIM_ALPHA)
        }
        .width('100%')
        .height('100%')
        .opacity(this.materialAlpha())
        .hitTestBehavior(HitTestMode.None)

        // ⑤ 歌词层（放在内容层**下面**）：歌词在下、内容在上，
        //    封面页时播控永远在最高层，一定能点；歌词页时内容层整块设 None 穿过去。
        //    左右边距用 LYRIC_EDGE_PADDING_VP（官方歌词条的墨迹从 ~33vp 开始，
        //    比页面默认的 24vp 大一号）。
        //    **上下都不留白**：歌词从屏幕最顶端一直排到最底端，封面/歌名浮在
        //    上面，靠「模糊 + 变淡」区分层次（用户明确要求去掉上下边界）。
        //    areaTopVp 传 0 —— 渐隐条、模糊分段和「活跃行钉在 25% 处」都以屏幕算。
        Column() {
          LyricsComponent({
            isShowControl: false,
            isTablet: false,
            screenHeightVp: this.screenHeightVp,
            // 歌词从「顶栏 + 小封面」下面开始排：活跃行仍然钉在屏幕 25% 处，
            // 但第一句不会再压在左上角的封面/歌名上。
            lyricsAreaTopVp: this.lyricsHeaderBottomVp(),
            // 底边让给底部紧凑播控条：歌词的底部渐隐在它上沿就开始收
            lyricsAreaBottomVp: this.lyricBarTopVp() - LYRIC_BAR_GAP_VP,
            // 左右边距交给歌词组件自己处理：背景（模糊运动层）要铺满整宽，
            // 只有文字区收边 —— 以前 padding 挂在容器上，背景也会跟着缩进去。
            edgePaddingVp: LYRIC_EDGE_PADDING_VP,
            // 模糊运动背景用当前曲目的封面（本地沙箱路径，空串则退回纯色）
            coverPath: this.coverSourcePath(),
            // 只有歌词页真的在前台时才让心跳跑（封面页时零开销）
            active: this.lyrics > 0.5,
            showTranslation: this.showTranslation,
            onToggleTranslation: (): void => {
              this.showTranslation = !this.showTranslation;
            },
            aiRequest: this.aiRequest,
            onTransInfo: (state: number): void => {
              this.transState = state;
            }
          })
        }
        .width(this.screenWidthVp)
        // 歌词层铺满**整屏**（y=0）：背景的模糊流光要一路延伸到最顶端，
        // 否则「头部（小封面/歌名）」与「歌词区」之间会出现一条生硬的色带分界。
        // 头部让位由歌词组件内部用 areaTopVp 顶出（列表顶部垫片 = 锚点高度）。
        .height(this.screenHeightVp)
        .position({ x: 0, y: 0 })
        .opacity(this.lyrics * this.contentAlpha())
        .translate({ x: (1 - this.lyrics) * 32 })
        .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.Default : HitTestMode.None)

        // ⑤.5 封面：卡片坐标系里插值（见 coverLocalCx/Cy 的注释）。
        //
        // **必须画在内容层之下**：播放页封面现在是「满幅贴顶」的，顶栏的收起
        // 箭头、歌词页头部那行文字都要压在它上面；歌词页时同一张图缩成左上角
        // 44vp 的小封面。旧顺序（封面上、内容下）在满幅之后会把顶栏盖住。
        Image(this.coverSource())
          .width(this.coverSizeVp())
          .height(this.coverSizeVp())
          .borderRadius(this.coverRadiusVp())
          .objectFit(ImageFit.Cover)
          .position({
            x: this.coverLocalCx() - this.coverSizeVp() / 2,
            y: this.coverLocalCy() - this.coverSizeVp() / 2
          })
          .shadow({
            radius: 24 * this.materialAlpha(),
            color: '#40000000',
            offsetY: 8
          })
          // 封面纯展示，不参与命中：它盖在中上区域，别让它抢走下面的手势。
          .hitTestBehavior(HitTestMode.None)


        // ⑥ 内容层：按**最终坐标**排版，靠卡片裁出来。
        //    官方录屏里左上角的收起箭头、右上角的循环图标从一开始就贴在卡片
        //    左上/右上角，随卡片一起长出来 —— 正是这个结构的直接证据。
        Column() {
          // 顶栏（含顶部避让：状态栏 / 挖孔）
          // 进歌词页后**整条顶栏淡出**：Apple Music 的歌词页左上角是小封面 + 歌名，
          // 没有收起箭头（点那一组就回播放页，见 lyricHeaderBack）。
          Column() {
            this.topBar()
          }
          .width('100%')
          .height(this.topSafeVp() + TOP_BAR_HEIGHT_VP)
          .padding({ top: this.topSafeVp() })
          .opacity((1 - this.lyrics) * this.headAlpha())

          // 歌名区：紧跟封面下沿（封面在卡片坐标系里，这里按同一套几何留位置）
          Column() {
            this.bigTitleBlock()
          }
          .width('100%')
          .padding({ left: EDGE_PADDING_VP, right: EDGE_PADDING_VP })
          .margin({ top: COVER_TITLE_GAP_VP + this.fullCoverSizeVp() + COVER_TITLE_GAP_VP })
          .opacity((1 - this.lyrics) * this.headAlpha())
          .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.None : HitTestMode.Default)

          // 进度条 + 播控：紧跟在歌名下方（空白全部落到底部）。
          // 落位时有一个很小的回弹（contentBump），只缩不位移。
          Column({ space: 16 }) {
            this.progressBlock()
            this.transportBlock()
            this.volumeBlock()
          }
          .width('100%')
          .padding({ left: EDGE_PADDING_VP, right: EDGE_PADDING_VP })
          .margin({ top: 36 })
          .opacity((1 - this.lyrics) * this.spotAlpha())
          .scale({ x: this.contentBump, y: this.contentBump })
          .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.None : HitTestMode.Default)

          // 空白全部落到底部：把底部条压到屏幕最下沿
          Column()
            .layoutWeight(1)

          // 底部条：封面页 = 「歌词」入口（Apple 播放页左下那颗）；歌词页 = 紧凑播控。
          // 两组叠在同一块区域，靠 lyrics 互斥淡入淡出。
          Stack({ alignContent: Alignment.BottomStart }) {
            // **只挂载当前那一组**：以前两组同时挂着、靠 opacity 互斥，
            // 但透明的那一组命中区还在，于是「点播放下方的词/循环」会落到
            // 歌词页的上一首/下一首上（用户反馈的误按）。按状态挂载后，
            // 屏幕上存在的按钮就是唯一能接收点击的按钮。
            if (this.lyrics > 0.5) {
              this.lyricTransport()
            } else {
              this.lyricsEntry()
            }
          }
          .width('100%')
          .height(LYRIC_BAR_HEIGHT_VP + this.bottomSafeVp())
        }
        .width(this.screenWidthVp)
        .height(this.screenHeightVp)
        // 整层不再做统一淡入/位移 —— 淡入节奏已经下沉到上面三组各自控制。
        // 这样「顶栏和歌名先显形、进度条和播控后落位」的层次才出得来。
        .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.None : HitTestMode.Default)


        // ⑧ 歌词页左上角：小封面右侧的歌名 / 艺人
        Column({ space: 2 }) {
          Text(this.playerViewModel.songTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.playerViewModel.songSinger())
            .fontSize(13)
            .fontColor(Color.White)
            .opacity(0.62)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .position({
          x: LYRIC_EDGE_PADDING_VP + COVER_SMALL_VP + 12,
          y: this.topBarBottomVp() + COVER_SMALL_VP / 2 - 18
        })
        .width(this.screenWidthVp - EDGE_PADDING_VP * 2 - COVER_SMALL_VP - 12)
        .opacity(this.lyrics * this.contentAlpha())
        .hitTestBehavior(HitTestMode.None)

        // ⑨ 歌词页「返回播放页」热区：盖住左上角小封面 + 歌名那一条。
        //
        // Apple Music 的歌词页没有收起箭头 —— 点左上角那一组就回到播放页。
        // 顺便解决一个观感问题：以前顶栏收起箭头在歌词页里还显示着，但整层
        // 按 lyrics 关掉了命中，等于「看得见点不动」。
        Column() {
          this.lyricHeaderBack()
        }
        .width(this.screenWidthVp)
        .position({ x: 0, y: this.topBarBottomVp() })
        .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.Default : HitTestMode.None)

        // ⑩ 歌词页右上角「译」：原来在歌词底部右下角（用户反馈位置别扭），
        //    现在和左上角「小封面 + 歌名」同一行、贴右上角，样式与收起箭头一致
        //    （官方歌词页的译文开关也是浮在界面上的玻璃圆钮）。
        //    必须放在 ⑨ 之后：⑨ 是一条整宽热区，放它前面会被吞掉点击。
        Row() {
          this.lyricTranslationToggle()
        }
        .width(this.screenWidthVp)
        .padding({ right: LYRIC_EDGE_PADDING_VP })
        .position({ x: 0, y: this.topBarBottomVp() + (COVER_SMALL_VP - 36) / 2 })
        .justifyContent(FlexAlign.End)
        .opacity(this.lyrics * this.contentAlpha())
        .hitTestBehavior(this.lyrics > 0.5 ? HitTestMode.Default : HitTestMode.None)
      }
      .width(this.cardWVp())
      .height(this.cardHVp())
      .borderRadius(this.cardRVp())
      // 圆角裁剪是「卡片」这个观感的来源：官方录屏里能清楚看到动画中途的圆角。
      .clip(true)
      .position({ x: this.cardXVp(), y: this.cardYVp() })
      // 还只是播放条那么大时，不要吃播放下方 tab 的触摸。
      .hitTestBehavior(this.bgP() > 0.02 ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    // 两个手势合并成一个 GestureGroup。
    // 同一节点上连着写两个 .gesture() 会互相覆盖，只有最后一个注册上。
    // GestureMode.Parallel：竖直（下拉收起）和横向（切歌词页）方向互不相干。
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PanGesture(this.verticalPan)
          // 只在「页面已经展开」时起手的下拉才算收起手势。
          .onActionStart(() => {
            this.dismissActive = this.sheet.value > 0.9;
          })
          .onActionUpdate((event?: GestureEvent) => {
            if (event === undefined || !this.dismissActive) {
              return;
            }
            this.onDismissUpdate(event.offsetY);
          })
          .onActionEnd((event?: GestureEvent) => {
            if (event === undefined || !this.dismissActive) {
              return;
            }
            this.dismissActive = false;
            this.onDismissEnd(event.offsetY, this.getUIContext().px2vp(event.velocityY));
          })
          .onActionCancel(() => {
            this.dismissActive = false;
          }),
        PanGesture(this.horizontalPan)
          .onActionStart((event?: GestureEvent) => {
            if (event === undefined) {
              return;
            }
            const fingers: FingerInfo[] | undefined = event.fingerList;
            const gx: number = fingers !== undefined && fingers.length > 0 ? fingers[0].globalX : 0;
            this.onSwipeStart(gx, event.offsetX);
          })
          .onActionUpdate((event?: GestureEvent) => {
            if (event === undefined) {
              return;
            }
            // 从边缘起手的右滑 = 返回：跟手收起播放页，不再当作切歌词。
            if (this.edgeBack && this.lyrics < 0.5 && this.sheet.value > 0.01) {
              this.onEdgeBackUpdate(event.offsetX);
              return;
            }
            this.onSwipeUpdate(event.offsetX);
          })
          .onActionEnd((event?: GestureEvent) => {
            if (event === undefined) {
              return;
            }
            const vx: number = this.getUIContext().px2vp(event.velocityX);
            if (this.edgeBack) {
              this.edgeBack = false;
              if (this.lyrics < 0.5 && this.sheet.value < 0.995) {
                this.onEdgeBackEnd(vx);
                return;
              }
            }
            this.onSwipeEnd(event.offsetX, vx);
          })
          .onActionCancel(() => {
            this.edgeBack = false;
          })
      )
    )
  }
}
