# Apple Music iOS 26 播放页 · 像素级规格（实测）

参考图（已存仓库，可直接 `read_image` 复核）：

- `docs/ref/apple-music-ios26-player.png` —— 播放页（封面视图），Apple 官方 App Store 截图（版本 3.8 / 2026-09-14，即当前最新的 iOS 26 版 Apple Music）
- `docs/ref/apple-music-ios26-lyrics.png` —— 歌词页（带翻译），同一批官方截图
- `docs/ref/apple-music-ios26-store-sheet.jpg` —— 六张官方截图拼图（用于判断这是最新版）

来源：App Store 官方截图（`itunes.apple.com/lookup?id=1108187390` → `screenshotUrls`，
把 URL 尾部的 `320x480bb.jpg` 换成 `1200x0w.png` 即得高清图）。营销图为 iPhone 6.9 吋（440×956 pt）渲染后缩放到 1200 宽，
按「屏幕内容宽 911px = 440pt」换算，比例 **2.0705 px/pt**；下文所有数字均换算回 pt。

> 复核方法：屏幕左右边缘从像素剖面读出（左 144px / 右 1055px，中间是黑色边框），
> 用状态栏 `9:41` 的字宽（35pt）交叉验证过比例尺，误差 <2%。

---

## 一、整体结构（两页共用同一套底部控制区）

```
[状态栏 / 灵动岛]
（歌词页）拖拽把手 64×4.3pt，居中，y≈76pt
（歌词页）小封面 80×80 + 歌名/艺人 + ⭐ / ••• 两颗 37pt 玻璃圆钮
（播放页）封面：**满幅、贴顶、无圆角**，底边用渐变融入糊化背景
歌名 + 艺人（同字号，左对齐，x=35pt）
进度条（无圆点）
时间行：左「已播」／中「状态标签」／右「−剩余」
播控：上一首 / 播放暂停 / 下一首（**裸字形、无圆底**）
音量行：喇叭 + 细滑块 + 喇叭
底部图标行：歌词 / 隔空播放 / 队列（中心在 21.4% / 50% / 78.2%）
```

## 二、播放页（封面视图）实测值

| 元素 | 规格（440×956pt 参考机） | 换算到本项目（420×836.9vp） |
|---|---|---|
| 封面 | 满幅 440 宽、贴屏幕顶、**无圆角**，底边渐变淡出（不透明→透明） | 420 宽、贴顶、底部 80vp 渐变 |
| 内容左右边距 | 35pt（屏宽 8%） | 33vp |
| 歌名 | 20pt / 半粗 / 纯白 | 21vp / Medium |
| 艺人 | **同字号** 20pt / Regular / 白 0.58 | 21vp / 白 0.58 |
| 标题区右侧 | ⭐ 与 ••• 两颗 37pt 玻璃圆钮（白 12% 底），圆心 x=338 / 391 | 35vp 圆钮，右边缘距屏 30vp |
| 进度条 | 高 **8pt**、圆头；已播 白 0.6；未播 白 0.2；两端 36pt 边距 | 高 7vp，0.6 / 0.2 |
| 时间行 | 13pt，白 0.5；左 `0:04`（**无前导零**）、右 `−2:26`（**剩余**）；中间小标签（如「Mixing」「Sing」）13pt 白 0.85 | 已实现左/右 |
| 播控 | 裸字形：暂停两条竖杠 **33pt 高、14pt 宽、间隔 6pt**；上一首/下一首 43×33pt；三颗圆心间距 ±116pt | play_fill/pause_fill 44vp，前后 34vp，SpaceEvenly |
| 音量行 | 喇叭 17pt（x≈40 / 390）+ 滑块 304×8pt（已播 0.55 / 未播 0.2） | 待接 `avPlayer.setVolume` |
| 底部图标 | 3 颗，约 28pt，白 0.75，圆心 x = 94 / 220 / 344 | 21% / 50% / 78% 槽位 |
| 纵向节奏（自底向上） | 图标中心 73.5pt；音量 122pt；播控 228pt；时间行 304pt；进度 328pt；艺人底 374pt | 同比例（×0.955） |

**关键判据**：播放/暂停**没有圆底**，是纯白裸字形；进度条**静止时没有圆点**；右侧时间是**剩余时长且带负号**。

## 三、歌词页实测值

