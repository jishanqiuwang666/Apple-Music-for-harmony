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
 * Apple Music 风格歌词页的「数据 + 动画状态」层（纯数据，不含 UI）。
 *
 * 设计要点（都是踩过坑之后收敛出来的）：
 *
 * ① **高亮粒度是「字形」**：一行由若干 {@link TokenVisual} 组成，一个词的时长
 *    按字数摊开，每个字形在自己的那一小段里**从左往右填充**（白字亮层按宽度裁剪）。
 *    按字形裁剪时移动的边只有一个字宽，读起来是「字被填满」；按**整行**裁剪
 *    才会出现「一条亮边贯穿整行往右滑」的错觉（那才是被否的写法）。
 *
 * ② **token 下标 ≠ 词下标**：Apple 的 span 里经常夹带纯空白片段，空白会被并进
 *    前一个 token（Flex 里单独的空格 Text 宽度不可靠）。所以每个 token 必须显式
 *    记住自己覆盖的词区间（`firstWord`/`lastWord`），否则英文歌/带空格的歌词会
 *    「有的字永远不亮」。
 *
 * ③ **渐隐（fade）/ 景深（blur）/ 尺寸（scale）都挂在行上、且都是 @Trace 的**：
 *    它们在换行那一刻整体重算（每秒一次左右），不是每帧。放进 @Trace 是因为
 *    一变整行元素都要重画 —— 这正是官方观感里「远处那几句真的糊掉了」的来源。
 */
import { MeasureUtils } from '@kit.ArkUI';
import { LyricLine, LyricWord } from 'musicbasic';

/**
 * 灰字（**除当前行已唱部分以外的所有字**）的不透明度。
 *
 * 0.20 —— 官方录屏逐像素量出来的值：把 432×932 的帧按行取「字迹峰值 vs 局部背景」，
 * 得到 α = (peak - bg) / (255 - bg) ≈ 0.19~0.23，而且**与离当前行多远无关**
 * （第 1 行、第 3 行、第 5 行都测了，一样），也与「当前行里还没唱到的字」一致。
 *
 * 也就是说 Apple 的「聚焦感」不来自给当前行提亮，而来自
 * **整页只有当前行已唱的字是纯白（α=1）**，其余全部压到同一档灰；
 * 远近的层次完全交给「渐隐 + 景深模糊 + 尺寸差」去做。
 */
export const LYRIC_DIM_ALPHA: number = 0.20;
/** 和声行（Apple 用 `ttm:role="x-bg"` 标记）在灰字基础上再压一档。 */
export const LYRIC_BG_EXTRA_DIM: number = 0.62;

/**
 * 当前行的「辉光」（halo）层强度。
 *
 * iOS 的歌词层（macOS `LyricsX` 私有模块里能看到 `glowRadius` / `glowRange` 两个参数）
 * 确实给正在唱的字加了一层柔光。ArkUI 里不能对每个 Text 单独加 `textShadow` ——
 * 阴影按**节点边界**裁剪，一行拆成十几个 Text 后，最边上那个字会在自己节点边界
 * 被切出一条笔直的竖向分界线（本项目踩过）。所以这里改成：
 * **整行副本（同一套 token 树）+ 整层 `.blur()`**，模糊不按节点裁，观感与官方一致。
 */
export const LYRIC_GLOW_ALPHA: number = 0.14;
/** 辉光层的模糊半径（vp）：小一点才像「发光的字」，大了就成霓虹灯。 */
export const LYRIC_GLOW_BLUR_VP: number = 9;

/**
 * 非活跃行的尺寸梯度（官方 iOS 26 实测：活跃行 39pt、其余约 26pt ⇒ 0.67）。
 *
 * 用 `scale` 而不是改字号：变换**不参与布局**，行高与滚动定位完全不受影响
 * （改字号会把折行数与行高一起改掉，滚动位置立刻错）。
 * 逐级递减就是为了复查时一眼看出「越远越小」的层次。
 */
