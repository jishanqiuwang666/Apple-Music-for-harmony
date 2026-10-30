# Widevine License 调试记录（2026-09-12 凌晨）

## 结论：卡在 license 请求（Apple 返回 `{"errorCode":-42585,"status":-1021}`）

## 已经做通的（真机实测）

| 环节 | 状态 | 证据 |
|---|---|---|
| user token 注入 | ✅ | len=246 |
| developer token 抓取 | ✅ | len=268（从 music.apple.com index.js） |
| 账号校验 | ✅ | `{"meta":{"subscription":{"active":true,"storefront":"cn"}}}` |
| webPlayback 取资源 | ✅ | 拿到 6 个 flavor 的资产 URL |
| 子清单解析 | ✅ | `METHOD=ISO-23001-7`、`#EXT-X-MAP`、28 个 byte-range 分片 |
| WVD 解析 + CDM 初始化 | ✅ | rsaBits=2048（原先错写成 1024 已修） |
| RSA-SHA1 签名 | ✅ | 256 字节，用设备公钥验证**通过** |
| challenge 生成 | ✅ | 2134 字节（与 pywidevine 同长同构） |

## 卡点定位过程（排除了所有外部因素）

1. **对比 pywidevine**：设备 challenge 与 pywidevine challenge **逐字段一致**
   - field1 client_id(1789B) ✅、field2 content_id(60B) ✅、type=1 ✅、request_time ✅、protocol_version=21 ✅、key_control_nonce ✅
   - **唯一差异**：request_id 的随机值（`B8D4417A…` vs `39C9FC3D…`），格式完全相同（32 字节 ASCII hex）
2. **签名有效性**：用 WVD 公钥 `pkcs1_15.verify(SHA1(msg), sig)` → **通过**
3. **base64 编码**：与 pywidevine 前 32 字符逐字符一致，长度 2848
4. **HTTP 层**：临时搭了转发代理抓到设备真实请求 →
   - body 3005 字节，JSON 合法，challenge/uri/adamId 全对
   - headers：authorization✅ cookie✅ content-type✅ origin✅
   - **代理原样转发给 Apple → 仍然被拒**
5. **凭证是否被限流**：同一时间用 Python 跑成功的脚本 → **成功**（拿到 content key）
6. **终极判断**：把【设备原样的 challenge】拿到纯 Python 环境发送 → **同样被拒**

**⇒ 已排除**：鸿蒙 http 模块、headers、body 编码、base64、签名算法、凭证有效性、网络环境。
**⇒ 剩下的可能**：challenge 里有某个**肉眼与逐字段对比都看不出来**的差异（可能是签名值本身的某个特性，或 Apple 对 request_id 值的隐性校验）。

## 下一步建议（三选一）

**A. 继续追查**（时间不可控）
- 思路：用"二分法" —— 把 pywidevine 的 LicenseRequest 逐段替换为设备的对应段，定位到具体字节

**B. 换实现：NDK + OpenSSL**（推荐）
- 用 C++ 重写 Widevine 的密码学部分（RSA-SHA1 签名、RSA-OAEP、CMAC、AES），通过 NAPI 暴露给 ArkTS
- 理由：OpenSSL 与 PyCryptodome 行为完全一致，能消除"密码学实现差异"这个最大变量
- 工作量：2–3 天（CMake + NAPI + 移植已有流程）

**C. 务实方案**
- 先用"电脑下载（gamdl）→ 传输到手机"顶着（这条已经验证可用）
- 原生客户端等 B 方案完成后再继续

## 本次新增/修改的文件

- `common/musicbasic/src/main/ets/apple/`（12 个文件，HAR 已编译通过）
  - `AppleApi.ets` / `AppleModels.ets` / `AppleDownloader.ets` / `AppleCache.ets`
  - `HlsParser.ets` / `Mp4Box.ets` / `CencDecryptor.ets`
  - `widevine/{Pb,Crypto,WvdParser,BuiltinWvd,WidevineCdm}.ets`
- `tools/apple-music/app/`（POC 工程，真机自检用）
- 备份：`backups/musichome-before-applemusic-20260911-214027.tar.gz`
