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
 * Apple Music 风格歌词页（2026-10-30 整体重构）。
 *
 * ## 这一版要解决什么（对照 iOS 26 官方歌词页逐项拆开）
 *
 * 1. **景深**：官方不是「整页一个渐变模糊」，而是**每行按距离真模糊** ——
 *    锚点附近清晰，往上下逐级糊掉（上边两句几乎看不清），同时配合变淡。
 *    旧实现只有 opacity + scale，远处那句仍然边缘锐利，所以永远像「一屏灰字」。
 *    现在每行带自己的 {@link LineVisual.blurPx}（走官方 `.blur()`），
 *    外层再叠一层 `linearGradientBlur` 做「上下缘更强」的整体景深。
 * 2. **高光**：正在唱的字是纯白 + 一层柔光。iOS 的歌词层确实有 glow
 *    （macOS `LyricsX` 私有模块的 `glowRadius` / `glowRange` 就是它）。
 *    ArkUI 不能给每个 Text 加 `textShadow`（阴影按节点边界裁 → 一行拆成几十个
 *    Text 会切出竖向硬边，本项目踩过）。这里改成**整行副本 + 整层 `.blur()`**：
 *    结构与正文完全一致（同一套 token / 同一宽度），所以不会错位，也不会切边。
 * 3. **背景的模糊运动**：官方背景是封面的大幅模糊，而且**在缓慢流动**
 *    （模糊色块整体漂移 + 局部冷暖光呼吸），不是一张静止的图。
 *    这里在歌词区叠一张低透明度的重度模糊封面 + 缓慢的 scale/translate，
 *    再用一层径向光随「当前行在屏幕上的位置」轻微漂移。
 * 4. **译文**：官方只有正在唱的那一句下面有译文，其余行不显示。
 *    旧实现每行都挂译文（虽然压到 0.18），整页一片碎字。现在译文淡入淡出跟活跃行走。
 * 5. **定位**：仍然坚持「问 List 要真实矩形」（`getItemRect` + 顶部垫片），
 *    这是唯一不会累积误差的做法；落位后校验一次、偏差 > 3vp 补滚。
 * 6. **灵动**：换行时 fade / scale / blur 三者**一起**用 300ms 过渡（旧实现是直接赋值，
 *    整列瞬间变化 → 观感发硬）；滚动走官方 `curves.springMotion`；
 *    换行瞬间锚点柔光呼吸一下；逐字填充仍然是 33ms 按播放头直接算（最顺、不飘）。
 *
 * ## 时间（曾经是最大的坑，别再动）
 *
 * 唯一时间源是 {@link LyricPlayhead}：主源 = AVPlayer `currentTime`（播放头本体），
 * 备源 = `state.progress` 锚点。**禁止**用「事件 + 墙钟插值」推算（实测能领先 15 秒）。
 *
 * ## 负载
 *
 *  - 心跳只在歌词页可见时跑（`active`），封面页零开销；
 *  - 逐字只碰当前行；景深只在换行时整体重算一次；
 *  - 单行 blur 只在 |距离| ≤ 4 的行上非零，更远的行 fade 已经是 0（不绘制）；
 *  - 背景那张模糊图用「小尺寸渲染 + scale 放大」压住模糊的像素成本。
 */
import { AppStorageV2, curves, MeasureUtils } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { AppStorageKeys, AppleArtworkCache, AppleLyric, AiLyricsTranslator, Logger, LyricLine, LyricWord } from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';
import {
  BLUR_BY_DISTANCE,
  DIM_ALPHA_BY_DISTANCE,
  LineVisual,
  LYRIC_BG_EXTRA_DIM,
  LYRIC_DIM_ALPHA,
  LYRIC_GLOW_ALPHA,
  LYRIC_GLOW_BLUR_VP,
  LyricLineLayout,
  SCALE_ACTIVE,
  SCALE_AWAY,
  SCALE_FAR,
  SCALE_FARTHEST,
  SCALE_NEAR,
  TokenVisual,
} from '../model/LyricVisual';
import { LyricPlayhead } from '../model/LyricPlayhead';

const TAG: string = 'AppleLyricsView';
/** 指挥器心跳（毫秒）：只负责「发现换行 / 滚动 / 景深」，不负责画每一帧。 */
// 42：触发精度从 66ms 提到 42ms。滚动/起跳都是「到点就动」，
// 采样粗了就会出现"该动的那一拍刚好错过，等到下一拍"——顿挫的一半来自这里。
const CONDUCTOR_MS: number = 42;
/** 逐字填充的刷新周期（≈30fps）。白层宽度每帧直接按播放头算，不用动画框架插值。 */
const FILL_MS: number = 33;
/** 字间距；测量与渲染必须用同一个值，否则估算行数会偏。 */
const LETTER_SPACING: number = 0.5;
/** 视觉行行高（vp）。官方活跃行行高 50pt ≈ 48vp；这里取 44 兼顾多行折行。 */
// 42.5：实测 Apple 行内行距 42.7vp（445 宽录屏帧 49px × 0.8712 = 42.7）
const LINE_HEIGHT_VP: number = 42.5;
/** 段落间距（vp）：相邻两个 ListItem 各出一半。 */
// 32：实测句间"行顶到行顶"74.9~76.7vp，减去行高 42.5 → 额外 32.4~34.2
/**
 * 句与句之间的间距（vp）—— Apple Music 的标准值。
 *
 * 来源：官方歌词页 39pt 字 / 84pt 段距（约 2.15 倍字高），按本项目 35vp 字号
 * 换算即 32vp。这正是「最开始」那份规格。
 *
 * 它同时是**译文的位置**：译文高 28 + 上下各 2 = 32，正好把这段间距塞满。
 * 于是「有译文」与「没译文」的行等高，句间距恒为 32，观感统一。
 * （行高已改为由内容自适应，所以这个值不会再因为估算误差而忽大忽小。）
 */
const PARA_GAP_VP: number = 18;
/**
 * **文字字形行框**（vp）：= 原行高 + 14。
 *
 * 拉丁字母的 descender（g j p q y 的尾巴）垂在基线以下，标准行高（42.5）
 * 装不下 —— 它会落在行框外，被 Text 的溢出规则裁掉，于是那截永远不参与高亮
 * （中文是方块字、没有下伸部，所以从来不会暴露这个限制）。
 *
 * 关键：**灰字层、白字层、辉光层必须用同一个值**。只改其中一层会让两层字形
 * 基线错开、变成重影（这个坑已经踩过三次）。
 * 行框变大后段落间距从 32 收到 18，总行距仍是 74.5，整页节奏不变。
 */
const GLYPH_BOX_VP: number = LINE_HEIGHT_VP + 14;
/** 相邻两条歌词的中心距（vp）。 */
const LINE_PITCH_VP: number = LINE_HEIGHT_VP + PARA_GAP_VP;
/** 译文行占用高度（vp），只用于估行高（显示与否都占位，避免行高跳动）。 */
const TRANS_LINE_VP: number = 34;
/** 译文每一行文字的行高（vp）：比整块最小高度小，两行时总高才不夸张。 */
const TRANS_TEXT_LINE_VP: number = 30;
/**
 * 译文上下各自的呼吸（vp）。
 *
 * 有译文行的句间空间 = 译文高 + 2×它（3 + 34 + 3 = 40），比无译文行的 32 略大。
 * 之前把译文高度压到 28 想让它「住进」32 的段距里，结果 23.8fp 的字（实际行高约
 * 28.6）上下被切掉、译文显示不全 —— 译文高度该按字高来定，段距跟着它走。
 */
const TRANS_PAD_VP: number = 3;
/**
 * 活跃行中心固定在**歌词区**高度 × 这个比例处（整首歌不动）。
 *
 * 用户 2026-10-19 明确要求「正在播放的那一句中间靠下」，之后又要「再往上一点点」，
 * 所以落在 45.5% —— 上下都留出两三行上下文，视线落点仍在屏幕中部。
 */
// 0.255：实测当前句**首行**中心落在屏高 25.5%（录屏 y0=221px × 0.8712 = 192.5vp，
// 加半个行高 21 → 213.5vp / 837vp）。以前用的 0.455 是「中间靠下」，与 Apple 差约 170vp。
const ACTIVE_IN_AREA: number = 0.255;
/** 手指离开后，等多久自动回到正在播放的那一句（毫秒）。 */
const FOLLOW_RESUME_MS: number = 4000;
/**
 * 逐字高亮的**提前量**（毫秒）。
 *
 * 用户反馈「文字跳动的时机有些晚」：歌词时间戳是「字被唱出」的时刻，而渲染有
 * 1~2 帧延迟、心跳采样又是 33ms 一档，叠加起来总是慢半拍。做法是把判定用的
 * 播放头整体前移 {@link LEAD_MS}：白层提前 90ms 开始长、弹跳也提前落下，
 * 于是「字亮起」与「听到字」在感知上对齐（音乐类 UI 的常规做法）。
 */
const LEAD_MS: number = 240;
/**
 * 字填到这个比例就开始「弹」一下（不等填满，视觉上才跟得上声音）。
 */
const POP_AT: number = 0.86;
/**
 * 弹跳幅度**按字长自适应**（Apple 的做法：语速快 → 每个字的时间窗短 → 跳动更轻更快；
 * 语速慢 → 时间窗长 → 幅度略大、回落更缓）。
 *
 * 基准：一个「普通语速」的汉字约 {@link POP_BASE_MS} 毫秒。
 * 用户在快歌里被「每个字都大跳一下」搞得很吵，所以这里不再是固定幅度，
 * 而是 `幅度 = 1 + POP_GAIN * 权重`，权重 = clamp(字长 / 320, 0.5, 1.8)。
 */
const POP_BASE_MS: number = 320;
// 0：逐帧比对实录（11.4s 前后那一行 5 个字，连续 4 帧的 x 墨迹范围 38..233 完全不变、
// 峰值恒 255）→ Apple **没有**整字放大。之前的 1.026 倍是照"活泼"加的，与官方不符。
const POP_GAIN: number = 0.0;
/**
 * 「高光波形」的向上峰值（vp，负值=向上）× 字长权重。
 *
 * 注意这里**不是弹跳**：位移由 `sin(π × 填充比例)` 驱动 —— 高光扫到字中间时抬到最高，
 * 扫完自然落回 0。整行十几个字连起来就是「一道波从左往右流过」，而不是每个字各弹一下。
 */
// 逐字「上跳后停留」：这个字一被唱到就往上跳，然后**停在上面**（不回落到基线），
// 于是整行唱过的字都比没唱的高一截，从左往右像台阶一样一级级跳上去。
// 之前做成 sin(πp) 的波形（上去又落回），方向是反的。
// ── 整行波浪（不是逐字跳）────────────────────────────────────────────
// 抬升量的**唯一依据**是「这个字离白色高光边界有多远」，所以整行是一道连续的波：
// 波峰永远压在灰白交界上，向左（已唱）和向右（未唱）都平滑回落到基线。
// 这样它既不是"每个字各自跳"（会有台阶缝），也不会出现"字跳完停在上面"
// （那样已唱部分会整体悬空）。
const WAVE_AMP_VP: number = 3.0;
const WAVE_HALF_TOKENS: number = 2.2;

// 灰白交界的柔和带（vp）：多层递进裁剪逼近 alpha 渐变。
// 4 层 / 8vp 时每阶 alpha 差 0.25（≈50/255），肉眼能看到阶梯线；
// 现在 11 层 / 12vp（每阶 1.2vp、alpha 差 ≈0.08≈17/255），低于可见阈值。
// **只对「正在填的那个 token」展开这 11 层**（同一时刻最多 1~2 个），
// 其它 token 用单层硬边 —— 节点数几乎不增加。
/**
 * 白层边缘的柔化带宽（vp）。
 *
 * 12 → 5：这是「下一个字提前铺白」的宽度。汉字才 ~17vp 宽，12vp 的预热带
 * 一展开就等于把大半个字整块提亮 —— 用户反馈「高光移到那个字时，字的底
 * 突然整体变亮一点，而不是从左到右逐渐变亮」，根因就是这个带宽。
 * 5vp（约字宽 30%）既能柔化交界，又只表现为「左边缘开始亮」。
 */
const EDGE_BAND_VP: number = 13.0;
// 16 层：6vp 的坡道落在 3.25x 屏上是 19.5px，每层约 1.2px，
// 层与层之间足够密，肉眼才连成一条渐变而不是几个台阶。
// 32 层：6vp 的坡道 => 每层 0.19vp（≈0.6px @3.25x），相邻层的白度差 1/31 ≈ 3.2%
// （在深色幕布上约 7/255，低于「肉眼能看出台阶」的 8/255 阈值）。
// 16 层时差值 6.7% ≈ 14/255 —— 那就是用户说的「一条线」：不是渐变断了，
// 而是每一级台阶本身就够亮、够宽，被看成了一条条的硬边。
// 44 层：13vp 的坡道 => 每级 0.30vp（≈1.0px @3.25x），相邻层白度差 1/43 ≈ 2.3%
// （深色幕布上约 5/255，远低于可辨阈值 8/255）。层数不够时，每一级台阶
// 本身就是一条细硬边 —— 加带宽而不加层数，只会把线拉宽、不会消失。
const EDGE_STEPS: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29
];
// **前段陡降**的序列（1.0 → 0.005）。
// 关键认知：这些层是叠在一起的（最宽的在底层），覆盖区的实际亮度
// 是 1-(1-a1)(1-a2)… 的累积，所以「每层降幅一致」看起来反而是
// 前 2~3vp 一片纯白、然后突然掉下来 —— 那正是用户说的那条线。
// 让靠内的几层迅速降下来，合成后才是一条视觉上的连续坡道。
// ── 逐层 alpha 是**解出来的**，不是拍的 ──
//
// 这些层是叠在一起的（第 15 层最宽在最底，第 0 层最窄在最上），
// 某个像素的最终白度 = 1 - Π(1-a_i)，对所有「比自己宽」的层求积。
// 之前我按「每层等幅下降」调，叠起来外层很快就接近纯白 —— 于是
// 前几 vp 一片死白、后面突然掉下去，那就是用户反复说的「分界线」。
//
// 想要合成后是一条 1 → 0 的**线性**坡道（宽 k 个段的位置白度为 k/15），
// 递推解出每层应当是不透明 1/i：
//   P_k = ∏_{i=k+1..15}(1-a_i) = k/15  ⇒  a_j = 1/j
// 于是 a = [1, 1/1, 1/2, 1/3, …, 1/15]。数学上严丝合缝，不再有台阶。
const EDGE_ALPHA: number[] = [
  1.0, 1.0000, 0.5000, 0.3333, 0.2500, 0.2000, 0.1667, 0.1429,
  0.1250, 0.1111, 0.1000, 0.0909, 0.0833, 0.0769, 0.0714, 0.0667,
  0.0625, 0.0588, 0.0556, 0.0526, 0.0500, 0.0476, 0.0455, 0.0435,
  0.0417, 0.0400, 0.0385, 0.0370, 0.0357, 0.0345
];

const JUMP_VP: number = 2.2;
// 起跳动画：不再手动做"两档过冲"，交给弹簧曲线。
// response 0.26 / damping 0.55 → 大约 220ms 内到位，中段自然过冲 15% 左右，
// 观感是"弹一下再稳稳停住"，比写死两档值顺得多。
const JUMP_MS: number = 260;
const JUMP_RESPONSE: number = 0.26;
const JUMP_DAMPING: number = 0.55;
const LIFT_BASE_VP: number = 0.0;
/** 末尾长音的泛光：字时长超过这个值、且位于行尾，就点亮一层持续呼吸的柔光。 */
const TAIL_GLOW_MS: number = 480;
/** 当前行唱完后，提前多久开始滚到下一行（毫秒）。 */
// 100 → 150：上一行最后一个字刚落音就启动（不是等句子空档过完），
// 这样下一句开口时动画基本走完 —— 用户要的「即将播放的那句已经在该在的位置」。
// 0：上一句**一唱完就滚**（用户要求：上一句播完，下一句就要去它该在的位置）。
// 不再提前，也不会等 —— 句间空隙整段都留给滚动动画。
const SCROLL_LEAD_MS: number = 0;
/** 自动回位用的时长（比换行滚动慢一点，用户能看见它滑回去）。 */
const RETURN_DURATION_MS: number = 520;
const RETURN_RESPONSE: number = 0.46;
const RETURN_DAMPING: number = 0.80;
/**
 * 锚点上方：从锚点往上到区域顶边，不透明度按这个指数衰减。
 *
 * 0.42 是「缓衰减」：锚点上方两行仍有 ~0.76，一直到屏幕顶边才柔和归零。
 * （之前用 smoothstep，锚点上方约 180vp/4 行就整块消失了 —— 用户反馈
 * 「只能看到屏幕中间那几行，上面的歌词全看不见」。）
 */
const FADE_UP_EXP: number = 0.42;
/** 点击 seek 之后保护期内不接受播放头的旧采样（避免高光闪回旧行）。 */
const SEEK_GUARD_MS: number = 900;
/** 锚点下方：走到剩余行程的这个比例之后开始收，到区域底边归零。 */
const FADE_DOWN_START: number = 0.86;
/** 最底部这几十 vp 再快速压一遍，避免最后一行「齐刷刷断掉」。 */
const FADE_DOWN_TAIL_VP: number = 34;
/**
 * 整页渐变模糊的最大半径（**px**）。
 *
 * 有了逐行真模糊之后，这一层只负责「上下缘更强」的整体景深，所以比旧值小
 * （旧值 30px 会和逐行 blur 叠加成一团浆糊）。
 */
// 从 15 → 56：这一层现在**承担上下缘的全部遮盖**（透明度渐隐已取消）。
// 字号约 35vp（≈114px），56px 的半径足以把边缘文字糊成一片色块，
// 拖动时不会露出「半截清晰、半截看不见」的割裂。
// 56 → 44：半径过大时 ArkUI 的渐变模糊要先降采样再卷积，降采样倍率高就会出块状伪影。
// 44px 配合两端 0.92/1.0 的强度已经能把边缘文字糊成一片色块。
const EDGE_BLUR_PX: number = 44;
/** 超过这个距离的行不再做逐行模糊（观感无损失，省掉离屏层）。 */
// 0 = 关闭逐行模糊。逐行 `.blur()` 与全屏 `linearGradientBlur` 是**两层独立模糊**：
// 平台边缘那几行既有 4~6vp 的逐行 blur，又落在全屏模糊的过渡区，叠起来就把笔画
// 糊成了色块（用户看到「像马赛克一样糊掉」）。现在景深完全交给视口级模糊，
// 只保留一处，且顺带省掉多条离屏渲染。
const BLUR_MAX_DIST: number = 0;
/**
 * 窗口化渲染：只给锚点上下这么多行建真实节点。
 *
 * 整列 100+ 行全量挂载时，每帧平移整块纹理都要过 300 个文本节点，120Hz 吃不下。
 * 25 行 ≈ 一屏半，覆盖到「屏幕上下沿再各留半屏」的余量，滚动时不会看到空白。
 */
const WINDOW_UP: number = 18;
const WINDOW_DOWN: number = 20;
/** 缓冲区：锚点离窗口边界还剩这么多行时不重建（避免每换一行就增删节点）。 */
const WINDOW_MARGIN: number = 6;
/**
 * 手动浏览后多久回到播放位置（用户要求：5 秒不动就回去）。
 *
 * 注意这是「从手指离开屏幕算起」，不含拖动过程本身。
 */