// 缩放档位：**全部 1.0**。
// 逐字量过实录视频（11.4s 那行「我爱故我在」，5 个字墨迹总宽 196px；灰行单字 36px、
// 两个字 72px）：当前行 em≈35vp、其它行 em≈33~35vp —— **字号几乎相同**。
// Apple 的层次来自「纯白 vs 灰 0.11~0.23」「清晰 vs 真模糊」「粗 vs 细」，
// 而不是把非活跃行缩小。所以这里彻底取消缩放：行高/折行恒定，切换时不会有任何
// 「字变大」的观感（用户之前反馈的就是这个）。
export const SCALE_ACTIVE: number = 1.0;
export const SCALE_NEAR: number = 1.0;
export const SCALE_FAR: number = 1.0;
export const SCALE_FARTHEST: number = 1.0;
export const SCALE_AWAY: number = 1.0;

/**
 * 非活跃行的**真模糊**半径（vp），下标 = 离活跃行几行（0、1、2、3、4+）。
 *
 * 这是 2026-10-30 这一轮最关键的一条：旧实现只有「整页 linearGradientBlur + 降透明度」，
 * 于是远处那几句只是变淡、边缘依旧锐利，看起来像「一屏灰字」。
 * 官方录屏放大看，锚点上方第二句已经完全糊掉（≈8~12vp@3x 的高斯模糊）。
 */
// 实测：灰字边缘的 20%→80% 上升宽度约 5~7px（4.4~6.1vp），扣掉字形本身的抗锯齿
// （清晰标题实测 2px），真实模糊半径约 2~4vp 量级 —— 以前 7.0/10.5/13.0 明显过糊，
// 糊到看不出字的结构，反而不像官方。
export const BLUR_BY_DISTANCE: number[] = [0, 2.4, 4.0, 5.2, 6.4];

// 未唱部分的灰度（按离当前句的行数）：实测 0.23 / 0.19 / 0.14 / 0.11
export const DIM_ALPHA_BY_DISTANCE: number[] = [0.23, 0.19, 0.14, 0.11];

/**
 * 译文行的可见度：只有活跃行（及其紧邻一行）显示译文。
 *
 * 官方截图里整页只有正在唱的那一句下面有译文，其余行的译文完全不出现；
 * 我们保留固定高度占位（避免行高变化导致滚动定位错位），只改透明度。
 */
export const TRANS_ALPHA_ACTIVE: number = 0.72;
export const TRANS_ALPHA_NEAR: number = 0.22;
export const TRANS_ALPHA_FAR: number = 0.0;

/**
 * 一个「字/词」的动画状态。
 *
 * 官方录屏逐帧看过：逐字高亮**不是**「亮色层按宽度扫过去」的硬边，
 * 而是每个字在自己的时间窗内**整体由灰渐变到白**（字内部没有明暗分界）。
 * 同时整体又是「一个词从左到右逐渐显示」——两者叠加的效果就是
 * 「白色沿着字往右长，长到的部分已经足够白」。所以这里同时保留：
 * 底色透明度（alpha）+ 白层裁剪比例（fill）。
 */
