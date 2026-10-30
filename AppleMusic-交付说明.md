# 鸿蒙音乐播放器 · Apple Music 版 交付说明

> 2026-09-12 交付。音源已从「导入本地音乐」整体切换为**你自己的 Apple Music 订阅账号**。
> 只供个人使用，不上架、不走 App Store，也不需要 Apple Developer 账号（省掉 688 元/年）。

---

## 一、安装

构建产物：

```
products/default/build/default/outputs/default/musichomesample-default-signed.hap
```

安装到手机（手机需开「开发者模式 + USB 调试」，用数据线连着电脑）：

```bash
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc \
  install -r /Users/jishanqiuwang/vibecodingforharmony/products/default/build/default/outputs/default/musichomesample-default-signed.hap
```

也可以用 DevEco Studio 打开工程直接 Run（模块 `musichomesample`，设备选 ALN-AL00）。

重新构建：

```bash
cd /Users/jishanqiuwang/vibecodingforharmony
HVIGOR_USER_HOME=/tmp/hvigor_home npm_config_cache=/tmp/npm_cache \
NPM_CONFIG_USERCONFIG=/tmp/npmrc \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default \
devecocli build --modules musichomesample
```

---

## 二、怎么用

### 1. 登录（只需一次）

首次打开如果还没登录，会自动弹出**全屏登录页**（内嵌 Apple 官网的登录页面）：

1. 输入 Apple ID（邮箱/手机号）→ 继续
2. 输入密码 → 完成双重认证
3. App 检测到登录 cookie 后**自动**：抓 developer token → 读资料库 → 关掉登录页

登录态存在 App 私有 Preferences 里，之后启动自动恢复。想换账号：目前需在系统设置里清除 App 数据（或卸载重装）。

> 也可以随时手动开登录页：艺人页空态里的「登录 Apple Music」按钮。

### 2. 四个板块

底部悬浮胶囊栏四个页签，内容全部来自你的 Apple Music 资料库：

| 页签 | 内容 |
|---|---|
| 艺人 | 资料库里的艺人，按名称排序；头像取该艺人**最早**发行专辑的封面；点进去看他的专辑并能直接播 |
| 专辑 | 资料库里的专辑网格，按发行年份由早到晚 |
| 歌曲 | 资料库全部歌曲，可按歌名/歌手/专辑搜索 |
| 歌单 | 你自己在 Apple Music 里建的歌单；点进去看曲目、播放全部 |

四个页签顶部都有搜索框；艺人页左上角有**同步按钮**（🔄）和**外观切换按钮**（跟随系统/亮/暗）。

### 3. 播放

点任意一行即开始播放，播控条在底部胶囊栏右侧（点一下=播放/暂停，向左滑=展开）。

- **首次播放某一首**：需要联网「下载 + 解密」，会弹一条「正在加载并解密歌曲…」提示，**同时播放条上会转圈**（折叠态转圈代替播放图标，展开态显示「正在加载 xx…」）
  - 快网约 **1~2 秒**；慢网或大文件（二十多 MB）约 **15 秒**（实测同一首歌，下载耗时会在 0.2s ~ 19s 之间波动，取决于当下网速与文件大小）
- **切下一首**：当前曲目开始播放时，App 已经在后台把**下一首**下载解密好了，所以切歌基本是秒开
- **再次播放**：直接走本地缓存，秒开、可离线
- **万一某首放不出来**：会明确告诉你原因（如「这首歌暂时放不了：HTTP 403」），并自动把可能有问题的缓存清掉，**再点一次就会重新下载**，不会卡死

> **屏幕常亮**：App 在前台时会保持屏幕常亮（`setWindowKeepScreenOn`），不熄屏、不挂起，方便长时间播放与调试。

### 4. 缓存策略（已按约定设定）

- 上限 **3GB**，超出后按 **LRU**（最久没用过的先删）清理到 90%
- 被标记为「保留（pinned）」的歌曲永不自动清理（标记入口尚未接入 UI，需要时再加）
- 文件位置：`<应用缓存目录>/apple_music/<歌曲ID>.m4a`，索引持久化在 Preferences
- **写入是原子的**（先写 `.part` 再改名），且命中缓存时会校验文件大小；下载被中断留下的半截文件不会污染缓存
- 启动时会自动扫一遍缓存，清掉损坏条目和残留的临时文件

### 5. 性能数据（2026-09-12 真机实测）

| 阶段 | 优化前 | 优化后 |
|---|---|---|
| 解密（3.87MB / 5152 samples） | 4629 ms | **339 ms**（13.6×） |
| 整曲下载+解密（同上） | 6102 ms | **1575 ms** |
| 同上，网络慢时 | 单请求 5697 ms | 4 路并发 **2578 ms**（2.21×） |

> 解密提速的诀窍：CENC 是 per-sample 加密的，原来每个 sample 都重建一次密钥和 cipher（5162 个 sample = 两万多次异步调用），改成「密钥只转一次 + cipher 对象池 + 8 路并发」后固定开销基本消失。优化前后的产物 **SHA256 完全一致**（已逐字节比对验证）。

---

## 三、这次改了什么

### 删掉的（按用户要求）

| 内容 | 说明 |
|---|---|
| 导入外部音乐功能 | `MusicLibraryScanner`（文件夹扫描/多选导入）、`MusicFolderStore`（文件夹授权持久化）、`SampleMusicLoader`（示例音乐）全部删除 |
| 系统分享接收 | `ShareReceiveAbility` + `ShareLoading` 页面删除（不再能从别的 App「分享到音乐库」） |
| 艺人页工具栏 | 「导入音乐」「清空数据」两个按钮删掉，换成「同步资料库」 |
| 空态引导文案 | 由「点击导入音乐…」改成「登录 Apple Music 账号后，你的资料库会自动同步到这里」 |
| **历史导入的音乐数据** | 你之前导入的 **742 首**本地歌曲及其沙盒副本已清空（判据 `apple_id = ''`，一次性幂等） |
| 相关权限 | 去掉 `ohos.permission.FILE_ACCESS_PERSIST`（导入文件夹授权专用） |

删除的原文件备份在 `backups/removed-import-feature/`，需要可随时取回。

### 新增/改动的

- **Apple Music 音源层**：`common/musicbasic/src/main/ets/apple/` —— 认证、资料库/歌单接口、HLS 解析、MP4 box 解析、CENC(AES-CTR) 解密、纯 ArkTS 实现的 Widevine L3 CDM
- **全屏登录页**：`features/library/src/main/ets/view/AppleLoginView.ets`（ArkWeb 内嵌 music.apple.com）
- **歌单板块**：`PlaylistsPage.ets` + `PlaylistDetailPage.ets`，路由登记在 `features/library/src/main/resources/base/profile/router_map.json`
- **播放链路接入**：`features/player/.../SongItemBuilder.ets` 增加 `apple:<歌曲ID>` 分支——命中缓存直接播，未命中就先下载解密。播放器主体（MediaService / AVPlayer / 播控条）**没有改动**
- **预加载**：`MediaService.applySongSource` 在当前曲目就绪后调 `AppleCache.preload(下一首)`
- **数据库**：新增 `apple_playlists` 表；`songs` 表新增 `apple_id / cached_path / cover_url / pinned / is_library` 五个字段（ALTER 迁移，老数据不丢）

---

## 四、技术要点（想自己继续改的话看这里）

1. **完全不需要 Apple Developer 账号**
   - developer token：从 `music.apple.com` 首页的 `index.js` 里正则抓现成 JWT（约 70 天有效，App 每次启动自动刷新）
   - user token：用户在 ArkWeb 里正常登录后，从 cookie 里取 `media-user-token`
2. **DRM 在纯 ArkTS 里解**：Widevine L3 CDM（RSA-PSS(SHA1) 签名 + AES-CMAC 派生会话密钥 + AES-CTR 解 CENC），**没有用 NDK**。注意鸿蒙签名要显式 `setSignSpec(PSS_SALT_LEN_NUM, 20)`（默认 MAX=234 会失败）
3. **音质**：`28:ctrp256`，AAC 256kbps（与 Apple Music 网页版同档）
4. **取 license 的关键**：必须用 `webPlayback` 返回的 `songList[0].songId`（catalog 数字 id），**不是**资料库 id（`i.xxx`）——否则返回 `{"status":-1003}`
5. **全曲一个 MP4**：约 9MB，子清单用 `#EXT-X-BYTERANGE` 切片，解密后是标准 m4a，可直接给 AVPlayer 播
6. **必须删掉 `moov` 里的 `pssh`（这是「一半歌点了没反应」的根因）**
   Apple 给**部分曲目**下发的 fMP4 在 `moov` 末尾带一个 **484 字节的 `pssh`**（Widevine 的 `Protection System Specific Header`），另一部分没有。音频虽然已经被我们解密成明文，但 `pssh` 还在 —— **鸿蒙 AVPlayer 据此认为这是受 DRM 保护的曲目，去等一个永远不会到来的许可授权，于是 `prepare()` 永不完成、`state` 永远停在 `initialized`、`duration` 恒为 -1**。
   - 修复：`common/musicbasic/src/main/ets/apple/Mp4Cleaner.ets` 的 `stripPssh()`，在写文件前从 `moov` 子树里删掉 `pssh`
   - **只动 `moov`，绝不动 `moof`/`traf`**：`pssh` 在 `moov` 末尾，删除只改变 `moov` 长度、不影响任何相对偏移（`trun.data_offset` 是相对 `moof` 起点算的）；而在 `moof` 里删 box 必须同步修 `data_offset`，而且**实测删掉 `senc`/`saiz`/`sinf` 会让 AVPlayer 在 native 层直接崩溃退进程**
   - 重建容器时**只递归真正的容器 box**，叶子 box（尤其 `stsd`、采样条目）必须原样拷贝 —— 它们是带固定头的结构，当容器递归会丢头、把文件搞坏

---

## 五、已知限制

| 限制 | 说明 |
|---|---|
| 「喜爱歌曲」这类自动歌单打不开曲目 | Apple 官方对这类歌单的 `/tracks` 接口固定返回 404，不是 App 的问题，页面会明确提示 |
| 歌单列表不显示曲目数 | Apple 的资料库歌单接口不返回 trackCount，列表统一显示「打开查看曲目」，进详情才显示真实数量 |
| 首次播放要等几秒 | 需下载+解密（快网 1~2 秒；二十多 MB 的大文件慢网下约 15 秒），现已转圈 + toast 提示；之后的切歌靠预加载基本秒开 |
| 离线只能播缓存过的歌 | 缓存上限 3GB |
| 换 Apple 账号 | 目前要清 App 数据 |
| 歌词 | 未接入（Apple 没有开放网页版歌词接口） |
| 手机→手表传输 | 旧代码还在（`MusicTransferService`），但现在资料库里是 Apple 音源，手表端拿不到可播的文件——按你之前说的「分布式不用做了」，这块建议下次一并删掉 |

---

## 六、回滚

改造前的完整源码备份：

```
backups/musichome-before-applemusic-20260911-214027.tar.gz   # 改造前（含本地导入）
backups/musichome-applemusic-only-20260912-171811.tar.gz     # 改造后（Apple Music 版）
backups/removed-import-feature/                              # 删掉的 5 个导入相关源文件
```

回到改造前：

```bash
cd /Users/jishanqiuwang/vibecodingforharmony
tar -xzf backups/musichome-before-applemusic-20260911-214027.tar.gz
```

