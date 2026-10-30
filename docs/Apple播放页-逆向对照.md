# Apple Music 播放页（含歌词）逆向对照与改造方案

> 2026-10-18。目标：把播放页做到"功能与 Apple Music 一致"，并把歌词的定位/显示/弹性做到同水准。
> 逆向对象：**macOS 的 `Music.app`**（不加密、无需越狱；iOS 版共用同一套 `LyricsX` 模块，
> 符号族完全一致，因此 macOS 的结论对 iOS 同样成立）。

## 一、逆向方法与可复现命令

```bash
B=/System/Applications/Music.app/Contents/MacOS/Music      # 32 MB，arm64e / arm64e.x1 双切片
otool -L "$B" | grep -i music                              # → MusicUI / MusicUI_Mac / AMPDesktopUI
strings -a "$B" | grep -oE '_TtC7LyricsX[0-9A-Za-z_]+'      # → 14 个实现类
strings -a "$B" | grep -oiE 'blurRadius|glowRadius|glowRange|damping|stiffness' # → 参数名
nm -a "$B" | grep LyricsX                                  # → 832 条本地符号（含地址）
xcrun swift-demangle --simplified                          # → Swift 符号反修饰
otool -ov "$B" > /tmp/music_objc.txt                       # → 类/ivar 布局（310k 行）
```

- **SIP 开启 ⇒ 不能 attach lldb / Frida**（`task_for_pid` 拒绝）。所以运行期"真实动画参数"拿不到，
  只能静态分析 + 真机截图像素量测双向收敛。
- `MusicUI.framework` 目录里只剩资源与签名（二进制在 dyld 共享缓存里），但**歌词实现类内嵌在 Music 主二进制内**，
  所以静态分析完全可行。

## 二、Apple 的组件树（`SyncedLyricsLineLayer` 的嵌套类型，实测符号）

```
SyncedLyricsViewController                 ← displayLinkFired / scrollViewWillBeginScrolling /
│                                            scrollViewDidEndScrolling / handleTap: / viewDidLayout
├── SyncedLyricsVisualExperienceManager    ← 总编排（15 个 ivar：delegate/manager/specs(880B)/lyrics/timingProvider…）
│   └── StaticTimingProvider               ← 静态时间轴（无逐字时回退整行）
├── SyncedLyricsManager                    ← 行集合 + 时序
├── SyncedLyricsLineView                   ← 行视图（layout / sizeThatFits: / mouseEntered: / primaryAction）
└── SyncedLyricsLineLayer                  ← 行图层
    ├── TextContainer.TextContainerLayer
    ├── SBS_TextContentLayer.TextLayer     ← 文字本体（CATextLayer 体系）
    ├── Word.WordLayer                     ← 词级
    ├── Syllable.SyllableLayer             ← 音节级
    │   └── Syllable.SyllableContainerLayer
    ├── Glyph.GlyphLayer                   ← 字形级（连单字笔画层都有）
    └── LineProgressGradientLayer          ← 扫光：渐变进度层（NoAnimationLayer 子类）
辅助：TextKitLabel / LyricsOptionsManager / Lyrics（数据模型）
翻译：Music.LyricsXViewController → toggleTranslation / toggleTransliteration / translationButtonClicked
```

结论：**Apple 不是"给每个字改颜色"，而是"一组图层 + 渐变的进度遮罩在移动"**，再叠词/音节/字形三级细粒度。
译文与音译是独立图层（`translationLineLayer` / `translationLargeFont` / `translationSpacing`）。

## 三、从二进制里捞出的参数名（= Apple 真实可调的旋钮）

| 组 | 名字 |
|---|---|
| 景深 | `blurRadius`、`blurFilter`、`blurredLineViews`、`blurredTexture`、`BlurView` |
| 光效 | `glowColor`、`glowRadius`、`glowRange` |
| 弹簧 | `SpringAnimationParameters`、`SpringTimingParameters`、`damping`、`stiffness` |
| 进度 | `LineProgressGradientLayer`、`progress`、`anchorPoint`、`translation` |
| 译文 | `translationLineLayer`、`translationTextColor`、`translationLargeFont`、`translationSmallFont`、`translationSpacing`、`translationBottomPadding` |

