# 技术实现：在鸿蒙设备上播放 Apple Music 音源

这份文档是这个项目最核心的部分：**从「登录」到「听见声音」的完整链路**，
包括取证方式、接口细节、密码学流程，以及一路踩平过的坑。
它不是教程，而是一份**实现记录**——照它做，你能少走我走过的弯路。

> 全部代码在 `common/musicbasic/src/main/ets/apple/` 下：
> `AppleApi`（接口）、`AppleDownloader` + `HlsParser`（取流）、`Mp4Box` + `Mp4Cleaner`（容器）、
> `CencDecryptor`（解密）、`widevine/*`（CDM）、`AppleCache`（落盘）、`AppleLibrarySync`（同步）。

---

## 0. 先证明一件事：鸿蒙上没有可用的 DRM

动手之前先确认可行性，否则全是白做。实测环境：Mate 60 Pro+ / ALN-AL00 / HarmonyOS 7（API 26）。

| 检查项 | 结果 |
|---|---|
| `drm.getMediaKeySystems()` | 只有 `com.wiseplay.drm` |
| `isMediaKeySystemSupported('com.widevine.alpha')` | `false` |
| ArkWeb EME `requestMediaKeySystemAccess('com.widevine.alpha')` | `NotSupportedError` |
| 加载 `music.apple.com` 抓 EME 请求序列 | PlayReady → Widevine → ClearKey → FairPlay 全部失败，仅 ClearKey 通过 |

结论：**网页播放走不通**（Apple 不会用 ClearKey 保护正版内容）。
唯一可行的路是「应用内自带 Widevine L3 软件 CDM，自己解密，再把明文交给系统播放器」。

这一步也顺带解释了为什么市面上没有鸿蒙版 Apple Music 客户端：
不是没人想写，是这道 DRM 关卡在鸿蒙上必须自己补。

---

## 1. 登录：只拿票据，不碰密码

```
ArkWeb 加载 https://music.apple.com/cn/login
   ↓ 用户在 Apple 自己的页面里完成登录 + 双重认证
WebCookieManager.saveCookieAsync()  // 先把 Web 引擎内存里的 cookie 落盘
   ↓
fetchUserTokenFromCookie()          // 读 media-user-token（长度 ≥50 才认）
   ↓
Preferences 持久化（AppleApi.persist）
```

三个要点：

1. **不自己画账号密码表单**。Apple 的登录页在自己的域里、DOM 动态渲染，
   注入脚本填不进去（试过，真机失败）。硬做的另一个后果是「第三方应用收集 Apple ID 密码」，
   这对一个开源项目是灾难性的形象。所以就是**内嵌官方页面 + 自动检测收尾**。
2. **`media-user-token` 是票据不是密码**。它等价于「这个账号的音乐身份」，
   丢了就重新登录，不涉及密码；但也别外泄——它等于你的资料库钥匙。
3. **开发者 token 从页面里抓**（`AMPWebPlay` 的 JWT）。它过期很快，每次启动重新取，
   不要硬编码在源码里。

> 登录页顺带做了一件体验上的事：检测到票据后**不立刻关页**，而是在这一页上带进度把资料库同步完
> （见第 3 节），再自动进主界面。否则用户看到的是「登录成功了，但界面空着等十几秒」。

---

## 2. 接口主机：用 `amp-api`，不是 `api`

| 主机 | 用途 |
|---|---|
| `amp-api.music.apple.com` | **本项目所有请求走这里**。接受网页版开发者 token |
| `api.music.apple.com` | 公开 MusicKit 主机，用网页 token 会 403 |

请求头三件套：`Authorization: Bearer <developerToken>`、`Music-User-Token: <media-user-token>`、
`Origin: https://music.apple.com`。

资料库端点：

```
GET /v1/me/library/songs?limit=100&offset=N
GET /v1/me/library/albums?limit=100&offset=N        // 带 ?extend=inFavorites 才有收藏标记
GET /v1/me/library/artists?limit=100&offset=N       // ?extend=inFavorites
GET /v1/me/library/playlists?limit=100&offset=N
GET /v1/me/library/albums/{l.xxx}/tracks            // 资料库专辑的曲目
```

**几个必须记住的坑：**

- **资料库 id ≠ 目录 id**：资料库资源长 `l.xxx`（专辑）/ `r.xxx`（艺人）/ `i.xxx`（歌曲），
  而 `webPlayback`、`/v1/catalog/...`、`/v1/me/ratings/...` 要的是**目录 id**（纯数字）。
  把 `l.xxx` 丢给 ratings 会得到 `400 code 40008 "Ratings not allowed for resource type 'albums'"`——
  错误信息极具误导性，容易得出「开放接口不支持收藏」的错误结论。