> 注意：数据库结构有 ALTER 迁移（只增列、不删列），回滚代码后老版本仍能正常读到自己的数据；但被清掉的 742 首导入歌曲**不会**自动回来，需要重新导入。


---

## 搜索板块 UI / 动效一致性（2026-09-13）

用户要求：搜索页里所有界面效果与动画都与已有板块保持一致，含「长按封面进艺人页」与
「从详情页退出的动画」。本轮把搜索 tab 彻底对齐专辑/艺人板块：

### 1. 结构：搜索 tab 现在也有 Shell + 首页 NavDestination
- 新增 `SearchTabShell` + 路由 `SearchHome`，`SearchPage` 本体改成 `HdsNavDestination`。
- 原因：官方规定共享元素转场（geometryTransition）只在**两个 NavDestination 之间**
  生效，Navigation 的首页内容做不了共享元素源 —— 这也是专辑/艺人板块早就 Shell 化的
  同一个原因。改完后「点封面 → 专辑详情」「点艺人行 → 艺人页」才真正有英雄转场。

### 2. 视觉四件套与其它板块逐项对齐
| 项 | 实现 |
| --- | --- |
| 整屏流光背景 | 官方 `UV_BACKGROUND_FLOW_LIGHT`（#317AF7 / #8A8E96，8s 循环）+ `FlowLightRegistry.KEY_SEARCH`，切 tab / 被覆盖时自动暂停 |
| 顶部标题栏 | HDS `GRADIENT_BLUR` + 毛玻璃搜索条（92% 宽居中、按压缩放 `responsiveSpringMotion`、按下点亮官方点光源） |
| 大标题 | 「搜索」34fp 粗体 + 副标题统计，随滚动 130vp 淡出 |
| 点光源 | 页面 Stack 内固定 2×2 源点，位置弹簧跟随手指；卡片只留受光面（DEFAULT_FEATHERING_BORDER） |
| 列表行 | 歌曲用 `SongListItem`（按压白光 + 正在播放高亮/呼吸图标），艺人用复刻艺人板块的 `CatalogArtistRow`（毛玻璃圆头像 + pressShadow + 右箭头） |

### 3. 转场动画
- **点专辑封面 → 专辑详情**：`geometryTransition` 共享元素飞入（作用域 `search-tab`），
  详情页内容随后从落点生长出来；返回反向缩回。
- **点艺人行 → 艺人主页**：圆形头像作为共享元素飞入。
- **长按专辑封面 → 艺人主页**：没有圆形头像可共享，用艺人页现成的「从被点封面位置
  生长 / 缩回」动画，英雄区头像直接取 Apple 目录里的艺人头像。
- **返回**：艺人页与专辑页都改成按 `activeStack()`（本页实际压在哪条栈）弹出并播放收缩
  动画 —— 修掉了「从搜索页进入艺人页后按返回没反应」的死结。

### 4. 顺带修掉的三个体验问题
1. **长按「没反应」**：原实现要串两次网络请求才推页。现在
   `AppleApi.catalogAlbumArtist()` 一次请求同时拿艺人 id/名称/头像，并加内存缓存；
   搜索结果一返回就在后台预热前 6 张专辑 → 长按基本即时进页。
2. **详情页闪一帧空页面**：路由参数新增 `coverUrl`，详情页的大图与毛玻璃背景先用目录
   封面撑住，标题栏在曲目未到时显示「正在读取曲目…」，列表插入一条「正在读取目录
   曲目…」占位行。
3. **从搜索长按进的艺人页是空白页**：旧判据「本地专辑数为 0 就当空页面」对
   「资料库里没有这位艺人」的情况完全错判（连收藏按钮都点不到）。现在判据改为
   「目录作品 + 本地唱片都没有、且已读取完毕」才算空；收藏时带 `catalogArtistId`
   的走按 id 取全部作品，不再猜名字。

### 5. 验证
- `tools/apple-music/build.sh` 编译通过；`hdc install -r` 覆盖安装；`aa force-stop` +
  `aa start` 重启后 `hilog` 无异常，`SearchHome` 的路由告警与其它三个 tab 完全一致
  （属良性噪声）。UI 动效由用户真机手动验收。


---

## 这一轮：黑屏修复 + 艺人页音乐板块 + 收藏横排动画 + 切 tab 提速（2026-09-13）

### 1. 主页面按返回黑屏（最严重）——已修
**症状**：任意主页面按系统返回 → 整屏只剩底色（深色模式下就是黑屏），只能重启 App。

**根因**：四个板块的首页（艺人 / 专辑 / 歌单 / 搜索）本身就是各自导航栈里压着的
**第一页**，返回键把它也弹掉了 → 栈变空 → 没人再把它压回来（Shell 只在
`aboutToAppear` 里压一次）→ 页面只剩底色。搜索页上一轮改成 NavDestination 之后
也加入了这一行列，所以感觉「哪个主页面都会黑」。

**修法**（`features/library/src/main/ets/util/HomeBack.ets`，四个首页统一调用）：
- 设置抽屉开着 → 先关抽屉（返回键的常规语义）；
- 否则 `moveAbilityToBackground()` 回桌面 —— 音乐继续后台播放（音乐类 App 顶层的
  标准返回行为）；
- **任何情况下都消费掉返回事件**，首页永远不会被弹出。

### 2. 艺人页按音乐板块分区
- 数据来源：Apple 资料库接口的 `attributes.genreNames`（每首歌/每张专辑都自带），
  **不额外发请求**；歌曲表新增 `genre` 列（含老库 ALTER 迁移 + 歌单曲目行的补写）。
- 归类规则：`common/musicbasic/src/main/ets/util/GenreBuckets.ets` 关键词映射 →
  流行 / 古典 / 爵士 / 摇滚 / R&B/灵魂 / 电子/舞曲 / 嘻哈/说唱 / 民谣/唱作 /
  原声/配乐 / 世界音乐 / 其他；艺人取其曲目的众数板块。
- 列表改为「板块标题行 + 艺人行」混排（LazyForEach 同一数据源），板块顺序固定、
  空板块不显示、板块内保持原排序。
- 真机实测分布：**流行 52 / 古典 34 / 爵士 16 / 摇滚 18 / R&B/灵魂 11 /
  电子/舞曲 11 / 原声/配乐 2 / 世界音乐 3 / 嘻哈/说唱 1 / 其他 4**（共 152 位艺人）。
  （日志行：`MusicDatabase | 艺人板块分布: …`，可随时自查。）

### 3. 收藏的艺人横排：可以左右滑、点开/退出都有动画
- 横排本来就是横向 Scroll；这轮补上**共享元素头像**（`HeroArtwork` + 独立的
  `artist-hero-fav-*` 作用域，避免与下方同名艺人撞 id）+「点按弹簧缩放」反馈，
  并把卡片在窗口中的位置作为详情页生长/缩回的锚点。
- 效果：从收藏横排点进去、返回时，头像都会与下方列表行一样飞入/飞回。

### 4. 切换 tab 变快
- `HdsTabsController.preloadItems([4])`：启动 1.5s 后**在后台把搜索页先建好**
  （TabContent 默认「首次显示才创建」，第一次点搜索要现建整页 —— 流光 shader +
  标题栏 + 列表 —— 用户能感到明显等待）。日志确认：`preloadItems: 搜索页已预建完成`。
- `.cachedMaxCount(5, TabsCacheMode.CACHE_LATEST_SWITCHED)`：已访问过的 tab 页不再
  销毁重建；页面数据刷新本来就靠 `LibrarySignal`，常驻不会变旧。
- 资源开销：最多多留 4 个 tab 页在内存（懒列表 + 已暂停的流光 shader），
  属于可接受范围；换来的是切 tab 不再重建整页。


---

## 这一轮：收藏横排滑不动 / 拖动排序 / 流光不动 / 切 tab 更顺（2026-09-13 第二轮）

### 1. 「收藏横排左右滑不动」「长按拖动有 bug」的同一个根因
根容器（Index 的根 Stack）上挂着一个**整屏的横向 `priorityGesture`（distance 4）**，
它是当初为了「任意页面向右滑拉出设置抽屉」加的。priority 意味着它抢在所有内容
手势之前：页内任何横向拖动（横向列表滑动、长按拖动排序）都被它吃掉了 ——
所以「滑不动」和「拖动有 bug」是同一个原因，跟收藏横排本身无关。

改法：抽屉手势**只挂在两条很窄的组件**上，不再挂整屏。
- 左侧 `x = 24~56vp`、整高的窄条（`HitTestMode.Transparent`，自己不画东西、
  也不影响下面内容的点击）：从 24vp 起是为了躲开系统返回手势区；
- 抽屉面板自己（开着时在它上面左滑即可收起）。

验证：`uitest dumpLayout` 里收藏横排是 `scrollable=true`，抽屉窄条
`bounds=[78,0][182,2720] hitTestMode=Transparent z=5`。

### 2. 收藏艺人排序（长按拖动，和桌面图标换位一样）
- 横排从 `Scroll + Row` 换成官方横向 `List`（左右滑动是它的原生能力），
  并接官方 item 拖拽四件套：`onItemDragStart` / `onItemDrop`（+ 浮起回显 builder）。
- **过渡动画**：落位时 `animateTo(springMotion)` 让其它卡片平滑让位（不是瞬移）；
  拖走的那张原位淡出（0.25 透明度），跟手的是放大 + 投影的浮起卡片。
- **震动提示**：拿起 40ms、落下 20ms（官方 `vibrator`，新增
  `ohos.permission.VIBRATE`；失败静默，不影响交互）。
- **排序持久化**：`favorite_artists` 新增 `sort_order` 列（含老表迁移），
  拖动后写回；新收藏的排在最后；没排过的仍按收藏时间。
- 修掉官方样例的一个坑：样例里 `insertIndex >= arr.length` 直接 return，
  导致「拖到最右端」是空操作（用户实测就是这里像 bug）。现在把插入位置钳制到
  `[0, length]`，并处理「先摘出再插回、向后拖时插入点左移一位」。

### 3. 流光效果：背景不动，只有上面的 UI 动
- 以前**每个板块页各带一层** `UV_BACKGROUND_FLOW_LIGHT`，节点在 TabContent 里，
  所以左右切 tab 时背景跟着页面一起滑。
- 现在整个 App **只有一层**，放在 `HdsTabs` 外面（根 Stack 的第一层）：
  切 tab、push 详情页都不动它，只有上层内容在动。
- 附带收益：全屏 shader 从 5 个降到 1 个，显存/合成开销明显下降（发热时的滑动卡顿
  主要就是这类全屏特效在抢渲染预算）。

### 4. 卡顿与「首次进入黑一下」
- 流光节点**延后到首帧之后**再创建（260ms）：shader 第一次编译要占渲染预算，
  之前和页面内容抢同一帧，表现就是「首次进入某个板块先黑一下」。
- **分批预建**全部 tab 页（`TabsController.preloadItems`，官方 API）：
  启动后 1.5s / 2.9s / 4.3s 三批建完搜索、专辑、歌曲、歌单页 —— 第一次点任何 tab
  都不再现建整页。日志确认三批 `preloadItems ok`。
- **滚动时让流光让位**：列表滚动期间暂停这层 shader，停手 220ms 自动恢复
  （`FlowLightRegistry.beginScroll()`，所有 tab 页的 `onDidScroll` 都接了）。
  视觉上察觉不到，但把滑动那几帧的渲染预算还给了列表。