| 元素 | 规格 |
|---|---|
| 头部 | 小封面 **80×80pt**、圆角约 10pt，左边缘 35pt；歌名 18pt 半粗、艺人 18pt 白 0.6；⭐ / ••• 37pt 圆钮 |
| 活跃行 | **39pt 粗体**，纯白，行高 50pt，左对齐 36pt |
| 译文行 | 20pt Regular，白 0.72，紧贴活跃行下方（约 10pt 间距） |
| 非活跃行 | **约 26pt（0.68×）**，且**逐级模糊**（越远越糊），白 0.5→0.25 |
| 背景 | 整页是封面的**大幅模糊**（无深色幕布压黑，仅轻微压暗） |
| 底部 | 与播放页**完全相同**的一套控制区 |

> 这与 iOS 18 的差别就在「非活跃行变小 + 真模糊」：以前是**同字号 + 只降透明度**。

## 四、本轮已按此规格改动（2026-10-19）

1. 播控换成裸字形：`pause_round_triangle_fill/play_round_triangle_fill` → `pause_fill/play_fill`；尺寸 44vp，前后 34vp。
2. 进度条：`trackThickness` 4→7、`selectedColor` 白 0.6、`trackColor` 白 0.2、圆点透明（静止不可见）。
3. 时间行：右侧改为**剩余时长**（`−2:26`）、去掉前导零、13vp / 白 0.5。
4. 歌名与艺人改为**同字号**（21vp），只差字重与透明度（0.58）。
5. 底部图标行按官方槽位（21% / 78%）摆放，原来的右上角播放模式挪到这里；顶部只留收起按钮。
6. 歌词逐字高亮改为**字形级淡入**（见主文档第十二节）。

## 五、仍未对齐（按优先级）

1. **封面满幅贴顶 + 底边渐变淡出**：现在仍是「居中圆角方块 + 阴影」。
   难点：封面是与迷你播放条共享元素动画的定位节点（`coverLocalCx/Cy` 插值），
   改成满幅会牵动展开动画，需要重做几何。
2. **字幕/歌词页非活跃行「变小 + 真模糊」**：现在只有 `scale 0.94` + 透明度 + 整页渐隐遮罩。
3. **音量行**：需要给 `MediaService` 加 `setVolume` 并在 `MusicAppState` 回写。
4. **标题右侧 ⭐ / •••**：⭐ 需要「收藏当前歌曲」的写接口（`PUT /v1/me/ratings/songs/{catalogId}`，待做）。
5. **中置状态标签**（AutoMix / Sing 之类）与 **Up Next 队列**。

---

## 六、2026-10-19 第二轮：满幅封面 + 音量行 + 「译」上移（已真机验证）

### 1. 封面改成「满幅贴顶」
- `fullCoverSizeVp()` 由 `min(屏宽-48, 320)` 改为 **屏宽**（387.7vp），`targetCoverCy()` 改为屏宽/2（方图从 y=0 起），
  `coverRadiusVp()` 全屏态 **0**（只有歌词页小封面留 8vp），阴影只在歌词页小封面保留。
- **画在内容层之下**：满幅之后封面会盖住顶栏的收起箭头，所以把 Image 块移到内容层之前（歌词层之后）。
- 底边不是硬边：`linearGradientBlur(26, [[0,0],[0.66,0],[1,1]], Bottom)` + 一层 86vp 的
  透明→黑（0 → 0x24 → 0xA6）渐变纱。**ArkUI 的 `mask()` 只支持几何形状（Circle/Rect/Path/ProgressMask），
  没有 alpha 渐变遮罩**，所以只能用「模糊 + 黑纱」逼近官方的「照片融进背景」。
- 歌名区 margin 改成 `屏宽 + 26 − 顶栏底边`（`topBarBottomVp()`）：满幅封面之后歌名紧跟可见底边，
  真机实测歌名顶边落在屏高 52%（官方 56.5%）。

### 2. 音量行上线
- 新增 `MediaService.setVolume(v)`（钳制 0~1，同时回写 `MusicAppState.volume`）。
- 播放页在播控与底部图标之间加了官方那一行：`speaker_fill` + 细滑块（7vp 轨、白 0.55/0.15）+ `speaker_wave_3_fill`。
  顺带填掉了原来「播控与底部图标之间空一大块」的空洞。

### 3. 「译」从右下角挪到右上角
- 用户反馈歌词页右下角那颗「译」位置别扭。现在放在**歌词页头部同一行的最右端**：
  36vp 玻璃圆钮（底 白 20% / 开启态 33%），与左上角「小封面 + 歌名」同一水平线。