const BROWSE_IDLE_MS: number = 5000;
/** 抬手惯性：把速度外推成额外位移，再让 Friction 收住。 */
const BROWSE_FLING_MS: number = 420;
const BROWSE_FLING_GAIN: number = 0.10;
const BROWSE_FLING_MAX_VP: number = 520;
/** 滚动动画期间全屏渐变模糊降到多少（0 = 关闭；动画结束再恢复）。 */
// 不再在滚动/拖动时降级：降级会让边缘瞬间变清晰，正好破坏「靠模糊盖住」。
const EDGE_BLUR_SCROLLING_PX: number = 44;
/** 锚点附近「无模糊」平台宽度（按行计）：保证当前行及其紧邻一行清晰。 */
const BLUR_PLATEAU_LINES: number = 1.05;
/**
 * 锚点柔光层的边长（vp）。
 *
 * **必须是正方形、且用 `radius: '50%'`**：ArkUI 的 radialGradient 里
 * `radius` 只认「数字」或「百分比」，传 '200vp' 这种带单位的字符串会失效
 * → 整个盒子被填成一块半透明白矩形（用户反馈的「光线明显的边界是一个矩形」）。
 */
const GLOW_SIDE_VP: number = 460;
/** 柔光平时 / 换行瞬间的强度。 */
const GLOW_IDLE: number = 0.55;
const GLOW_PEAK: number = 1.0;
/** 手指触摸后多久内不抢滚动位置（毫秒）。 */
// 900 → 420：手指哪怕只是蹭一下屏幕，也会让自动跟随停这么久。
// 实测这个"误冻结"是「有时不滚」的主要体感来源之一。
const TOUCH_HOLD_MS: number = 420;
/** 换行滚动的时长与弹簧参数（对齐 Apple 的 SpringAnimationParameters）。 */
// 260 → 240：跟句子节奏更贴（阻尼不变，仍然不过冲）
// 150：实录换行滚动从开始到停止共 133ms（60fps 逐帧：0/1/4/8/13/23/36/55/64/65px），
// 位移 65px = 56.6vp。这里取 150ms 让弹簧的尾段自然收掉。
// 130：句间空隙通常 200~600ms，130ms 足够在下一句开口前落位；
// 再短会显硬，再长就会"下一句已经唱了还在滑"。
// 340：整列平移（translate）比滚动更"重"，时长略长观感更绵；阻尼 0.92 不过冲。
const SCROLL_DURATION_MS: number = 470;
// 每拍（42ms）吃掉差值的比例；配 Linear 短动画 → 速度连续、无回弹
const SCROLL_FOLLOW_ALPHA: number = 0.30;
const SCROLL_FOLLOW_MS: number = 50;
// 0.28 → 0.36：响应变长一点，滑过去更「缓」，但阻尼仍保持 0.95（不过冲）——
// 用户明确不喜欢「跳过头再弹回来」，弹性只放在景深/亮度那一层。
// 0.20：实测曲线是「慢-快-慢」的 S 形、**没有过冲**（末两帧 9px→1px 直接停）。
// response 0.20 ≈ 200ms 的时间常数，主行程落在 60~70% 处，正好对上 133ms。
// 0.40：整列平移的"重量"更大，响应给长一点才有惯性感
const SCROLL_RESPONSE: number = 0.42;
// 0.92：留一点点余韵，但实测没有回弹，所以不降到 0.8x
// 0.92 → 0.68：留出**可见的回弹**（冲过目标不到 5% 再落回）。
// 0.92 那档几乎不过冲，观感就是"生硬地停在目标上"——用户明确要曲线和回弹。
// 0.62：过冲约 8%，肉眼能看出「冲过去再落回来」的回弹感；
// 0.68 那一档过冲只有 4% 左右，用户反馈「还是生硬」。
const SCROLL_DAMPING: number = 0.62;
/** 滚动落位后多少毫秒做一次校验（列表还在布局时首次滚动会落空）。 */
const SCROLL_SETTLE_MS: number = 520;
/** 景深（fade/scale/blur/译文）过渡时长（毫秒）：官方换行时整列是「滑过去」的，不是跳变。 */
const DEPTH_ANIM_MS: number = 340;
/** 景深过渡的弹簧参数：response 越大越慢，damping < 1 才有回弹（要「Q」就靠它）。 */
const DEPTH_RESPONSE: number = 0.40;
const DEPTH_DAMPING: number = 0.86;

// 换行过渡（官方 curves.springMotion）。
//  · 透明度/模糊这一层：阻尼 0.74 —— 略微过冲一点，看起来是「柔和地亮起来」；
//    阻尼再低（<0.7）字会先亮过头再退回，观感像闪。
//  · 尺寸这一层：响应更长、阻尼更低 —— 整列像被手指按住后松开那样滑过去。
// 逐字预热：开唱前多少毫秒开始提亮、提亮到多少
/**
 * 「整字预热」已废弃（保留常量仅为兼容旧引用）。
 *
 * 原先在字开唱前 220ms 把**整个字的底色**从 dimAlpha(0.20) 抬到 0.55
 * （2.75 倍），本意是还原录屏里「下一字提前发亮」的现象。
 * 但实测它和「逐字从左到右填充」在机制上矛盾：用户看到的不是`亮边进入这个字`，
 * 而是`这个字的底整体亮了一度`——因为抬的是整字 alpha，不是填充边界。
 * 现在底色恒为未唱灰度，白层的推进完全交给 fill。
 */
const PREHEAT_MS: number = 0;
const PREHEAT_ALPHA: number = 0.20;

const DEPTH_FADE_MS: number = 520;
const DEPTH_FADE_RESPONSE: number = 0.44;
const DEPTH_FADE_DAMPING: number = 0.74;
const DEPTH_SCALE_MS: number = 640;
const DEPTH_SCALE_RESPONSE: number = 0.56;
const DEPTH_SCALE_DAMPING: number = 0.62;
/** 背景层：模糊封面图的渲染尺寸比例 / 放大倍数 / 模糊半径（vp）。 */
const BG_IMAGE_RATIO: number = 0.62;
const BG_IMAGE_ZOOM: number = 2.9;
const BG_IMAGE_BLUR: number = 30;
const BG_IMAGE_ALPHA: number = 0.62;
/**
 * 官方「UV 背景流光」的配色（hdsEffect 的 UV_BACKGROUND_FLOW_LIGHT）。
 *
 * Apple Music 歌词页背景不是「一张糊掉的封面」，而是**封面被糊开之后还在缓慢流动**：
 * 冷暖两块色在整屏上互相漫过来。这种「流动」用静图做不到，正好对上鸿蒙官方的
 * 背景流光着色器 —— 外壳（Index）已经在用同一条效果，这里只是把配色换成
 * 「深蓝 × 暖褐」，贴近官方那种「舞台灯」的观感，并且让流光的流动层压在
 * 模糊封面之上（两层叠加出「模糊 + 流光」）。
 */
// 兜底色（没有封面主色时用）：深蓝单色系，**不再是「蓝 × 褐」两种色相**。
const FLOW_SOURCE: string[] = ['#1B2B4A', '#5E7BA8'];
const FLOW_TARGET: string[] = ['#5E7BA8', '#1B2B4A'];
const FLOW_DURATION_MS: number = 7000;
/**
 * 官方 UV 流光开关（**关**）。
 *
 * 实测结论：`UV_BACKGROUND_FLOW_LIGHT` 不按给定颜色出图 —— 它内部有一套固定配色
 * （shader 自带一层灰，且只给 colorSource 时会朝默认目标色过渡），拿封面色喂进去，
 * 屏幕上仍是它自己那套彩色。用户连续两轮反馈「流光跟封面没关系 / 五彩斑斓的默认颜色」，
 * 根因就在这一层。现在背景改由下面三个「封面色」图层承担（渐变 + 两团漂移光斑 + 呼吸光），
 * 颜色完全由我们控制，同时省掉一次全屏 shader（性能也是净收益）。
 */
const FLOW_SHADER_ENABLED: boolean = false;
/**
 * 歌词页是否绘制**自己的**背景内容（色纱/光斑/呼吸光）。
 *
 * 关：背景统一由宿主播放页的材质组提供 —— 那是「滑动时背景不动」的前提。
 * 开着的话歌词页每翻一页/一滑都会带着自己那层背景一起动，屏幕上就是
 * 两层背景互相错位（用户反馈的「背景应该只有一张、只有元素在动」）。
 * 歌词页只保留**静止**的压暗纱与上下渐变（它们本来就不随滑动变化）。
 */
const LYRIC_BG_SELF: boolean = false;
const FLOW_ALPHA: number = 0.78;
/** 两团缓慢漂移的光斑（保证「流动」肉眼可见，不依赖 shader 观感）。 */
const BLOB_SIDE_VP: number = 520;
const BLOB_BLUR_VP: number = 46;
/** 背景暗纱：压暗到「文字看得清、色彩仍可见」的程度。 */
const BG_DIM: number = 0.10;
/** 背景运动的周期与幅度（一次动画走完全程，渲染线程插值，UI 线程不参与）。 */
const BG_MOTION_MS: number = 11000;
const BG_SCALE_MIN: number = 1.04;
const BG_SCALE_MAX: number = 1.14;
const BG_SHIFT_VP: number = 12;
/** 调试开关：换行时打印一行诊断（排查用；平时关掉省 IO）。 */
const LYRIC_TRACE: boolean = false;

/**
 * 一行歌词。
 *
 * 结构（三档，节点数按需要给；整页几十行，只有活跃行是三层）：
 *  · 活跃行：辉光层（整行副本 + 整层 blur）+ 正文层（灰底 + 白填充）
 *  · 非活跃行：一层灰字
 *  · 译文：固定高度占位，可见度跟随 {@link LineVisual.transAlpha}
 *
 * 为什么不用 `Text + ForEach(Span)`：`ForEach` 直接放在 `Text` 里不渲染（踩过），
 * 而 token 数量是动态的 —— 只能用「Flex + 若干 Text」，折行交给 Flex 自己排。
 */
@ComponentV2
struct LyricLineItem {
  /** 歌词行数据。 */
  @Param line: LyricLine = new LyricLine();
  /** 该行的可观察状态（含逐字填充、景深、译文可见度）。 */
  @Param visual: LineVisual = new LineVisual();
  /** 字号（fp）。 */
  @Param fontSize: number = 35;
  /** 是否显示译文。 */
  @Param showTranslation: boolean = true;
  /** 点击回调（跳播）。 */
  @Param onTap: () => void = (): void => {};
  /** 行块实测高度上报（父组件据此重算滚动定位）。 */
  @Event onMeasured: () => void = (): void => {};

  /**
   * 亮层容器宽度（vp）= 这一段的实测宽度 × fill。
   *
   * **绝对不能写成百分比**：Stack 里的百分比按父级约束解析，会把外层 Stack
   * 撑成整行宽，Flex 立刻退化成「一个字一行」（真机踩过）。
   */
  /**
   * 第 step 层的裁剪宽度：`fill × 自身宽 + step × (EDGE_BAND / 层数)`。
   *
   * step=0 就是老的白层宽度（精确到 fill），后面几层依次多露一点，
   * 靠透明度递减形成斜坡。唱满（fill=1）时所有层宽度都 ≥ 自身宽，
   * 等于整字全白，不会在字尾留下半透明边。
   */
  /**
   * 第 step 层白层的裁剪宽度（vp）——**以行内绝对坐标为唯一依据**。
   *
   * 整行只有一个填充边界 {@link LineVisual.fillPx}，渐变带以它为中心、
   * 总宽 EDGE_BAND_VP（左半已填、右半未填）。每一层的右边界固定为
   * `fillPx - B/2 + step*B/(N-1)`，因此：
   *  · 边界左边的字：每层都盖满整字 → 合成纯白；
   *  · 边界所在/相邻的那个字：各层宽度不同 → 合成一段连续的坡；
   *  · 边界右边更远的字：各层宽度都是 0 → 不画白层。
   * 坡在任何时刻都是「同一条、同一个方向」，跨字边界也不会重新开始。
   */
  private fillWidthStep(t: TokenVisual, step: number): number {
    const w: number = t.widthVp > 0 ? t.widthVp : 16;
    const vis: LineVisual = this.visual;
    const half: number = EDGE_BAND_VP * 0.5;
    // ── 结构恒定（每层都建，不用 if 增删节点）是**消除闪烁的前提**：
    //    之前用「是否落在渐变带内」决定建不建多层，边界扫过一个字就会
    //    建 44 个节点、扫过去又销毁，33ms 一次 —— 屏幕上一闪一闪的。
    //    现在只改宽度，节点树形状永远不变。
    // ── 但这会带来「整字全白时 24 层完全重叠、重复绘制」的浪费，
    //    所以下面把两种情况压成单层：整字已在渐变带左侧（纯白）→ 只留最实的一层；
    //    整字在右侧（纯灰）→ 各层宽度都为 0。
    // 只用「字符序列虚拟坐标」判断，**不看视觉行号**：
    // 我们自己累加出来的折行位置和 Flex 真实换行早晚会差一点点，一旦判据里
    // 掺进行号，折行句就会出现「第二行开头的字提前跟着第一行亮」这类错。
    // 现在 xVp 是跨视觉行连续累加的量（第 2 行接在第 1 行末尾），边界在同一
    // 个轴上单调前进，于是「点亮时刻」只跟唱到哪一个字有关，与排版位置无关。
    // **不再做「整字已白 → 压成单层」的早退**。
    // 那个优化看着省节点，实际是一条**宽度突变**：某个词在边界扫过的瞬间从
    // 30 层突然变成 1 层，两层结构在边缘抗锯齿上的差异就表现为「闪一下」——
    // 英文尤其明显（一个 token 覆盖整个单词，宽、变化快）。现在宽度只随
    // fillPx 连续变化，结构恒定，不可能闪。
    const n: number = EDGE_STEPS.length - 1;
    const edge: number = vis.fillPx - half + (step * EDGE_BAND_VP) / n;
    const width: number = edge - t.xVp;
    if (width <= 0) {
      return 0;
    }
    if (width >= w) {
      return w;
    }
    // **量化到 0.5vp**：不量化的话宽度每帧都在亚像素级变化，每帧都要重新裁剪，
    // 偶发一帧就会漏画笔画（用户看到的「字母右侧某块闪一下」，'O' 那种细弧线
    // 最明显）。0.5vp 的变化肉眼不可见，但能把重裁次数降一个量级。
    return Math.round(width * 2) / 2;
  }


  /** 把 0~1 的不透明度换成白色 ARGB。 */
  private colorOf(alpha: number): string {
    const v: number = alpha < 0 ? 0 : (alpha > 1 ? 1 : alpha);
    const h: string = Math.round(v * 255).toString(16).padStart(2, '0');
    return `#${h}FFFFFF`;
  }

  /** 这一行是否真的会渲染译文（决定行高、上下间距与底部 padding 的分账方式）。 */
  private hasTrans(): boolean {
    return this.showTranslation && this.visual.translation.length > 0;
  }