- 清掉启动期 TEMP 诊断（LibraryDiag 的艺人/样本/缺失探测、方大同搜索探测、
  preferences 目录 dump）：它们每次启动都发一批请求 + 打几百行日志。


---

## 补丁：收藏艺人拖动排序的真正原因（2026-09-13 第三轮）

用户复验后反馈：长按头像会「变成一张方形图片跟着手指走」，但原头像留在原地、
两侧不避让、松手也不换位。

### 根因：`Image.draggable` 自 API 11 起默认为 **true**
封面是 `Image`，长按先触发了**图片自带的通用拖拽**（跟手的就是那张图片的快照），
它优先级高于 List 的条目拖拽，于是：
- 跟手的是方形图片（不是我们的浮起卡片）；
- 原卡片不动（List 的 `onItemDragStart` 压根没触发，所以没有隐藏/让位）；
- 松手也没有 `onItemDrop`（当然不会换位）。

修法：封面 `Image` 显式 `.draggable(false)`（`HeroArtwork` 与 `SongListItem`，
即所有艺人头像/专辑封面/歌曲封面），把长按让回给 List 的条目拖拽。

### 同时改成交互更接近「桌面图标」的实现
- 起拖：被拖的那张原位隐藏（opacity 0），跟手的是放大 + 投影的浮起卡片，震动 40ms；
- 拖动中：`onItemDragMove` 只更新「落点」，让落点及其后的卡片整体右移一个卡位
  （72 + 14 = 86vp，弹簧动画）——**数据全程不动**，所以框架给的
  `itemIndex` / `insertIndex` 始终有效，不会因为中途改数组而错位；
- 拖出列表：`onItemDragLeave` 收起落点；松手落回原位则不改数据、不震动；
- 落下：`onItemDrop` 里才真正 splice 换位（弹簧动画）+ 震动 20ms + 写
  `favorite_artists.sort_order` 落库；
- 兜底：12 秒内没收到 `onItemDrop`（手势被系统打断）就把视觉状态收回来，
  避免有卡片一直停在隐身状态。


---

## 补丁 2：收藏排序改成自研手势拖动（2026-09-13 第四轮）

上一版按官方 `onItemDragStart/onItemDrop` 实现，但**真机上横向 List 的条目拖拽不生效**
（`.draggable(false)` 关掉图片通用拖拽后，长按变成「什么都不发生」）。因此改成完全
自研的手势拖动，不再依赖框架条目拖拽：

- **手势**：卡片上挂 `GestureGroup(GestureMode.Sequence, LongPressGesture(350ms),
  PanGesture)` —— 长按拿起 → 进入拖动；封面 `Image` 已 `.draggable(false)`，
  不会再被图片通用拖拽抢走。
- **卡位收起**：被拿起的那张**不从数组里摘掉**，而是 `width(0)` + `opacity(0)`
  把卡位收起来。这点很关键：手势挂在卡片节点上，一旦把它从数组里移除，节点被
  卸载，拖动事件就断了（这是上一版「拖一下就断」的原因）。
- **让位**：拖动中按落点把「收起后数组」里落点及其后的卡片 `.translate(+86vp)`，
  弹簧动画让出一个卡位；`favInsert` 用「收起后坐标」，与最终插入位置一一对应。
- **落下**：`splice` 摘出原位置 → 按落点插回 → 弹簧动画 → 20ms 震动 → 写
  `favorite_artists.sort_order`。**取消**（手势被打断/拖出范围）只要清状态，
  因为数据全程没动。
- **禁滚动**：拖动期间横排 List 与主 List 都 `enableScrollInteraction(false)`，
  避免跟手时列表自己也跟着滚。
- **诊断日志**：`fav-drag pick/move/drop/cancel` 四类日志，用来确认卡在哪一环。


---

## 补丁 3：拖动偶发失效 + 浮起卡片黑底（2026-09-13 第五轮）

用户复验：能拖了，但「有时能拖、有时不能拖」，且被拿起的头像背后有一块黑底。

### 1. 偶发拖不动：两个叠加原因
- **手势优先级**：原来挂在卡片上的是普通 `.gesture()`，而横向 List 的滚动也会认领
  同一个触摸 —— 谁先抢到是时序相关的，抢输就「完全没反应」。改成
  `.priorityGesture()`：长按成立时拖动一定赢；长按没成立（快速滑动）时本手势失败，
  触摸交回列表，左右滑动照旧。
- **状态卡死**：`favDragging` 一旦置起，`pickUpFav` 就会直接 return。原来只有
  「拖动后松手」才会复位；**「按住但没移动就松手」不会触发 `onItemDrop` 之类的回调**
  → 状态一直挂着 → 之后再长按全被挡住，体感就是「怎么按都不动了」。
  现在长按手势的 `onActionEnd` / `onActionCancel` 都会把拿起状态收回来，
  另加 8 秒兜底定时器（正常拖动基本不会超过 8 秒）。

### 2. 黑底：浮起卡片不该有底色
浮起卡片原样用了 `library_card_bg` 当底色 + `#40000000` 投影；而深色模式下
`library_card_bg = #1C1C1E`（近黑）→ 被拿起的头像背后就是一块黑底。
现在浮起卡片**不画底色、不加投影**，只保留 1.08 放大与名字文字。

### 3. 诊断日志（保留）
`fav-drag pick / move / drop / cancel` 四类日志继续保留，便于后续定位。


---

## 补丁 4：拖动改成「原始触摸自判定」，彻底不抢手势（2026-09-13 第六轮）

用户复验：仍然「有时拖得动有时拖不动」「很难触发」，且拖起来「不跟手」。

### 1. 触发难/偶发失效：根因是「手势在争」
不管用 `gesture` 还是 `priorityGesture`，本质都是让框架在手势仲裁里裁决：
- 普通 `gesture` 会被横向 List 的滚动抢走；
- `priorityGesture` 虽然优先，但它和长按的时序、手指微小抖动都相关，仍然会出现
  「这次不灵」；而且优先级太高又有吃掉列表滚动的风险。

**最终做法：完全不用手势。** 卡片直接吃原始触摸事件（`onTouch` 的 Down/Move/Up/Cancel），
页面上自己做长按判定：
- 按下 → 起 260ms 计时；
- 260ms 内手指移动不超过 12vp → 判定「拿起」，震动 + 卡位收起 + 浮起卡片；
- 移动超过 12vp → 判定为滑动，放弃拿起（列表照常滚动）；
- 抬手：拖着就落位，没拖着就什么都不做（**不会留下卡住的状态** —— 这正是之前
  「有时怎么按都不动」的原因）。

`onTouch` 不参与手势竞争，所以「什么时候算长按」100% 由我们决定，也不再影响横排
左右滑动。

### 2. 不跟手：浮起卡片改成纯变换跟手
- 拿起时只记录一次基准位置，之后**每帧只更新位移**（`.translate()`，渲染变换，
  不触发布局重排）；之前每帧改 `.position()` 会带着布局一起算。
- 让位动画从长弹簧换成 `curves.responsiveSpringMotion()`，落点只在真正变化时才动。
- 拖动期间两侧列表 `enableScrollInteraction(false)`，避免跟手时列表自己也滚。


---

## 补丁 5：侧滑抽屉热区（2026-09-13 第七轮）

用户反馈：收藏拖动好了，但「从左往右滑，侧边标签页出不来了」。

### 原因
上上轮为了修「页内横滑被整屏手势吃掉」，把抽屉手势收窄成屏幕左侧 **24~56vp 的
32vp 窄条**，而且用的还是 `priorityGesture` —— 一是太窄（手指很难正好落在里面），
二是它仍然参与手势仲裁，被页内滚动抢到就不响应。

### 现在
热区加宽到 **20~84vp（64vp 宽、整高）**，并改成**原始触摸自判定**（和收藏卡片拖动
同一套机制，不参与任何手势竞争）：
- 只认「向右滑」：滑过 6vp 才开始拉抽屉；向左滑照旧交给页内列表；
- 松手时「过了面板宽度 30%」或「滑过 60vp」→ 展开，否则回弹收起；
- 收藏卡片正在拖动排序时（`MusicAppState.sortDragActive`）热区完全让位，
  避免「向右拖卡片把抽屉一起拽出来」；
- 起手点从 20vp 开始，避开最左 20vp 的系统返回手势区（那里留给系统返回）；
- 点击「不滑」不会误触发（`drawerTouchPull` 未置位就什么都不做）。

屏幕最左的小齿轮把手仍然是一下点开（适合不知道手势的场合）。


---

## 补丁 6：抽屉「拉不出来」的真机调参 + 误触下方行（2026-09-13 第九、十轮）

### 1. 用日志量化真实手感（关键）
埋了 `drawerZoneLog`（down / pull start / up 决策 / 齿轮点击 / 抽屉开关）后，用户滑几次就能读数：
```
down x=46 inZone=true
pull start dx=23
up dx=63 drawerX=-217 pull=true open=true     ← 只有这种幅度才开
up dx=55 drawerX=-225 pull=true open=false    ← 46~55vp 全被弹回去（旧阈值 >60vp 或 >面板 30%）
```
结论：**用户习惯的滑动幅度在 46~67vp**，原来的判定太严 → 表现就是「有时出得来、有时出不来」。
现在：起拉阈值 10vp；展开条件 = 滑过 34vp，**或**快速一甩（300ms 内滑过 18vp），
**或**已拉到面板 45%。

### 2. 侧滑误触下方行
抽屉触摸层是整屏透明的（不透明则手指很难落进热区），触摸会同时落到下面的列表行上，
短促右滑会既开抽屉、又被下面那行当成点击（用户反馈「误触到下方的艺人」）。
- 新增 `MusicAppState.tapBlockUntil` + `features/library/src/main/ets/util/TapGuard.ets`：
  拉抽屉一开始就写「未来 700ms 内吞掉点击」；
- 各主要点击入口（歌曲行 `SongListItem`、专辑卡片 `AlbumGridCard` 与角标、艺人行与
  收藏卡片、目录作品卡片 `CatalogWorkCard`、歌单行、搜索页艺人行）都加了
  `if (TapGuard.blocked()) return;`。


---

## 补丁 7：收藏横排与抽屉热区重叠（2026-09-13 第十一轮）

用户反馈：在「收藏的艺人」横排上往右滑，会呼出设置抽屉（本意是想滚动横排）。

### 原因
两者在屏幕上物理重叠：横排第一张卡片从 x=16vp 起（72vp 宽），正好落在抽屉热区
20~96vp 里。

### 修法：把横排那块矩形从抽屉热区里「挖掉」
- 艺人页在横排容器的 `onAreaChange` 里把矩形实时上报给 `MusicAppState`
  （`favRowX/Y/W/H`，随滚动自动更新）；
- 艺人页 `onHidden` 时把 `favRowW/H` 清 0，避免在别的 tab 上误挖一块；
- 外壳（Index）判定起手点时：`x∈[20,96]` **且不在该矩形内（±6vp）** 才算抽屉手势；
- 真机日志确认：`rect=(0,221,388,104)`，起手点 y 落在 221~325 之内时 `hitFavRow=true`
  → 走横排滚动，不拉抽屉；在其上方/下方起手仍然是抽屉手势。


---

