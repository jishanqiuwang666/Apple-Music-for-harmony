/**
 * Widevine 用到的密码学操作封装
 *
 * 已在本机（Mate 60 Pro+ / HarmonyOS 6.1.1）实测可用：
 *   RSA|PKCS1|SHA1 签名 / RSA-OAEP(SHA1) 解密 / AES-CBC / AES-CTR / CMAC(AES128) / HMAC(SHA256)
 *
 * 注意：RSA 位数必须与 WVD 里私钥一致（内置凭证是 2048），否则签出来的签名长度不对，
 * 服务端会拒绝（表现为 license 返回 status=-1021）。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

function blob(data: Uint8Array): cryptoFramework.DataBlob {
  const spec: cryptoFramework.DataBlob = { data: data };
  return spec;
}

/** DER(PKCS#1 RSAPrivateKey) 里解析模数位数：1024 / 2048 / 4096 */
export function detectRsaBits(der: Uint8Array): number {
  try {
    let p: number = 0;
    if (der[p] !== 0x30) {
      return 2048;
    }
    p++;
    if ((der[p] & 0x80) !== 0) {
      p += 1 + (der[p] & 0x7f);
    } else {
      p++;
    }
    // 第一个 INTEGER：version
    if (der[p] !== 0x02) {
      return 2048;
    }
    p++;
    const vlen: number = der[p];
    p += 1 + vlen;
    // 第二个 INTEGER：modulus
    if (der[p] !== 0x02) {
      return 2048;
    }
    p++;
    let mlen: number = der[p];
    if ((mlen & 0x80) !== 0) {
      const n: number = mlen & 0x7f;
      mlen = 0;
      for (let i = 0; i < n; i++) {
        mlen = mlen * 256 + der[p + 1 + i];
      }
      p += 1 + n;
    } else {
      p++;
    }
    let bytes: number = mlen;
    if (der[p] === 0) {
      bytes--;
    }
    const bits: number = bytes * 8;
    if (bits === 1024 || bits === 2048 || bits === 4096) {
      return bits;
    }
    return 2048;
  } catch (e) {
    return 2048;
  }
}

/** 从 PEM 私钥字符串导入 RSA 私钥对象（位数必须匹配） */
export async function loadRsaPrivateKeyFromPem(pem: string, bits: number): Promise<cryptoFramework.PriKey> {
  const gen = cryptoFramework.createAsyKeyGenerator('RSA' + bits);
  const kp: cryptoFramework.KeyPair = await gen.convertPemKey('', pem);
  return kp.priKey;
}

/** RSA-PSS(SHA1) 签名 —— Widevine LicenseRequest 要求 PSS
 *  关键：必须把 salt 长度设为 20（= SHA1 摘要长度），
 *  鸿蒙默认用的是「最大 salt」（2048 位密钥 = 234 字节），服务端会拒绝。
 */
export async function rsaPssSha1Sign(priKey: cryptoFramework.PriKey, bits: number,
                                     data: Uint8Array): Promise<Uint8Array> {
  const signer = cryptoFramework.createSign('RSA' + bits + '|PSS|SHA1|MGF1_SHA1');
  try {
    signer.setSignSpec(cryptoFramework.SignSpecItem.PSS_SALT_LEN_NUM, 20);
  } catch (e) {
    // 老版本不支持该参数时忽略（会退回默认 salt）
  }
  await signer.init(priKey);
  await signer.update(blob(data));
  const sig: cryptoFramework.DataBlob = await signer.sign(null);
  return sig.data;
}

/** 兼容旧名（内部已改为 PSS） */
export async function rsaSha1Sign(priKey: cryptoFramework.PriKey, bits: number,
                                  data: Uint8Array): Promise<Uint8Array> {
  return rsaPssSha1Sign(priKey, bits, data);
}

/** RSA-OAEP(SHA1) 解密 —— 用于解 license 响应里的 session_key */
export async function rsaOaepSha1Decrypt(priKey: cryptoFramework.PriKey, bits: number,
                                         data: Uint8Array): Promise<Uint8Array> {
  const cipher = cryptoFramework.createCipher('RSA' + bits + '|PKCS1_OAEP|SHA1|MGF1_SHA1');
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, priKey, null);
  const out: cryptoFramework.DataBlob = await cipher.doFinal(blob(data));
  return out.data;
}

