# 🎯 根因与修复（2026-09-12 上午）—— 签名算法必须是 PSS

## 一句话结论

**Widevine LicenseRequest 必须用 RSASSA-PSS(SHA1) 签名，不能用 PKCS1 v1.5(SHA1)。**
我之前用 PKCS1，签名"数学上有效"（用设备公钥能验过），但**算法不匹配**，Apple 一律返回
`{"errorCode":-42585,"status":-1021}`。

## 怎么找到的（关键实验）

排查到后期，所有"肉眼可见"的差异都被排除了（challenge 结构、字段、长度、base64、headers、body、client_id），
于是做了这个对照实验：

```
① pywidevine 原始 challenge                     → status=0      OK ✅
② 用 openssl 命令行给同一个 LicenseRequest 签名 → status=-1021  FAIL
③ 把①解析后重新序列化（签名逐字节相同）        → status=-1021  FAIL
```

③ 失败但字节与①相同，说明**问题在签名算法本身**。回头看 pywidevine 源码：

```python
# pywidevine/cdm.py:121
self.__signer = pss.new(rsa_key)        # ← RSASSA-PSS！
...
# :362
signature=self.__signer.sign(SHA1.new(license_request))
```

用 Python 验证：

```
✅ PSS(SHA1) 验证通过 → pywidevine 用的是 PSS
❌ PKCS1(SHA1) 验证失败: Invalid signature
```

## PSS 参数（供各平台对齐）

| 项 | 值 |
|---|---|
| 算法 | RSASSA-PSS |
| hash | SHA1（对 LicenseRequest 的序列化字节取摘要） |
| MGF | MGF1 + SHA1 |
| salt 长度 | 20（= SHA1 摘要长度，PyCryptodome 默认） |
| 密钥 | WVD 里的 RSA2048 私钥 |

## 修复后的验证结果

用 Python 完全按 ArkTS 的构造逻辑（client_id 原始字节透传 + Android 风格 request_id + 手工字段顺序）
+ **PSS 签名** → 发送 → **`status=0, license 拿到`** ✅

说明 ArkTS 侧只要把 `RSA2048|PKCS1|SHA1` 换成 **`RSA2048|PSS|SHA1|MGF1_SHA1`** 即可。

## 鸿蒙端修复（已完成，编译通过）

`common/musicbasic/src/main/ets/apple/widevine/Crypto.ets`：

```typescript
export async function rsaPssSha1Sign(priKey: cryptoFramework.PriKey, bits: number,
                                     data: Uint8Array): Promise<Uint8Array> {
  const signer = cryptoFramework.createSign('RSA' + bits + '|PSS|SHA1|MGF1_SHA1');
  await signer.init(priKey);
  await signer.update(blob(data));
  const sig: cryptoFramework.DataBlob = await signer.sign(null);
  return sig.data;
}
```

（`rsaSha1Sign` 保留为别名，内部走 PSS）

## 顺带修掉的另一个 bug

WVD 私钥是 **RSA2048**（DER 1192 字节），原先我硬编码 `RSA1024` 导致签名只有 128 字节。
现在 `WvdParser` 会从 DER 里解析出 `rsaBits`（`detectRsaBits()`），动态选 `RSA1024/RSA2048/RSA4096`。

## 经验教训（值得记住）

1. **"签名验证有效" ≠ "签名算法正确"** —— 不同签名算法都能通过各自的验签，必须和**参照实现**逐字节/逐算法对齐
2. **排错要二分**：当所有字段都"看起来一致"时，用**第三方实现**（openssl 命令行）作为对照，能迅速把问题逼到最小范围
3. 上游开源项目（pywidevine）的**那一行初始化代码**（`pss.new(...)`）比任何文档都权威