## 补丁 8：外观只留图标 / 删补齐入口 / 全局圆形搜索按钮 + 资料库合一搜索（2026-09-14）

用户要求：
1. 设置抽屉换成半透明材质 + 上下圆角；
2. 外观设置删掉文字，只留 3 个图标；
3. 删掉「补齐曲库版本」入口；
4. 主界面里删掉上方切换深浅色的按钮；
5. 各主界面的「搜索艺人 / 专辑 / 歌曲」搜索框，全部换成一个**固定的圆形搜索按钮**，
   点开只搜本机资料库，且按钮不随 tab 切换而动。

### 实现
- **抽屉**：面板本体 `BlurStyle.COMPONENT_ULTRA_THICK → COMPONENT_THICK`、
  底色 `#2EFFFFFF → #26FFFFFF`、`borderRadius(26)`；外壳给面板容器加上下
  `padding 14vp`，于是它成为一块浮起的圆角半透明卡片。
- **外观**：`ModeChip` 从「图标 + 文字胶囊」改成 46×46 圆形图标按钮（只留图标）。
- **补齐曲库版本**：入口行 + `filling` 状态 + `fillCatalog()` 方法一并删除。
- **深浅色按钮**：艺人页工具栏里的外观按钮删除（连带 `appearanceLabel` /
  `cycleAppearance` / `appearanceSymbol` 与相关 import）。工具栏现在只剩同步按钮。
- **统一搜索**：新增 `features/library/src/main/ets/view/LibrarySearchOverlay.ets`
  —— 半透明材质浮层 + 顶部搜索框与「取消」，结果按 艺人 / 专辑 / 歌曲 / 歌单
  四个板块展示（内存过滤 + 120ms 防抖，每板块最多 30 条并提示总数）。歌曲直接播
  （队列 = 当前搜索结果），艺人 / 专辑 / 歌单通过外壳切到对应板块再 push 详情页
  （因为详情页的返回逻辑绑定在自己的导航栈上）。
- **固定圆形搜索按钮**：挂在 Index 根 Stack（tab 容器之外）、右上角（top 64vp /
  right 16vp、40×40 毛玻璃），`hitTestBehavior(Transparent)` 只吃自己那颗按钮的
  事件；切 tab 时它不动。点开浮层 zIndex 11（在 tab 之上、抽屉之下）。
- 四个板块页原有的搜索条（艺人 / 专辑 / 歌曲 / 歌单）与标题栏 stackBuilder 一并移除，
  Scroll 顶部留白 112vp → 76vp。


---

## 补丁 9：抽屉取消圆角 / 按钮对齐 / 搜索页标题位置（2026-09-14）

用户看图反馈四件事，逐条处理：

### 1. 标签页不要圆角
撤销上一轮给抽屉加的 `borderRadius(26)` 与外壳的上下 14vp 留边，恢复整高方角样式
（半透明材质保留，因为那是上一轮明确要的；若要连材质一起回退可再改）。

### 2. 左上同步按钮和「艺人」标题撞在一起
上一轮把各页顶部留白从 112vp 收到 76vp 引起的：工具栏按钮占 64~104vp，标题 76vp
就跟它重叠。艺人页留白改回 **112vp**（专辑/歌曲/歌单页没有左上按钮，仍保持 76vp）。

### 3. 左侧同步按钮与右侧搜索按钮不在一个高度
用 `uitest dumpLayout` 量真机坐标：同步按钮 `y=44~84vp`（标题栏的 stackBuilder 内容
会被 56vp 的 MINI 栏夹一下，实际比写的 64vp 高），搜索按钮 `y=64~104vp`。
把外壳搜索按钮行的 `padding.top` 从 64 改成 **44**，两颗按钮现在同为
**40×40vp、y=44~84vp**，完全对齐。

### 4. Apple Music 搜索页不显示资料库搜索按钮
外壳的圆形搜索按钮加 `currentTab !== 4`（第 5 个 tab 就是 Apple Music 搜索页）。

### 5. 搜索页「搜索」二字上方空太多（真因是 Blank 会抢剩余空间）
像素级测量截图发现：搜索页大标题实际在 **297vp**，而代码只留了 112vp 的占位。
原因是 **ArkUI 的 `Blank()` 在容器主轴上会自动填充剩余空间** —— 搜索页内容少时，
顶部 `Blank(112)` 与底部 `Blank(120)` 把剩余空间瓜分，标题被一路挤到屏幕 1/3 处。
改为固定高度的 `Column().height(...)` 占位后，标题回到 112vp（紧贴搜索框下方）。
专辑页同类隐患（专辑少时标题下沉）也一并改成固定占位。


---

## 补丁 10：顶部按钮统一到外壳 / 歌单页 UI·动画与其他页对齐（2026-09-14）

用户反馈：搜索页上方仍有空；同步按钮要像搜索按钮一样跟着页面走；歌单页「歌单」与
左上角同步按钮打架；歌单页的 UI 与动画逻辑要和其他页面统一。

### 1. 同步按钮搬到外壳（与搜索按钮同一行）
新增 `Index.syncLibraryNow()`（refreshDeveloperToken → syncSongs → syncPlaylists →
syncAllPlaylistTracks → remapQueueAfterSync → LibrarySignal.notifyChanged + toast），
顶部那一行改成 `justifyContent(SpaceBetween)`：**左同步、右搜索**，两颗都是
40×40vp、`padding.top = 44`，真机 dumpLayout 实测两者都是 `y=44~84vp`。
同步时按钮内换成 LoadingProgress。各板块页原来的工具栏同步按钮（艺人页 / 歌单页）
已整体移除 —— 这也顺带解决了「歌单」标题与按钮重叠。

### 2. 各页大标题留白统一 96vp
外壳两颗按钮占到 84vp，标题从 96vp 起才不会与之重叠（真机截图确认「歌单」不再被压）。

### 3. 搜索页顶部再收紧
Apple Music 搜索页的搜索框 `padding.top` 由 64 → 44（与外壳那排同高），大标题留白
112 → 96，标题紧跟搜索框下方；该页仍然不显示「资料库搜索」按钮（那是它自己的搜索界面）。

### 4. 歌单页 UI / 动画与其他页统一
- 歌单行封面改用 `HeroArtwork`（`playlistHeroIdOf(id)`），行内 `onAreaChange` 回传矩形；
- 打开歌单详情：`animateTo(springMotion) + pushPathByName(..., false)`，与专辑/艺人页
  同一套共享元素 + 生长动画；
- 歌单详情页新增 `heroId` / `sourceRect` 参数、`onHeroMeasured` 错峰生长
  （按钮 60ms、曲目 120ms，ENTER_MS=450）、`animatedBack()`（EXIT_MS=350 收缩后 pop）、
  `systemTransition(NONE)`、`onBackPressed` 走同一套收缩；
- 背景从纯色 `library_bg` 换成「封面铺满 + `backgroundBlurStyle(Regular)`」，
  与专辑/艺人详情页一致（删掉了那层不透明底色）。


---

## 补丁 11：搜索页空白真因（Scroll 居中）+ 歌单详情页对齐专辑详情页（2026-09-14）

### 1. 「搜索」上方大片空白的真因不是 Blank，而是 **Scroll 把短内容垂直居中**
临时在 Index 里加了一行「启动后自动切到搜索 tab」的测量钩子，dump 出真实结构：
```
Stack > Column(全屏) > Scroll(全屏) > Column [0,614][1260,2107]   ← 内容从 614px(189vp) 才开始
```
即：搜索页内容比视口短，`Scroll` 把整块内容**垂直居中**了（大标题因此落在 285vp）。
修法：给 Scroll 的内容列加 `.constraintSize({ minHeight: '100%' })` 撑满视口（艺人详情页
早就这么做了），标题即回到 96vp 贴顶。专辑页做了同样加固。

### 2. 搜索页顶部一并收拾
- 搜索框 `padding.top` 44 → 64（用户反馈 44 太靠上）；
- **该页整排外壳按钮都不显示**（原来只隐藏搜索按钮，同步按钮仍与搜索框重叠）：
  把外壳顶部那行整体包进 `if (this.currentTab !== 4)`。

### 3. 歌单详情页改成和专辑详情页完全一致
- 结构：`36vp 顶部留白 → 居中 210×210 大封面（HeroArtwork 共享元素）→ 两个 52×52
  圆形按钮（蓝「播放全部」/ 黄「继续播放」，同色值、同按压缩放）→ 曲目列表`；
- 曲目列表：每行一条分割线（跳过第一条，避免封面下方出线）、`SongListItem(showCover:false)`、
  `cachedCount(3,true)`、`clip(false)`、`padding(bottom 90)`、弹簧边缘、整段跟着封面一起
  生长/收缩（按钮 60ms、列表 120ms、ENTER 450、EXIT 350 —— 与专辑页同一组常量）；
- 读取中/出错改为列表里的占位行（不再整页 spinner）；
- 标题栏副标题格式也对齐（`N 首 · 时长`）。


---

## 补丁 12：艺人头像换官方图 + tab 栏加高加长 + 折叠播放条封面居中放大（2026-09-14）

### 1. 艺人头像：全部改成 Apple Music 官方艺人图
- **来源（零额外思路成本）**：资料库歌曲自带 `playParams.catalogId`（目录歌曲 id），
  按「每位艺人只取一首歌」收成探针表 → 批量请求
  `/v1/catalog/{sf}/songs?ids=…&include=artists`（一次 100 个 id）→ 返回的
  `relationships.artists.data[0].attributes.artwork` 就是官方艺人图。
  整库 ~150 位艺人通常只要 **2 次请求**（不是每人一次）。
- **落库**：新表 `artist_avatars(name PK, artwork_url, updated_at)`，**每次资料库同步
  整体覆盖刷新**（所以会随 Apple Music 更新）。实测日志：
  `艺人官方头像已更新：132 位` / `reloadArtistAvatars: 132 位艺人有官方头像`。
- **聚合**：`rebuildAggregates()` 里艺人 `coverPath` 直接取该表；没有官方图的
  （多为“某某 & 某某”合作行）显示渐变占位。
- **删除的旧逻辑**：`ArtistAvatarStore`（手动选图 + Preferences 存储）、
  艺人页与收藏横排的 `avatarOverrides`、艺人详情页“点头像换图”、
  以及“取最早发行专辑封面当头像”的聚合分支。

### 2. tab 栏
- 高度 52 → **60**（HDS `barHeight`，两个分支都改）。
- 胶囊宽度：手机是 **MD 断点**，实际吃 `barWidth.mediumWidth`（原来 248）→ 改成
  **292**（与播放条同宽），右侧那段 ~76vp 空隙缩到 4~16vp。

### 3. 折叠播放条
- HDS 的折叠槽是 **bar 高度见方**（60×60），宽度由外壳给定；实测 dump：
  槽 `x 311.7..371.7`、`y 742.8..802.8`。
- 封面 + 进度环 44 → **52**（槽内左右各留 4vp），并把折叠态的左边距按槽宽算成 4vp
  → 实测封面/环 52×52、`x 315.7..367.7`，**水平垂直都居中**。
- 折叠态不再显示歌名（槽只有 60 见方）；歌名仍只在展开态显示。


---

## 补丁 13：展开播放条改版（单键贴右 / 滑动切歌 / 触碰发光）（2026-09-14）

用户要求：展开态把播放/暂停放到最右、删除前后切歌按钮、左右滑动播放条切歌、
并加上「和左侧 tab 栏一样的触碰发光」。