- **`l=en-US` 会改名称口径**：带上它，资料库资源返回英文规范名（`David Tao`），
  与曲目里的本地化名（`陶喆`）对不上；做名称匹配时**不要带 l**。
- **名称不可靠，跨接口关联一律用 id**：同一张专辑在 `/library/albums` 里叫 `Hatsukoi`，
  在曲目侧叫「初恋」（Utada）。
- **收藏不是 ratings**：`attributes.inFavorites` 靠 `?extend=inFavorites` 才返回；
  不带这个参数 Apple 根本不回这个字段。写入规则按资源类型分叉：
  专辑用 `PUT /v1/me/ratings/albums/{目录id}`，艺人反而只能 `POST /v1/me/favorites?ids[artists]=`，
  写入是最终一致（约 6 秒后 `inFavorites` 才变），UI 必须乐观更新。
- **鸿蒙 http 不允许 POST/DELETE 传空 body**（本地报 `Parameter error`，会被误判成 Apple 拒绝），
  取消收藏要传 `'{}'`。

---

## 3. 资料库同步：把 65 秒压到 14 秒

初版串行分页 + 逐条写库，一整库 2888 首要 65~75 秒。三个改动把它压到 **14.2 秒**：

1. **不要带用不到的 `include=` / `extend=`**：`?include=albums,artists&extend=artistUrl` 会给每首歌
   附带完整的关系对象，响应体成倍膨胀（仅删掉这两个参数，拉取时间 16.7s → 9.8s）。
2. **分页并发**：29 页串行 ≈ 55~60s，6 路并发 ≈ 10s（`limit=300` 会被 Apple 400 拒绝，上限 100）。
3. **批量写库**：`batchInsertWithConflictResolution`，每 400 行一批，2888 行 0.8s；
   逐条 `insert()` 要 4~6s。

成功判据不要只看「请求 200」：要拿本地行数和 Apple 返回的 `total` 对账。
另外「同步中不要 notifyChanged 把页面打崩」——早期在 `EntryAbility` 非 UI 上下文里广播刷新信号，
会把 HDS 悬浮播放条打成不渲染（组件树在、画面没了）。

---

## 4. 取流：`webPlayback` + HLS

```
GET /v1/me/library/songs/{i.xxx}?include=catalog
   ↓ 拿到目录 id + playParams
GET {AMP}/v1/me/webPlayback?ids[songs]={目录数字id}   // POST，body 用 {"universalLibraryId":"i.xxx"}
   ↓ 返回 songList[0].assets[0].url → HLS(m3u8)
解析 #EXT-X-STREAM-INF / #EXT-X-BYTERANGE → 分片列表
   ↓ 4 路并发 Range 下载（实测 2.2×，且逐字节一致）
按顺序拼装成 fMP4
```

**必须记住的两点：**

- **license 与取流都要 catalog 数字 id**：资料库歌曲 id `i.PkdZ2vqUPbmxvL2` 直接当 adamId 发 license
  会得到 `{"status":-1003}`。正确做法就是先 `webPlayback`（body 用 `universalLibraryId`），
  它会把 id 换回 catalog 数字 id。
- **`#EXT-X-BYTERANGE` 省略 `@offset` 时表示「紧接上一段」**。按 0 处理会拼出一堆错误数据；
  拼装完要做**覆盖性校验**（分片首尾连续），不连续就回退成整段单请求。

---

## 5. 解密：Widevine L3（WVD）在应用内跑

这是整个项目最硬的一段，也是最难复述的一段。大致流程：

```
WVD(设备凭证) ──解析──▶ 设备私钥 + 设备 id + 客户端 id
        │
        ├─ 生成 challenge（PB 序列化：content_id / 请求类型 / 协议版本 / key_control_nonce / request_id）
        │
        ├─ POST 到 Apple 的 license 服务（头里带 Bearer / 设备 id / 会话签名）
        │        └─▶ 返回 license（含 content key，被设备公钥包裹）
        │
        ├─ RSA 解 license → 得到 session key + 内容密钥（AES-128）
        │
        └─ 用内容密钥逐 sample 解密（CENC）
```

实现上分几个文件：`Pb`（protobuf 手写编解码）、`Crypto`（RSA-SHA1 签名、AES-CTR、CMAC）、
`WvdParser`（凭证解析）、`WidevineCdm`（挑战/响应状态机）、`CencDecryptor`（按 fMP4 的
`moof/traf/senc/saiz` 逐 sample 解密）。

### 5.1 性能：4629ms → 339ms（13.6×）

第一版每个 sample 都 `createSymKeyGenerator → convertKey → createCipher → init → doFinal`，
5162 个 sample 就是两万多次异步调用，**解密占整曲耗时的 76%**（网络只占 3%）。

改成：

- 密钥**只 convertKey 一次**；
- 每个 worker 持有一个 cipher，靠 `init` 换 IV；
- **8 路并发**。