/** AES-CBC 解密（NoPadding） */
export async function aesCbcDecrypt(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await gen.convertKey(blob(key));
  const cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
  const params: cryptoFramework.IvParamsSpec = {
    iv: blob(iv),
    algName: 'IvParamsSpec'
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
  const out: cryptoFramework.DataBlob = await cipher.doFinal(blob(data));
  return out.data;
}

/** AES-CTR 解密（NoPadding）—— 用于 CENC 音频分片解密 */
export async function aesCtrDecrypt(key: Uint8Array, iv: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await gen.convertKey(blob(key));
  const cipher = cryptoFramework.createCipher('AES128|CTR|NoPadding');
  const params: cryptoFramework.IvParamsSpec = {
    iv: blob(iv),
    algName: 'IvParamsSpec'
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
  const out: cryptoFramework.DataBlob = await cipher.doFinal(blob(data));
  return out.data;
}

/** 批量解密的并发度（cipher 对象池大小）。 */
export const AES_CTR_BATCH_WORKERS: number = 8;

/**
 * 批量 AES-CTR 解密：一次解密多段独立密文（每段用自己的 IV）。
 *
 * 为什么需要它：{@link aesCtrDecrypt} 每次调用要经历
 * createSymKeyGenerator → convertKey → createCipher → init → doFinal 五次异步调用。
 * CENC 是 per-sample 加密的，一首 4 分钟的 AAC 有 5000~14000 个 sample，
 * 也就是几万次固定开销 —— 实测解密 3.8MB 要 4.6 秒，而真正的 AES 运算只占
 * 极小一部分。这里把密钥只转一次、每个 worker 复用一个 cipher（靠 init 重置
 * IV），并批内并发，把固定开销摊薄到几乎可以忽略。
 *
 * @param key 内容密钥（16 字节，整个文件同一把）
 * @param ivs 每段密文各自的 16 字节 CTR 计数器
 * @param datas 每段密文（调用方传拷贝，避免与本段写回互相干扰）
 * @returns 与 {@link datas} 等长、同样顺序的明文数组
 */
export async function aesCtrDecryptBatch(key: Uint8Array, ivs: Uint8Array[],
                                         datas: Uint8Array[]): Promise<Uint8Array[]> {
  const count: number = datas.length;
  const out: Uint8Array[] = [];
  for (let i = 0; i < count; i++) {
    out.push(new Uint8Array(0));
  }
  if (count === 0) {
    return out;
  }
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await gen.convertKey(blob(key));
  /** 共享的取任务游标（ArkTS 单线程事件循环，自增不会竞争）。 */
  let next: number = 0;
  const worker = async (): Promise<void> => {
    // 每个 worker 自己持有一个 cipher，靠 init 换 IV，避免重复 createCipher。
    const cipher = cryptoFramework.createCipher('AES128|CTR|NoPadding');
    while (true) {
      const i: number = next;
      if (i >= count) {
        return;
      }
      next++;
      const params: cryptoFramework.IvParamsSpec = {
        iv: blob(ivs[i]),
        algName: 'IvParamsSpec'
      };
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      const res: cryptoFramework.DataBlob = await cipher.doFinal(blob(datas[i]));
      out[i] = res.data;
    }
  };
  const workers: Promise<void>[] = [];
  const workerCount: number = Math.min(AES_CTR_BATCH_WORKERS, count);
  for (let k = 0; k < workerCount; k++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return out;
}

/** AES-CMAC —— 用于 Widevine 的密钥派生 */
export async function aesCmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await gen.convertKey(blob(key));
  const spec: cryptoFramework.CmacSpec = {
    algName: 'CMAC',
    cipherName: 'AES128'
  };
  const mac = cryptoFramework.createMac(spec);
  await mac.init(symKey);
  await mac.update(blob(data));
  const res: cryptoFramework.DataBlob = await mac.doFinal();
  return res.data;
}

/** HMAC-SHA256 —— 用于校验 license 响应签名 */
export async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  let symKey: cryptoFramework.SymKey;
  try {
    symKey = await gen.convertKey(blob(key));
  } catch (e) {
    const gen2 = cryptoFramework.createSymKeyGenerator('HMAC|SHA256');
    symKey = await gen2.convertKey(blob(key));
  }
  const spec: cryptoFramework.HmacSpec = {
    algName: 'HMAC',
    mdName: 'SHA256'
  };
  const mac = cryptoFramework.createMac(spec);
  await mac.init(symKey);
  await mac.update(blob(data));
  const res: cryptoFramework.DataBlob = await mac.doFinal();
  return res.data;
}

/** 由 raw key 创建 AES SymKey（流式解密时复用） */
export async function makeAesKey(key: Uint8Array): Promise<cryptoFramework.SymKey> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  return await gen.convertKey(blob(key));
}