### 1. 展开态控制键
- 删除 `backward_end_fill` / `forward_end_fill` 两个切歌按钮；
- 只留播放/暂停，`playButtonX() = expandedBarWidthVp - 24 - 16`（贴最右，右边距 16vp）；
- 文字宽度随之重算：`expandedBarWidthVp - 封面(52) - 按钮(24) - 44`。

### 2. 滑动切歌（`.priorityGesture(PanGesture, distance 24)`）
- 展开态：**右滑 = 上一首**（offsetX > 40），**左滑 = 下一首**（offsetX < -40）；
- 折叠态：保持原来的「左滑展开」（offsetX < -10 → `applyMiniBarStyle(EXPAND)`）；
- 用 `priorityGesture` 独占横向滑动，避免与外层 HDS 的展开/收起手势互抢；24vp 起判、
  40vp 才触发切歌，轻触仍是播放/暂停。

### 3. 触碰发光
- 真机/文档核对：HDS 的 **光效开关只在 `HdsTabsFloatingStyle.lightColor`（“页签栏光效颜色”，
  默认 深色 `#33E5E5E5` / 浅色 `#33FFFFFF`）**，`HdsTabsMiniBar` 并没有对应字段，
  所以播放条拿不到 HDS 自带的光效；
- 复刻方式：播放条外层改为 `Stack`，底层放一层与可见胶囊同宽同高（折叠 60 见方 /
  展开 `expandedBarWidthVp`）、圆角 30 的高光层，颜色取上面那个官方光效色 `#33FFFFFF`，
  手指按下时用 `curves.responsiveSpringMotion()` 淡入、抬起淡出 —— 观感与左侧 tab 栏点按一致，
  且不是「点光源」（上一版误用点光源已被用户否决）。


---

## 补丁 14：播放条触碰光效（按键布局 + 跟手光晕 + SDK 限制说明）（2026-09-14）

### 1. 展开态控制键（用户定）
- 删除前后切歌按钮，只留播放/暂停，贴最右（右边距 16vp）；
- 切歌改为滑动播放条：右滑上一首（>40vp）、左滑下一首（<-40vp）；
- `priorityGesture(PanGesture, distance 24)` 独占横向滑动；折叠态仍是左滑展开。

### 2. 触碰光效：能查到的事实与 SDK 限制（重要）
- HDS 悬浮 tab 栏那层光**是组件内部由沉浸材质（IMMERSIVE）自带的交互光**；
- 其官方开关在**较新 SDK**：`uiMaterial.ImmersiveMaterial({ interactive: true, lightEffect: { color } })`
  （见官方《空间化沉浸光感》最佳实践）——**本机 SDK（HarmonyOS 6.1.1 / API 24）没有 `uiMaterial`、也没有 `ImmersiveStyle`**，
  `hdsMaterial` 只有 `MaterialType`（NONE/ADAPTIVE/IMMERSIVE）与 `MaterialLevel`；
- `HdsTabsMiniBar` 接口里**没有**光效字段（光效只在 `HdsTabsFloatingStyle.lightColor`，属页签栏）；
- `hdsEffect` 只有三样：`pressShadow` / `pointLight`（用户已明确否决）/ `shaderEffect`（只有
  `DUAL_EDGE_FLOW_LIGHT`、`UV_BACKGROUND_FLOW_LIGHT`）；
- 结论：自定义播放条**拿不到"原厂那层光"**，只能按官方同色值（#33FFFFFF / #33E5E5E5）复刻。

### 3. 当前实现（复刻版，已截图验证能画出来）
- `Stack` 结构 = **光效层（底） → 内容 Row（中） → 触摸层（顶，HitTestMode.Transparent）**；
- 光效层与可见胶囊同宽同高并 `clip(true)`：整条 8% 白底 + 一团 132×60 的径向柔光
  （20% → 12% → 0 的柔化衰减），中心 `lightX` **跟着手指水平移动**，按下淡入、抬起淡出；
- 触摸层只喂手指位置（x 相对播放条左边缘，vp），`Transparent` 保证下层封面/播放键照常响应点击；
- 备用方案（如这版仍不像）：本机 SDK 有官方 `HdsVisualComponent` + `DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK`
  场景（光沿播放条边缘流动，是鸿蒙常见的"流光"），可随时替换。


---

## 补丁 15：播放条四项修正（滑动展开 / 按钮回封面 / 进度环外置 / 行内暂停键）（2026-09-14）

用户反馈 4 条（光效保持现状）：

### 1. 折叠态左滑展不开 —— 手势被 priorityGesture 抢了
上一版把 `gesture` 改成 `priorityGesture` 想独占横滑，结果**外层 HDS 的手势优先**，左滑展开失效。
改回 `.gesture(PanGesture(...))`，并把起判距离 24vp → **10vp**（更灵敏）。
展开态仍是：右滑 > 40vp 上一首 / 左滑 < -40vp 下一首。

### 2. 展开态去掉右侧播放/暂停键，改回画在封面上
删除展开态那颗贴右按钮与 `playButtonX()`；播放/暂停图标改为**折叠/展开都画在专辑封面上**
（`loadingText` 时仍是转圈），点封面即切换；文字宽度相应放宽为 `条宽 - 封面 - 24`。

### 3. 进度环可视度差 → 封面缩小、环外置
- 封面 52vp → **48vp**；
- 新增 `ringSideVp() = 封面 + 10 = 58vp`，进度环画在封面**外侧**（每侧露 5vp），58 < 60 也不会被胶囊裁；
- 环所在 Stack 取环尺寸（58），左内边距 = 1vp → 环心 31vp，仍与胶囊左半圆圆心一致。

### 4. 列表里"正在播放"那一行最右侧的按钮可切播放/暂停
- `SongListItem` 新增 `@Event onTogglePlay`；正在播放行的右侧图标（暂停/播放）加 `.onClick`，
  调 `PlayerDataUtil.togglePlayPause(this.appState)`（`features/player/Index.ets` 新导出 `PlayerDataUtil`）；
- 行本身仍走原来的 `onPlay`（从这首开始播），并用 `glyphTapped` 守卫吞掉图标点击冒泡到行的那一次，避免重复触发；
- 5 个调用点全部接上：专辑详情 / 歌单详情 / 全部歌曲 / Apple Music 搜索页 / 资料库搜索浮层
  （浮层为此补了 `appState`）。


---

## 补丁 16：右滑播放条会「呼出设置面板」的真因与修复（2026-09-14）

**现象**：在底部播放条上**向右滑切歌**，结果把设置抽屉（侧边面板）拖了出来。

**真因**：设置面板是**常驻挂载 + 位移移出屏幕**的（为了收起动画不闪黑，之前特意改成常驻），
但它的 `priorityGesture`（左滑收起/跟手拖动）**仍然挂在那个面板节点上**：面板命中区仍可能
压在底部 tab 栏/播放条这一带。于是：
- 播放条上的右滑 → 命中面板的手势 → `drawerPanStart` 记 `drawerStartX = -width`；
- `drawerPanUpdate` → `drawerX = -width + delta` → 面板被**跟手拖进来**（用户看到的就是"呼出标签页"）；
- 抬手 `drawerPanEnd`：`velocity > 150` 或 `drawerX > -width/4` → `openDrawer()`。

**修复**（两层保险）：
1. 面板加 `.hitTestBehavior(drawerOpen || drawerDragging ? Default : None)` —— 收起且未拖动时整块面板**不吃触摸**，事件透给下面的 tab 栏/播放条；
2. `drawerPanStart / drawerPanUpdate / drawerPanEnd` 三个处理都加守卫：`if (!drawerOpen && !drawerDragging) return;`。

顺带确认：`HdsTabs.scrollable(false)` 早已设置，所以"呼出标签页"不是 tab 横滑切换，确实是设置面板。


---

## 补丁 17：点「正在播放」那一行要一次点击就接着进度继续（2026-09-14）

**现象**：点正在播放的那首歌（暂停状态）要**点两次**才能继续，而且继续时**从头播**。

**两个根因**：
1. **要点两次**：上一版给行内那颗播放/暂停图标单独挂了 `onClick`，并用 `glyphTapped` 标记
   去吞掉"行本身的那次点击"。但图标点击**不一定冒泡到行**：不冒泡时标记就残留下来，
   于是**下一次点击被吞掉**（表现为要点两次）；
2. **从头播**：点行走的是 `onPlay`（`playSongList/playAlbumAt…`，会**重新加载曲目**从 0 播），
   而不是"继续"。

**修复（SongListItem 一处改完）**：
- 删除图标的独立 `onClick` 与 `glyphTapped` 标记（图标只作为状态指示）；
- 行点击统一语义：
  - `isCurrent === true`（正在播放那一行，暂停也算）→ `onTogglePlay()` →
    `PlayerDataUtil.togglePlayPause()` → `MediaService.play()`，**接着上次进度继续**；
  - 其它行 → `onPlay()`（从这首歌开始播）。


---

## 补丁 18：代码清理 + 研究包产出（2026-09-13）

### 1. 死代码清理（先扫描、再分批删、每批编译验证）
- **删掉的文件**：`util/LibraryDiag.ets`（临时诊断类，无人 import）、
  `entryability/SelfTest.ets`（已关闭的自检）、样例残留视图
  `PlaylistSplitHero.ets` / `MiniBarAlbumCover.ets` / `PlaylistLaneListSection.ets`、
  `viewmodel/MusicListPlaybackViewModel.ets`、
  `util/PlaylistDataUtil.ets` / `model/PlaylistSongUiDataSource.ets` / `model/PlaylistModels.ets`；
- **删掉的成员**（只声明零调用）：`CencDecryptor.findBoxTag`、`CatalogFillService.toOffer`、
  `AppleDownloader.stripDrmBoxes`、`AppleApi.probeSearchVariants`、
  `AllSongsPage.topInsetVp|SearchBuilder`、`AlbumsPage.SearchBuilder`、
  `ArtistsPage.topInsetVp|ToolButton`、`PlaylistDetailPage.Header`、
  `ArtistDetailPage.WorkRow|ContextMenu|openAlbumDetail`、`Player.buttonsWidthVp`、
  `PlaybackPage.isPhoneLyricsStyleBackdropLayout`、`MediaTools.validatePixelMapFilePath`、
  `LrcView.calculateOffset|isTouchLyricArea`、`Index.drawerIgnore|drawerPanHandlersInstalled`；
- **删掉的日志**：`drawerZoneLog` ×7、`fav-drag` ×4、`player-light` ×1（均为临时诊断）；
- **清理未用 import**：17 个文件共 44 个；
- **误删修复**：中途一次删除把 `ArtistsPage.authState` 字段与
  `ArtistDetailPage` 的 struct 边界吃掉（还有一处悬空 `@Builder`）→ 已从备份恢复并改为
  "逐个删 + 断言切掉的片段不含 `@Local/@Param/@Builder/build()`"的保守算法，最终 BUILD SUCCESSFUL。
- 核查过**不能删**的：`module.json5` 里声明的 Widget 卡片（`WidgetFormAbility`）、
  备份扩展（`PhoneBackupExtAbility`）、`WidgetUpdater/WidgetStateStore`、`AppleDiag`（活跃日志）。