@ObservedV2
export class TokenVisual {
  /** 这一段的文本。 */
  public text: string = '';
  /**
   * 这一段覆盖的**词**区间（含头含尾，下标对应 `LyricLine.words`）。
   *
   * 必须记！空白片段会被并进前一个 token，于是 token 下标 ≠ 词下标 ——
   * 直接拿 token 下标去对 `words[i].startMs` 会让高亮错位。
   */
  public firstWord: number = 0;
  public lastWord: number = 0;
  /** 底色字的不透明度（灰字底）：恒定 {@link LYRIC_DIM_ALPHA}，白色亮层另有一份。 */
  @Trace public alpha: number = LYRIC_DIM_ALPHA;
  /**
   * 白色亮层在这一段里的**填充比例**（0~1，从左往右）。
   *
   * 渲染是两层 —— 灰字底层 + 白字亮层（外层容器宽 = 这一段宽度 × fill、`clip(true)`），
   * 亮层从左边开始长出来，观感就是「沿着字往右填」。
   *
   * 之所以按**单个字形**裁剪而不是整行裁剪：整行裁剪时移动的是一条贯穿整行的硬边，
   * 看起来像「亮边在字上往右滑」（上一版被否的原因）；按字形裁剪时硬边只在
   * 一个字宽的范围里移动，视线读到的是「这个字被填满」，与官方一致。
   */
  @Trace public fill: number = 0;
  /**
   * 辉光层的可见度（0~1）：已唱到的字才发光，避免「整行一起亮」。
   * 由同一套 fill 推出（fill>0 即有光，fill=1 时最亮）。
   */
  @Trace public glow: number = 0;
  /**
   * 「跳跃感」用的缩放（1 = 原尺寸）。
   *
   * 官方逐字动画带一点弹性：每个字被点亮时会轻微放大再弹回。
   * 这里在字形唱完（fill 到 1）时做一次 1.02 → 1 的弹簧，幅度很小，
   * 但整行的节奏会立刻「活」起来（用户要的「轻微跳跃的灵动感」）。
   */
  @Trace public pop: number = 1;
  /**
   * 「向上微跳」用的竖直位移（vp，负值=向上）。
   *
   * 用户对照官方后明确要求「一个词从左到右逐渐显示，并向上微微跳跃」——
   * 后者就是 Apple 逐字动画里那一下轻微的抬升。和 `pop` 一起在字被填满的瞬间
   * 弹一下（pop 1.02 + lift −1.1vp），再用弹簧收回。
   */
  @Trace public lift: number = 0;
  /**
   * 白字亮层的整体不透明度（0~1）。
   *
   * 平时是 1；**一行唱完、要让位给下一行时**从 1 淡到 0（260ms）再拆掉双层结构，
   * 这样「上一行变暗」是渐隐而不是硬切。官方画面里唱完的行是很快暗下去的，
   * 但绝不是「啪」一下消失。
   */
  @Trace public whiteAlpha: number = 1;
  /**
   * 这一段的实测像素宽度（vp；按**当前字号 + Bold** 量的）。
   *
   * 为什么必须要它：亮层容器的宽度只能用**具体 vp 值**，不能用百分比 ——
   * `Stack` 里写 `width('30%')` 时，百分比会按父级约束（整行可用宽度）解析，
   * 于是外层 Stack 被撑成整行宽，Flex 每段都独占一行 → 屏幕上变成
   * 「一个字一行、竖着往下排」（真机踩过）。所以激活当前行时用 MeasureUtils
   * 逐段量一次宽度，之后只改 `fill × widthVp` 这个数值。
   */
  @Trace public widthVp: number = 0;
  /**
   * 这一段在**其视觉行内的左偏移**（vp）与行号（折行后的第几行）。
   *
   * 逐字高亮的渐变带必须用「行内绝对坐标」才连续：以前每个字按自己的 fill
   * 在**字内**展开渐变，屏幕上是「每个字都从左边亮起、右边渐暗」——字与字交界处
   * 一亮一暗地来回，就是用户说的割裂感。改成整行只有一个填充边界后，
   * 渐变永远是同一处、同一个方向，跨过字边界时完全接得上。
   */
  @Trace public xVp: number = 0;
  @Trace public rowIdx: number = 0;
  /**
   * 这一段在**所属词**的时间窗里占的区间（0~1）。
   *
   * 汉字：一个字一个 token（一段≈一个字）。
   * 拉丁文：整词一个 token（字母级闪烁反而难读，Apple 的词内部是渐变、不拆字母）。
   */
  public fracStart: number = 0;
  public fracEnd: number = 1;
  /**
   * 这一段当前处在哪个阶段：0=还没开始（全灰），1=正在填充，2=已经填满。
   *
   * 阶段切换时才动一次动画（起跳 / 落回），其余心跳不碰这个字。
   */
  public phase: number = 0;
  /**
   * 这个字的「弹一下」是否已经放过了。
   *
   * 为什么不能靠 phase 判断：弹跳现在**提前**到 fill≈0.88 就放（跟声音对齐），
   * 而 phase 要到「填满」才变 2，两者不再同步 —— 用 phase 会让同一个字弹两次。
   */
  public popped: boolean = false;
  /** 这一段是否已经起跳到「上方停住」的位置（每段只跳一次，防重复下动画）。 */
  public jumped: boolean = false;
  /** 填充边界的柔化半径（vp）：只在 fill ∈ (0,1) 时 > 0，唱满自动归零。 */
  @Trace public edgeBlur: number = 0;