- 状态从 `LyricsComponent` 的 `@Local` 上移到宿主 `PhonePlaybackPage`（`@Param showTranslation` + `@Event onToggleTranslation`），
  并删掉 `LyricsComponent` 底部那一整行工具图标（官方没有那一行）。
- 注意层级：它必须排在「返回播放页」的整宽热区**之后**，否则点击会被那条热区吞掉。

### 4. 真机实测位置（对比官方比例）
| 元素 | 本项目（屏高 837vp） | 官方（屏高 956pt） |
|---|---|---|
| 封面可见底边 | 46% | ~54% |
| 歌名顶边 | 52% | 56.5% |
| 进度条 | 62% | 65.7% |
| 播控中心 | 75% | 76.2% |
| 音量行 | 83% | 87.2% |
| 底部图标 | 95% | 92.3% |

仍差：官方封面区域比「屏宽方形」更高（约 1.17:1，会把方图上下裁一点），我们目前还是正方形。

---

## 七、2026-10-19 第三轮：封面回退 + ⭐收藏/分享 + 歌词尺寸分层

### 1. 封面回退成「居中圆角方块 + 阴影」（用户拍板）

官方 iOS 26 是「满幅贴顶」，但用户明确说之前那版更好看，所以保留原形态：
`fullCoverSizeVp() = min(屏宽−2×24, 320)`、居中、16vp 圆角、24 阴影；
同时**删掉**满幅时代的两件东西（`linearGradientBlur` 底边模糊 + 86vp 黑纱渐变）。
封面节点仍留在**内容层之下**（满幅时为了不盖住顶栏改的顺序，对小方块无害且更稳）。

### 2. 标题右侧加 ⭐ 收藏 + 分享（官方同位置的两颗 36vp 玻璃圆钮）

- 收藏写入：先 `PUT/DELETE /v1/me/ratings/songs/{目录id}`，非 2xx 自动回退
  `POST/DELETE /v1/me/favorites?ids[songs]={目录id}`（艺人就是后者那一套，两个都留着兜底）。
- 读状态 + 取目录 id：`GET /v1/me/library/songs/{i.xxxx}?include=catalog&extend=inFavorites`。
  **资料库歌曲 id 形如 `i.xxxx`，不能直接拿去收藏**（与专辑同一个坑）。
- 当前曲目 → 资料库 id：`state.getCurrentSongItem().src` 形如 `apple:i.xxxx`，截掉前缀。
- 换歌判重：只在 libId 变化时请求；回包回来若 libId 已变则丢弃（防串台）。
- UI 乐观更新：Apple 侧约 6 秒才传播到 inFavorites，所以点击立刻翻转，失败回滚 + Toast。
- 分享：`@kit.ShareKit` 的 `systemShare.ShareController`，内容 = `歌名 - 艺人` + Apple Music 链接
  （`https://music.apple.com/cn/song/{目录id}`，拿到目录 id 才有）；`utd='general.plain-text'`。

### 3. 歌词非活跃行按官方比例缩小

官方实测（iOS 26 歌词页）：活跃行 39pt、其余行约 26pt ⇒ **0.67**。
原来 `0.975/0.95/0.93` 三档几乎看不出差别，等于「聚焦感全靠亮度」；
现改为 **0.84 / 0.74 / 0.68**（紧邻 → 最远），仍用 `scale` 变换，不动布局与滚动定位。

### 4. 真机验证

- 封面页：居中圆角封面 + 阴影回来了；标题行右侧两颗玻璃圆钮（☆ / 分享）位置与官方一致；
- 歌词页：`在 哪里记载…` 大字、往下逐级变小，层次明显（截图对比第三轮前后）。

---

## 八、分享：为什么必须是「链接」而不是拼文字（2026-10-19）

### 结论
Apple Music 的分享面板分享的是**歌曲链接**；微信/QQ/微博 拿到链接后自己去抓该页面的
Open Graph 标签，于是渲染成「大封面 + 歌名艺人 + Apple Music」的卡片。自己把歌名艺人拼成
一段文字发出去，对方只会看到纯文本，永远不会生成卡片。

### 实测证据（2026-10-19）
```
curl "https://music.apple.com/cn/song/535824738"（iPhone UA）
→ 200
og:title       Apple Music 上周杰伦的歌曲《晴天》
og:description 歌曲 · 2003年 · 时长 4:29
og:image       https://is1-ssl.mzstatic.com/.../1200x630wp-60  ← 社媒卡片大图
og:type        music.song
```
注意：`/cn/album/{id}?i={id}` 这种拼法是 404，**歌曲分享只能用 `/cn/song/{songId}`**。