### 2. 研究包（个人研究用，放在项目里待搬）
`研究归档/musichome-研究包-20260913/`
- `00-README-索引.md`：包内说明 + 搬运命令
- `01-AppleMusic集成-技术文档.md`：认证两条 token、接口清单（真实路径/参数）、
  资料库/专辑/艺人/歌单/收藏/搜索各功能做法、播放六步流水线、RDB 模型、**局限性与风险**、
  踩坑清单、常量速查（缓存 3GB / 封面 400 张 / 分页 100 / flavor `28:ctrp256` 等）
- `02-apple核心代码-带批注/`：`apple/` 16 文件 + `widevine/` 5 文件的带批注副本
  （文件头批注 + 行内 `【注】`）+ `00-代码导读.md`（阅读顺序 + 三条关键调用链）
- `03-工具链-带批注/`：17 个核心脚本（脱敏）+ 193 个开发过程脚本子目录 + 说明
- `04-完整源码/`：App 全量源码 296 文件（不含构建产物/备份/工具链/无关项目）+ 结构说明
- 同名 `.tar.gz`（35.8 MB）；安全自检确认**未打包** `am_cookies.json` 等凭据


---

## 补丁 19：换成蓝底白音符图标 + 同款开屏（2026-09-13）

用户给了一张蓝底白音符的图标，要求：① 手机软件图标改成它；② 开屏 = 蓝色背景 + 白色音符。

### 生成的资源（全部 1024×1024，与原有规格一致）
| 文件 | 内容 | 用在哪 |
|---|---|---|
| `products/default/.../media/ic_music_icon.png` | 完整图标（裁掉原图白边，蓝底圆角方块 + 白音符） | ability 图标（桌面/启动器） |
| `AppScope/.../media/background.png` | 蓝色垂直渐变（`#3494FD → #0E53EE`，取自原图上下边缘） | layered icon 背景层 |
| `AppScope/.../media/foreground.png` | 白色音符（透明底） | layered icon 前景层 |
| `products/default/.../media/startIcon.png` | 白色音符（透明底） | 开屏图标 |
| `base/dark` 的 `color.json`：`start_window_background` | `#186DFC`（取自原图中心） | 开屏背景 |

### 做法要点（可复用）
- 从原图里定位**蓝色区域 bbox**（`b > 150 && b - r > 40`）→ 裁掉白边；
- 白音符用「离白程度」做 alpha 掩膜：`a = clamp((min(r,g,b) - 150) / 90, 0, 1)`；
- **坑**：只用白度掩膜会把原图蓝方块**外侧的白色圆角区**也当音符收进去（开屏上出现白色圆角方框）→
  必须再乘一层**圆角方形几何遮罩**，并把遮罩**内缩 2.2%** 以去掉边缘抗锯齿白线；
- 开屏底色取原图中心蓝（`#186DFC`），与音符叠加后就是「纯蓝屏 + 白音符」。

### 验证
真机强制停止后冷启动，`snapshot_display` 抓 starting window：蓝底 + 白色双音符，
无白框/无边缘细线；`hvigor BUILD SUCCESSFUL`。

> 提示：这个图标形态与 Apple Music 的品牌图标高度相似。个人自用没问题，
> 但**一旦发布/开源/上架就会构成商标侵权**，届时需要换成自己的设计。


---

## 补丁 20：流畅度优化（HarmonyOS 7 上启动卡顿 / 切主页面掉帧）（2026-09-18）

### 先量再改（冷启动时间线，日志时间戳实测）
| 事件 | 优化前 | 优化后 |
|---|---|---|
| 资料库就绪（进程启动后） | +3973ms | **+3077ms** |
| 第 1/2/3 批预建页面 | +5277 / +6680 / +8263ms（头 8 秒里连卡三下） | **+6894 / +11938 / +16894ms** |
| 启动全库同步 | +5658ms 起（立刻跑） | **+29882ms**（延后 25s）|

结论：卡顿**不在数据库**（DB 就绪仅 ~180ms），而是「三批整页预建 + 全库同步（2724 首写库 +
重建聚合 + 通知 4 个板块刷新）」挤在用户刚打开应用的同一两秒里。

### 改动
1. **预建页面**：顺序改为「专辑 → 歌曲/歌单 → 搜索页（最重最少用，放最后）」，
   间隔 4s / 9s / 16s；每批触发前检查「用户 1.2s 内是否碰过屏幕」，
   碰过就顺延 3s（最多 4 次）→ 预建永不与交互抢渲染预算；
2. **启动同步延后 25s**（外壳左上的手动同步按钮不受影响）；
3. **预建期间流光让位 700ms**（复用切 tab 那套 `flowResumeSeq` 序号守卫，避免互相踩）；
4. **列表封面按显示尺寸请求**：新增 `AppleApi.artworkAt(url, size)`，
   `HeroArtwork` 对 ≤120vp 的小图按 2 倍像素请求（上限 320），大图/网格/详情仍 600；
   `SongListItem` 的 52vp 封面改请求 200px —— 原来一律 600×600，解码内存差 4 倍以上；
5. 记录用户触摸时间用的是抽屉那层**整屏透明触摸层**（被动通知，不影响任何子组件事件）。

### 待观察 / 下一批手段（若体感仍不够）
- 给 `preloadItems` 加耗时日志，量出每批实际卡多久；
- 流光降帧率或更激进让位（`FrameRateType`）；
- HDS 材质等级调档（`MaterialLevel`：沉浸观感 vs 性能的平衡点）；
- 列表 `cachedCount` 微调（现为 3）；
- 官方「跟手光效」仍需要 **API 26 SDK**（本机未安装，`uiMaterial` 搜不到）。


---

## 补丁 21：专辑页虚拟化失效（首建 1~2 秒 / 切出掉帧）修复（2026-09-18）

### 现象（用户反馈）
1. 重新打开应用后**立即点「专辑」**，要等 1~2 秒才出现内容；
2. **从「专辑」页切走**时帧率明显低于其他页面之间互切。

### 根因：Scroll 里套 Grid，虚拟化退化
专辑页原结构是 `Scroll > Column > (占位 96 + 大标题 + Grid(LazyForEach))`。
ArkUI 里 **Grid 放在 Scroll 内拿不到确定视口高度** → `LazyForEach` 退化成**全量构建**：
327 张卡片一次性建出来，每张还带点光源 `visualEffect` + 远程封面解码。
这一条同时解释了两个现象：首建要 1~2 秒、以及它参与页面切换时（出/入屏重绘）掉帧。

> 注：其余三个板块页用的是 `List`（正常虚拟化），所以只有「专辑」有这个问题 ——
> 与用户描述「只有专辑相关切换掉帧」完全吻合。

### 修复
新增 `AlbumRowDataSource`（每行 2 张专辑的行数据源），专辑页改为
`List({space:18}) { 表头 ListItem + LazyForEach(行) }`：
- List 只创建可视区的行（约 6~10 行 → 12~20 张卡），节点数从 327 降到十几；
- 大标题仍是第 0 个 ListItem，照旧随内容滚走；
- 视觉对齐原 Grid：列间距 14 / 行间距 18 / 左右内边距 16（放在行上，避免与标题自带 padding 叠成 32）/ 底部 90vp 给悬浮栏让位 / 弹簧回弹 / 标题淡出绑定同一个 Scroller。

### 影响面
- `features/library/src/main/ets/model/ListDataSources.ets`：+`AlbumRowDataSource`
- `features/library/src/main/ets/view/AlbumsPage.ets`：容器由 Scroll+Grid 改为 List+行


---

## 补丁 22：播放条光效（跟手光升级 + 官方光效待 SDK）（2026-09-19）

### 1. 现在能做的：跟手光升级成「两层结构 + 按下生长」
- **外层宽柔光** 208×60 径向渐变（峰值 14% 白、边缘化开）——模拟材质被点亮的大面积扩散；
- **内层光核** 104×56 径向渐变（峰值 30% 白）——给光晕一个「源点」；
- 两层都跟 `lightX`（手指位置）水平移动、被胶囊 `clip(true)` 裁切、叠在内容**下层**；
- **按下 0.72 → 1、抬手缩回**（`curves.responsiveSpringMotion()`），即官方「光从触点生长」的观感；
- 外加整条 6% 底光。文件：`features/player/.../view/Player.ets`。

### 2. 官方那套（`uiMaterial.ImmersiveMaterial` + `lightEffect`）——卡在 SDK
- 本机 **DevEco Studio 6.1.1.290**、内置 SDK `HarmonyOS 6.1.1（API 24）`，**无 `uiMaterial`**；
  官方光效属 **API 26（HarmonyOS 7）** 能力，需先在 DevEco 的 SDK Manager 里装 API 26。
- 已把「改哪两处、代码写法、官方 FAQ 四个坑、验证清单」写成
  `研究归档/.../05-待应用补丁-播放条官方光效（需API26）.md`，SDK 到位后几分钟即可应用。
- 本机可用的官方备选：`HdsVisualComponent` + `DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK`（边缘流光）。


---

## 补丁 23：升级 API 26 基线 + 播放条官方沉浸光效（2026-09-19）

### 1. 环境前提（用户完成）
- DevEco Studio 从 6.1.1.290 升级到 **26.0.0.821**，内置 SDK 变为 `HarmonyOS 26.0.0 / API 26`
  （`sdk/default` 里出现 `@ohos.arkui.uiMaterial.d.ts`）。

### 2. 编译基线：**26 之后的版本字符串格式变了**（踩坑）
- 旧写法：`"targetSdkVersion": "6.1.1(24)"`（`X.Y.Z(API)`，API ≤25 用）；
- 新写法：**`"26.0.0"`**（纯 `major.minor.patch`，删掉括号）——
  写成 `"7.0.0(26)"` 或 `"26.0.0(26)"` 都会报
  `api version parameter is illegal` / `Specification Limit Violation`；
  但也不能写成 `"26"`（hvigor 报 `00306042 Specification Limit Violation`，要求 `26.0.0`）。
- 本次最终：`compatibleSdkVersion: "26.0.0"`、`targetSdkVersion: "26.0.0"`。

### 3. 播放条官方光效（本次正式落地）
`features/player/src/main/ets/view/Player.ets`：
```ets
private immersiveOk: boolean = uiMaterial.isImmersiveMaterialSupported();
private immersiveMat: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  interactive: true,
  lightEffect: { color: undefined }
});
// …光效层容器：
.systemMaterial(this.immersiveOk ? this.immersiveMat : undefined)
```
- **支持则用官方材质**（和左侧 tab 栏同一套交互光效）；**不支持则回退**到之前手搓的三层光
  （三层光被包进 `if (!this.immersiveOk)`，两种情况下都不会叠加）；
- 启动时打一条诊断：`immersive=<bool> level=<MaterialLevel>`；
- 顺带修掉两处自身失误：把 `if` 插进组件树时括号顺序写错（多一个 `}`）、
  重复添加 `aboutToAppear`（与原有重名）→ 均已修正并编译通过。

### 4. 状态
- `hvigor BUILD SUCCESSFUL`（API 26 基线）✔；HAP 已安装（`updateTime` 已刷新）✔；
- **待用户验证**：当时手机处于锁屏，`aa start` 报 `10106102 … screen is locked`，
  无法自动拉起 → 需解锁手机后打开 App，按住播放条看光效。
- 提醒：提基线到 26 后要回归一遍**播放链路**（CENC/FFmpeg 那套是针对鸿蒙 7 修的）与**后台/锁屏播控**。


---

