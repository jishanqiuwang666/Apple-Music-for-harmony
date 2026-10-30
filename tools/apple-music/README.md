# Apple Music 离线下载工具（个人自用）

把你自己 **Apple Music 订阅**里的音乐下载成普通 m4a 文件，再传到鸿蒙手机本地播放。

> ⚠️ **仅限个人自用**。这会绕过 Apple 的版权保护（DRM），违反 Apple Music 服务条款，理论上存在**账号被封**的风险，也请不要传播下载所得文件。你自己的订阅、你自己的设备、你自己听——风险请自行判断。

---

## 一、为什么用这条路（背景）

鸿蒙设备上实测：
- 系统 DRM 只有 `com.wiseplay.drm`，**没有 Widevine / FairPlay / PlayReady**
- ArkWeb 浏览器内核 EME 也不支持这三者 → Apple Music 网页版播不了全曲
- 所以「在手机上装个 Apple Music 客户端」这条路，只能靠**自己实现 Widevine 解密**（B 站那位 UP 主做的就是这个）

本方案换了个思路：**在电脑上一次性把歌下载成普通文件，手机只负责本地播放**——手机端零 DRM 依赖，稳定、省电、离线可用。

---

## 二、快速开始（3 步）

```bash
cd ~/vibecodingforharmony/tools/apple-music

# 1) 装环境（只做一次，约 1 分钟）
bash setup.sh

# 2) 准备 cookies（见下一节，拿到 media-user-token 后执行）
python3 make-cookies.py

# 3) 下载
./am-dl.sh "https://music.apple.com/cn/album/xxxxx"
```

默认下载到 `~/Music/AppleMusic`，按「艺人/专辑」自动分文件夹，标签和封面都会写好。

---

## 三、拿到 media-user-token（关键一步）

**先在浏览器登录** <https://music.apple.com>（账号必须是有订阅的）。

### 方法 A：手动复制（推荐，最省事）

1. 在 `music.apple.com` 页面按 `F12` 打开开发者工具
2. 切到 **Application / 应用程序** → 左侧 **Storage → Cookies → https://music.apple.com**
3. 在列表里找到 **`media-user-token`**，双击它 **Value** 列，全选复制（几百个字符的长串）
4. 回到终端执行：

```bash
cd ~/vibecodingforharmony/tools/apple-music
python3 make-cookies.py            # 粘贴后回车
```

### 方法 B：用扩展导出（如果方法 A 找不到该项）

- Chrome：装扩展 **Get cookies.txt LOCALLY** → 在 music.apple.com 页面点扩展 → Export
- Firefox：装扩展 **Export Cookies** → 导出

把导出得到的 `cookies.txt` 直接放到本目录（`tools/apple-music/cookies.txt`）即可，跳过 `make-cookies.py`。

> 只有 Safari 不方便导 cookie；用 Chrome / Firefox / Edge 登录一次即可，与 Safari 登录同一账号不冲突。

---

## 四、下载用法

```bash
# 单曲
./am-dl.sh "https://music.apple.com/cn/song/春日影/1234567890"

# 整张专辑
./am-dl.sh "https://music.apple.com/cn/album/xxxxx"

# 歌单（自己建的库歌单，链接形如 .../library/playlists/...）
./am-dl.sh "https://music.apple.com/cn/library/playlists/xxxxx"

# 一次多个
./am-dl.sh "URL1" "URL2" "URL3"

# 从文本文件批量（每行一个链接）
./am-dl.sh -f urls.txt

# 换输出目录
AM_OUTPUT=~/Music/MyAM ./am-dl.sh "URL"
```

**音质**：默认 `AAC 256kbps`（Apple Music 的高质量档，和手机端设置里的"高质量"一致）。
想下 **无损 ALAC** 需要额外跑一个 wrapper 服务（`glomatico/wrapper-v2`），步骤较多，暂时不建议；真要弄我再帮你配。

**同步歌词 / 封面 / 标签**：gamdl 会自动下载并写入（歌词默认 LRC）。

---

## 五、传输到手机

下载完之后，把 `~/Music/AppleMusic` 里的文件夹整体放到手机里 `Mymusic` 目录（你的播放器项目约定的扫描目录），然后打开播放器点刷新。