两个关键含义：
1. **景深是"预渲染模糊副本"**（`blurredLineViews` / `blurredTexture`），不是逐行实时 filter。
2. **弹性是阻尼弹簧**（`damping` + `stiffness`），行切换有轻微过冲。

## 四、本轮已落地的三处改造（编译通过）

| 问题 | 根因 | 改法 |
|---|---|---|
| 歌词定位（折行行偏移） | 旧实现用 `scrollToIndex(..., ScrollAlign.START)` —— 把**行顶部**对齐，折成两行的歌词中心就比锚点低半行，高亮与 25% 锚点错位 | 改为自己算 y 偏移：`scrollTo({yOffset: lineCenters[i], animation:{curve: curves.springMotion(...)}})`；`contentStartOffset` 直接取锚点位置，于是"行中心落到锚点"= 滚动到行中心值（对 1/2/N 行都成立） |
| 末尾几行到不了锚点 | 列表最大滚动量被内容高度卡住（没有底部内边距） | 列表末尾加**底部垫片** ListItem（高度 = 区域高 − 锚点位置），等价 Apple 的 `contentInset.bottom` |
| 弹性感不足 | 旧实现用 `scrollToIndex(smooth=true)` 的固定时长曲线；且每 2s 硬拽一次位置 | 全部换成 `curves.springMotion(0.34, 0.84)`；滚动动画期间不叠新滚动；落位后 520ms 做一次校验（偏差 >3vp 才补滚）；每 2s 的"重申"改为**只在实际漂移 >0.6 行时才补滚** |
| 显示层次（聚焦感） | 只有亮度差，没有尺寸差 | 行级 `.scale()`（1.0 / 0.975 / 0.95 / 0.93 按距离），变换不参与布局，定位不受影响 |

## 五、功能对照表（我们 vs Apple Music 播放页）

| 功能 | Apple | 我们 | 备注 |
|---|---|---|---|
| 封面 + 背景取色/模糊 | ✔ | ✔ | 已有 |
| 标题/艺人 | ✔ | ✔ | |
| 进度条拖动 | ✔ | ✔ | |
| 上一首/播放/下一首 | ✔ | ✔ | |
| 随机 / 循环（单曲） | ✔ | ✔ | symbol: shuffle / repeat / repeat_1 |
| 歌词开关 | ✔ | ✔ | lyrics_square |
| 歌词逐句高亮 + 自动跟随 | ✔ | ✔（本轮修定位/弹性） | |
| 歌词逐音节/逐字 | ✔（SyllableLayer/GlyphLayer） | △ 逐词 | 下一步改成逐音节 |
| 扫光形态 | 渐变进度遮罩 | △ 逐字 alpha | 下一步换成遮罩位移 |
| 点歌词跳转（tap-to-seek） | ✔ | ✔ | |
| 译文 | ✔ | ✔ | |
| **音译（transliteration）** | ✔ | ✗ | 缺 |
| **⭐ 喜欢当前曲目** | ✔ | ✗ | 缺 |
| **Up Next / 队列** | ✔ | ✗ | 缺 |
| **更多菜单（⋯）/ 分享** | ✔ | ✗ | 缺 |
| **输出设备选择** | ✔（AirPlay） | ✗ | 鸿蒙侧对应"音频输出设备" |
| 用手滚歌词后自动恢复跟随 | ✔ | △ 有触摸保护，但恢复时机偏硬 | 下一步对齐 `scrollViewDidEndScrolling` |

## 六、下一步实施计划（按可验收的边界切）

**第 2 期（歌词观感，2 个工作日）**
1. 逐音节切分：`AppleLyric.lines[i].words[j]` 已有逐词时间，需要在解析层按字符区间细分为音节（`MSVLyricsWord.characterRange` 的做法）。
2. 扫光：改"单层渐变 + `clip` 遮罩位移"（对应 `LineProgressGradientLayer`），当前行的白/灰由遮罩边界决定，代替逐 token alpha。
3. 景深：按 Apple 的做法把"整表 `linearGradientBlur`"换成"离锚点距离取两档预渲染模糊强度"，减少实时 filter 开销。