  constructor(text: string, alpha: number) {
    this.text = text;
    this.alpha = alpha;
  }
}

/**
 * 一整行歌词的可观察状态。
 */
@ObservedV2
export class LineVisual {
  /** 是否为当前正在唱的行（决定双层结构、译文亮度、辉光）。 */
  @Trace public active: boolean = false;
  /**
   * 这一行的译文（空串 = 没有译文，不占位）。
   *
   * 来源有两个：① Apple 官方 TTML 的 `<translation>` 层；② 官方没有时用户点「译」
   * 触发的 AI 翻译。统一写在这个字段上，渲染侧不必关心译文从哪来。
   */
  @Trace public translation: string = '';
  /**
   * 该行**每个 token 的绝对时间窗**（毫秒，与 `tokens` 一一对应）。
   *
   * 这是「逐字填充」的唯一时间依据，构建行时一次算好：
   * 词级时间 `[word.startMs, word.endMs]` 内部再按字形数均摊。
   */
  public tokenStart: number[] = [];
  public tokenEnd: number[] = [];
  /**
   * 空间渐隐系数（0~1）：按这一行**在屏幕上离活跃行多远**算出来。
   *
   * 活跃行被钉在歌词区的 {@link ACTIVE_IN_AREA} 处，所以每行的「屏幕位置」可以由
   * 它到活跃行的累计高度差精确算出来 —— 这就是「渐隐条钉在屏幕上」而不是
   * 「离当前行 N 行」的原因（行距不均匀时两者差别很明显）。
   */
  @Trace public fade: number = 1;
  /**
   * 行级缩放（Apple 做法）：只有正在唱的那一行是满尺寸，其余行按距离缩小。
   */
  @Trace public scale: number = SCALE_NEAR;
  /**
   * 行级**真模糊**半径（vp）：距离越远越糊。
   *
   * 和 `fade` 分工不同：`fade` 管「淡」，`blur` 管「糊」。官方是两者叠加 ——
   * 只淡不糊会像「灰字」，只糊不淡会像「失焦相机」，两者一起才是景深。
   */
  @Trace public blurPx: number = 0;
  /** 译文行的可见度（只有活跃行附近才显示）。 */
  @Trace public transAlpha: number = 0;
  /** 辉光层整体强度（0~1；只在活跃行非零）。 */
  @Trace public glow: number = 0;
  /** 逐字动画状态：一行 = 若干「字/词」。 */
  public tokens: TokenVisual[] = [];
  /** 这一行折成了几个视觉行（用于估算行高，见 LyricLineLayout.rowCount）。 */
  public rowCount: number = 1;
  /** 白色高光前沿所在的 token 下标（渐变带只挂在它身上）。 */
  @Trace public frontIdx: number = 0;
  /** 前沿在 frontIdx 内部的进度（0~1）：用于让下一个字的渐变带提前长出来。 */
  @Trace public frontFill: number = 0;
  /** 整行唯一的填充边界（视觉行内绝对 vp）与它落在第几个视觉行。 */
  @Trace public fillPx: number = 0;
  @Trace public fillRow: number = 0;
  /** 当前这一行「未唱部分」应有的灰度（按离活跃行的距离分级，见 DIM_ALPHA_BY_DISTANCE）。 */
  @Trace public dimAlpha: number = LYRIC_DIM_ALPHA;
  /**
   * 这一行在列表里的**固定布局高度**（vp）。
   *
   * 这是 2026-10-30 第五轮解决「位置乱跳」的关键：以前行高是「内容自然高度」，
   * 而内容高度取决于实际折行数 —— 活跃行用 Bold（折行多）、非活跃行用 Normal（折行少），
   * 于是同一行在不同时刻高度会差一个行高，滚动目标（按估算累加）与实际位置就对不上，
   * 只能靠事后补滚去追（表现就是「跳多了一下又回去」）。
   * 现在把高度**钉死**在估算值上（Bold 折行数 ≥ Normal，所以只会留白、不会溢出），
   * 内容坐标与屏幕位置严格一一对应，滚动变成纯加法，一次到位。
   */
  @Trace public heightVp: number = 0;
  /**
   * 该行**实测**高度（vp，由行块的 onAreaChange 回填）。
   *
   * 滚动定位只能用它：heightVp 是估算（按字宽累加推折行数），只要估算比实际
   * 大一点，滚到后面就会「越来越偏上」——每行差 1vp，一百行就差出一整行。
   * 0 表示还没渲染过，此时退回 heightVp 兜底。
   */
  @Trace public measuredH: number = 0;
  /** 逐段宽度是按哪个字号量的（-1 = 还没量）；字号变了要重量。 */
  public widthForFont: number = -1;
  /** 整行是否基本是「和声」（`ttm:role="x-bg"` 字符过半），是的话渲染再压暗一档。 */
  public background: boolean = false;
}