### 方法 1：一键推送（推荐，需要数据线）

```bash
# 手机开「开发者选项 → USB调试」并连上电脑，然后：
./sync-to-phone.sh
```

脚本会自动找手机上的 `Mymusic` 目录并推送过去。若提示找不到目录，先看提示里的命令确认路径，再：

```bash
AM_PHONE_DIR=<手机上的绝对路径> ./sync-to-phone.sh
```

### 方法 2：手动/图形方式

| 方式 | 命令/操作 | 说明 |
|---|---|---|
| USB + hdc（快） | `hdc file send ~/Music/AppleMusic <手机目录>` | 手机需开开发者模式并连电脑 |
| 华为手机助手 | 图形界面拖拽 | 无命令行，最省事 |
| 云盘 | 华为云空间 / 百度网盘上传后手机端下载 | 适合不在电脑边的时候 |
| 微信文件传输助手 | 单曲少量 | 方便但限速，不推荐批量 |

推送完成后：**打开播放器 → 点「刷新」**（如果提示重新授权目录，选 `我的手机/Mymusic`）。

---

### 方法 3：手机上直接在线听（电脑当音乐服务器，推荐家里用）

不用往手机里拷文件——电脑跑一个本地音乐服务，手机浏览器打开就能听、能搜、能拖动进度：

```bash
cd ~/vibecodingforharmony/tools/apple-music
python3 music-server.py
```

终端会打印一个 `http://192.168.x.x:8765/` 地址，**手机连同一个 Wi-Fi，浏览器打开它**即可：

- 按专辑分组的歌曲列表 + 搜索框
- 点歌即播（支持拖动进度、上一首/下一首、自动连播）
- 每首右侧有「下载」按钮，想离线存手机就点它
- 零第三方依赖（Python 标准库），Ctrl+C 停止

> 想在外网也能听：让电脑跑着服务 + 用 Tailscale/ZeroTier 组个虚拟局域网，手机装同款 App 即可（需电脑不睡眠）。

---

## 六、常见问题

**Q: 报错 `media-user-token cookie not found`**
→ cookies 没生成好：确认用 `make-cookies.py` 生成的是 `.music.apple.com` 域；或直接用扩展导出的 cookies.txt。

**Q: 报错连接超时 / 403**
→ 需要代理。脚本会自动尝试开 `~/scripts/vpn.sh`；也可以手动 `~/scripts/vpn.sh on` 后重跑。

**Q: 提示需要订阅 / 只能下 30 秒**
→ 该账号没有 Apple Music 订阅，或订阅已过期。

**Q: 会不会封号？**
→ 有理论风险（等于用第三方工具拉流）。建议：不要短时间大批量下载、不要分享下载的文件、不要用来做任何公开传播。真要稳妥，用小号订阅下载、大号日常用。

**Q: 为什么不用手机上直接下载？**
→ 手机端要跑 Python + Widevine 解密，工程量很大（等于把 gamdl 重写成鸿蒙 App）。电脑下载一次、手机离线听，是目前性价比最高的做法。

**Q: 能不能下无损 / 空间占用？**
→ AAC 256 一首约 8–10MB，一张专辑 100MB 左右；ALAC 无损约为其 3–5 倍。手机 256GB 放几千首没问题。

---

## 七、技术备注（给未来的自己）

- **不需要 Apple Developer 账号（省 688 元/年）**：Developer Token 由 gamdl 直接从 `music.apple.com` 首页的 `index.js` 里正则抓取（`iss: AMPWebPlay`，有效期约 70 天，自动刷新）。
- **不需要自己找 `.wvd`**：gamdl 内置了一份 Widevine L3 凭证（源码注释：Dumped from Android Studio Virtual Device running Android 9）。
- 解密链路：HLS 分片(CENC/AES-CTR) → pywidevine 向 Apple license 服务器取 key → 本地解密 → 写出 m4a。
- 版本：gamdl 3.8.5 / pywidevine 1.9.0 / Python 3.14（Homebrew），2026-09-11 验证可用。
- 目录结构：`setup.sh`（装环境）、`make-cookies.py`（生成 cookies）、`am-dl.sh`（下载）、本文件。