## 补丁 24：官方沉浸材质在本机「报支持但不渲染」（实测结论）（2026-09-19）

设备：Mate 60 Pro+ / **HarmonyOS 7.0.0.107（API 26）**；工程基线 API 26（`26.0.0`）。

### 三次隔离实验（都用截图判定，非推测）
1. 材质挂在「光效层空容器」上（`ULTRA_THICK` + `materialColor '#66 22AAFF'`）→ 截图无任何变化；
2. 材质移到「触摸层」（有条目尺寸、能收触摸）→ 依旧无变化；
3. 页面中央放独立测试块，三种配置对照：
   A `THIN + applyShadow + interactive`、B `ULTRA_THICK + 浓色 materialColor`、C `REGULAR` + 显式透明背景
   → **三块都只有文字，没有任何材质/着色/阴影**。

### 系统自报状态（日志）
```
Player | useOfficial=false immersive=true level=1 state=0 type=2
```
`isImmersiveMaterialSupported()=true`、`getMaterialInfo()={state:DEFAULT(0), type:IMMERSIVE(2)}`、
`getGlobalMaterialLevel()=GENTLE(1)` —— 即 API 层面"支持"，但渲染层**没有效果**。
推测原因（未证实）：该系统版本尚未对三方应用开启材质渲染，或按 `GENTLE` 档位做了降级/关闭；
也可能与色卡/温控策略有关。

### 当前处置
- `Player.ets` 新增开关 **`useOfficialMaterial = false`**（默认走手搓光，保证有光效）；
- 官方材质代码保留在触摸层上，只在使用开关时才应用：
  `.systemMaterial(this.useOfficialMaterial && this.immersiveOk ? this.immersiveMat : undefined)`；
- 启动诊断日志保留（`useOfficial / immersive / level / state / type`），便于将来复查；
- 临时测试块已从 `Index.ets` 清除（含那里的 `uiMaterial` import）。
- **后续**：等系统 OTA 后再把开关改成 `true` 验证一次；若届时生效即完成。


---

## 补丁 25：官方材质「不渲染」的真因 = 缺应用级开关（2026-09-19，重要更正）

**上一轮结论作废**：我说"系统还没给三方应用实现材质渲染"——错。用户指出**同机另一个音乐 App 的播放条就有这种光效**，
顺着这条线索重读官方《沉浸光感》指南，找到了漏掉的一步：

> 应用级开启的配置参数 name 需为 **`ohos.arkui.UIMaterial.state`**，value 可为 `default`/`enable`/`disable`。
> **应用级开关为 default 时普通组件没有材质效果**（只有 Dialog / Toast / Chip / AlphabetIndexer /
> SegmentButton / 菜单 / Select 等少数组件默认带材质）；为 disable 时无论 `systemMaterial` 设成什么都不生效。

我们一直是 `getMaterialInfo().state == 0 (DEFAULT)` → 组件级 `systemMaterial` 完全不渲染。
修复：`products/default/src/main/module.json5` 的 `module` 内加
```json5
"metadata": [{
  "name": "ohos.arkui.UIMaterial.state",
  "value": "enable"
}],
```
改后真机日志：`Player | useOfficial=true immersive=true level=1 state=1 type=2` ——
**state 由 0(DEFAULT) → 1(ENABLE)** ✔。

同时 `Player.ets` 的 `useOfficialMaterial` 置为 `true`（手搓三层光随之关闭）：
光效宿主 = 「尺寸等于播放条、且能收到触摸」的透明层；参数 `style: THIN` + `interactive: true` + `lightEffect: { color: undefined }`。

### 教训
- **组件级 `systemMaterial` 必须配合应用级 `module.json5` 开关（enable）**；否则"API 报支持、画面什么都没有"；
- 排查"看不见的效果"：隔离对照实验 + **先去官方指南核对完整流程**（我漏了"应用级/组件级"这一节）；
- 用户的外部反证（"别的 App 能做到"）价值极高 —— **不要用"系统没实现"来解释自己的失败**。


---

## 补丁 26：官方材质在播放条上不可用的**真正原因**＝HarmonyOS 7 收紧了生效范围（2026-09-19 定论）