### 实现（PhonePlaybackPage）
- `resolveCatalogSongId()`：目录曲目（`src = apple:<纯数字>`）直接用；资料库曲目（`apple:i.xxxx`）
  先复用收藏流程已取到的 `favCatalogId`，没有才请求 `include=catalog`。
- `utd: UniformDataType.HYPERLINK`（不是 PLAIN_TEXT）+ `content = 链接` + `title = 歌名 - 艺人`
  + `description = Apple Music`；拿不到目录 id 时才退化为纯文本。
- 不传 `thumbnail`：让微信按 og:image 渲染，才会得到 Apple Music 那种整块封面卡片。

### 朋友圈的真实限制
- 系统分享面板 → 微信：只能发到**会话**（微信不开放「外部直接发朋友圈」的入口）。
- 朋友圈：把链接分享到会话/复制后，**在微信里打开链接 → 右上角「…」→ 分享到朋友圈**，
  此时微信用同一套 og 信息生成带封面卡片。这是微信的产品设计，不是本 App 能绕的。
- 唯一能直接调 `WXSceneTimeline` 的路是微信开放平台鸿蒙 SDK（`@tencent/wechat_open_sdk`），
  需要注册应用拿 AppID + 上传应用信息审核 + 签名绑定；本 App 个人自用不上架，走不通。

---

## 九、Apple Music「带封面分享」的真相（2026-10-19 查证 + 实测）

### 1. 那层封面到底是什么