结果 4629ms → **339ms**，产物 SHA256 与逐 sample 版本**完全相同**。
凡是「小段 × 大量」的加解密都该这么写。

### 5.2 `senc` 的 IV 长度不能写死

CENC 的 `senc` box 里每个 sample 的 IV 长度由常量决定，无 subsample 的曲目是 **8 字节**，
有 subsample 的是 16。写死 16 会让一半 sample 解错（ffmpeg 解码时报上万行 AAC 错误，但播放器
可能只是「听起来有杂音」而不报错）。

### 5.3 交播放器之前，必须删掉 `moov` 里的 `pssh`

这是最阴的一个 bug：**约一半的曲目点了永远不响**。

- `AVPlayer.prepare()` 的 Promise 会 resolve，但 `state` 永远停在 `initialized`，
  `duration` 恒为 -1，不派发 `prepared`，`play()` 无效。
- 根因：Apple 给**部分曲目**下发的 fMP4，`moov` 末尾多一个 **484 字节的 `pssh`（Widevine 系统头）**。
  音频已经解密成明文，但 `pssh` 还在 ⇒ 播放器认为这是受 DRM 保护的内容，
  去等一个永远不会到来的许可证。
- 定位方法（值得复用）：**分片二分 + 交叉拼接** —— 把坏文件截断成「前 K 个分片」逐个测，
  再把好文件的 `moov` 与坏文件的分片交叉拼，一刀切开「元数据问题」还是「数据问题」；
  然后把 `moov` 的 box 树**完整递归 dump**（我第一次就是漏打了几种 box，白折腾几小时）。
- 修法：只重建 `moov` 子树，丢掉 `pssh`。因为 `pssh` 在 `moov` 末尾，删除只改变 `moov` 长度，
  **不影响任何相对偏移**（`trun.data_offset` 是相对 `moof` 起点算的）。
  **绝不要动 `moof/traf`** —— 在那里删 box 要同步修 `data_offset`；实测乱删 `senc/saiz`
  会让 AVPlayer 在 native 层直接崩进程。

---

## 6. 播放：明文交给系统

解密完是普通 m4a，落到沙箱（**原子写**：先写 `.part`，成功后 rename），
然后用 `fdSrc` 交给 AVPlayer：

```ts
const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
avPlayer.fdSrc = { fd: file.fd, offset: 0, length: fileIo.statSync(path).size };
```

配套的三条纪律（都踩过）：

1. **播放器是应用级单例**，页面销毁不 `release()`，否则退出播放页音乐就断。
2. **换轨/换实例必须收敛成一个入口**，所有回调加实例身份守卫（`this.player === p` 才处理），
   旧实例在释放途中还会吐 `idle/stopped`，不守卫就会把新实例的音源清掉。
3. **`pendingResumeMs` 每次都要显式赋值**（`startPositionMs > 0 ? startPositionMs : -1`），
   只在正数时赋值会让新歌继承上一首的续播位置。

## 7. 缓存与并发：三条铁律

- **single-flight**：同一首被并发请求时共享同一个 Promise（预取与点播同时命中同一首是常态）。
- **原子写**：`.part` → rename；失败清掉 `.part`；启动时扫掉遗留的 `.part` 与坏文件。
- **完整性校验**：小于体积下限的缓存视为损坏，作废重取。
  否则一个半截文件被登记进缓存索引，这首歌就**永久播不出来**，且不会重下。

---

## 8. 排查速查表

| 现象 | 先查什么 |
|---|---|
| 登录后没有资料库 | `MediaUser-Token` 是否有值；`webPlayback` 是否 401 |
| 点歌无反应 | license 是否返回 `-1003` / `-42585`；是否用了 `l.xxx` 而不是数字 id |
| 一半歌能播一半不能 | `moov` 里是否残留 `pssh` |
| 有声音但时长 -1 | `prepare()` 卡在 `initialized`，同上 |
| 解码报一堆 AAC 错误 | `senc` 的 IV 长度是否写死 16 |
| 偶发「这首永远播不出来」 | 缓存里是否留了半截文件（缺完整性校验） |
| 同步特别慢 | 是否带了 `include=` / `extend=`；分页是否串行 |
| 播放条消失 | 是否在非 UI 上下文调了 `LibrarySignal.notifyChanged()` |

---

## 9. 这份记录想说明什么

技术上它是「在缺 DRM 的平台上补齐 DRM 客户端」的一次完整实践：
登录票据 → 授权换取密钥 → 解密 → 交给系统播放器，每一环都有明确的接口与判据。

工程上，凭据不进仓库（`WvdLocal.ets` / `AiKeyLocal.ets` 都被 gitignore），分发包由 `build.sh ... public`
保证不含任何 key / WVD —— 这两条是让这份代码可以被公开分享的前提。