用户反馈：「另外的音乐 App 底部播放条就有这种光效」→ 说明能力开放，问题在我们。继续深挖后，
在华为 2026-09-03 更新的 **OS 平台行为变更说明**里找到了答案（[IT之家报道](https://www.ithome.com/0/998/191.htm)）：

> **沉浸光感新增生效约束**
> * 变更原因：为确保性能和功耗体验最优，规范沉浸光感组件使用，沉浸光感对部分组件**新增生效范围约束**；
> * 变更影响：涉及接口为 **26.0.0 Beta 新增接口**，因此**变更仅在应用 `targetSdkVersion ≥ 26.0.0` 时生效**；
> * 变更后**只有两类位置生效**：
>   ① 弹窗类组件 / 接口（AlertDialog、ActionSheet、CustomDialog、Calendar/Date/Time/TextPickerDialog、
>      SelectionMenu、AlphabetIndexer 弹窗、Text 长按/双击菜单、PromptAction 等）；
>   ② 其他组件**仅在 `Navigation`/`NavDestination` 标题栏**，或**横向 Tabs 中 `barPosition = BarPosition.End` 的底部 TabBar** 中生效；
> * **「在其他区域中设置沉浸光感效果不生效」**（官方示例正是 `Column` + `systemMaterial` → 不生效）。

**结论**：我们的底部播放条（HDS 悬浮栏里的 miniBar 内的自定义节点）属于"其他区域" →
系统**直接忽略** `systemMaterial`。这不是代码/开关问题（应用级开关我们已补上并且 `state=ENABLE` ✔），
而是 OS 版本行为约束。用户看到的那款第三方 App 的光效位于**底部 TabBar 区域**（合法范围之一）。

### 处置
1. `Player.ets` 的 `useOfficialMaterial` 置回 **false**（恢复手搓三层光，保证有光效），
   并把上述官方约束写进该字段的注释；
2. 应用级开关（`module.json5` 的 `ohos.arkui.UIMaterial.state = enable`）**保留** ——
   它让 App 内**合法区域**（标题栏 / 底部 TabBar / 弹窗 Toast 等）材质的观感与规范一致；
3. 若日后希望播放条也有官方光效，唯一合规路径是**把播放条并入底部 TabBar 区域**（设计改动，需另行评估）。


---

## 补丁 27：底部改成「两条 bar」（官方两行布局）（2026-09-19）

用户提出：「能不能把播放条也变成和 tab bar 一样的属性，相当于下方有两个 tab bar」。
这条思路正好落在沉浸光感允许的区域（底部 TabBar）内，且 HDS 本身就支持这种形态：

> `HdsBarLayoutMode.VERTICAL`（官方注释：*Vertical bar layout: minibar and tabbar are arranged
> vertically in two rows*，since 6.1.1(24)）—— miniBar 与 tabBar **上下排成两行**。

改动：`products/default/src/main/ets/pages/Index.ets`
- import 增加 `HdsBarLayoutMode`；
- `barFloatingStyle.miniBar` 增加 `barLayoutMode: HdsBarLayoutMode.VERTICAL`。

效果（真机截图确认）：播放条单独成一条（宽胶囊，位于页签栏上方），页签栏在下方 —— 即"两条 bar"。
两者都由 HDS 绘制，处于「底部 TabBar」这一沉浸光感允许区域内。

**待验证**：按压/滑动播放条时，官方那层跟手光是否覆盖到 miniBar 这一行。
- 若覆盖 → 目标达成（用户最初要的"和 tab 栏一样的光"）；
- 若不覆盖 → 走备选方案：把播放条做成**底部 TabBar 的第 6 个"页签项"**
  （`.tabBar(this.PlayerItem())` + 空 TabContent + `onContentWillChange` 拦截选中态），
  这样它与其它页签完全同权，必然获得页签级的光效；代价是页签等宽、布局需重排。


---

## 补丁 28：播放条独立成「第二个底部页签栏」（2026-09-19）

用户反馈：两行布局（`HdsBarLayoutMode.VERTICAL`）下**仍然没有光** → 进一步确认：
官方沉浸光感的跟手光**只跟随"页签项"**，miniBar 那一行不算页签，配什么参数都不会亮。

### 改动（`products/default/src/main/ets/pages/Index.ets`）
1. **主栏移除 `miniBar` 配置**（播放条不再挂在主页签栏里）；
2. 新增 `PlayerTabBar()`：一条**独立的 `HdsTabs` 底部页签栏**，只有**一个页签项**：
   ```ets
   HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
     TabContent() { Column() }                 // 空内容（永不显示）
       .tabBar(this.PlayerTabItem())           // 页签项 = 播放条本体
   }
   .barFloatingStyle({ barWidth: {...}, barBottomMargin: 0,
     systemMaterialEffect: { materialType: IMMERSIVE, materialLevel: ADAPTIVE } })
   ```
   - 宽度随状态：折叠 60vp（圆槽）/ 展开 `expandedPlayerBarWidthVp()`；
   - 整屏透明容器 + 底部对齐 + `paddingBottom = 主栏底距 + 68`，正好落在主页签栏上方；
   - `hitTestBehavior(HitTestMode.Transparent)`：只有这条 bar 自己吃触摸；
3. 新增 `PlayerTabItem()`：内容就是 `Player`，`onExpandRequest` 改为直接切
   `appState.miniBarExpanded = true`（不再调用 HDS 的 `applyMiniBarStyle`）。

### 效果（真机截图）
底部变成两条 bar：主页签栏（5 个页签）+ 其上方一条独立 bar（折叠态为居中的 60vp 圆）。

**待验证**：按住这条 bar 左右滑 → 是否出现官方页签级的跟手光。
- 有 → 收工，再微调位置/宽度（例如保持靠右、与主栏等宽）；
- 无 → 说明页签光只在主栏内生效，剩下唯一办法是把播放条并入主栏的页签行（第 6 个页签项），
  代价是页签等宽 + 布局重排；届时与用户确认是否值得。


---

## 补丁 29：官方光效成功了 + 播放条回归原位置与交互（2026-09-19）

用户确认：把播放条做成「单页签的独立 `HdsTabs`」之后 **官方跟手光出现了** ✔✔
（此前两轮：miniBar 加 systemMaterial ❌、miniBar 与 tabBar 两行布局 ❌ —— 证实那层光**只跟随页签项**）。

用户接着要求：**放回原来的位置 + 保持原来的交互**。本次改动（`products/default/src/main/ets/pages/Index.ets`）：

1. `PlayerTabBar()` 从「整屏透明容器 + 底部对齐」改为**绝对定位**，并新增三个 helper：
   - `screenWidthVp()/screenHeightVp()`：由 `windowInfo` 换算；
   - `playerBarWidthVp()`：折叠 = 60（圆槽）/ 展开 = `expandedPlayerBarWidthVp()`；
   - `playerBarLeftVp()`：折叠 = `屏宽 - 16 - 60`（**贴主页签栏右侧、同一行 = 原位置**）/ 展开 = 16（与主栏左对齐）；
   - `playerBarTopVp()`：折叠 = `屏高 - 底距 - 60`（与主页签栏同排）/ 展开 = 再上移 68（独占一行）。
2. **切 tab 时自动收回折叠态**（展开态独占一行，切页时收回去更顺手）。
3. **启动强制折叠**（`aboutToAppear` 里 `miniBarExpanded = false`）——之前残留的展开态会把播放条留在上面那一行。
4. 交互全部保留（`Player` 组件未改）：轻点封面播/暂停、折叠态左滑展开、展开态左右滑切歌、点最右播放键切播/暂停。

真机截图确认：底部同一行 = 页签胶囊（左）+ 播放条圆槽（贴右，原位置），官方光效仍在。


---

## 补丁 30：恢复原位置/大小 + 同排展开 + 弹簧回弹（2026-09-19）

用户要求：① tab 栏/播放条的位置与大小改回之前；② 在**未展开态播放条左侧的 tab 栏**上左滑 → tab 栏收缩、
右侧播放条展开；③ 展开态**不要跑到 tab 栏上面**；④ 要有**动画回弹**。

### 关键设计（把"官方光效"和"原来的外观"同时保住）
官方那层光只认「页签项」→ 播放条必须是独立页签栏（`PlayerTabBar`，单页签 `HdsTabs`）；
而"原来的外观"是主栏胶囊（292 宽、居中）里含 5 个页签 + 右侧 60 的 miniBar 槽。
两者可以**叠加**实现：

1. 主栏**恢复 miniBar 配置**，但 `miniBarBuilder` 只放一个**透明占位**（`MiniBarPlaceholder`，
   `.width(60).height(60)`）并 `enableMiniBarBackground: false` —— 作用只是让 5 个页签按 232 宽
   紧凑排在胶囊左侧、右侧留出 60 槽位（= 之前的样子），自己不画任何东西；
2. `PlayerTabBar`（带官方光效的独立页签栏）**精确叠在那个槽位上**：
   `collapsedPlayerBarLeftVp() = (屏宽 + 292)/2 - 60`（主栏居中、宽 292、槽位在右侧 60），
   `playerBarTopVp() = 屏高 - 底距 - 60` —— 与主页签栏**同一行**；
3. **展开/收起改为动画数值驱动**：新增 `@Local playerBarW / playerBarX`，
   `expandPlayer()` 在 `animateTo({ curve: curves.springMotion(0.4, 0.7) })` 里把
   宽度设为 `屏宽-32`、x 设为 16（**同一行**铺开、覆盖页签栏，绝不上移）；`collapsePlayer()` 缩回槽位；
4. 手势：在主栏上方叠一条**透明手势层**（`HitTestMode.Transparent`，不挡页签点击），
   **左滑 = 展开**；右滑**不处理**（展开态右滑是「上一首」，不能抢）；
5. 切 tab 自动收起改走 `collapsePlayer()`（同一套弹簧动画）；启动强制折叠并初始化 `playerBarX`。

### 状态
构建通过、已装机（截图时前台被用户切到别的 App，故本轮几何由数值保证：
折叠 60 圆槽贴主栏右端、展开同排铺满、y 恒为 `屏高-底距-60`）。


---

## 补丁 31：展开态「tab 栏缩成圆圈」+ 折叠态不再打架 + 圆心重合（2026-09-19）

用户反馈四项，逐条处理：

### 1. 展开后 tab 栏整个消失 → 改为「缩成一个圆圈，圈内是当前主界面」
- 展开时主栏仍被播放条覆盖（视觉上"收进去"），右侧**画一个 60 圆**表示 tab 栏：
  位置 = 折叠态播放条的位置（`屏宽-16-60`），内容 = **当前页签的 Symbol**（`currentTabSymbol()`），
  底色 `#33FFFFFF` 半透明；**点它即收回折叠态**（回到原来的 5 页签胶囊）。
- 展开态播放条宽度相应收窄：`屏宽 - 16 - 60 - 4 - 16`（给圆圈留位），仍在**同一行**。

### 2. 折叠态播放条偏左、和 tab 栏打架 → 主栏收窄让位
- 主栏 `barWidth` 三档统一为 **228**（按 292 算时它右端会伸到 339.85，与右侧播放条重叠 28vp）；
  实测手机实际断点是 **SM**，只改 `mediumWidth` 无效 → 三档都改成 228 才生效。
- 播放条折叠态贴屏右 **16vp**（`屏宽-16-60`）→ 与主栏(79.85..307.85)之间留约 4vp 间隙，互不重叠。

### 3. 封面与背后半透明材质「圆心不重合」→ 找到根因
- 根因：折叠态原 `.padding({left:1,right:4})` 不对称（偏 1.5vp），更深一层是
  **进度环 58vp 塞不进 52vp 内容盒**（padding 4/4）→ ArkUI 对超宽子节点**靠左排不居中** →
  封面圆心实测偏右 **3.5vp**。
- 修正：折叠态 `.padding({left:1,right:1})`（60-58=2，环正好放得下）→ 环/封面/播放键/材质圆心对齐。
  量化复核：封面亮区质心与圆槽中心偏差 **3.5vp → 0.8vp**（y 向 1.1vp，测量噪声级）。

### 4. 你现在要的圆形构成（已满足）
- 封面正中央 = 播放/暂停键（`Stack(alignContent: Center)` + 16fp Symbol，70% 不透明度）；
- 封面外侧一圈 = 进度环（`MiniBarProgressRing`，`ringSideVp = cover+10`）；
- 背后 = HDS 悬浮栏的**半透明沉浸材质**圆槽（60×60，圆角 30）；
- 四者同圆心（量化验证如上）。


---

## 补丁 32：整体居中 + 布局级同心 + 展开态「左侧圆形 tab」（2026-09-19）

### 1. 整组居中（用户：tab 栏与未展开播放条整体偏右）
- 主栏 `barWidth` 三档回到 **292**（居中 → 实测 `TabBar` bounds **x 47.7..340.0 y 742.8..802.8**）；
- 折叠态播放条回到**主栏右端的 miniBar 槽位**：`collapsedPlayerBarLeftVp() = (屏宽+292)/2 - 60` = 279.85；
  于是"整组"= 主栏本身（292，居中）→ 视觉整体居中 ✔。

### 2. 圆心真正重合（布局级，不再靠 padding 凑）
- 折叠态把「进度环 58 / 封面 48 / 播放键」放进一个 **60×60、`alignContent: Center` 的 Stack**
  （与 HDS 圆槽等大）→ 由布局保证同心；
- 量化复核（截图亮区质心 vs 理论圆心）：**偏差 0.9vp（x）/ 1.1vp（包围盒 y）**，此前是 3.5vp。
- 记录根因：① 原 padding `left:1/right:4` 不对称；② 环 58 > 内容盒 52 时 **ArkUI 不会居中超宽子节点**（靠左排）。

### 3. 展开态：tab 栏向左收成一个圆（不再显示到右侧）
- `tabCircleLeftVp() = 16`（**左侧**），60 圆、半透明底 `#33FFFFFF`、内含当前页签 Symbol，
  点击即收回折叠态；展开态播放条 `playerBarX = 80`、宽 `屏宽-80-16`，仍在同一行。

### 4. 已知现状（需用户确认取舍）
- 实测 5 个页签在 `BarMode.Fixed` 下会**等分铺满整条 292**（第 5 个 x 273.8..327.7），
  因而第 5 个（搜索）会落在播放条圆槽下方 —— 这与**原版**（miniBar 盖住第 5 格）表现一致；
  若要 5 个页签都露出来，需要改 `BarMode.Scrollable` + 每个页签固定 46.4 宽 + 第 6 个 60 占位项
  （5×46.4+60=292 正好铺满，页签靠左），属结构性改动，待用户确认。


---

## 补丁 33：页签不再被播放条遮挡 + 主栏铺到整行（2026-09-19）

用户反馈：① 折叠态播放条挡住了「搜索」页签，且主栏仍显得居中 → 要求主栏左移；
② 展开时不要另画一个 tab 图标，而是**让 tab 栏自己带动画收起来**（并提示"看看改之前的代码怎么做的"）。

### 改动（`Index.ets`）
1. 主栏宽度 **292 → 355.7**（三档统一）。HDS 悬浮栏居中 → 355.7 时正好覆盖 **15.7..371.4**，
   即左右各 16vp 边距 —— 视觉上主栏整体左移、与播放条合起来铺满整行（整组居中）；
2. 新增**第 6 个透明占位页签** `TabBarPlaceholder`（60×60 空 Column）→ Fixed 模式下 6 等分（各 59.28vp）：
   5 个页签落在 16..312，**第 6 格留给播放条**；
3. 折叠态播放条位置改为 `屏宽-16-60 = 311.7`（第 6 格）；
4. 移除上一轮另画的「主界面圆圈」（用户明确不要）。

### 实测（uitest dumpLayout）
- `TabBar` bounds：**x 15.7..371.4**（主栏铺满整行、左边距 16 ✔）；
- 5 个页签：44.3..66.5 / 99.4..121.5 / 154.8..176.9 / 209.8..232.0 / **265.2..287.4**
  → 第 5 个（搜索）右边缘 287.4，距播放条 311.7 还有 24vp ✔ **不再被遮挡**。

### 关于「让 tab 栏带动画收起来」（下一轮）
- **为什么改之前能动画**：老的 `miniBar` 方案里，收起/展开是 **HDS 自己的动画**
  （`hdsTabsController.applyMiniBarStyle(EXPAND/COLLAPSE)` + `onMiniBarAnimationStart/End`、`onTabBarAnimationStart`）。
  我们为了拿到官方页签光效，把播放条移出了 miniBar（独立单页签 HdsTabs），**那套 HDS 动画就用不上了**。
- 现在可行的做法：展开时把主栏 `barWidth` 292 → 60，并且**只保留当前页签项**（其余项宽度收成 0），
  整体放进 `animateTo({ curve: curves.springMotion(...) })` → 主栏自身收缩成一个圆（内含当前板块），
  播放条在同一行展开到它右侧。需要一轮实现 + dump 验证。


---

## 补丁 34：C 方案（混合）验证版（2026-09-19）

用户选 C。思路：老版之所以「能自动布局 + 有官方折叠动画」，是因为播放条住在 HDS 的 **miniBar** 里；
为了让播放条拿到官方页签光效才搬成独立 HdsTabs，因而丢了那两项。C = 两者叠加：

1. 主栏宽度回 **292**（原版），移除第 6 个占位页签；
2. **加回 `miniBar`**：`miniBarBuilder → this.miniBar()`（内容 = `Player`）、
   `miniBarWidth = expandedPlayerBarWidthVp()`、`onBarStyleChange → onMiniBarStyleChange`、
   `onMiniBarAnimationStart → syncGhostBar(to === EXPAND)` ⇒ 拿回 **HDS 自动布局 + 官方折叠动画**；
3. 保留独立单页签 `HdsTabs`（`PlayerTabBar`）作为**光效层**：页签项内容置空且透明，
   折叠态对齐 miniBar 槽位 `(屏宽+292)/2-60`，展开态按回调移到居中并铺到 `屏宽-96`；
4. `expandPlayer()/collapsePlayer()` 改为 `applyMiniBarStyle(EXPAND/COLLAPSE)`（官方动画），光效层随回调同步。

构建通过并已装机。**待用户验证**：① 展开是否出现 HDS 官方「tab 栏折叠」动画；
② 按压时官方光效是否出现在播放条位置；③ 光效层材质薄膜是否影响播放条观感。

> 工程注意：本轮用内联 Python 改中文文件时把 shell 弄进了 pager（SIGABRT），
> 教训是这类改动一律「先写 .py 文件再运行」。