/**
 * 排版器：只回答一个问题 —— **这一行在给定宽度下会折成几行**。
 *
 * 渲染交给 `Flex(wrap)` 自己折行（Text 里放不了 ForEach 的 Span，踩过），
 * 这里只需要一个够准的行数来估行高（空间渐隐要用）。逐词贪心累加宽度，
 * 与 Flex 的断行位置基本一致。
 */
export class LyricLineLayout {
  /**
   * 计算一行的视觉行数。
   *
   * @param line 歌词行。
   * @param maxWidthVp 可用宽度（vp）。
   * @param fontSize 字号（fp，与 Text.fontSize 同单位）。
   * @param letterSpacing 字间距（vp）。
   * @param measure 文本测量器（来自 `getUIContext().getMeasureUtils()`）。
   * @param pxToVp px→vp 换算系数（取 `getUIContext().px2vp(1)`）。
   * @returns 至少 1 的视觉行数。
   */
  public static rowCount(line: LyricLine, maxWidthVp: number, fontSize: number, letterSpacing: number,
    measure: MeasureUtils, pxToVp: number): number {
    const limit: number = maxWidthVp > 0 ? maxWidthVp : 320;
    const words: LyricWord[] = LyricLineLayout.wordsOf(line);
    if (words.length <= 1) {
      return 1;
    }
    const widthOf = (s: string): number => {
      if (s.length === 0) {
        return 0;
      }
      const px: number = measure.measureText({
        textContent: s,
        fontSize: fontSize,
        fontWeight: FontWeight.Bold,
        letterSpacing: letterSpacing
      });
      return px * pxToVp;
    };
    let rows: number = 1;
    let acc: string = '';
    for (let i = 0; i < words.length; i++) {
      const cand: string = acc + words[i].text;
      if (acc.length > 0 && widthOf(cand) > limit) {
        rows++;
        acc = LyricLineLayout.trimStart(words[i].text);
      } else {
        acc = cand;
      }
    }
    return rows;
  }

  /** 行内没有词片段时（异常数据）兜底成整行一个片段。 */
  private static wordsOf(line: LyricLine): LyricWord[] {
    if (line.words.length > 0) {
      return line.words;
    }
    const only: LyricWord = new LyricWord();
    only.text = line.text;
    only.startMs = line.startMs;
    only.endMs = line.endMs > line.startMs ? line.endMs : line.startMs + 3000;
    return [only];
  }

  /** 去掉前导空白（换行后行首不该有空格）。 */
  private static trimStart(s: string): string {
    let i: number = 0;
    while (i < s.length) {
      const c: string = s.charAt(i);
      if (c === ' ' || c === '\t') {
        i++;
      } else {
        break;
      }
    }
    return i > 0 ? s.substring(i) : s;
  }
}