**第 3 期（功能补齐，1-2 个工作日）**
4. ⭐ 收藏当前曲目（`PUT/DELETE /v1/me/ratings/songs/{catalogId}`，已有专辑版实现可复用）。
5. Up Next 队列面板（`playQueueUris` 已是唯一真源，直接渲染）。
6. 音译行（有 `transliterations` 字段就显示，独立字号/颜色）。
7. 更多菜单（分享/查看专辑/报告问题占位）。

## 七、资源评估

- 逐音节高亮只影响**当前行**（其余行仍整块 Text）：每行节点从 ~10 增到 ~15，无全屏 shader。
- 渐变遮罩方案比逐 token alpha **更省**：每帧只改一个遮罩位移，而不是 N 个 Text 的 alpha。
- 弹簧滚动取代高频 `scrollToIndex` + 2s 重申，滚动相关调用从"每秒若干次"降到"换行一次"。
- 景深若改预渲染副本会增加内存（每行一张模糊位图），需要按可视范围裁剪；短期先保留整表渐变模糊。

## 八、限制（真话）

- SIP 开启 ⇒ 无法动态验证 Apple 的真实动画参数；`damping`/`glowRadius` 的具体数值仍是"量测逼近"。
- 想拿具体常数只能反汇编读立即数（可行但不可靠），ROI 低；观感差距主要来自结构（音节粒度、遮罩扫光、弹簧），不是那几个数字。
- 真机验证边界：本轮改动已编译，但**手机当时断连（ping 100% 丢包 / hdc 无设备）**，尚未装机验证。

## 九、真机验收（2026-10-19，FMR0223916114016）

先用「顶部垫片 + 自算 y 偏移（lineCenters）」实现，实测：

| 位置 | 活跃行 | 行心实测 | 目标 209.2vp | 误差 |
|---|---|---|---|---|
| 60% | 双行「在 哪里记载／第一个桃花贼」 | 207.7vp | 209.2vp | **−1.5vp** |
| 92% | 双行「爱 还是会期待／觉得孤单太失败」 | 194.8vp | 209.2vp | **−14.4vp** |

⇒ 按估算行高累加的坐标**会累积误差**（越往后的行偏得越多）。

改为向 List 要真实矩形（`scroller.getItemRect(index + 1)`，+1 是因为**第 0 项是顶部垫片**），
目标偏移 = 当前偏移 + (该项在视口里的中心 − 锚点)，实测：

| 位置 | 行心实测 | 误差 |
|---|---|---|
| 60% | 207.9vp | −1.3vp |
| 92% | 208.1vp | −1.1vp |

两处都收敛到 ±1.5vp 内，且**跨位置一致**（不再随距离漂移）。踩过的两个坑：
1. `getItemRect` 的索引含头部垫片，忘了 +1 会让目标永远差一行（第一次实测偏 +115vp）；
2. 垫片方案下不能再叠 `contentStartOffset`，两者语义会打架。

最终实现：`topSpacer(高度=锚点) + 歌词行 + bottomSpacer(高度=区域高−锚点)`，
`scrollTo(yOffset=targetOffsetFor(i), curve=springMotion(0.34,0.84))`，落位 520ms 后校验一次。

## 十、逐字高亮改「词内连续扫光」（2026-10-19）

Apple 的 `LineProgressGradientLayer` 不是「整段字一起变白」，而是在**词内部连续扫过去**
（他们把每个词的时长摊给音节/字形）。旧实现按 token 切 `alpha`，视觉上是一顿一顿的。

现在的实现（三种做法都试过，这是唯一既像又省的一种）：

| 做法 | 结论 |
|---|---|
| 逐 token 改 `alpha`（旧） | 每段整体跳变，一眼看出「顿」✗ |
| 整行亮层按行宽裁剪 | 中文一行常折成两三行，裁剪边跨行对不上 ✗ |
| **逐 token：灰底 + 白字副本按 `progress × 实测宽度` 裁剪** | 与 Apple 观感一致、不重排、不跨行 ✔ |

关键点：
1. `TokenVisual` 新增 `progress`（0~1）与 `widthVp`（用 `measureText` 按 Bold 实测，
   不能按字数比例算 —— 中英混排/标点差很多）；
2. 白字副本的 `Text` **固定宽度**（`widthVp + 1`），只有外面那层容器按 progress 收窄并
   `clip(true)`，所以裁剪过程中字不会被重新折行，边是干净的一条竖线；