  /** 非活跃行：只画一层灰字（省节点）。 */
  @Builder
  dimLayer() {
    Flex({
      wrap: FlexWrap.Wrap,
      direction: FlexDirection.Row,
      justifyContent: FlexAlign.Start,
      alignItems: ItemAlign.Start
    }) {
      ForEach(this.visual.tokens, (t: TokenVisual, i: number): void => {
        // 全粗体（用户要求）：未播放/已播放/正在播放统一 Bold。
        // 顺带一个好处：行高估算是按 Bold 量的，渲染也用 Bold 之后，
        // 「估算行高 = 实际行高」严格成立，滚动目标（纯加法）就永远准。
        Text(t.text)
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(LETTER_SPACING)
          .lineHeight(GLYPH_BOX_VP)
          .fontColor(this.colorOf(t.alpha))
          // 固定宽度 + 单行：**必须与活跃层/辉光层完全同构**。
          // 以前这里用的是文字自然宽度，而活跃层每段多 1.5vp —— 一行二十来段就宽出
          // 30vp 左右，本来排得下的句子一切到活跃态就折成两行（用户说的「一行变两行」）。
          .width(t.widthVp > 0 ? t.widthVp : 16)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Clip })
      }, (t: TokenVisual, i: number): string => {
        return i.toString();
      })
    }
    .width('100%')
  }

  /**
   * 活跃行的辉光层：整行副本 + 整层 `.blur()`。
   *
   * 关键点：**布局必须与正文完全一致**（同一套 token、同一字号/字距/行高/宽度），
   * 否则模糊光晕会和正文错位，看起来像「字后面有个重影」。
   * 每个 token 的可见度跟随它自己的 {@link TokenVisual.glow}（已唱到才亮）。
   */
  @Builder
  glowLayer() {
    Flex({
      wrap: FlexWrap.Wrap,
      direction: FlexDirection.Row,
      justifyContent: FlexAlign.Start,
      alignItems: ItemAlign.Start
    }) {
      ForEach(this.visual.tokens, (t: TokenVisual, i: number): void => {
        // **必须与正文层用同一个固定宽度**（widthVp）：辉光层若按文字的
        // 自然宽度排，每个字比正文的固定宽度窄 1.5vp，十几个字累下来折行点
        // 就会和正文错开 —— 屏幕上表现为「字后面还跟着一层错位的模糊字」（重影）。
        Stack({ alignContent: Alignment.TopStart }) {
          Text(t.text)
            .fontSize(this.fontSize)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(LETTER_SPACING)
            .lineHeight(GLYPH_BOX_VP)
            .fontColor('#FFFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Clip })
        }
        .width(t.widthVp > 0 ? t.widthVp : 16)
        .opacity(t.glow)
        .hitTestBehavior(HitTestMode.None)
      }, (t: TokenVisual, i: number): string => {
        return i.toString();
      })
    }
    .width('100%')
    .blur(LYRIC_GLOW_BLUR_VP)
    .opacity(LYRIC_GLOW_ALPHA * this.visual.glow)
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 活跃行的正文层：灰底字 + 白字亮层（按宽度裁剪）。
   *
   * 白层外层容器宽 = 这一段的实测宽度 × fill 并 `clip(true)`，于是白色从左边长出来 ——
   * 硬边只在一个字宽内移动，读起来是「字被填满」，不会像整行裁剪那样变成
   * 「亮边往右滑」。
   */
  @Builder
  activeLayer() {
    Flex({
      wrap: FlexWrap.Wrap,
      direction: FlexDirection.Row,
      justifyContent: FlexAlign.Start,
      alignItems: ItemAlign.Start
    }) {
      ForEach(this.visual.tokens, (t: TokenVisual, i: number): void => {
        Stack({ alignContent: Alignment.TopStart }) {
          Text(t.text)
            .fontSize(this.fontSize)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(LETTER_SPACING)
            .lineHeight(GLYPH_BOX_VP)
            .fontColor(this.colorOf(t.alpha))
            .width(t.widthVp > 0 ? t.widthVp : 16)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Clip })
          // ── 灰白交界的柔和过渡 ──────────────────────────────────
          // 单个 clip 是硬切（能看到一条刀切线），blur 会让整字发虚（用户反馈"字变模糊了"）。
          // 这里用 **4 层递进裁剪**叠出 alpha 斜坡：每层比前一层多露出 2/3/4 个 EDGE_BAND 的
          // 份额、透明度依次 1 / .75 / .5 / .25。叠加后的等效 alpha 是
          //   边界内 1.00 → 0.91 → 0.63 → 0.25 → 0
          // 也就是 ~8vp 的柔和带，且每层只影响交界附近、字本身完全清晰。
          // 只有「正在填」的这一段需要渐变带（前沿在它内部）；
          // 未唱的段（fill=0）宽 0、唱满的段（fill=1）整字全白，都不需要分层 ——
          // 上一版给所有段都叠了 extra 宽度，于是**未唱的字最左侧露出一条白边**。
          // 前沿那一段带渐变；当前沿快唱满（>50%）时，**下一个字**也开始长出渐变带，
          // 两者重叠 → 交界处不再出现「白字紧贴纯灰字」的硬切。
          // **只给正在填的那一个字**建多层渐变（fill ∈ (0,1)，或刚进入该字 fill≈0）。
          // 原来还带了「下一个字在前沿过半后也预热」——那一份既不显示（grow=0 宽度为 0），
          // 又白白多出 32 个 Text 节点，还会让「下一个字提前亮」的旧观感有复发的余地。
          // 白层：**结构恒定**（24 层恒在，只改宽度），这样边界扫过时不会有
          // 节点增删 —— 闪烁就是这么来的。整字已全白/全灰的情况由
          // fillWidthStep 压成单层，实际绘制的 Text 仍然只有边界那一个字。
          ForEach(EDGE_STEPS, (step: number, si: number): void => {
            Stack({ alignContent: Alignment.TopStart }) {
              Text(t.text)
                .fontSize(this.fontSize)
                .fontWeight(FontWeight.Bold)
                .letterSpacing(LETTER_SPACING)
                .lineHeight(GLYPH_BOX_VP)
                .fontColor('#FFFFFFFF')
                // 与灰字层**同宽**：宽度定死就不会自己折行，于是不需要
                // maxLines 来防折行。这一点很关键 —— 上次去掉 maxLines 却
                // 没给宽度，白字自己折成好几行才出的乱子。
                .width(t.widthVp > 0 ? t.widthVp : 16)
                // 不设 maxLines / textOverflow：官方规格里 textOverflow(Clip) 的裁剪
                // 是按**段落行边界**做的，行高（lineHeight）只影响组件高度、不改段落
                // 内部行高 —— 所以 descender 永远在行边界之外被裁掉，加高行框无效。
                // 揭示完全交给外层容器的 clip（它的可见区已扩到行框之外）。
            }
            .width(this.fillWidthStep(t, step))
            // **绘制区比行框高、但用 position 脱离布局**：
            // 白层靠 clip 揭示，而 clip 只显示自身盒子内的像素；盒子高度原本就是
            // 行高，j/g/y/p 的**下伸笔画**落在行框外 → 那截永远不亮
            // （用户: "j 最底下的尖一直到高光过去还是灰的"）。
            // 不能用 height+margin（margin 会把文字推偏 → 重影，已踩过），
            // position 不参与布局：盒子向上扩 12、向下扩 12，占位仍是 0，
            // 文字位置完全不变。
            // 盒子向下扩高 + **position 脱离父级高度约束**：
            // 父级（token 盒子）高度固定为 GLYPH_BOX_VP，子项的 height 会被父级
            // 约束收窄，clip 的裁剪范围实际仍只有那么高 —— 这大概是 descender
            // 一直不亮的原因。position 让它脱离布局约束，x/y 取 0 就是 token
            // 左上角（与原来严格对齐，不会错位）。
            .height(GLYPH_BOX_VP + 40)
            .position({ x: 0, y: 0 })
            .opacity(si === 0 ? t.whiteAlpha : t.whiteAlpha * EDGE_ALPHA[si])
            .clip(true)
            .hitTestBehavior(HitTestMode.None)
          }, (step: number): string => {
            return 'e' + step.toString();
          })
        }
        .width(t.widthVp > 0 ? t.widthVp : 16)
        // 与字形行框同高：白层盒子额外多出的部分由这一层吸收，
        // Flex 的行高 = GLYPH_BOX_VP（含 descender 空间）。
        .height(GLYPH_BOX_VP)
        // 逐字弹跳：唱完这个字时 1.02 → 1（弹簧）+ 向上 1.1vp 再落回
        .scale({ x: t.pop, y: t.pop })
        .translate({ y: t.lift })
      }, (t: TokenVisual, i: number): string => {
        return i.toString();
      })
    }
    .width('100%')
  }

  build() {
    Column({ space: 0 }) {
      if (this.visual.active) {
        Stack({ alignContent: Alignment.TopStart }) {
          // 辉光层已停用：它是一份整行模糊副本，与逐字填充叠加会让字比实际进度更亮。
          // 保留条件挂载的好处是彻底不建节点（一行的整层 blur 是实打实的开销）。
          if (this.visual.glow > 0.01) {
            this.glowLayer()
          }
          this.activeLayer()
        }
        .width('100%')
      } else {
        this.dimLayer()
      }

      if (this.showTranslation && this.visual.translation.length > 0) {
        // 译文：固定高度 + 可见度跟随活跃行（官方只有当前句下面有译文）
        Row() {
          Text(this.visual.translation)
            // 比正文小一号（35 → 23.8fp）。Apple 官方是 39pt 正文 / 20pt 译文（0.51），
            // 用户两次要求放大 → 0.68，读起来省力，同时仍明显小于正文。
            .fontSize(this.fontSize * 0.68)
            .fontWeight(FontWeight.Medium)
            .lineHeight(TRANS_TEXT_LINE_VP)
            // 与「未播放的原文」同色同亮度（LYRIC_DIM_ALPHA）：译文是辅助信息，
            // 不该比正文更亮 —— 以前是纯白，压过了还没唱到的原文。
            .fontColor(this.colorOf(LYRIC_DIM_ALPHA))
            .opacity(this.visual.transAlpha)
            // 最多两行：英文一句译成中文常有二三十字，一行只放得下十三四个，
            // 单行 + 省略号就是用户说的「翻译显示不完全」。
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        // 高度自适应（不再写死）：一行取 TRANS_LINE_VP 的最小高度，两行自然撑开。
        // 行块的定位由实测高度（onAreaChange）兜底，所以译文换行不会带偏滚动。
        .constraintSize({ minHeight: TRANS_LINE_VP })
        // 上方留「半个段落间距」，下方的半个由行块 bottom padding = 0 抵掉 ——
        // 于是译文正好落在「上一句正文底」与「下一句正文顶」的正中间（各 16vp）。
        // 译文上下各留 2vp 呼吸：它自己的高度就是「句间空白」的全部，
        // 不再额外加一个段落间距（否则有译文的歌整体比无译文的松散一截）。
        .margin({ top: TRANS_PAD_VP, bottom: TRANS_PAD_VP })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 高度钉死 = 估算行高（见 LineVisual.heightVp）。这样 List 的布局高度、
    // lineCenters、滚动目标三者严格一致，滚动是「纯加法」而不是「猜完再补」。
    // **不再写死行高**：以前这里 `.height(heightVp)` 把行钉在"估算高度"上，
    // 而内部内容是自然排布的。两者一旦不等（有没有译文、开关译文、AI 译文写入，
    // 都会让高度变化），估算大一点就在行底留下空白、小一点就让文字溢出压到下一行 ——
    // 屏幕上就是「有的两句离得特别远、有的贴得特别近」。
    // 这正是"加译文之前没事、加了之后出问题"的根因：以前高度是常量，误差被
    // 32vp 的段落间距吞掉了；间距收紧之后立刻暴露。
    // 现在高度完全由内容决定，视觉间距永远等于「内容 + padding」，
    // heightVp 退回它本来的职责：只用于滚动定位的累加估算。
    // 实测高度回填：页面滚动的累加位置只认这个值（heightVp 只是估算兜底）。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const h: number = typeof newValue.height === 'number' ? newValue.height as number : 0;
      if (h > 0 && Math.abs(h - this.visual.measuredH) > 0.5) {
        this.visual.measuredH = h;
        this.onMeasured();
      }
    })
    // 无译文行：上下各半个 PARA_GAP（= 32）。
    // 有译文行：上下 padding 都收 0 —— 整段 32 全部让给译文
    // （译文 28 + 上下各 2 = 32），两类行等高，句间距恒为 32。
    .padding({
      top: this.hasTrans() ? 0 : PARA_GAP_VP / 2,
      bottom: this.hasTrans() ? 0 : PARA_GAP_VP / 2
    })
    // 行级缩放：只改渲染变换、不改布局（行高与滚动定位不受影响）
    .scale({ x: this.visual.scale, y: this.visual.scale })
    // 景深模糊：离当前行越远越糊（官方最关键的层次来源）
    .blur(this.visual.blurPx)
    // 空间渐隐挂在整行上（和声行再压一档），这样只需要改一个数
    .opacity(this.visual.fade * (this.visual.background ? LYRIC_BG_EXTRA_DIM : 1))
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 歌词页主体：背景（模糊运动）、景深、逐字高亮、自动跟随滚动。
 */
@ComponentV2
export struct AppleLyricsView {
  /** 全局播放状态（是否在播、总时长、兜底进度）。 */
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** 歌词数据；undefined 表示还没拉到（或这首歌没有）。 */
  @Param lyric: AppleLyric | undefined = undefined;
  /** 正文字号（fp）。 */
  @Param fontSize: number = 35;
  /** 是否显示译文行。 */
  @Param showTranslation: boolean = true;
  /** 屏幕高度（vp）。 */
  @Param screenHeightVp: number = 837;
  /** 歌词区顶边在屏幕里的 y（vp）。 */
  @Param areaTopVp: number = 0;
  /** 歌词区底边在屏幕里的 y（vp）。 */
  @Param areaBottomVp: number = 0;
  /** 当前曲目的封面（本地沙箱路径）：只有它存在时才画「模糊运动背景」。 */
  @Param coverPath: string = '';
  /**
   * 歌词文字区左右边距（vp）。
   *
   * 背景层要铺满整宽（否则两侧会露出宿主的图），所以边距不挂在宿主容器上，
   * 由这里的 List 自己加；排版行数也按「全宽 − 2×边距」算。
   */
  @Param edgePaddingVp: number = 33;
  /** 歌词页是否在前台 —— false 时心跳与背景动画全部空转。 */
  @Param active: boolean = true;
  /** 点击某行时回调，参数是该行起点（毫秒）。 */
  @Param onSeek: (ms: number) => void = (): void => {};
  /**
   * 「译」按钮的递增请求号（父页面点一次 +1）。
   *
   * 用递增数字而不是布尔值：布尔值第二次点击没有「变化」，@Monitor 不会触发；
   * 数字每点一次都变，天然可以重复触发（失败后还能再点）。
   */
  @Param aiRequest: number = 0;
  /**
   * 译文状态上报：0 = 既没有官方翻译也没有 AI 译��；1 = 有官方翻译；2 = AI 翻译已就绪。
   *
   * 父页面（播放页）拿它决定右上角「译」按钮是亮还是暗。
   */
  @Event onTransInfo: (state: number) => void = (state: number): void => {};

  /** 可用宽度（vp），排版要用；由 onAreaChange 填。 */
  @Local areaWidthVp: number = 0;
  /** 歌词区高度（vp），渐变模糊的分段位置要按它归一化。 */
  @Local areaHeightVp: number = 0;
  /** 排版完成前不渲染列表。 */
  @Local ready: boolean = false;
  /** 高度上报的合并定时器（0 = 没有待处理）。 */
  private metricsTimer: number = 0;
  /** 这一首是否带官方译文（>0 行）。 */
  @Local officialTrans: boolean = false;
  /** AI 翻译是否正在进行（防重复点击）。 */
  @Local aiBusy: boolean = false;
  /** 每行的可观察状态。 */
  @Local visuals: LineVisual[] = [];
  /** 锚点柔光强度：平时 {@link GLOW_IDLE}，换行瞬间冲到 {@link GLOW_PEAK} 再回落。 */
  @Local glow: number = GLOW_IDLE;
  /** 背景层的运动量（scale / 位移 / 光斑纵向位置）——都在 {@link BG_MOTION_MS} 里缓慢走。 */
  @Local bgScale: number = BG_SCALE_MIN;
  @Local bgShiftX: number = 0;
  @Local bgShiftY: number = 0;
  @Local bgLightY: number = 240;
  /** 两团漂移光斑的位置（vp，相对自身左上角）。 */
  // ── 背景色斑 / 呼吸光的颜色：全部由封面主色派生（原来写死蓝 + 橙粉，
  //    两色交错漂移就是用户说的「粉色与蓝色相间的五彩斑斓」）。
  /**
   * 整页底色（封面色）。
   *
   * 不只是"加一层色"：宿主播放页背后也叠着一层同一个官方流光 shader，
   * 而那个 shader 有自己的内置彩色 —— 它会在整屏透出粉/蓝/青的流动。
   * 这层不透明底的色纱把下面那些杂色压住，同时给整页定下「封面色」基调。
   */
  @Local tintBase: string = 'rgba(96,134,255,0.46)';
  @Local blobAColor: string = 'rgba(96,134,255,0.34)';
  @Local blobAMid: string = 'rgba(96,134,255,0.13)';
  @Local blobBColor: string = 'rgba(150,180,255,0.26)';
  @Local blobBMid: string = 'rgba(150,180,255,0.10)';
  @Local glowColor: string = 'rgba(200,215,255,0.15)';
  @Local glowMid: string = 'rgba(200,215,255,0.06)';
  @Local blob1X: number = -120;
  @Local blob1Y: number = 120;
  @Local blob2X: number = 180;
  @Local blob2Y: number = 520;
  /** 官方背景流光的控制器（歌词页不可见时 pause，避免白烧 GPU）。 */
  private flowController: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();
  /**
   * 背景流光的两端配色。
   *
   * 规则：**同一色系的两个明度**，且 target 是 source 的反向 ——
   * 于是在 A→B→A 的循环里首尾天然接上，不会跳；整屏任何位置都是同一色相，
   * 不会出现「蓝色里突然漫出一块褐色」那种杂色。
   *
   * 之前这里写死的是 `['#2B4270', '#8E7A6C']`（深蓝 + 暖褐）两组四种颜色，
   * 两种色相互相漫过，看起来既脏又「跳」。
   */
  @Local flowSource: string[] = FLOW_SOURCE;
  @Local flowTarget: string[] = FLOW_TARGET;
  /** 封面取色的作业序号（换歌时丢弃上一次未完成的结果）。 */
  private flowColorSeq: number = 0;
  /** 流光是否已经挂载（延后一拍创建：shader 首次编译会拖住首帧）。 */
  @Local flowReady: boolean = false;
  /** 流光挂载定时器。 */
  private flowTimer: number = 0;
  /** 每行**内容坐标**里的中心 y（vp，累加高度），用来算空间渐隐。 */
  private lineCenters: number[] = [];
  /** 每行的内容坐标顶部（不含顶部锚点垫片）。窗口化时用来算前置/后置占位。 */
  private lineTops: number[] = [];
  /** 整列内容总高（不含锚点垫片与底部垫片）。 */
  private contentHeightVp: number = 0;
  /**
   * 当前真正挂载的行下标（窗口）。
   *
   * 只改这个数组、不改 scrollY 体系：被省略的行用等高占位撑住，
   * 所以 lineCenters / 滚动目标 / 点击定位全都不受影响。
   */
  @Local visibleIdx: number[] = [];
  /**
   * 结构代数：只在**换了歌词对象**（换歌 / 首次就绪）时 +1。
   *
   * 为什么需要它：`ForEach` 的 key 不变时**不会重建子组件**，子组件会一直持有
   * 第一次传进去的 `LineVisual` 引用。如果这时重建时换了新对象（宽度量出来会
   * 再排一次版），后面所有 `@Trace` 更新（逐字透明度、景深）都写在新对象上，
   * 屏幕上那份旧对象永远不动 —— 表现就是**歌词整屏「不高亮」**（真坑）。
   */
  @Local gen: number = 0;

  /** 列表滚动控制器。 */
  // **不再用 List / ListScroller**：整列内容放进一个 Column，靠 translateY 位移来「滚动」。
  // 位置完全由下面的 scrollY 决定 —— 不问 scroller 要 currentOffset（它的读回值会滞后，
  // 是之前「追随失准 / 忽快忽慢」的根源之一），也不受列表的边界、回弹、内容不足影响。
  // 一次换行只下一次固定时长的动画，结构上不可能出现「找补」。
  @Local scrollY: number = 0;
  /**
   * 当前生效的全屏渐变模糊半径。
   *
   * `linearGradientBlur` 是**全屏后处理**：内容每移动一帧它就得重算一遍，
   * 是滚动掉帧的第二大来源。滚动时先降到 0、动画结束 260ms 再恢复 ——
   * 滚动中画面本来就在动，几乎察觉不到；静止时模糊仍然完整。
   */
  @Local edgeBlurPx: number = EDGE_BLUR_PX;
  private edgeBlurRestoreTimer: number = -1;
  /** 目标滚动位置（vp）：换行时用它**预算**一次渐隐，滚动途中不再重算。 */
  private scrollTargetY: number = -1;
  /** 毫秒级、不漂移的播放头（见 LyricPlayhead 注释）。 */
  private playhead: LyricPlayhead = new LyricPlayhead();
  /** 指挥器定时器 id。 */
  private conductorId: number = 0;
  /** 填充驱动定时器（33ms）。 */
  private fillId: number = 0;
  /** 背景运动定时器。 */
  private bgTimer: number = 0;
  /** 背景运动方向（0/1 交替）。 */
  private bgFlip: number = 0;
  /** 当前行下标（-1 表示还没到第一行）。 */
  private activeIdx: number = -1;
  /**
   * **滚动锚点**（屏幕正中该是哪一行）。
   *
   * 这是本轮解决「乱跳」的核心：以前「换行判定（activeIdx）」和「滚动目标」是两个
   * 独立的触发点，换行瞬间景深已经按新行重算、而列表还在滚 → 看起来就是来回抽。
   * 现在统一由这个下标驱动滚动，景深也**以它**为基准（不再用 activeIdx），
   * 于是「哪一行在锚点」与「哪一行最大/最清楚」永远是同一行。
   */
  private scrollAnchorIdx: number = -1;
  /** 上一次处理到的词下标（避免同一段重复启动动画）。 */
  private lastWordIdx: number = -1;
  /** 组件是否已挂载。 */
  private mounted: boolean = false;
  /** 最近一次**手指**触摸列表的时刻（程序化滚动不更新它）。 */
  private lastTouchAt: number = 0;
  /** 手指正按在歌词区上（拖动浏览中）。 */
  private dragging: boolean = false;
  private dragLastY: number = 0;
  /** 拖动过程中累计的位移：每走 20vp 重算一次景深（fade），否则拖上来的行还是旧透明度。 */
  private browseDepthAcc: number = 0;
  /**
   * 拖动浏览期间是否「整列全量挂载」。
   *
   * 窗口化有个副作用：拖动时窗口按缓冲步进重建，新进来的行要等下一帧才绘制出来，
   * 观感是「拖着突然冒出一段」。用户要的是连续 —— 所以手指一落下就把整列挂满，
   * 拖动全程不再增删节点（一次重建发生在按下那一帧，几乎察觉不到）；
   * 回位到播放位置时再缩回窗口，保住静止播放时的 120fps。
   */
  private browseFull: boolean = false;
  /** 松手后 5 秒的「回位等待」计时器；>=0 表示还在等。 */
  private browseTimer: number = -1;
  /** 拖动过、正在等自动回位（这段时间 tick 不抢滚动）。 */
  private browseHold: boolean = false;
  /** tick 里发现这个标记就强制跑一次回弹回位（哪怕暂停中）。 */
  private pendingReturn: boolean = false;
  /** 点击 seek 后的保护期：这期间播放头的旧采样不得覆盖目标行。 */
  private seekGuardIdx: number = -1;
  private seekGuardUntil: number = 0;
  /** 最近一次**用户手动滚动**的时刻：超过 FOLLOW_RESUME_MS 没再动就自动回位。 */
  private userScrollAt: number = 0;
  /** 上一次心跳是否处在「用户正在浏览」：用来在恢复跟随的那一刻强制回位一次。 */
  private wasBrowsing: boolean = false;
  /** 最近一次发起滚动动画的时刻（弹簧动画期间不叠新滚动）。 */
  private lastScrollAt: number = 0;
  /** 上一次真正下发出去的滚动偏移（vp）：只用于判重与排查，不参与定位计算。 */
  private lastScrollY: number = -1;
  /**
   * 程序化滚动的「静默窗口」截止时间（ms）。
   *
   * 自动滚动同样会触发 onScrollStart / onScrollStop —— 以前靠
   * 「距 lastScrollAt < 500ms 就当我方滚动」来区分，但**回位动画是 520ms**，
   * 结束时早就超过 500ms，于是被当成"用户滚动" → 自动跟随白冻 4 秒。
   * 歌越到后面句子越密、滚动越频繁，这个误判也越容易命中——
   * 表现就是「越往后越不灵」。现在由我们自己记一个窗口，窗口内一律不算用户滚动。
   */
  private programmaticUntil: number = 0;
  /** 首次定位的延时器（要等列表布局出来）。 */
  private firstScrollTimer: number = 0;
  /** 上一次心跳看到的进度：跳变（seek/换歌）时整列重算。 */
  private lastPos: number = -1;

  /** 挂载后启动指挥器；歌词已就位时先排一版（@Monitor 不会为初始值触发）。 */
  aboutToAppear(): void {
    this.mounted = true;
    if (this.lyric !== undefined && this.lyric.lines.length > 0) {
      this.rebuildStructure();
    }
    // 进页面时先按「自己手上的封面」取一次色（@Monitor 只在变化时触发）；
    // 封面还没到 / 取不到时退回全局主色，再不行才是兜底蓝。
    void this.pickFlowColorFromCover();
    this.startConductor();
    this.startBackgroundMotion();
    // 流光延后 160ms 再挂：着色器第一次编译要几十毫秒，别抢歌词页首帧。
    this.flowTimer = setTimeout(() => {
      this.flowTimer = 0;
      if (!this.mounted) {
        return;
      }
      this.flowReady = true;
      if (!this.active) {
        this.flowPause();
      }
    }, 160);
  }

  /** 暂停/恢复背景流光（不可见时零开销）。 */
  private flowPause(): void {
    try {
      this.flowController.pause();
    } catch (err) {
      const e: Error = err as Error;
      Logger.info(TAG, `flow pause skipped: ${e.message}`);
    }
  }

  private flowResume(): void {
    if (!this.flowReady) {
      return;
    }
    try {
      this.flowController.resume();
    } catch (err) {
      const e: Error = err as Error;
      Logger.info(TAG, `flow resume skipped: ${e.message}`);
    }
  }

  /** 卸载时把定时器收干净。 */
  aboutToDisappear(): void {
    this.mounted = false;
    this.stopConductor();
    this.flowPause();
    if (this.bgTimer !== 0) {
      clearInterval(this.bgTimer);
      this.bgTimer = 0;
    }
    if (this.flowTimer !== 0) {
      clearTimeout(this.flowTimer);
      this.flowTimer = 0;
    }
    if (this.firstScrollTimer !== 0) {
      clearTimeout(this.firstScrollTimer);
      this.firstScrollTimer = 0;
    }
  }

  /** 播放进度变化：喂一次兜底锚点（主源是播放头，这里只是保险）。 */
  /** 换歌 → 重新从封面主色派生流光配色。 */
  @Monitor('state.flowColor')
  onFlowColorChange(): void {
    this.rebuildFlowColors();
  }

  /**
   * 把封面主色展开成「暗端 / 亮端」两个同色系颜色。
   *
   * @param k 正 = 向白混合（提亮），负 = 向黑混合（压暗）
   */
  private shadeHex(hex: string, k: number): string {
    let h: string = hex.trim();
    if (h.startsWith('#')) {
      h = h.substring(1);
    }
    if (h.length === 8) {
      h = h.substring(0, 6);
    }
    if (h.length !== 6) {
      return hex;
    }
    const toHex2 = (v: number): string => {
      const c: string = Math.max(0, Math.min(255, Math.round(v))).toString(16);
      return c.length === 1 ? `0${c}` : c;
    };
    const mix = (s2: string): number => {
      const v: number = parseInt(s2, 16);
      const target: number = k >= 0 ? 255 : 0;
      return v + (target - v) * Math.abs(k);
    };
    return `#${toHex2(mix(h.substring(0, 2)))}${toHex2(mix(h.substring(2, 4)))}` +
      `${toHex2(mix(h.substring(4, 6)))}`;
  }

  private rebuildFlowColors(): void {
    const base: string = this.state.flowColor;
    if (base.length === 0) {
      return;
    }
    const dark: string = this.shadeHex(base, -0.50);
    const light: string = this.shadeHex(base, 0.35);
    // 两端互为反向 → 循环首尾相接
    this.flowSource = [dark, light];
    this.flowTarget = [light, dark];
  }

  @Monitor('state.progress')
  onProgressChanged(): void {
    this.playhead.anchor(this.state.progress);
  }

  /** 歌词数据换了：重建结构（对象全部换新，代数 +1 强制 List 重建子项）。 */
  @Monitor('lyric')
  onLyricChanged(): void {
    this.playhead.reset();
    this.rebuildStructure();
  }

  /** 宽度 / 字号 / 译文开关 / 边距变了：只重算行高与景深，**不换对象**。 */
  /**
   * 用户点了「译」按钮，但这一首没有官方翻译 —— 走 AI 翻译。
   *
   * 只在 `aiRequest` 变化时触发；官方译文存在时直接忽略（用官方那份，更权威）。
   */
  @Monitor('aiRequest')
  private onAiRequest(): void {
    this.runAiTranslate();
  }

  private runAiTranslate(): void {
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined || lyric.lines.length === 0) {
      return;
    }
    if (this.aiBusy) {
      return;
    }
    if (this.officialTrans) {
      return;
    }
    // 正文本来就是中文 → 再翻成中文毫无意义（还白花钱）。中文歌的按钮就保持暗着。
    if (lyric.language.length >= 2 && lyric.language.substring(0, 2).toLowerCase() === 'zh') {
      return;
    }
    const cached: string[] | undefined = AiLyricsTranslator.cached(lyric.songId);
    if (cached !== undefined) {
      this.applyAiLines(cached);
      return;
    }
    const lines: string[] = [];
    for (let i = 0; i < lyric.lines.length; i++) {
      lines.push(lyric.lines[i].text);
    }
    this.aiBusy = true;
    AiLyricsTranslator.translate(lyric.songId, lines).then((out: string[]) => {
      this.aiBusy = false;
      if (out.length === 0) {
        this.onTransInfo(0);
        return;
      }
      this.applyAiLines(out);
    }).catch(() => {
      this.aiBusy = false;
      this.onTransInfo(0);
    });
  }

  /** 把 AI 译文写进各行（@Trace 字段，写完立即上屏）。 */
  private applyAiLines(out: string[]): void {
    let written: number = 0;
    for (let i = 0; i < this.visuals.length && i < out.length; i++) {
      const t: string = out[i];
      if (t.length > 0 && this.visuals[i].translation.length === 0) {
        this.visuals[i].translation = t;
        written++;
      }
    }
    if (written > 0) {
      this.onTransInfo(2);
      // 行高要跟着重算（有译文行会多出译文那一行的空间）
      this.relayout();
    } else {
      this.onTransInfo(0);
    }
  }

  @Monitor('areaWidthVp', 'showTranslation', 'fontSize', 'edgePaddingVp')
  onLayoutChanged(): void {
    this.relayout();
  }

  /** 封面换了：背景图跟着换（不需要重建歌词）。 */
  @Monitor('coverPath')
  onCoverChanged(): void {
    this.bgScale = BG_SCALE_MIN;
    this.bgShiftX = 0;
    this.bgShiftY = 0;
    // 换歌 → 重新按新封面取色（流光配色跟着封面走）
    void this.pickFlowColorFromCover();
  }

  /**
   * 从**当前封面**取主色，作为背景流光的配色来源。
   *
   * 为什么不读播放页写进全局的那个颜色：播放页的取色只在它自己被创建 / 换歌时跑，
   * 而歌词页往往先出现（从播放条直接拉开歌词），那时候全局色还是默认值 ——
   * 流光就退化成兜底的蓝色，看起来「和封面一点关系都没有」。
   * 这里以歌词页自己手上的 {@link coverPath} 为唯一依据；
   * AppleArtworkCache 命中时会同步返回已落盘的路径，几乎零成本。
   */
  private async pickFlowColorFromCover(): Promise<void> {
    const cover: string = this.coverPath;
    if (cover.length === 0) {
      return;
    }
    const seq: number = ++this.flowColorSeq;
    let src: image.ImageSource | undefined = undefined;
    let pm: image.PixelMap | undefined = undefined;
    try {
      const path: string = await AppleArtworkCache.ensure(cover);
      Logger.info(TAG, `流光辉色 ensure ok=${path.length > 0} seq=${seq}`);
      if (path === '' || !this.mounted || seq !== this.flowColorSeq) {
        return;
      }
      // **必须自己读成 ArrayBuffer 再解码**：`createImageSource(纯沙箱路径)` 会返回
      // undefined（本项目早前定过规矩：Image 认沙箱 URI、createImageSource 不认，
      // 统一走 fd / buffer 通道）。播放页取色走的也是 buffer 路线，这里与它对齐 ——
      // 之前"流光始终是兜底色"就卡在这一步。
      const st: fileIo.Stat = fileIo.statSync(path);
      const f: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const coverBuf: ArrayBuffer = new ArrayBuffer(st.size);
      try {
        fileIo.readSync(f.fd, coverBuf);
      } finally {
        fileIo.closeSync(f);
      }
      Logger.info(TAG, `流光辉色 读到封面 ${st.size}B`);
      src = image.createImageSource(coverBuf);
      if (src === undefined) {
        Logger.warn(TAG, '流光辉色 createImageSource 返回空');
        return;
      }
      pm = await src.createPixelMap({
        desiredSize: { width: 32, height: 32 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (err) {
      Logger.warn(TAG, '流光辉色解码失败: ' + ((err as Error).message ?? ''));
      return;
    } finally {
      if (src !== undefined) {
        try {
          src.release();
        } catch (e) {
          // ignore
        }
      }
    }
    if (pm === undefined || seq !== this.flowColorSeq) {
      Logger.warn(TAG, `流光辉色 解码未完成 pm=${pm !== undefined}`);
      return;
    }
    // **自己读像素算主色**，不再走 effectKit：
    // 它的回调一旦不触发就只能吃兜底色，而「流光跟封面没关系」正是这么来的。
    // 32×32 一共 1024 个像素，遍历一次 < 1ms，换歌时才跑。
    try {
      // 尺寸**问实际解码结果**，不写死 32×32：desiredSize 是建议值，
      // 拿到比预期小的图会让缓冲区不够、读出半张或直接抛错。
      const info: image.ImageInfo = await pm.getImageInfo();
      const need: number = info.size.width * info.size.height * 4;
      const buf: ArrayBuffer = new ArrayBuffer(need > 0 ? need : 32 * 32 * 4);
      await pm.readPixelsToBuffer(buf);
      const data: Uint8Array = new Uint8Array(buf);
      const rgb: number[] = AppleLyricsView.dominantColor(data);
      if (seq === this.flowColorSeq) {
        this.applyFlowBase(rgb[0], rgb[1], rgb[2]);
      }
    } catch (err) {
      Logger.warn(TAG, '流光辉色读像素失败: ' + ((err as Error).message ?? ''));
    } finally {
      try {
        pm.release();
      } catch (e) {
        // ignore
      }
    }
  }

  /**
   * 从 RGBA 像素里挑出**最像封面主色调**的颜色。
   *
   * 不取简单平均值 —— 一张深色封面平均下来几乎恒为黑灰，流光就「没有颜色」。
   * 做法：跳过过暗/过亮/低饱和的像素，按 30° 色相分 12 桶，用「饱和度 × 亮度」加权投票，
   * 取票数最高的那一桶的加权平均。这样拿到的是封面上**面积大且鲜艳**的那一族颜色。
   * 全灰封面（没有任何像素通过筛选）才退回整体平均色。
   */
  private static dominantColor(data: Uint8Array): number[] {
    const bins: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const accR: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const accG: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    const accB: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    let allR: number = 0;
    let allG: number = 0;
    let allB: number = 0;
    let count: number = 0;
    for (let i = 0; i + 3 < data.length; i += 4) {
      const r: number = data[i];
      const g: number = data[i + 1];
      const b: number = data[i + 2];
      const a: number = data[i + 3];
      if (a < 128) {
        continue;
      }
      allR += r;
      allG += g;
      allB += b;
      count++;
      const mx: number = Math.max(r, Math.max(g, b));
      const mn: number = Math.min(r, Math.min(g, b));
      if (mx < 36 || mn > 224) {
        continue;
      }
      const sat: number = mx === 0 ? 0 : (mx - mn) / mx;
      if (sat < 0.08) {
        continue;
      }
      const d: number = mx - mn;
      let hue: number = 0;
      if (mx === r) {
        hue = ((g - b) / d) % 6;
      } else if (mx === g) {
        hue = (b - r) / d + 2;
      } else {
        hue = (r - g) / d + 4;
      }
      hue = hue * 60;
      if (hue < 0) {
        hue += 360;
      }
      let bin: number = Math.floor(hue / 30);
      if (bin < 0) {
        bin = 0;
      }
      if (bin > 11) {
        bin = 11;
      }
      const wgt: number = sat * (mx / 255);
      bins[bin] += wgt;
      accR[bin] += r * wgt;
      accG[bin] += g * wgt;
      accB[bin] += b * wgt;
    }
    if (count === 0) {
      return [56, 76, 120];
    }
    let best: number = -1;
    let bestW: number = 0;
    for (let k = 0; k < 12; k++) {
      if (bins[k] > bestW) {
        bestW = bins[k];
        best = k;
      }
    }
    if (best >= 0 && bestW > 0.4) {
      return [
        Math.round(accR[best] / bestW),
        Math.round(accG[best] / bestW),
        Math.round(accB[best] / bestW)
      ];
    }
    return [Math.round(allR / count), Math.round(allG / count), Math.round(allB / count)];
  }

  private applyFlowBase(r: number, g: number, b: number): void {
    let rr: number = r;
    let gg: number = g;
    let bb: number = b;
    // 暗封面 / 灰封面：先抬到能看出色相的最低亮度，否则流光几乎不可见
    const max: number = Math.max(rr, Math.max(gg, bb));
    if (max < 64) {
      const k: number = 64 / Math.max(1, max);
      rr = rr * k;
      gg = gg * k;
      bb = bb * k;
    }
    // **保证最低饱和度**：很多封面整体偏低饱和（实测某首主色 #6A8581，
    // 派生出来是灰绿，看着跟"默认样式"没区别 —— 用户就是这么反馈的）。
    // 这里保持色相、把三通道围绕均值拉开，使 sat=(max-min)/max 至少到 0.30。
    const mx0: number = Math.max(rr, Math.max(gg, bb));
    const mn0: number = Math.min(rr, Math.min(gg, bb));
    const avg0: number = (rr + gg + bb) / 3;
    if (mx0 > 1 && (mx0 - mn0) / mx0 < 0.30) {
      const k: number = (0.30 * mx0) / Math.max(1, mx0 - mn0);
      rr = avg0 + (rr - avg0) * k;
      gg = avg0 + (gg - avg0) * k;
      bb = avg0 + (bb - avg0) * k;
    }
    // 再加一点存在感：三通道向均值外扩 1.35，避免「灰扑扑一片」
    const avg: number = (rr + gg + bb) / 3;
    const sat: number = 1.35;
    rr = avg + (rr - avg) * sat;
    gg = avg + (gg - avg) * sat;
    bb = avg + (bb - avg) * sat;
    const toHex2 = (v: number): string => {
      const c: string = Math.max(0, Math.min(255, Math.round(v))).toString(16);
      return c.length === 1 ? `0${c}` : c;
    };
    const ri: number = Math.max(0, Math.min(255, Math.round(rr)));
    const gi: number = Math.max(0, Math.min(255, Math.round(gg)));
    const bi: number = Math.max(0, Math.min(255, Math.round(bb)));
    // 亮端（给第二团光斑与呼吸光用）：向白混 32% 且保持色相
    const li: number[] = [
      Math.min(255, Math.round(ri + (255 - ri) * 0.32)),
      Math.min(255, Math.round(gi + (255 - gi) * 0.32)),
      Math.min(255, Math.round(bi + (255 - bi) * 0.32))
    ];
    this.tintBase = `rgba(${ri},${gi},${bi},0.46)`;
    this.blobAColor = `rgba(${ri},${gi},${bi},0.36)`;
    this.blobAMid = `rgba(${ri},${gi},${bi},0.14)`;
    this.blobBColor = `rgba(${li[0]},${li[1]},${li[2]},0.28)`;
    this.blobBMid = `rgba(${li[0]},${li[1]},${li[2]},0.11)`;
    this.glowColor = `rgba(${li[0]},${li[1]},${li[2]},0.16)`;
    this.glowMid = `rgba(${li[0]},${li[1]},${li[2]},0.06)`;
    const base: string = `#${toHex2(rr)}${toHex2(gg)}${toHex2(bb)}`;
    const dark: string = this.shadeHex(base, -0.55);
    const light: string = this.shadeHex(base, 0.30);
    this.flowSource = [dark, light];
    this.flowTarget = [light, dark];
    // 写回全局：外壳那层「整 App 背景流光」也吃这个颜色，
    // 否则它仍用写死的蓝灰，两层叠起来就"看不出跟封面有关系"。
    this.state.flowColor = base;
    Logger.info(TAG, `流光辉色 base=${base} dark=${dark} light=${light}`);
  }

  /**
   * 歌词页从后台回到前台：清掉播放头采样并强制重算一次。
   *
   * 必须做 —— 隐藏期间心跳是停的，回来时 activeIdx/逐字状态可能已经过期。
   */
  @Monitor('active')
  onActiveChanged(): void {
    if (!this.active) {
      this.flowPause();
      return;
    }
    this.flowResume();
    this.lastPos = -1;
    this.lastWordIdx = -1;
    if (this.ready) {
      this.tick(true);
    }
    // 回到前台时把背景动画重新拉起来（长时间不可见后动画可能已经被系统停掉）
    this.startBackgroundMotion();
  }

  /** 背景的「模糊运动」：缓慢缩放 + 漂移 + 光斑上下浮，一周期一次 animateTo。 */
  private startBackgroundMotion(): void {
    if (this.bgTimer !== 0) {
      clearInterval(this.bgTimer);
      this.bgTimer = 0;
    }
    this.bgTimer = setInterval(() => {
      if (!this.mounted || !this.active || this.coverPath.length === 0) {
        return;
      }
      this.bgFlip = this.bgFlip === 0 ? 1 : 0;
      const dir: number = this.bgFlip === 0 ? -1 : 1;
      const h: number = this.areaHeightVp > 0 ? this.areaHeightVp : 620;
      this.getUIContext().animateTo({ duration: BG_MOTION_MS, curve: Curve.EaseInOut }, () => {
        this.bgScale = this.bgFlip === 0 ? BG_SCALE_MIN : BG_SCALE_MAX;
        this.bgShiftX = dir * BG_SHIFT_VP;
        this.bgShiftY = -dir * BG_SHIFT_VP * 0.6;
        // 光斑在锚点上下缓慢游走：这就是官方背景里那团「会呼吸的暖光」
        this.bgLightY = this.activeCenterY() + dir * h * 0.16;
        // 两团色斑交错漂移 —— 「背景在流动」主要靠它们（肉眼一定看得见）
        this.blob1X = dir > 0 ? 60 : -150;
        this.blob1Y = dir > 0 ? 60 : 300;
        this.blob2X = dir > 0 ? -80 : 200;
        this.blob2Y = dir > 0 ? 620 : 360;
      });
    }, BG_MOTION_MS);
  }

  /**
   * 重建结构：给每行建 token 状态、估行高，算出景深。
   *
   * **只有在歌词对象变化时调用**（换歌 / 首次就绪）。
   */
  private rebuildStructure(): void {
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined || lyric.lines.length === 0) {
      this.ready = false;
      this.visuals = [];
      this.lineCenters = [];
      this.lineTops = [];
      this.contentHeightVp = 0;
      this.visibleIdx = [];
      return;
    }
    const visuals: LineVisual[] = [];
    // AI 译文缓存（换歌再切回来时直接复用，不重复花钱）
    const aiCached: string[] | undefined = AiLyricsTranslator.cached(lyric.songId);
    for (let i = 0; i < lyric.lines.length; i++) {
      const vis: LineVisual = new LineVisual();
      vis.translation = lyric.lines[i].translation;
      if (vis.translation.length === 0 && aiCached !== undefined && i < aiCached.length) {
        vis.translation = aiCached[i];
      }
      AppleLyricsView.buildTokens(lyric.lines[i], vis);
      // 行内绝对坐标（xVp / rowIdx）**不在这里算**：
      // 此刻 token 的 widthVp 还是 0（宽度要等 measureLineRows 才量出来），
      // 用兜底值估算会让每个字的「行内左偏移」全部错位 —— 表现为
      // 「边界以每个字自己的左边为参照，一个字从左亮到右、下一个字又从左亮」。
      // 统一由 measureLineRows / ensureTokenWidths 在拿到实测宽度后填。
      visuals.push(vis);
    }
    this.visuals = visuals;
    this.activeIdx = -1;
    this.scrollAnchorIdx = -1;
    this.lastWordIdx = -1;
    this.lastPos = -1;
    this.ready = true;
    this.gen++;
    // 统计官方译文：有译文行就说明「官方翻译可用」，按钮该亮着
    let withTrans: number = 0;
    for (let i = 0; i < visuals.length; i++) {
      if (visuals[i].translation.length > 0) {
        withTrans++;
      }
    }
    this.officialTrans = withTrans > 0;
    // 延后一拍回调：rebuildStructure 是渲染过程中调用的，
    // 在这里直接改父页面状态会触发「渲染中修改状态」的告警。
    const st: number = withTrans > 0 ? 1 : 0;
    setTimeout(() => {
      this.onTransInfo(st);
    }, 0);
    this.relayout();
    // 列表刚建出来，立刻 scrollToIndex 会落空，等一帧
    if (this.firstScrollTimer !== 0) {
      clearTimeout(this.firstScrollTimer);
    }
    this.firstScrollTimer = setTimeout(() => {
      this.firstScrollTimer = 0;
      if (this.mounted) {
        this.lastPos = -1;
        this.tick(true);
      }
    }, 48);
  }

  /**
   * 只重算「排版相关」的数值：行高、累计中心、景深。
   *
   * 不动 `visuals` 里的对象，也不动 tokens —— 折行结果只影响行高，词结构只跟
   * 歌词文本有关，与宽度无关。
   */
  private relayout(): void {
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined || lyric.lines.length === 0) {
      return;
    }
    if (!this.ready || this.visuals.length !== lyric.lines.length) {
      this.rebuildStructure();
      return;
    }
    // 宽度还没测出来时先按 320vp 排一版，避免一直卡在转圈
    const widthVp: number = this.contentWidthVp();
    const ui = this.getUIContext();
    const pxToVp: number = ui.px2vp(1);
    const measure: MeasureUtils = ui.getMeasureUtils();
    const centers: number[] = [];
    const tops: number[] = [];
    let acc: number = 0;
    for (let i = 0; i < lyric.lines.length; i++) {
      const line: LyricLine = lyric.lines[i];
      const vis: LineVisual = this.visuals[i];
      // 行高按「逐段固定宽度」模拟 Flex 换行来算 —— 与三层渲染严格同构。
      // 顺带把全部行的段宽在这里一次量好（原来只有活跃行才量、且行高用整行
      // measureText 估，两种量法在临界行上会差一行，那正是「行数会变」的来源）。
      vis.rowCount = this.measureLineRows(vis, widthVp, measure, pxToVp);
      // 行高 = 视觉行数 × 行高 + 段落间距 (+ 译文)
      // 行块高度与渲染严格同一套分账：
      //   无译文 = 正文 + PARA_GAP
      //   有译文 = 正文 + 译文高 + 上下各 TRANS_PAD（padding 为 0）
      // 有译文行 = 正文 + 译文（含上下呼吸）；无译文行 = 正文 + 段落间距。
      // （渲染侧 padding：有译文上下收 0、无译文各留 PARA_GAP/2，与此严格对应。）
      const lineHasTrans: boolean = this.showTranslation && vis.translation.length > 0;
      const h: number = vis.rowCount * LINE_HEIGHT_VP +
        (lineHasTrans ? TRANS_LINE_VP + TRANS_PAD_VP * 2 : PARA_GAP_VP);
      vis.heightVp = h;
      // **首行中心**（不是行块中心）：实测多行句子里，Apple 是把「该句第一行」
      // 固定在 25.5% 处，后面的行往下长。以前用行块中心，两行句会把整块居中，
      // 首行就偏上半个行高，越到多行句子越明显。
      centers.push(acc + GLYPH_BOX_VP / 2);
      tops.push(acc);
      acc += h;
    }
    this.lineCenters = centers;
    this.lineTops = tops;
    this.contentHeightVp = acc;
    this.updateWindow(this.scrollAnchorIdx >= 0 ? this.scrollAnchorIdx : 0, true);
    this.playhead.anchor(this.state.progress);
    // 重建后立刻把景深算一遍：不这样做的话，切过来那一瞬间整列 fade 还是旧值，
    // 用户看到的就是「歌词有时整屏不显示」。
    this.applyDepth(false);
  }

  /**
   * 把一行歌词切成逐字 token。
   *
   * 纯空白的片段并进前一个 token（Flex 里单独的空格 Text 宽度不可靠），
   * 并把它的词区间一起并过去 —— 这样「token 下标 ≠ 词下标」也不会错位。
   */
  private static buildTokens(line: LyricLine, vis: LineVisual): void {
    if (line.words.length === 0) {
      const tk: TokenVisual = new TokenVisual(line.text, LYRIC_DIM_ALPHA);
      vis.tokens.push(tk);
      const ls: number = line.startMs;
      const le: number = line.endMs > ls ? line.endMs : ls + 1;
      vis.tokenStart.push(ls);
      vis.tokenEnd.push(le);
      return;
    }
    let bgChars: number = 0;
    let allChars: number = 0;
    for (let w = 0; w < line.words.length; w++) {
      const piece: string = line.words[w].text;
      allChars += piece.length;
      if (line.words[w].isBackground) {
        bgChars += piece.length;
      }
      if (piece.trim().length === 0 && vis.tokens.length > 0) {
        const lastIdx: number = vis.tokens.length - 1;
        const last: TokenVisual = vis.tokens[lastIdx];
        last.text = last.text + piece;
        // 空白并进前一段时，**时间窗也要一起延长**（否则这一段的时长会被空白词压成 1ms）
        const wEnd: number = line.words[w].endMs > line.words[w].startMs
          ? line.words[w].endMs : line.words[w].startMs;
        if (wEnd > vis.tokenEnd[lastIdx]) {
          vis.tokenEnd[lastIdx] = wEnd;
        }
        continue;
      }
      // 把一个词切成若干「字形段」：汉字一字一段（这就是 Apple 的 GlyphLayer），
      // 拉丁整词一段（字母级闪烁反而难读；Apple 在词内部走渐变、不拆字母）。
      const grains: string[] = AppleLyricsView.splitGrains(piece);
      const total: number = grains.length;
      const ws0: number = line.words[w].startMs;
      const we0: number = line.words[w].endMs > ws0 ? line.words[w].endMs : ws0 + 1;
      const wdur: number = we0 - ws0;
      for (let g = 0; g < total; g++) {
        const tk: TokenVisual = new TokenVisual(grains[g], LYRIC_DIM_ALPHA);
        tk.firstWord = w;
        tk.lastWord = w;
        tk.fracStart = total > 0 ? g / total : 0;
        tk.fracEnd = total > 0 ? (g + 1) / total : 1;
        vis.tokens.push(tk);
        // 绝对时间窗：词内按字数均摊（这就是 Apple 的 GlyphLayer 时间粒度）
        vis.tokenStart.push(ws0 + (wdur * g) / Math.max(1, total));
        vis.tokenEnd.push(ws0 + (wdur * (g + 1)) / Math.max(1, total));
      }
    }
    vis.background = allChars > 0 && bgChars * 2 > allChars;
  }

  /**
   * 把一个词切成若干「字形段」。
   *
   * 汉字（含全角标点、假名、谚文）**一字一段** —— 这就是 Apple 的 GlyphLayer 粒度；
   * 拉丁字母/数字整词一段（拆成字母会闪烁、也更耗节点）。
   */
  private static splitGrains(word: string): string[] {
    const out: string[] = [];
    let latin: string = '';
    const flushLatin = (): void => {
      if (latin.length > 0) {
        out.push(latin);
        latin = '';
      }
    };
    for (let i = 0; i < word.length; i++) {
      const c: string = word.charAt(i);
      const code: number = word.charCodeAt(i);
      const isWide: boolean = code >= 0x2E80;   // CJK 部首扩展起：汉字/假名/谚文/全角符号
      if (isWide) {
        flushLatin();
        out.push(c);
      } else if (c === ' ' || c === '\t' || c === '\u00a0') {
        // 空白并进前一段，避免 Flex 在段间多点一个折行机会
        if (out.length > 0) {
          out[out.length - 1] = out[out.length - 1] + c;
        } else {
          latin += c;
        }
      } else {
        latin += c;
      }
    }
    flushLatin();
    return out.length > 0 ? out : [word];
  }

  /**
   * 某一行的实际高度（vp）：优先实测，没渲染过就用估算兜底。
   *
   * 滚动定位必须用它累加 —— 这是「高亮行越到后面越偏上」的根治点。
   */
  private rowHeightAt(i: number): number {
    const v: LineVisual = this.visuals[i];
    if (v.measuredH > 0) {
      return v.measuredH;
    }
    return v.heightVp > 0 ? v.heightVp : LINE_HEIGHT_VP + PARA_GAP_VP;
  }

  /** 合并同一帧内的多次高度上报，避免一屏十几行各自触发一次全量重算。 */
  private scheduleMetrics(): void {
    if (this.metricsTimer !== 0) {
      return;
    }
    this.metricsTimer = setTimeout(() => {
      this.metricsTimer = 0;
      this.recomputeMetrics();
    }, 0);
  }

  /**
   * 用实测高度重算「每行顶部 / 中心 / 内容总高」，并把当前锚点行重新对齐。
   *
   * 不做这一步的表现是：播放越久，高亮行越往屏幕上方漂（行高估算与实际
   * 每差一点，几十行就累积成一行的高度）。
   */
  private recomputeMetrics(): void {
    if (!this.ready || this.visuals.length === 0) {
      return;
    }
    const centers: number[] = [];
    const tops: number[] = [];
    let acc: number = 0;
    for (let i = 0; i < this.visuals.length; i++) {
      // 首行中心（Apple 把「该句第一行」钉在锚点位置，不是行块中心）
      centers.push(acc + LINE_HEIGHT_VP / 2);
      tops.push(acc);
      acc += this.rowHeightAt(i);
    }
    this.lineCenters = centers;
    this.lineTops = tops;
    this.contentHeightVp = acc;
    // 高度变了，原来的 scrollY 已不对应同一行 → 重新对齐到锚点行
    const idx: number = this.scrollAnchorIdx >= 0 ? this.scrollAnchorIdx : this.activeIdx;
    // 只在「跟随播放」时重新对齐；用户正在拖动浏览就别抢滚动
    if (idx >= 0 && idx < centers.length && !this.dragging && Date.now() - this.userScrollAt > 4000) {
      const y: number = centers[idx];
      if (Math.abs(y - this.scrollY) > 0.5) {
        this.scrollY = y;
        this.applyDepthAt(y, y, false);
      }
    }
  }

  /** 活跃行中心的屏幕 y（vp）：歌词区高度 × {@link ACTIVE_IN_AREA}。 */
  private activeCenterY(): number {
    const top: number = this.areaTopVp;
    const bottom: number = this.areaBottom();
    const span: number = bottom - top;
    if (span <= 40) {
      return this.screenHeightVp * 0.5;
    }
    return top + span * ACTIVE_IN_AREA;
  }

  /** 歌词区底边（屏幕坐标 vp）。 */
  private areaBottom(): number {
    return this.areaBottomVp > 0 ? this.areaBottomVp : this.screenHeightVp;
  }

  /** 文字区可用宽度（vp）= 全宽 − 2×边距（背景铺满全宽，文字收边）。 */
  private contentWidthVp(): number {
    if (this.areaWidthVp <= 0) {
      return 320;
    }
    const w: number = this.areaWidthVp - this.edgePaddingVp * 2;
    return w > 80 ? w : 80;
  }

  /**
   * 锚点在**组件坐标系**里的 y（vp）：活跃行中心要钉在这里。
   *
   * 组件的 y=0 就是宿主的 `areaTopVp`，所以锚点 = activeCenterY - areaTopVp。
   */
  private anchorLocalVp(): number {
    // 组件现在铺满整屏（宿主 y=0），所以**组件坐标 = 屏幕坐标**，不用再减 areaTopVp。
    // 顶部垫片高度 = 这个值：列表内容从锚点开始往下排，上方那块空白正好让给头部。
    const v: number = this.activeCenterY();
    return v > 0 ? v : 0;
  }

  /**
   * 列表底部垫片高度：让**最后几行**也能滚到锚点位置。
   *
   * 没有这块垫片时，列表的最大滚动量被内容高度卡住，倒数第二行之后根本到不了锚点。
   */
  private footerHeightVp(): number {
    const h: number = this.areaHeightVp > 0 ? this.areaHeightVp : 620;
    const pad: number = h - this.anchorLocalVp();
    // 加 12vp 余量：抵消像素取整（density 3.25 下 0.1vp 级误差会累积到边界上）。
    // 注：曾怀疑「末尾几十行滚不到锚点是因为垫片不够」，用真实参数做过数值验证——
    // 原式 `h − anchor` 的行程是够的（最大滚动量 = Σ行高，最后一行中心 = Σ行高 − h_last/2，
    // 恒小于它），所以**不是**这个原因。这里只留余量，定位问题不背这个锅。
    return pad > 0 ? pad + 12 : 0;
  }

  /** 把 v 夹到 [lo, hi]。 */
  private clamp(v: number, lo: number, hi: number): number {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  /** 柔光层顶边（本组件坐标，vp）：以锚点为圆心。 */
  private glowTopVp(): number {
    return this.activeCenterY() - GLOW_SIDE_VP / 2;
  }

  /** 换行时让柔光「呼吸」一下：冲到峰值再缓落回常态。 */
  private pulseGlow(): void {
    const ui = this.getUIContext();
    ui.animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
      this.glow = GLOW_PEAK;
    });
    setTimeout(() => {
      if (!this.mounted) {
        return;
      }
      this.getUIContext().animateTo({ duration: 860, curve: Curve.EaseInOut }, () => {
        this.glow = GLOW_IDLE;
      });
    }, 300);
  }

  /**
   * 算「离活跃行多远」，返回该距离对应的缩放 / 模糊半径 / 译文可见度。
   *
   * 只回答一个数：`dist`（0 = 当前行）。三种效果共用同一个距离，保证层次一致。
   */
  /**
   * 把第 idx 行滚到锚点。
   *
   * 这是**唯一**的滚动入口，做法与 AMLL 一致：目标位置是纯加法算出来的绝对坐标，
   * 一次性赋给 scrollY —— 交给 `animateTo` 从当前值平滑过去。
   * `animateTo` 在动画中途被新目标打断时会从当前渲染值继续，速度连续，不会回弹；
   * 而且同一时刻只有一个动画在跑（不像 scrollTo 那样每拍下发一次）。
   *
   * @param animate false = 立即到位（首次进入 / seek 跳转），true = 正常换行
   */
  /**
   * 滚动期间把全屏渐变模糊降级/恢复。
   *
   * `linearGradientBlur` 是全屏后处理：内容每移动一帧就得重算，是滚动掉帧的第二大来源。
   * 滚动时降到 0、动画结束 260ms 后恢复 —— 滚动中画面本来就在动，几乎察觉不到。
   */
  private setEdgeBlurScrolling(scrolling: boolean): void {
    if (this.edgeBlurRestoreTimer >= 0) {
      clearTimeout(this.edgeBlurRestoreTimer);
      this.edgeBlurRestoreTimer = -1;
    }
    if (scrolling) {
      if (this.edgeBlurPx !== EDGE_BLUR_SCROLLING_PX) {
        this.edgeBlurPx = EDGE_BLUR_SCROLLING_PX;
      }
      return;
    }
    this.edgeBlurRestoreTimer = setTimeout(() => {
      this.edgeBlurRestoreTimer = -1;
      if (!this.mounted) {
        return;
      }
      if (this.edgeBlurPx !== EDGE_BLUR_PX) {
        this.edgeBlurPx = EDGE_BLUR_PX;
      }
    }, 260);
  }

  /**
   * 重算挂载窗口。
   *
   * `hard = true` 时无条件重建（重建结构 / 初始化），否则只在锚点逼近窗口边界时才扩窗。
   */
  private updateWindow(anchorIdx: number, hard: boolean): void {
    const n: number = this.visuals.length;
    if (n === 0) {
      if (this.visibleIdx.length > 0) {
        this.visibleIdx = [];
      }
      return;
    }
    const a: number = this.clamp(anchorIdx, 0, n - 1);
    if (this.browseFull) {
      // 拖动浏览：全量挂载，绝不在拖动中重建（连续优先）
      if (this.visibleIdx.length === n) {
        return;
      }
      const full: number[] = [];
      for (let i = 0; i < n; i++) {
        full.push(i);
      }
      this.visibleIdx = full;
      return;
    }
    if (!hard && this.visibleIdx.length > 0) {
      const curS: number = this.visibleIdx[0];
      const curE: number = this.visibleIdx[this.visibleIdx.length - 1];
      const fits: boolean = a >= curS && a <= curE
        && (a - curS) >= WINDOW_MARGIN
        && (curE - a) >= WINDOW_MARGIN;
      if (fits) {
        return;
      }
    }
    const s0: number = Math.max(0, a - WINDOW_UP);
    const e0: number = Math.min(n - 1, a + WINDOW_DOWN);
    const arr: number[] = [];
    for (let i = s0; i <= e0; i++) {
      arr.push(i);
    }
    if (arr.length === this.visibleIdx.length && arr[0] === this.visibleIdx[0]) {
      return;
    }
    this.visibleIdx = arr;
  }

  /** 被省略的行（窗口之前）需要占掉的高度。 */
  private windowTopVp(): number {
    if (this.visibleIdx.length === 0 || this.lineTops.length === 0) {
      return 0;
    }
    return this.lineTops[this.visibleIdx[0]];
  }

  /** 被省略的行（窗口之后）需要占掉的高度。 */
  private windowBottomVp(): number {
    if (this.visibleIdx.length === 0) {
      return 0;
    }
    const last: number = this.visibleIdx[this.visibleIdx.length - 1];
    if (last >= this.visuals.length || last >= this.lineTops.length) {
      return 0;
    }
    const tail: number = this.lineTops[last] + this.visuals[last].heightVp;
    return Math.max(0, this.contentHeightVp - tail);
  }

  private scrollToLine(idx: number, animate: boolean): void {
    if (idx < 0 || idx >= this.lineCenters.length) {
      return;
    }
    const y: number = this.lineCenters[idx];
    if (Math.abs(y - this.scrollY) < 0.3) {
      return;
    }
    if (!animate) {
      this.scrollY = y;
      return;
    }
    // 换行时用**目标位置**一次性算好整列的渐隐（并动画过去），滚动途中不再逐拍重算。
    // 之前每拍调一次 applyDepth：100 行 × 每行 20 个 token 的 @Trace 写入，
    // 一秒钟 24 次 —— 那就是掉帧的主因。
    this.scrollTargetY = y;
    this.updateWindow(idx, false);
    this.applyDepthAt(this.scrollY, y, true);
    this.setEdgeBlurScrolling(true);
    try {
      this.getUIContext().animateTo({
        duration: SCROLL_DURATION_MS,
        curve: curves.springMotion(SCROLL_RESPONSE, SCROLL_DAMPING),
        onFinish: () => {
          this.setEdgeBlurScrolling(false);
        }
      }, () => {
        this.scrollY = y;
      });
    } catch (err) {
      this.scrollY = y;
    }
  }

  /**
   * 「白色高光边界」在行内的位置（以 token 为单位，3.4 = 第 3 段唱了 40%）。
   *
   * 整行的所有位移都由它推出来 —— 这是「整行一个算法」的锚点。
   */
  private headPosOf(vis: LineVisual, line: LyricLine, pos: number): number {
    const n: number = vis.tokens.length;
    for (let t = 0; t < n; t++) {
      const sp: number[] = this.spanOf(vis, t, line);
      if (pos < sp[1]) {
        if (pos <= sp[0]) {
          return t;
        }
        return t + (pos - sp[0]) / Math.max(1, sp[1] - sp[0]);
      }
    }
    return n;
  }

  /**
   * 某一段的抬升量：以「离高光边界的距离」为唯一变量，余弦钟形。
   *
   *  - 峰在高光边界（-WAVE_AMP_VP），向左右各 WAVE_HALF_TOKENS 个字平滑衰减到 0；
   *  - 端点导数为 0，所以相邻字之间没有折角、也没有"谁先动谁后动"的顿挫；
   *  - 已唱过的字（离边界远）自然回到基线，未唱的字也是——只有交界处抬起。
   * 这就是用户要的「整行像波浪一样上去」。
   */
  private waveLift(fill: number): number {
    // 抬升量 = **这一段的填充进度** × 幅度。
    //
    // 之前用「离 headPos 的距离」做余弦钟形，虽然 headPos 与 fill 在时间上同源
    // （同一套 spanOf、同一个 pos），但**钟形在未唱一侧也抬起**（峰值前移 2.2 个字），
    // 于是「跳动」看起来总跑在「高光」前面 —— 用户连续两次反馈的就是这个错位。
    // 现在直接吃 fill：未唱 = 0、正在唱 = 按比例升起、唱满 = 停在顶端。
    // 两者由**同一个量化驱动**，从机制上不可能再错位。
    if (fill <= 0) {
      return 0;
    }
    if (fill >= 0.999) {
      return -WAVE_AMP_VP;
    }
    return -WAVE_AMP_VP * fill;
  }

  /**
   * 把一个字抬到「跳上去后的位置」并停住。
   *
   * 只在这里（每字一次）下动画：`animateTo` + 官方弹簧，damping 0.55 会自然过冲，
   * 效果就是「弹上去、落定、不动」。一行里各字按演唱顺序依次触发 → 波浪。
   */
  private jumpToken(tk: TokenVisual): void {
    try {
      this.getUIContext().animateTo({
        duration: JUMP_MS,
        curve: curves.springMotion(JUMP_RESPONSE, JUMP_DAMPING)
      }, () => {
        tk.lift = -JUMP_VP;
      });
    } catch (err) {
      tk.lift = -JUMP_VP;
    }
  }

  /** 未唱部分的灰度：0.23（紧邻）→ 0.11（远处）。实测自实录视频逐行取峰值对比度。 */
  private dimAlphaOf(dist: number): number {
    const a: number[] = DIM_ALPHA_BY_DISTANCE;
    const i: number = dist < 0 ? 0 : dist;
    if (i >= a.length) {
      return a[a.length - 1];
    }
    return a[i];
  }

  private blurOf(dist: number): number {
    if (dist < 0) {
      return BLUR_BY_DISTANCE[0];
    }
    return dist < BLUR_BY_DISTANCE.length ? BLUR_BY_DISTANCE[dist] : BLUR_BY_DISTANCE[BLUR_BY_DISTANCE.length - 1];
  }

  private scaleOf(dist: number): number {
    if (dist === 0) {
      return SCALE_ACTIVE;
    }
    if (dist === 1) {
      return SCALE_NEAR;
    }
    if (dist === 2) {
      return SCALE_FAR;
    }
    if (dist === 3) {
      return SCALE_FARTHEST;
    }
    return SCALE_AWAY;
  }

  /**
   * 译文可见度。
   *
   * **全文可见**：不再按「离活跃行的行距」衰减（那样只有当前句和上下各一句
   * 能看到译文，用户上下翻动时下面的句子看不到翻译）。
   * 距离感交给行整体的 {@link LineVisual.fade} 处理 —— 它会把远处的正文和译文
   * 一起淡出，所以不会突兀，也不会出现「译文亮、正文灰」的割裂。
   */
  private transAlphaOf(dist: number): number {
    return 1;
  }

  /**
   * 空间渐隐 + 景深：按每行**在屏幕上的位置**算 fade，按**离活跃行的行距**算
   * scale / blur / 译文可见度。
   *
   * 为什么 fade 用屏幕位置、而 scale/blur 用行距：渐隐要「钉在屏幕上」
   * （官方上下缘各有一条渐隐带）；尺寸与模糊要「跟着当前行走」
   * （当前行换掉时，整列层次跟着平移）。两者混用会互相打架。
   *
   * @param animate true 时用 {@link DEPTH_ANIM_MS} 过渡（换行那一刻），
   *                false 时直接赋值（首次布局，避免入场时整列「跳」一下）。
   */
  private applyDepth(animate: boolean): void {
    this.applyDepthAt(this.scrollY, this.scrollY, animate);
  }

  /**
   * 按「当前滚动位置 fromY」算每一行此刻的屏幕 y、但按「目标位置 toY」取渐隐强度。
   *
   * 换行时调用一次即可：整列在 280ms 内平移，途中各行的亮度已经是终值 ——
   * 观感上是「整列平滑滑动」，不会出现底部行「先隐没、滚上去又变亮」的割裂，
   * 也不需要每拍重算（那正是掉帧的来源）。
   */
  private applyDepthAt(fromY: number, toY: number, animate: boolean): void {
    const n: number = this.visuals.length;
    if (n === 0 || this.lineCenters.length !== n) {
      return;
    }
    // 基准 = **滚动锚点**（不是 activeIdx）：滚动到哪一行，那一行就是最大/最清楚的，
    // 两者分开就会出现「字已经放大但列表还没滚过去」的错位感（用户说的「乱跳」）。
    // 浏览上下文时（还没恢复跟随）退回 activeIdx，避免用户手动滚到哪里、景深就跳到哪里。
    const focusIdx: number = this.scrollAnchorIdx >= 0 ? this.scrollAnchorIdx : this.activeIdx;
    const baseIdx: number = focusIdx >= 0 ? focusIdx : 0;
    const activeY: number = this.activeCenterY();
    const top: number = this.areaTopVp;
    const bottom: number = this.areaBottom();
    const upSpan: number = Math.max(1, activeY - top);
    const downFrom: number = activeY + Math.max(0, bottom - activeY) * FADE_DOWN_START;

    const applyFade = (): void => {
      // 用**真实的滚动位置**算每一行在屏幕上的 y。
      // 以前是 `activeY + (lineCenters[i] - base)` —— 那等于假设「活跃行此刻正好在锚点」，
      // 但滚动动画进行中并不成立：画面里某行才刚从底部冒出来，fade 却按它"已经在上面"
      // 来算，于是底部那行先被算成该隐没、滚到中途又突然变清晰 —— 就是用户说的
      // 「最底下那一行要等上面滚上去之后才刷新出来」。
      for (let i = 0; i < n; i++) {
        const y: number = this.lineCenters[i] - toY + activeY;
        void fromY;
        // **不再按屏幕位置做透明度渐隐**（用户要求）：
        // 原先上下缘各有一条 alpha 带，拖动时歌词会「逐渐显现 / 逐渐隐去」——
        // 那是透明度在动，不是景深。现在 fade 恒 1，上下缘完全交给
        // `linearGradientBlur` 的全屏渐变模糊去盖：靠糊而不靠淡。
        void y;
        void activeY;
        void top;
        void upSpan;
        void downFrom;
        void bottom;
        const f: number = 1;
        const vis: LineVisual = this.visuals[i];
        if (Math.abs(vis.fade - f) > 0.002) {
          vis.fade = f;
        }
        const dist: number = Math.abs(i - baseIdx);
        // 只给**锚点附近 5 行**真模糊：.blur() 会让节点进离屏渲染，
        // 100 多行各来一层是最贵的开销；而远处行本身已被 fade 压得很暗，
        // 模糊在屏幕上根本看不出来 —— 这一条能同时省掉大量合成与内存带宽。
        const bl: number = dist <= BLUR_MAX_DIST ? this.blurOf(dist) : 0;
        if (Math.abs(vis.blurPx - bl) > 0.05) {
          vis.blurPx = bl;
        }
        const ta: number = this.transAlphaOf(dist);
        if (Math.abs(vis.transAlpha - ta) > 0.002) {
          vis.transAlpha = ta;
        }
        // 未唱部分的灰度按距离分级（实测 0.23 / 0.19 / 0.14 / 0.11）。
        // 只在距离变化时同步到 token，避免每次换行都遍历几千个 token。
        const da: number = this.dimAlphaOf(dist);
        if (Math.abs(vis.dimAlpha - da) > 0.004) {
          vis.dimAlpha = da;
          const toks: TokenVisual[] = vis.tokens;
          for (let t = 0; t < toks.length; t++) {
            if (toks[t].fill < 0.999) {
              toks[t].alpha = da;
            }
          }
        }
        // 行级辉光也关掉：它同样是「整行模糊副本」，与逐字填充叠加后
        // 会让每个字都比实际进度更亮。glowLayer 因此不再被创建（省一次全行 blur）。
        const gl: number = 0;
        if (vis.glow !== gl) {
          vis.glow = gl;
        }
      }
    };

    // 尺寸单独走弹簧（能回弹），透明度/模糊走 EaseOut（过冲会让字闪）——
    // 两段动画同时进行，观感就是官方那种「整列带着一点弹性滑过去」。
    const applyScale = (): void => {
      for (let i = 0; i < n; i++) {
        const dist: number = Math.abs(i - baseIdx);
        const sc: number = this.scaleOf(dist);
        const vis: LineVisual = this.visuals[i];
        if (Math.abs(vis.scale - sc) > 0.002) {
          vis.scale = sc;
        }
      }
    };

    if (animate) {
      // 两层都走官方 curves.springMotion（用户反馈「动画依旧是线性的」就是这里：
      // 以前透明度/模糊这一层用的是 Curve.EaseOut —— 匀速收尾，看着发硬）。
      this.getUIContext().animateTo({
        duration: DEPTH_FADE_MS,
        curve: curves.springMotion(DEPTH_FADE_RESPONSE, DEPTH_FADE_DAMPING)
      }, applyFade);
      this.getUIContext().animateTo({
        duration: DEPTH_SCALE_MS,
        curve: curves.springMotion(DEPTH_SCALE_RESPONSE, DEPTH_SCALE_DAMPING)
      }, applyScale);
    } else {
      applyFade();
      applyScale();
    }
  }

  /**
   * 渐变模糊的分段（[模糊程度 0~1, 位置 0~1]）。
   *
   * 官方画面是「以锚点为中心的双侧景深」：锚点附近（约 ±一行）完全清晰，
   * 然后往外越来越糊。逐行 blur 已经承担了大部分层次，这一层只做**上下缘更强**
   * 的整体压深 —— 所以半径比旧版小（20px），否则会和逐行 blur 叠成一团。
   */
  private blurStops(): FractionStop[] {
    const h: number = this.areaHeightVp > 0 ? this.areaHeightVp : 620;
    const anchorT: number = this.clamp(this.activeCenterY() / h, 0.10, 0.90);
    const plateau: number = this.clamp((LINE_PITCH_VP * BLUR_PLATEAU_LINES) / h, 0.03, 0.20);
    const a: number = Math.max(0.04, anchorT - plateau);
    const b: number = Math.min(0.96, anchorT + plateau);
    const stops: FractionStop[] = [];
    // 顶边到锚点上方平台之间：模糊从 0.92 平滑降到 0（平台内完全清晰）。
    const s0: FractionStop = [0.92, 0.0];
    const s1: FractionStop = [0.45, a * 0.50];
    const s2: FractionStop = [0, a];
    stops.push(s0, s1, s2);
    if (b - a < 0.005) {
      stops.push([0, b + 0.01]);
    } else {
      stops.push([0, b]);
    }
    // 平台下方到屏幕底：模糊重新升到 1.0（底部最糊）
    const s3: FractionStop = [0.55, Math.min(0.99, b + (1 - b) * 0.50)];
    const s4: FractionStop = [1.0, 1.0];
    stops.push(s3, s4);
    return stops;
  }

  /** 启动指挥器心跳（100ms）+ 填充驱动（33ms）。 */
  private startConductor(): void {
    this.stopConductor();
    this.conductorId = setInterval(() => {
      this.tick(false);
    }, CONDUCTOR_MS);
    this.fillId = setInterval(() => {
      this.driveGlyphs();
    }, FILL_MS);
  }

  /** 停掉指挥器心跳与填充驱动。 */
  private stopConductor(): void {
    if (this.conductorId !== 0) {
      clearInterval(this.conductorId);
      this.conductorId = 0;
    }
    if (this.fillId !== 0) {
      clearInterval(this.fillId);
      this.fillId = 0;
    }
    // 停心跳时把「5 秒回位」的等待也撤掉，避免页面销毁后定时器还挂着
    this.clearBrowseTimer();
    this.dragging = false;
    this.browseHold = false;
    this.pendingReturn = false;
    this.browseFull = false;
  }

  /** 内容坐标可滚范围：0 .. 整列高度。 */
  private clampScroll(y: number): number {
    const max: number = Math.max(0, this.contentHeightVp);
    return this.clamp(y, 0, max);
  }

  /** 内容坐标 y 落在哪一行（和 lineCenters 同一套累计高度）。 */
  private lineIndexOfScroll(y: number): number {
    const n: number = this.lineCenters.length;
    if (n === 0) {
      return 0;
    }
    let lo: number = 0;
    let hi: number = n - 1;
    let ans: number = 0;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.lineCenters[mid] <= y) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  private clearBrowseTimer(): void {
    if (this.browseTimer >= 0) {
      clearTimeout(this.browseTimer);
      this.browseTimer = -1;
    }
  }

  private onBrowseDown(y: number): void {
    this.clearBrowseTimer();
    this.browseHold = false;
    this.dragging = true;
    this.lastTouchAt = Date.now();
    this.dragLastY = y;
    // 一按下就整列挂满：拖动过程中不再重建节点，观感才连续
    this.browseFull = true;
    this.updateWindow(this.lineIndexOfScroll(this.scrollY), true);
    // 把滚动目标钉在当前值，避免上一段自动滚动动画在拖动中继续把内容拽走
    this.scrollTargetY = this.scrollY;
  }

  private onBrowseMove(y: number): void {
    if (!this.dragging) {
      return;
    }
    this.lastTouchAt = Date.now();
    const dy: number = this.dragLastY - y;
    this.dragLastY = y;
    if (Math.abs(dy) < 0.01) {
      return;
    }
    const next: number = this.clampScroll(this.scrollY + dy);
    if (Math.abs(next - this.scrollY) < 0.01) {
      return;
    }
    // 浏览时窗口跟着视口走，拖到哪儿都有内容（不会露出占位空白）
    this.updateWindow(this.lineIndexOfScroll(next), false);
    this.scrollY = next;
    // 景深也要跟着走：fade 是按「每行此刻在屏幕上的 y」算的，
    // 只在滚动落位时算的话，拖动时新进入屏幕的行还带着旧的透明值 ——
    // 那就是用户说的「拖上去看不到歌词，只能看见中间几行」。
    // 每 20vp 重算一次（内部还有 0.002 的变化阈值），不会逐帧写满所有行。
    this.browseDepthAcc += Math.abs(dy);
    if (this.browseDepthAcc >= 12) {
      this.browseDepthAcc = 0;
      this.applyDepthAt(next, next, false);
    }
  }

  private onBrowseUp(velocityY: number): void {
    if (!this.dragging) {
      return;
    }
    this.dragging = false;
    this.lastTouchAt = Date.now();
    // 抬手惯性：速度越快滑得越远，但夹住上限免得一甩半首歌
    let fling: number = velocityY * BROWSE_FLING_GAIN;
    if (fling > BROWSE_FLING_MAX_VP) {
      fling = BROWSE_FLING_MAX_VP;
    } else if (fling < -BROWSE_FLING_MAX_VP) {
      fling = -BROWSE_FLING_MAX_VP;
    }
    if (Math.abs(fling) > 8) {
      const target: number = this.clampScroll(this.scrollY + fling);
      if (this.mounted) {
        this.getUIContext().animateTo({
          duration: BROWSE_FLING_MS,
          curve: Curve.Friction,
          onFinish: () => {
            if (this.mounted) {
              this.updateWindow(this.lineIndexOfScroll(this.scrollY), false);
              this.applyDepthAt(this.scrollY, this.scrollY, false);
            }
          }
        }, () => {
          this.scrollY = target;
        });
      }
    }
    // 5 秒无操作 → 回位到正在播放的位置
    this.browseHold = true;
    this.browseTimer = setTimeout(() => {
      this.browseTimer = -1;
      this.browseHold = false;
      if (!this.mounted) {
        return;
      }
      this.pendingReturn = true;
      this.tick(true);
    }, BROWSE_IDLE_MS);
  }

  /** 手指是否刚碰过列表（碰过就不抢滚动位置）。 */
  private isTouching(): boolean {
    return Date.now() - this.lastTouchAt < TOUCH_HOLD_MS;
  }

  /** 用户是否正在「看上下文」：手指按着、或刚手动滚动过且还没超过 {@link FOLLOW_RESUME_MS}。 */
  private isBrowsing(): boolean {
    if (this.dragging || this.browseHold) {
      return true;
    }
    if (this.isTouching()) {
      return true;
    }
    return this.userScrollAt > 0 && Date.now() - this.userScrollAt < FOLLOW_RESUME_MS;
  }

  /**
   * 把除目标行以外的所有行**立刻**清干净（白层/辉光/位移/阶段）。
   *
   * 为什么需要它：jumpTo 里先把 activeIdx 置 -1，于是 applyActive 的
   * 「清理上一行」分支被跳过（它要求 activeIdx >= 0），上一句的白层就留在
   * 屏幕上 —— 用户看到的就是「点了别的歌词，刚唱到一半那句还亮着」。
   * 而且上一行的淡出是挂在 animateTo 的 onFinish 上，动画被打断时也不会执行。
   */
  private resetLinesExcept(idx: number): void {
    const n: number = this.visuals.length;
    for (let i = 0; i < n; i++) {
      if (i === idx) {
        continue;
      }
      const vis: LineVisual = this.visuals[i];
      vis.active = false;
      vis.glow = 0;
      const toks: TokenVisual[] = vis.tokens;
      for (let t = 0; t < toks.length; t++) {
        const tk: TokenVisual = toks[t];
        tk.whiteAlpha = 0;
        tk.fill = 0;
        tk.glow = 0;
        tk.phase = 0;
        tk.pop = 1;
        tk.lift = 0;
        tk.edgeBlur = 0;
        tk.popped = false;
        tk.jumped = false;
        tk.alpha = vis.dimAlpha > 0 ? vis.dimAlpha : LYRIC_DIM_ALPHA;
      }
    }
  }

  /** 点击某一句：跳到它对应的进度，并立刻退出「浏览」状态。 */
  private jumpTo(ms: number): void {
    this.userScrollAt = 0;
    this.lastTouchAt = 0;
    this.onSeek(ms);
    // **立刻**把点中的那一行拉到锚点：以前要等播放头/seek 完成才动，
    // 中间那几百毫秒里画面停在旧位置 —— 用户看起来就是「点了没反应/位子乱跳」。
    const idx: number = this.lineIndexAt(ms);
    if (idx < 0 || idx >= this.visuals.length) {
      return;
    }
    // 先把其他行的白层/辉光全部清掉（否则上一句的高光会滞留）
    this.resetLinesExcept(idx);
    this.activeIdx = -1;
    this.applyActive(idx);
    this.scrollAnchorIdx = idx;
    this.lastPos = ms + LEAD_MS;
    // 保护期：AVPlayer 的 seek 是异步的，接下来几拍读到的播放头还是旧位置，
    // 不放这个闸门的话高光会先跳回旧行、几百毫秒后再跳过来。
    this.seekGuardIdx = idx;
    this.seekGuardUntil = Date.now() + SEEK_GUARD_MS;
    this.scrollToLine(idx, false);
  }

  /**
   * 一次心跳：更新当前行、必要时滚动、把逐字推到该到的位置。
   *
   * @param force true 时即使行没变也强制同步一次（首次排版 / 回到前台）。
   */
  private tick(force: boolean = false): void {
    if (!this.mounted || !this.ready || !this.active) {
      return;
    }
    // 拖动浏览中不跑心跳：用户在翻歌词，播放位置的高亮不需要跟着动，
    // 省下来的 @Trace 写入全部让位给拖动本身。
    if (this.dragging) {
      return;
    }
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined || lyric.lines.length === 0) {
      return;
    }
    // 判定用播放头整体前移 LEAD_MS（行切换与逐字高亮用同一个提前量，
    // 否则会出现「字亮了但行还没换」的错位）。
    const playing: boolean = this.state.isPlay;
    const pos: number = this.playhead.now(playing, this.state.progressMax) + LEAD_MS;
    let idx: number = this.lineIndexAt(pos);
    // 点击 seek 后的保护期：播放头还没追上目标行时沿用目标行，
    // 否则高光会被旧采样拽回上一句（「点了别的歌词，高光出不来」）。
    if (this.seekGuardIdx >= 0) {
      if (Date.now() > this.seekGuardUntil || idx >= this.seekGuardIdx) {
        this.seekGuardIdx = -1;
      } else {
        idx = this.seekGuardIdx;
      }
    }
    // 进度跳变：**首帧 / seek / 换歌**才重算整列。
    // 注意两点（暂停测试时就是这两个坑在抖）：
    //  ① 暂停期间播放头会有一两毫秒的抖动，不能让这种抖动触发重排；
    //  ② 跳变后要把滚动锚点标脏，让这一拍做**一次**重对齐 ——
    //     但绝不能「每一拍都当成跳变」，否则会连续重滚（看起来在乱跳）。
    let jumped: boolean = this.lastPos < 0 || Math.abs(pos - this.lastPos) > 1200;
    this.lastPos = pos;
    // 浏览期间（拖着 / 等回位）播放头当然会前进，但绝不能当成 seek 去重排整列 ——
    // 那会把用户正在看的位置一把拽走。真正的重排在回位那一刻做。
    if (this.dragging || this.browseHold) {
      jumped = false;
    }
    if (jumped) {
      this.resyncTokens(pos);
      this.scrollAnchorIdx = -1;
    }
    const browsing: boolean = this.isBrowsing();
    const nowTs: number = Date.now();
    // 暂停时不滚动：画面必须静止（用户暂停就是在看这一句）。
    // 只有「刚跳变 / 强制同步 / 浏览结束回位」这三种情况才允许在暂停状态下动。
    const allowScroll: boolean =
      playing || jumped || force || this.wasBrowsing || this.pendingReturn;

    // ① 滚动锚点：**当前行一唱完就滚到下一行**。
    //
    // 三个时机都试过：
    //  · 「提前滚下一句」→ 白字行会停在锚点上方一行（与「高光固定位置」冲突）；
    //  · 「等下一行开始才滚」→ 新行已经唱了一半才滑到位（用户说的「到位太晚」）；
    //  · **「上一行唱完就滚」** ← 现在这个：句子之间那段空隙正好装下滚动动画，
    //    新句开口时它已经（或几乎）在锚点上。
    let anchorIdx: number = idx >= 0 ? idx : 0;
    const lines: LyricLine[] = lyric.lines;
    if (idx >= 0 && idx + 1 < lines.length) {
      const nextStart: number = lines[idx + 1].startMs;
      const curEnd: number = lines[idx].endMs > lines[idx].startMs ? lines[idx].endMs : nextStart;
      // **上一句唱完（curEnd）就立刻滚**，绝不提前、也绝不拖延：
      // 提前滚会把还在唱的白字行往上推（破坏"高光固定在锚点"）；
      // 拖到下一句开口再滚，新句就已经唱了几个字（这就是"到位太晚"）。
      // 句间空隙整段留给这 130ms 的动画。
      // **取更早的那一个**：上一句唱完（curEnd）与「下一句开口前给动画留的余量」，
      // 谁先到就谁触发。很多歌词文件把行的 endMs 直接写成"下一行开始"，
      // 只看 curEnd 就会等成「下一句已经唱了半句才开始走」（用户实测）。
      // 下限 curEnd-500：避免长间奏里提前太久把还在唱的白字行推走。
      const byNext: number = nextStart - SCROLL_DURATION_MS - 80;
      const startAt: number = Math.min(curEnd, byNext);
      const earliest: number = curEnd - 500;
      const fireAt: number = startAt > earliest ? startAt : earliest;
      if (pos >= fireAt) {
        anchorIdx = idx + 1;
      }
      // **锚点只增不减**：播放头在临界点抖一下会让 anchorIdx 在 idx / idx+1 之间反复，
      // 于是每一拍都下发一次滚动 —— 那就是用户看到的「忽快忽慢、在找补」。
      if (this.scrollAnchorIdx >= 0 && anchorIdx < this.scrollAnchorIdx) {
        anchorIdx = this.scrollAnchorIdx;
      }
    }

    // ② 滚动：**唯一入口**。同一目标不重复下发；首次/跳变一次到位，正常换行跑弹簧。
    if (!browsing && allowScroll) {
      if (this.pendingReturn) {
        // 手动浏览结束：**用弹簧动画**回到当前行（不能走 first 的瞬间到位，
        // 那样观感是「啪」地跳回去）。
        this.pendingReturn = false;
        // 先把窗口缩回播放行附近（在动画开始前变，动画期间窗口不再动），
        // 静止播放时的 120fps 靠这一步保住。
        this.browseFull = false;
        this.updateWindow(anchorIdx, true);
        this.scrollAnchorIdx = anchorIdx;
        this.scrollToLine(anchorIdx, true);
      } else if (anchorIdx !== this.scrollAnchorIdx || force) {
        const first: boolean = this.scrollAnchorIdx < 0;
        this.scrollAnchorIdx = anchorIdx;
        this.scrollToLine(anchorIdx, !first && !jumped);
      }
    }

    // ③ 高亮行（白层/辉光）仍由播放头决定，与滚动锚点解耦
    if (idx !== this.activeIdx || force) {
      this.applyActive(idx);
    }
    this.wasBrowsing = browsing;
    this.driveGlyphs();
  }

  /** 二分找当前行：最后一个 startMs <= pos 的行。 */
  private lineIndexAt(pos: number): number {
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined) {
      return -1;
    }
    const lines: LyricLine[] = lyric.lines;
    if (lines.length === 0 || pos < lines[0].startMs) {
      return -1;
    }
    let lo: number = 0;
    let hi: number = lines.length - 1;
    let ans: number = 0;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (lines[mid].startMs <= pos) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /**
   * 跳变（seek / 换歌）后的整列重算：已唱完的行全亮，还没唱到的行全灰。
   *
   * 只在这个时刻遍历全部行 —— 平时心跳只碰当前行，代价可以忽略。
   */
  private resyncTokens(pos: number): void {
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined) {
      return;
    }
    for (let i = 0; i < this.visuals.length; i++) {
      const vis: LineVisual = this.visuals[i];
      // 用这一行**按距离算出来的**灰度（seek 之后也要保持正确的层次，
      // 否则跳转后整屏会短暂退回到统一的 0.20）
      const a: number = vis.dimAlpha > 0 ? vis.dimAlpha : LYRIC_DIM_ALPHA;
      for (let t = 0; t < vis.tokens.length; t++) {
        const tk: TokenVisual = vis.tokens[t];
        if (tk.alpha !== a) {
          tk.alpha = a;
        }
        tk.phase = 0;
        tk.fill = 0;
        tk.glow = 0;
        tk.pop = 1;
        tk.lift = 0;
        tk.popped = false;
        tk.jumped = false;
        tk.edgeBlur = 0;
        tk.whiteAlpha = 1;
      }
    }
    this.lastWordIdx = -1;
  }

  /**
   * 一段文字的**排版宽度**（vp）—— 三层渲染、行高估算、滚动定位共用这一个数。
   *
   * 以前这里加 1.5vp 余量（防白字右缘被裁），但活跃行每段都比真实宽 1.5vp，
   * 一行二十来段就宽出 30vp 左右：非活跃行（自然宽度）明明排得下，
   * 一变成活跃行（固定宽度）就折成两行 —— 「正在播放时字体变大、行数变了」的真身。
   * 现在余量收到 0.4vp（够防裁），并且**行高也按同一套宽度算**，折行恒定。
   */
  private static tokenWidthVp(text: string, measure: MeasureUtils, pxToVp: number, fontSize: number): number {
    if (text.length === 0) {
      return 0;
    }
    const px: number = measure.measureText({
      textContent: text,
      fontSize: fontSize,
      fontWeight: FontWeight.Bold,
      letterSpacing: LETTER_SPACING
    });
    const w: number = px * pxToVp + 0.4;
    return Math.max(3, Math.ceil(w * 10) / 10);
  }

  /**
   * 按「逐段固定宽度」模拟 Flex 换行，得出这一行折成几行。
   *
   * 与渲染严格同构：三个层里每个 token 都是「宽 = widthVp、单行、clip」，
   * Flex 只在 token 之间换行，所以这里也用 token 累加。**不要**再用
   * measureText 测整行字符串 —— 那种测法与逐段排版会在临界行上差一行。
   * 顺带把每段宽度缓存好（首次排版就把全部行量完，不是等到激活才量）。
   */
  private measureLineRows(vis: LineVisual, limit: number, measure: MeasureUtils, pxToVp: number): number {
    const toks: TokenVisual[] = vis.tokens;
    if (toks.length === 0) {
      return 1;
    }
    // **必须与渲染用同一个可用宽度**：以前这里减了 0.5（想留安全边距），
    // 结果临界行被多估一行，凭空多出 42.5vp 空白 —— 那就是「有的两句离得特别远」。
    const limitVp: number = limit > 0 ? limit : 320;
    let rows: number = 1;
    let acc: number = 0;
    let rowNo: number = 0;
    for (let i = 0; i < toks.length; i++) {
      const tk: TokenVisual = toks[i];
      tk.widthVp = AppleLyricsView.tokenWidthVp(tk.text, measure, pxToVp, this.fontSize);
      // 兜底宽度必须与渲染完全一致（渲染是 `widthVp > 0 ? widthVp : 16`）。
      // 这里以前对 0 宽的 token 直接 continue（不计宽度），可 Flex 仍会给它
      // 16vp 的位置 —— 于是我们**少算**了宽度，实际渲染比估算多折一行，
      // 内容溢出压到下一行，就是「有的两句贴得特别近」。
      const w: number = tk.widthVp > 0 ? tk.widthVp : 16;
      if (tk.widthVp <= 0) {
        tk.widthVp = w;
      }
      if (acc > 0 && acc + w > limitVp) {
        rows++;
        rowNo++;
      }
      // **xVp 跨视觉行连续累加**（换行不归零）：它是「字符序列上的位置」，
      // 不是屏幕坐标。逐字高亮的边界只认这个轴，折行就再也不会让
      // 第二行开头的字提前亮起来。rowIdx 只用于统计行数。
      tk.xVp = acc;
      tk.rowIdx = rowNo;
      acc += w;
    }
    vis.widthForFont = this.fontSize;
    return rows;
  }

  /**
   * 量出当前行每一段的宽度（vp），供白字亮层 / 辉光层的 `clip` 使用。
   *
   * 只量**当前行**（十几段），字号没变就复用上次的结果；用 Bold 量 ——
   * 当前行渲染就是 Bold，量错会让亮层比灰字窄/宽一点点。
   */
  private ensureTokenWidths(idx: number): void {
    if (idx < 0 || idx >= this.visuals.length) {
      return;
    }
    const vis: LineVisual = this.visuals[idx];
    if (vis.widthForFont === this.fontSize) {
      return;
    }
    const ui = this.getUIContext();
    const measure: MeasureUtils = ui.getMeasureUtils();
    const pxToVp: number = ui.px2vp(1);
    const limitVp: number = this.contentWidthVp() - 0.5;
    let acc: number = 0;
    let rowNo: number = 0;
    for (let t = 0; t < vis.tokens.length; t++) {
      const tk: TokenVisual = vis.tokens[t];
      const px: number = measure.measureText({
        textContent: tk.text,
        fontSize: this.fontSize,
        fontWeight: FontWeight.Bold,
        letterSpacing: LETTER_SPACING
      });
      // 与 relayout 里完全同一份公式（见 tokenWidthVp）：三层同宽，折行才不会变
      tk.widthVp = AppleLyricsView.tokenWidthVp(tk.text, measure, pxToVp, this.fontSize);
      // 宽度变了，序列坐标必须同步重算（否则渐变边界会落在错的字上）
      const w: number = tk.widthVp;
      if (w > 0 && acc > 0 && acc + w > limitVp) {
        rowNo++;   // 只记录行数，坐标继续累加
      }
      tk.xVp = acc;
      tk.rowIdx = rowNo;
      acc += w > 0 ? w : 0;
    }
    vis.widthForFont = this.fontSize;
  }

  /**
   * 切换当前行：上一行退回灰（带过渡），新行的白层从 0 开始。
   *
   * 「整页只有一行白」是官方的核心观感：唱完的行会很快暗下去（像聚光灯移动）。
   * 上一行的白层淡出 260ms 后再拆掉双层结构（回到单层灰字），而不是硬切。
   */
  private applyActive(idx: number): void {
    const ui = this.getUIContext();
    if (this.activeIdx !== idx && this.activeIdx >= 0 && this.activeIdx < this.visuals.length) {
      const prev: LineVisual = this.visuals[this.activeIdx];
      const tokens: TokenVisual[] = prev.tokens;
      const prevGlow: number = prev.glow;
      // 先让这一行的字**平滑落回基线**（同一段弹簧），再折叠成单层灰字；
      // 直接写 lift = 0 会看到"啪"地一下掉下来。
      ui.animateTo({
        duration: 220,
        curve: curves.springMotion(0.30, 0.78)
      }, () => {
        for (let t = 0; t < tokens.length; t++) {
          tokens[t].lift = 0;
          tokens[t].edgeBlur = 0;
        }
      });
      // 上一句的白层用 320ms 淡出，同时把它的灰度**动画**到目标值。
      // 之前是 180ms 淡出 + onFinish 里直接写 alpha → 白层消失与变暗撞在同一帧，
      // 观感是「刚唱完那一行突然暗掉」。
      ui.animateTo({
        duration: 320,
        curve: curves.springMotion(0.35, 0.80),
        onFinish: () => {
          if (!this.mounted) {
            return;
          }
          for (let t = 0; t < tokens.length; t++) {
            tokens[t].whiteAlpha = 1;
            tokens[t].fill = 0;
            tokens[t].glow = 0;
            tokens[t].phase = 0;
            tokens[t].pop = 1;
            tokens[t].lift = 0;
            tokens[t].edgeBlur = 0;
            tokens[t].jumped = false;
            tokens[t].popped = false;
            // 不在这里硬写 alpha：上面那段动画已经把它平移到 prev.dimAlpha 了
          }
          prev.active = false;
        }
      }, () => {
        const targetA: number = prev.dimAlpha > 0 ? prev.dimAlpha : LYRIC_DIM_ALPHA;
        for (let t = 0; t < tokens.length; t++) {
          tokens[t].whiteAlpha = 0;
          // 辉光同时淡出，否则上一行的光会「粘」在屏幕上 260ms
          tokens[t].glow = 0;
          // 白层淡出的同一段时间里，底色灰度平滑落到该行应有的灰度
          tokens[t].alpha = targetA;
        }
        prev.glow = 0;
        if (prevGlow > 0) {
          prev.glow = 0;
        }
      });
    }
    this.activeIdx = idx;
    this.lastWordIdx = -1;
    if (idx < 0 || idx >= this.visuals.length) {
      this.applyDepth(true);
      return;
    }
    const vis: LineVisual = this.visuals[idx];
    vis.active = true;
    // 亮层要按「具体 vp 宽度」裁剪，先把这一行每段的宽度量出来（只量当前行）
    this.ensureTokenWidths(idx);
    // 新行：白层从 0 开始，由 driveGlyphs() 按「已经唱到哪一段」从左往右填上来
    for (let t = 0; t < vis.tokens.length; t++) {
      const tk: TokenVisual = vis.tokens[t];
      tk.alpha = LYRIC_DIM_ALPHA;
      tk.fill = 0;
      tk.glow = 0;
      tk.phase = 0;
      tk.pop = 1;
      tk.lift = 0;
      tk.popped = false;
      tk.whiteAlpha = 1;
    }
    // 景深整体重算（换行那一刻的「整列滑过去」就是这个过渡）
    this.applyDepth(true);
    // 换行后立刻按当前播放头把这一行的白层算一遍（之后由 33ms 驱动持续推进）
    this.driveGlyphs();
    // 锚点柔光轻轻呼吸一下：换行时的「灵动感」有一半来自这里
    this.pulseGlow();
    if (LYRIC_TRACE) {
      const line: LyricLine = this.lyric !== undefined ? this.lyric.lines[idx] : new LyricLine();
      Logger.info(TAG, `换行 #${idx} "${line.text.substring(0, 16)}" token=${vis.tokens.length}`);
    }
  }

  /**
   * 算出某个字形段的时间窗（毫秒，左闭右开）。
   *
   * - **有逐词时间**：用词的 `[startMs, endMs]`，再按 `fracStart/fracEnd` 在词内摊开；
   * - **只有行时间**（部分曲目 / 老数据）：整行时长按 token 数均摊。
   */
  private spanOf(vis: LineVisual, index: number, line: LyricLine): number[] {
    if (index >= 0 && index < vis.tokenStart.length && index < vis.tokenEnd.length) {
      const s0: number = vis.tokenStart[index];
      const e0: number = vis.tokenEnd[index] > s0 ? vis.tokenEnd[index] : s0 + 1;
      return [s0, e0];
    }
    // 兜底：没有时间窗数据时按整行均摊（老缓存/异常数据）
    const ls: number = line.startMs;
    const le: number = line.endMs > ls ? line.endMs : ls + 1;
    const n: number = vis.tokens.length > 0 ? vis.tokens.length : 1;
    return [ls + ((index / n) * (le - ls)), ls + (((index + 1) / n) * (le - ls))];
  }

  /**
   * 逐字填充的驱动（关键：**自己算，不让动画框架插值**）。
   *
   * 前面两版失败原因都已量化确认：
   *  ① 100ms 心跳驱动 —— 汉字时间窗 150~300ms，采样点落不到中间，观感「字一个个蹦」；
   *  ② `keyframeAnimateTo({delay})` 排程 —— 各 keyframe 闭包在调用时就写入目标值，整行瞬间全白；
   *  ③ 定时器到点再 `animateTo(Linear)` —— 实测只有第一个字被平滑插值。
   * 结论：白层宽度**每帧直接按播放头算**（33ms，≈30fps），填充比例 = (播放头 − 字开始) / 字时长。
   */
  private driveGlyphs(): void {
    if (!this.mounted || !this.ready || !this.active) {
      return;
    }
    if (this.activeIdx < 0 || this.activeIdx >= this.visuals.length) {
      return;
    }
    const lyric: AppleLyric | undefined = this.lyric;
    if (lyric === undefined || this.activeIdx >= lyric.lines.length) {
      return;
    }
    const line: LyricLine = lyric.lines[this.activeIdx];
    const vis: LineVisual = this.visuals[this.activeIdx];
    const n: number = vis.tokens.length;
    if (n === 0) {
      return;
    }
    // 末尾长音的泛光只给「行内最后一个 token 且时长够长」的那一个（Apple 的拖尾光）
    const tail: number = this.tailGlowIndex(vis, line);
    // + LEAD_MS：把判定整体前移，抵消「采样 33ms + 渲染 2 帧」带来的滞后。
    // 用户反馈「文字跳动的时机有些晚」就是这几处叠加的结果。
    const pos: number = this.playhead.now(this.state.isPlay, this.state.progressMax) + LEAD_MS;
    // ── 整行一个算法：先算出「白色高光边界」落在行内的哪个位置（以 token 为单位）。
    // headPos = 3.4 表示第 3 段已经唱了 40%。所有位移都从这一个数推出来，
    // 所以整行是一道跟着高光走的波，而不是一堆各自为战的字。
    const headPos: number = this.headPosOf(vis, line, pos);
    // 前沿落在哪一段：整行第一个「还没唱满」的 token（可能 fill=0，即刚进入它左边缘）。
    // 渐变带必须挂在这一段上 —— 否则上一段刚唱满时前沿会「无处安放」，
    // 下一段整字瞬间变回纯灰（用户看到的「即将播放的字突然整块变灰」）。
    const frontIdx: number = headPos >= n ? n - 1 : Math.floor(headPos);
    if (vis.frontIdx !== frontIdx) {
      vis.frontIdx = frontIdx;
    }
    const frontFill: number = headPos >= n ? 1 : headPos - Math.floor(headPos);
    if (Math.abs(vis.frontFill - frontFill) > 0.01) {
      vis.frontFill = frontFill;
    }
    // 整行唯一的填充边界（视觉行内绝对 vp）：由前沿那一段的 x 偏移 + 段内进度算出。
    if (frontIdx >= 0 && frontIdx < vis.tokens.length) {
      const ft: TokenVisual = vis.tokens[frontIdx];
      const fw: number = ft.widthVp > 0 ? ft.widthVp : 16;
      const fpx: number = ft.xVp + frontFill * fw;
      if (Math.abs(vis.fillPx - fpx) > 0.3) {
        vis.fillPx = fpx;
      }
      if (vis.fillRow !== ft.rowIdx) {
        vis.fillRow = ft.rowIdx;
      }
    }
    for (let t = 0; t < n; t++) {
      const tk: TokenVisual = vis.tokens[t];
      const span: number[] = this.spanOf(vis, t, line);
      const s0: number = span[0];
      const e0: number = span[1];
      if (pos >= e0) {
        if (tk.fill < 0.999) {
          tk.fill = 1;
          tk.phase = 2;
        } else if (tk.phase !== 2) {
          tk.phase = 2;
        }
        // 唱满 → 停在顶端（不会回落）；与 fill=1 严格对应
        const lifted: number = this.waveLift(tk.fill);
        if (Math.abs(tk.lift - lifted) > 0.02) {
          tk.lift = lifted;
        }
        if (tk.pop !== 1) {
          tk.pop = 1;
        }
        // 逐字辉光已关闭（原实现是整字模糊副本，见下方 singing 分支注释）
        if (tk.glow !== 0) {
          tk.glow = 0;
        }
        void tail;
        continue;
      }
      if (pos <= s0) {
        if (tk.fill > 0.001) {
          tk.fill = 0;
        }
        if (tk.glow !== 0) {
          tk.glow = 0;
        }
        // 「预热」：实录里下一个字在真正开唱前约 100~200ms 就开始整体提亮
        // （11.4s 那行第 2 字峰值 102 → 129 → 157 → 199，四帧爬升），
        // 这是 Apple 让人感觉"提前知道下一字"的关键。这里用 220ms 线性升温。
        // 未唱段的底色恒定 = 该行应有的灰字灰度。
        // 这里**不再做整字预热**：抬整字 alpha 会让「字还没唱就先亮一块」，
        // 与逐字填充的前进方向打架（用户两次反馈的「底整体亮一度」）。
        const base: number = vis.dimAlpha > 0 ? vis.dimAlpha : LYRIC_DIM_ALPHA;
        if (Math.abs(tk.alpha - base) > 0.008) {
          tk.alpha = base;
        }
        if (tk.phase !== 0) {
          tk.phase = 0;
          tk.pop = 1;
          tk.lift = 0;
          tk.edgeBlur = 0;
          tk.jumped = false;
          tk.popped = false;
        }
        continue;
      }
      // 正在唱：线性填充（每帧直接写值，30fps 足够顺滑，且绝不错位）
      const p: number = (pos - s0) / Math.max(1, e0 - s0);
      if (Math.abs(p - tk.fill) > 0.004) {
        tk.fill = p;
      }
      // 底色必须与未唱段一致：亮起来的部分只该是白层扫过的那一段，
      // 而不是整个字的底（否则「唱到哪个字，哪个字的底就亮一度」）。
      const singingBase: number = vis.dimAlpha > 0 ? vis.dimAlpha : LYRIC_DIM_ALPHA;
      if (Math.abs(tk.alpha - singingBase) > 0.008) {
        tk.alpha = singingBase;
      }
      // 抬升跟着**同一个 fill** 升起 —— 跳动与高光边界从此不可能错位
      const rising: number = this.waveLift(p);
      if (Math.abs(tk.lift - rising) > 0.02) {
        tk.lift = rising;
      }
      // 缩放恒 1（官方没有整字放大）
      if (tk.pop !== 1) {
        tk.pop = 1;
      }
      if (tk.edgeBlur !== 0) {
        tk.edgeBlur = 0;
      }
      // 逐字辉光**取消**：它是一份「整字」的白字副本叠了整层 blur，
      // 亮度按 pow(p,0.6) 上升 —— 但副本宽度是整个字，与填充进度无关。
      // 于是字还没填到一半，整字周围已经亮了一圈，用户读到的就是
      // 「高光移到这个字，这个字的底整体亮了一度」。逐字高亮只需要白层，
      // 不需要 halo（实测 Apple Music 的当前行白字本来也没有光晕）。
      if (tk.glow !== 0) {
        tk.glow = 0;
      }
      if (tk.phase !== 1) {
        tk.phase = 1;
      }
    }
  }

  /**
   * 找「末尾长音」的 token 下标（没有就是 -1）。
   *
   * Apple 的歌词里，句子最后一个音如果被拉长（比如拖腔、长音、念白），
   * 那一两个字的柔光会**比别的字更亮、且唱完之后还在缓慢呼吸**。
   * 判定很朴素：行内最后一个 token、且它自己的时间窗超过 {@link TAIL_GLOW_MS}。
   */
  private tailGlowIndex(vis: LineVisual, line: LyricLine): number {
    const n: number = vis.tokens.length;
    if (n === 0) {
      return -1;
    }
    const last: number = n - 1;
    const span: number[] = this.spanOf(vis, last, line);
    return (span[1] - span[0]) >= TAIL_GLOW_MS ? last : -1;
  }

  /**
   * 旧的「整字弹一下」实现（已弃用，保留说明）。
   *
   * 用户明确说过：不要「整个字跳」，要「一个字随着高光从左到右的连续波形」。
   * 现在位移/缩放由 `sin(π × fill)` 每帧算出来（见 driveGlyphs），
   * 不再需要「上去 + 落回」两段动画 —— 那样必然是「整字跳一下」。
   */
  private popSoft(tk: TokenVisual, durMs: number): void {
    // 按「这个字被唱了多久」缩放幅度与节奏：
    //   快歌（字长 120~200ms）→ 权重 0.5 左右 → 只抬 0.5vp、几乎看不出；
    //   慢歌（字长 400~600ms）→ 权重 1.3~1.8 → 抬 1.2vp、回落更缓。
    // 这正是 Apple 的做法：跳动的周期跟着语速走，而不是每个字一个固定动作。
    const w: number = this.clamp(durMs / POP_BASE_MS, 0.5, 1.8);
    const peak: number = 1 + POP_GAIN * w;
    const lift: number = LIFT_BASE_VP * w;
    const upMs: number = Math.round(64 + 22 * w);
    const backMs: number = Math.round(300 + 220 * w);
    const ui = this.getUIContext();
    // 上去：官方急停曲线（够快才跟得上音节）
    ui.animateTo({ duration: upMs, curve: Curve.Friction }, () => {
      tk.pop = peak;
      tk.lift = lift;
    });
    // 落回：官方弹簧（damping < 1 ⇒ 轻微过冲再稳住，这就是「Q 弹」）
    ui.animateTo({ duration: backMs, curve: curves.springMotion(0.32, 0.52), delay: upMs }, () => {
      tk.pop = 1;
      tk.lift = 0;
    });
  }

  /**
   * 背景层：模糊封面（缓慢运动）+ 会呼吸的暖光 + 暗纱 + 上下渐变。
   *
   * 三个性能要点：
   *  ① 封面按 {@link BG_IMAGE_RATIO} 的小尺寸渲染，再放大 {@link BG_IMAGE_ZOOM} 倍 ——
   *     模糊是拿渲染尺寸的像素算的，小图放大等效「大半径模糊 + 低像素成本」；
   *  ② 运动只有 scale / translate（渲染变换，不触发布局）；
   *  ③ `hitTestBehavior(None)`，绝不抢列表的滑动。
   */
  @Builder
  backgroundLayer() {
    // 这里**不再自己画一张糊掉的封面**。
    //
    // 原因（用户反馈的两个问题一起解决）：
    //  ① 自绘一张模糊图会让「头部（小封面/歌名）」与「歌词区」出现一条生硬的
    //     两色分界 —— 因为那是两张不同的图；
    //  ② 静图永远不像官方那种「流光」。
    // 现在改成**纯叠加层**：宿主的整屏模糊封面继续当底色（所以整页颜色连续、没有接缝），
    // 上面叠官方 `UV_BACKGROUND_FLOW_LIGHT` 背景流光 + 会呼吸的暖光 + 一层薄暗纱，
    // 从而得到「模糊 + 流动」的观感。
    Stack({ alignContent: Alignment.Center }) {
      // ① 封面色底纱（最底层）：压住宿主那层不可控 shader 透上来的彩色
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.tintBase)
        .visibility(LYRIC_BG_SELF ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
      if (FLOW_SHADER_ENABLED && this.flowReady) {
        Column()
          .width('100%')
          .height('100%')
          .visualEffect(new hdsEffect.HdsEffectBuilder()
            .shaderEffect({
              effectType: hdsEffect.EffectType.UV_BACKGROUND_FLOW_LIGHT,
              animation: { duration: FLOW_DURATION_MS, iterations: -1, autoPlay: true },
              controller: this.flowController,
              params: {
                colorSource: this.flowSource,
                colorTarget: this.flowTarget
              }
            })
            .buildEffect())
          .opacity(FLOW_ALPHA)
          .visibility(LYRIC_BG_SELF ? Visibility.Visible : Visibility.Hidden)
          .hitTestBehavior(HitTestMode.None)
      }
      // 两团缓慢交错漂移的光斑：**「背景在流动」靠它们肉眼可见**，
      // 不依赖 shader 的观感（上一层官方流光偏淡，单靠它看不出动）。
      // 都是「色块 + 大半径 blur + 缓慢变换」，成本很低（纯渲染变换）。
      Column()
        .width(BLOB_SIDE_VP)
        .height(BLOB_SIDE_VP)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [
            [this.blobAColor, 0.0],
            [this.blobAMid, 0.45],
            ['rgba(0,0,0,0.0)', 1.0]
          ]
        })
        .blur(BLOB_BLUR_VP)
        .translate({ x: this.blob1X, y: this.blob1Y })
        .visibility(LYRIC_BG_SELF ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
      Column()
        .width(BLOB_SIDE_VP)
        .height(BLOB_SIDE_VP)
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [
            [this.blobBColor, 0.0],
            [this.blobBMid, 0.45],
            ['rgba(0,0,0,0.0)', 1.0]
          ]
        })
        .blur(BLOB_BLUR_VP)
        .translate({ x: this.blob2X, y: this.blob2Y })
        .visibility(LYRIC_BG_SELF ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
      // 会呼吸的暖光：中心跟着锚点缓慢上下浮（官方背景里那块「亮起来的地方」）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', this.bgLightY],
          radius: '76%',
          colors: [
            [this.glowColor, 0.0],
            [this.glowMid, 0.44],
            ['rgba(0,0,0,0.0)', 1.0]
          ]
        })
        .visibility(LYRIC_BG_SELF ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
      // 薄暗纱：只把整体压一档，保留流光的色彩（不再像上一版那样压成一片灰）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(BG_DIM)
        .hitTestBehavior(HitTestMode.None)
      // 上下渐变：**顶部从透明渐入**（不再是一条硬边），底部压暗接播控
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            ['#00000000', 0.0],
            ['#00000000', 0.08],
            ['#00000000', 0.30],
            ['#00000000', 0.68],
            ['#73000000', 0.92],
            ['#A6000000', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 背景：模糊封面 + 运动 + 暖光 + 暗纱
      this.backgroundLayer()

      // ② 锚点柔光：一层静止的径向渐变（换行时呼吸一下），只影响底色亮度
      Stack() {
        Column()
          .width(GLOW_SIDE_VP)
          .height(GLOW_SIDE_VP)
          .radialGradient({
            center: ['50%', '50%'],
            radius: '50%',
            colors: [
              ['rgba(255,255,255,0.085)', 0.0],
              ['rgba(255,255,255,0.042)', 0.42],
              ['rgba(255,255,255,0.0)', 1.0]
            ]
          })
      }
      .width('100%')
      .height(GLOW_SIDE_VP)
      .position({ x: 0, y: this.glowTopVp() })
      .opacity(this.glow)
      .hitTestBehavior(HitTestMode.None)

      // ③ 正文
      Column() {
        if (this.lyric === undefined || this.lyric.lines.length === 0) {
          Column() {
            Text('此歌曲暂无歌词')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .opacity(0.45)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (!this.ready) {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color('#FFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          // 整列内容放在 Column 里，用 translateY 位移来「滚动」（AMLL 的做法）。
          // clip 在 Stack 上，所以内容不会被画到歌词区之外。
          Stack({ alignContent: Alignment.TopStart }) {
            Column({ space: 0 }) {
              // 顶部垫片：让第一行也能落到锚点（等价 contentInset.top）
              Column().width('100%').height(this.anchorLocalVp())
              // 被省略的前置行：等高占位，撑住内容坐标（视觉上在屏幕上方之外）
              Column().width('100%').height(this.windowTopVp())
              // 只挂载窗口内的行（锚点上下各一段），其余靠占位
              ForEach(this.visibleIdx, (vi: number) => {
                Column() {
                  LyricLineItem({
                    line: this.lyric!.lines[vi],
                    visual: vi < this.visuals.length ? this.visuals[vi] : new LineVisual(),
                    fontSize: this.fontSize,
                    showTranslation: this.showTranslation,
                    onTap: (): void => {
                      this.jumpTo(this.lyric!.lines[vi].startMs);
                    },
                    onMeasured: (): void => {
                      this.scheduleMetrics();
                    }
                  })
                }
                .width('100%')
                // opacity 为 0 并不影响命中测试：不挡这一下，用户会点到一个
                // 「看不见的歌词」并跳走（这才是「点空白处居然跳了」的真因）。
                .hitTestBehavior(
                  vi < this.visuals.length && this.visuals[vi].fade < 0.06
                    ? HitTestMode.None
                    : HitTestMode.Default
                )
              }, (vi: number): string => {
                return this.gen + '_' + vi + '_' + this.lyric!.lines[vi].key;
              })
              // 被省略的后置行：等高占位
              Column().width('100%').height(this.windowBottomVp())
              // 底部垫片：让最后几行也能移到锚点
              Column().width('100%').height(this.footerHeightVp())
            }
            .width('100%')
            .translate({ y: -this.scrollY })
          }
          .width('100%')
          .layoutWeight(1)
          .clip(true)
          // 上下拖动浏览歌词：位移直接改 scrollY（纯渲染层，不触发布局）
          .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
              .onActionStart((ev: GestureEvent) => {
                this.onBrowseDown(ev.fingerList.length > 0 ? ev.fingerList[0].localY : ev.offsetY);
              })
              .onActionUpdate((ev: GestureEvent) => {
                this.onBrowseMove(ev.fingerList.length > 0 ? ev.fingerList[0].localY : ev.offsetY);
              })
              .onActionEnd((ev: GestureEvent) => {
                this.onBrowseUp(ev.velocityY);
              })
              .onActionCancel(() => {
                this.onBrowseUp(0);
              })
          )
          // 文字区收边（背景层仍然铺满整个歌词区）
          .padding({ left: this.edgePaddingVp, right: this.edgePaddingVp })
          // 官方渐变模糊：按视口取景，所以列表滚动时模糊钉在屏幕上
          .linearGradientBlur(this.edgeBlurPx, {
            fractionStops: this.blurStops(),
            direction: GradientDirection.Bottom
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldVal: Area, newVal: Area) => {
      const w: number = Number(newVal.width);
      const h: number = Number(newVal.height);
      if (w > 0 && Math.abs(w - this.areaWidthVp) > 0.5) {
        this.areaWidthVp = w;
      }
      if (h > 0 && Math.abs(h - this.areaHeightVp) > 0.5) {
        this.areaHeightVp = h;
      }
    })
  }
}