Apple Music 的「分享歌曲带封面」= **标准链接预览（Open Graph 卡片）**，不是图片、也不是私有协议。
iOS 上看起来最漂亮的那种卡片（iMessage 里带封面 + 播放按钮）是苹果自家的
[LPLinkMetadata](https://developer.apple.com/documentation/linkpresentation/lplinkmetadata) 富链接，只在苹果生态内生效；
出了苹果生态（微信/QQ/微博/Telegram/X），谁抓 `music.apple.com` 页面的 og 标签，谁就能画封面卡片。

### 2. 实测 Apple 歌曲页的 og 标签（`curl -L`，iPhone/微信 UA 都一样）

```
https://music.apple.com/cn/song/535824738
→ 301 → https://music.apple.com/cn/song/晴天/535824738  → 200（187KB）
og:title        Apple Music 上周杰伦的歌曲《晴天》
og:description  歌曲 · 2003年 · 时长 4:29
og:image        …/JAY.jpg/1200x630wp-60.jpg      ← 1200×630，正是社媒/朋友圈横版卡片尺寸
og:image:width  1200 / og:image:height 630 / og:type music.song
twitter:image   …/600x600bf-60.jpg（方版，另一套）
```
- `og:image` 的 CDN **允许外链直取**（无 referer 也 200 / image/jpeg），所以微信抓图不会失败。
- **slug 写错也没关系**：`/cn/song/WRONGNAME/535824738` → 301 回带正确歌名的地址，仍 200 且 og 完整。
  ⇒ 所以可以自己拼 `https://music.apple.com/cn/song/{encodeURIComponent(歌名)}/{目录id}`，
  命中规范地址时**零跳转**，对微信爬虫最友好（Apple Music 自己分享的就是这个形式）。

### 3. 因此本 App 的做法（已实现）

`utd: HYPERLINK` + `content = 规范链接` + `title = 歌名 - 艺人` + `description = Apple Music`；
**不塞 thumbnail**（微信会用 og:image 的 1200×630 封面绘制整块卡片，塞了反而可能降级成图片消息）。

### 4. 朋友圈这一步的真实边界

- 系统分享面板 → 微信：只能**发到会话**（微信不开放"外部直接发朋友圈"的入口；面板里也只列 微信/QQ/企业微信）。
- 朋友圈：**在微信里打开这条链接 → 右上角 … → 分享到朋友圈**，微信会用同一套 og 信息生成带封面卡片。
  也可以在分享面板里选「复制」，到微信里粘贴（微信会把它展开成卡片）。
- 想"一键直达朋友圈"只有微信开放平台 SDK（ohpm `@tencent/wechat_open_sdk`，腾讯官方，1.0.23）
  的 `WXSceneTimeline`，但需要 AppID + 应用信息审核 + 签名绑定；个人自用不上架的项目走不通。

参考：[知乎·为什么 Apple Music 在微信的分享连个封面都没（2017 旧结论，当时 Apple 页面还没 og:image）](https://www.zhihu.com/question/58950210)、
[知乎·怎么把 Apple Music 分享到朋友圈](https://www.zhihu.com/question/53212515)、
[微信链接卡片三要素（标题/描述/缩略图）](https://www.sdsdsoft.com/article/news-show/detail?id=3038)

---

## 十、音量跟随系统 + 歌词交互与逐字填充（2026-10-19 晚）

### 1. 音量：唯一真源 = 系统媒体音量

- **官方规则（《音量面板》文档原文）**：应用**不能直接调节系统音量**，只能通过
  `AVVolumePanel` 让用户在面板上调节；自定义音量条应订阅音频框架的
  `streamVolumeChange`，用真实音量画自己的 UI。
- 读：`AudioVolumeManager.getVolumeByStream(STREAM_USAGE_MUSIC)` +
  `getMin/MaxVolumeByStream` 换算成 0~1（API 20 起同步接口）。
  订阅 `on('streamVolumeChange', STREAM_USAGE_MUSIC, cb)`；
  **`off` 只接受 2 个参数**（type + callback），带 streamUsage 会编译报错。
- 写：滑块拖动只给 `AVVolumePanel` 的 `volumeLevel` 赋值，由面板把系统音量改掉
  （真机实测：面板档位 3 → 系统 `getVolumeByStream` 立刻读到 3，改 12 → 读到 12）。
  面板按 1% 不透明度铺在音量行底下、`hitTestBehavior(None)`，观感仍是那条细线。
- 播放器自身音量**钉在 1.0**（`MediaService.applySystemVolumeLevel`）：
  以前音量行改的是 `avPlayer.setVolume`，与系统音量叠成两层乘法，侧键推满也还是偏小。
- 拖动结束回读一次真实档位（150ms 后）：面板万一没受理，滑块立刻回到真实音量，
  永远不会显示一个不存在的音量。

### 2. 歌词：锚点下移 + 上下文滑动 + 点击跳播

| 项 | 实现 |
| --- | --- |
| 活跃行位置 | 歌词区高度的 52%（`ACTIVE_IN_AREA`），真机实测居中线 ≈ 屏幕 51%，即「中间靠下」 |
| 上下文 | List 渲染全部行；上下缘 `linearGradientBlur` 渐隐 + 行级 `fade`/`scale` 分层 |
| 手动滑动 | `onTouch`/`onScrollStart`/`onScrollStop` 记录**用户滚动**（用「距上次程序化滚动 >500ms」区分），进入「浏览」态 |
| 停手回位 | 浏览态 4s 后自动回位到当前句（`wasBrowsing` 跳变时无条件 `scrollTo(idx, true)`）。真机实测：滚到 318vp → 4s 后回到 58vp |
| 点击某句 | `onTap → jumpTo(line.startMs)`：清浏览态 + `MediaService.seek()`，列表随即弹到该行（实测 pos 跳到 41668ms、offset 174→482） |

### 3. 逐字：整词从左到右填充 + 轻微弹跳

旧实现是「每段透明度在自己那段时间里淡入」→ 视觉上**整段一起由暗到亮**。
官方是**整词从左往右填**。现在的做法：

- 每个字形渲染成 `Stack { 灰底 Text; 白字 Text（外层容器宽 = 实测宽度 × fill，clip） }`；
  `fill` 在字形自己的时间窗内 0→1（`animateTo` Linear，渲染线程插值，不靠 100ms 心跳写值）。
- **宽度必须实测**（`MeasureUtils.measureText` + Bold + letterSpacing）。
  曾用百分比宽度：百分比按父级约束解析 → 外层 Stack 被撑成整行宽 → Flex 每段独占一行，
  真机表现为「一个字一行竖着排」。只量当前行（十几段），字号变化才重量。
- 按**字形**裁剪而不是整行裁剪：整行裁剪时移动的是贯穿整行的硬边（「亮边往右滑」，被否）；
  按字形裁剪硬边只在一个字宽内移动，读起来就是「这个字被填满」。
- 弹跳：字形填满的一瞬间 `pop` 1.055 → 1（`springMotion(0.26, 0.42)`），
  只在「正在填→填满」时触发，跳播补帧不弹。
- 行切换：上一行白层 260ms 淡出后折叠回单层灰字（`animateTo(onFinish)`），不硬切。