3. 非活跃行不建白字副本（整页 30 行 × 6 段，白字层翻倍就是多画一遍字）；
4. `advance()` 每 100ms 直接算 `progress = (pos - 词起点) / (词时长)`，**不再叠 animateTo**
   （进度本身连续，再套动画会和心跳互相追，反而顿）；1.2 秒的四字词能拿到约 12 个中间态；
5. 换行时把上一行 `progress` 归零，否则那一行再次成为活跃行会先闪一下全白。

真机验证（注入 45% 进度单张截图）：活跃行里 `第` 字被从中间干净裁开，白/灰完全重合、无错位，
第二视觉行保持灰 —— 裁剪几何与坐标对齐都对。

## 十一、待查：起播约 1.7 秒后被「远程 pause」掉（2026-10-19 复现，与歌词无关）

真机日志：`state playing called` → 1.7s 后 `on pause , do pause task`（这是 **AVSession 远程暂停回调**，
不是 UI 或看门狗）。A/B 对照：**不进歌词页、纯封面页播放同样被暂停** ⇒ 与本次歌词改动无关。

影响：真机自检时播放头不动，歌词页没有活跃行，看起来「整页不高亮」（本轮因此走了弯路）。
待查方向：① 是否残留上一次会话的 AVSession（反复 force-stop 同一 bundle 后系统做会话交接时会向新会话发 pause）；
② `audioInterrupt` 是否被别的媒体抢占；③ 播控中心/蓝牙设备发来的 pause。

## 十二、逐字高亮最终形态：**字形级淡入**（2026-10-19，替代第十节的「裁剪扫光」）

第十节那版「白字副本按宽度裁剪」用户反馈：**像一条亮边从左往右滑过去**，不是字在浮现。
回看 Apple 的图层命名（`GlyphLayer` / `SyllableLayer` / `WordLayer` 三层并存）就能明白：
他们不是「一条移动的边」，而是**每个字/音节自己带着一小段时间窗，各自淡入**；
`LineProgressGradientLayer` 只负责边缘那一层柔化。

现在的实现：
1. **切分粒度 = 字形**：汉字（含假名/谚文/全角标点）一字一段；拉丁字母/数字**整词一段**
   （字母级会闪烁、也更耗节点）。空白并进前一段，避免 Flex 多一个折行点。
2. **词内时间按字数摊开**：第 g 个字占 `[g/n, (g+1)/n)`；`TokenVisual.fracStart/fracEnd` 记住区间。
3. **淡入用 `animateTo(Linear)` 走完自己的剩余时长**，不是每 100ms 写一次透明度 ——
   一个字的时间窗常常只有 150~300ms，心跳只有 1~3 个采样点，直接写值会看到台阶。
   为此引入 `TokenVisual.phase`（0 未开始 / 1 淡入中 / 2 已完成），只在阶段切换时动一次。
4. 提前 `GRAIN_LEAD_MS=140`（上限段长 35%）开始淡入，让相邻两个字的渐变**首尾重叠**，
   交界处不会有「谁都没在变」的空档。
5. 跳播/丢帧的自愈：`pos >= 段尾` 一律直接置白；切行/整列重算时 `phase` 归零。

真机验证（注入播放头钉在第 2 个词中间）：`哪里记载` 这四个字里 **「哪、里」已白、「记、载」仍灰**
—— 同一个词内部一半一半，证明渲染粒度已经是字形；而淡入过程由动画驱动，静态截图看不到中间态，
要判断顺滑度只能看真机播放（这也是为什么这一项必须你来验收）。


## 十三、iOS 26 官方规格（2026-10-19 实测，权威口径）

已获取当前最新 iOS 版 Apple Music（App Store 版本 3.8 / 2026-09-14）官方高清截图，
逐像素量出播放页与歌词页的完整规格，单独写成：

- 规格表：`docs/Apple iOS26 播放页-像素规格.md`
- 参考图：`docs/ref/apple-music-ios26-player.png`、`docs/ref/apple-music-ios26-lyrics.png`

**与本项目差异最大、且已确认的三条**：① 播控是**裸字形**（没有圆底）；② 进度条更粗（8pt）
且静止时**没有圆点**，右侧时间是**剩余时长带负号**；③ 歌词页非活跃行是**变小 + 真模糊**，不是同字号降透明度。
