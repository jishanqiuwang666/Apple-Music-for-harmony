/**
 * Widevine L3 CDM 核心（ArkTS 实现）
 *
 * 流程对齐 pywidevine：
 *   1. buildChallenge: 构造 LicenseRequest → RSA-SHA1 签名 → SignedMessage
 *   2. parseLicense  : RSA-OAEP 解 session_key → AES-CMAC 派生 enc/mac key
 *                      → HMAC-SHA256 校验签名 → AES-CBC 解出 content key
 *
 * 本机实测（Mate 60 Pro+ / HarmonyOS 6.1.1）所需算法全部可用。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PbWriter, PbReader, PbField, concatBytes, utf8Encode, bytesEqual, toHex } from './Pb';
import { WvdDevice } from './WvdParser';
import {
  loadRsaPrivateKeyFromPem, rsaSha1Sign, rsaOaepSha1Decrypt,
  aesCbcDecrypt, aesCmac, hmacSha256
} from './Crypto';

/** 一条内容密钥 */
export class ContentKey {
  id: Uint8Array = new Uint8Array(0);
  key: Uint8Array = new Uint8Array(0);
  type: number = 0;
}

/** challenge 生成后要留存的状态 */
export class ChallengeContext {
  requestId: Uint8Array = new Uint8Array(0);
  encContext: Uint8Array = new Uint8Array(0);
  macContext: Uint8Array = new Uint8Array(0);
  requestBody: Uint8Array = new Uint8Array(0);
}

/** KeyContainer 解析结果 */
class RawKeyContainer {
  id: Uint8Array = new Uint8Array(0);
  iv: Uint8Array = new Uint8Array(0);
  key: Uint8Array = new Uint8Array(0);
  type: number = 0;
}

const KEY_TYPE_CONTENT: number = 2;

export class WidevineCdm {
  private device: WvdDevice;
  private priKey: cryptoFramework.PriKey | null = null;

  constructor(device: WvdDevice) {
    this.device = device;
  }

  /** 载入设备私钥（DER → PEM → PriKey） */
  async init(): Promise<void> {
    this.priKey = await loadRsaPrivateKeyFromPem(this.device.privateKeyPem, this.device.rsaBits);
  }

  isReady(): boolean {
    return this.priKey !== null;
  }

  /** 字符串 → ASCII 字节 */
  private static toAscii(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
  }

  static randomBytes(n: number): Uint8Array {
    const blob: cryptoFramework.DataBlob = cryptoFramework.createRandom().generateRandomSync(n);
    return blob.data;
  }

  private static u32be(v: number): Uint8Array {
    return new Uint8Array([(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff]);
  }

  /** ENCRYPTION context = "ENCRYPTION" + 0x00 + msg + u32be(128) */
  private static encContext(msg: Uint8Array): Uint8Array {
    return concatBytes([utf8Encode('ENCRYPTION'), new Uint8Array([0]), msg, WidevineCdm.u32be(128)]);
  }

  /** AUTHENTICATION context = "AUTHENTICATION" + 0x00 + msg + u32be(512) */
  private static macContext(msg: Uint8Array): Uint8Array {
    return concatBytes([utf8Encode('AUTHENTICATION'), new Uint8Array([0]), msg, WidevineCdm.u32be(512)]);
  }

  /** _derive(key, context, counter) = CMAC(key, counter_byte + context) */
  private static async derive(key: Uint8Array, context: Uint8Array, counter: number): Promise<Uint8Array> {
    const data: Uint8Array = concatBytes([new Uint8Array([counter]), context]);
    return await aesCmac(key, data);
  }

  /**
   * 生成 license challenge
   * @param psshData Widevine PSSH payload（来自 HLS 清单的 pssh box 内容）
   * @param licenseType 1=STREAMING 2=OFFLINE 3=AUTOMATIC
   */
  async buildChallenge(psshData: Uint8Array, licenseType: number = 1): Promise<Uint8Array> {
    if (this.priKey === null) {
      throw new Error('CDM 未初始化，先调用 init()');
    }
    const ctx = new ChallengeContext();
    // Android 设备（WVD type=2）的 request_id 规则：random(4) + zeros(4) + session_number(8, LE)，
    // 然后整体转成 32 字节的大写 HEX 字符串（pywidevine 就是这么做的），否则服务端会拒
    const ridRaw = new Uint8Array(16);
    const rnd = WidevineCdm.randomBytes(4);
    ridRaw.set(rnd, 0);
    WidevineCdm.sessionCounter = WidevineCdm.sessionCounter + 1;
    let num: number = WidevineCdm.sessionCounter;
    for (let bi = 0; bi < 8; bi++) {
      ridRaw[8 + bi] = num % 256;
      num = Math.floor(num / 256);
    }
    const ridHex: string = toHex(ridRaw).toUpperCase();
    ctx.requestId = WidevineCdm.toAscii(ridHex);
    const nonce: number = Math.floor(Math.random() * 0x7fffffff) + 1;

    // WidevinePsshData { pssh_data=1, license_type=2, request_id=3 }
    const psshMsg: Uint8Array = new PbWriter()
      .bytes(1, psshData)
      .uint(2, licenseType)
      .bytes(3, ctx.requestId)
      .toUint8Array();

    // ContentIdentification { widevine_pssh_data=1 }
    const contentId: Uint8Array = new PbWriter().message(1, psshMsg).toUint8Array();

    // LicenseRequest
    const request: Uint8Array = new PbWriter()
      .bytes(1, this.device.clientId)
      .message(2, contentId)
      .uint(3, 1)
      .int64(4, Math.floor(new Date().getTime() / 1000))
      .uint(6, 21)
      .uint(7, nonce)
      .toUint8Array();

    ctx.requestBody = request;
    ctx.encContext = WidevineCdm.encContext(request);
    ctx.macContext = WidevineCdm.macContext(request);

    // signage: RSA-SHA1(license_request)
    const signature: Uint8Array = await rsaSha1Sign(this.priKey, this.device.rsaBits, request);

    // SignedMessage { type=1, msg=2, signature=3 }
    const signed: Uint8Array = new PbWriter()
      .uint(1, 1)
      .bytes(2, request)
      .bytes(3, signature)
      .toUint8Array();

    // 状态挂在返回的包装对象上（ArkTS 不支持动态属性，用静态 map 存）
    WidevineCdm.pending.set(toHex(ctx.requestId), ctx);
    WidevineCdm.lastDebug = 'rsaBits=' + this.device.rsaBits
      + ' requestIdLen=' + ctx.requestId.length
      + ' reqLen=' + request.length
      + ' sigLen=' + signature.length
      + ' challengeLen=' + signed.length
      + ' hex0=' + toHex(signed.subarray(0, 48));
    return signed;
  }

  /** requestId → context 的会话表 */
  private static pending: Map<string, ChallengeContext> = new Map<string, ChallengeContext>();

  /** 会话自增号（Android 的 request_id 需要，规则同 pywidevine） */
  private static sessionCounter: number = 0;

  /** 最近一次 challenge 的调试信息（供自检显示） */
  static lastDebug: string = '';

  /**
   * 解析 license 响应，返回内容密钥
   */
  async parseLicense(licenseMessage: Uint8Array): Promise<ContentKey[]> {
    if (this.priKey === null) {
      throw new Error('CDM 未初始化');
    }

    // ---- 解析外层 SignedMessage ----
    let type: number = 0;
    let msg: Uint8Array = new Uint8Array(0);
    let signature: Uint8Array = new Uint8Array(0);
    let sessionKey: Uint8Array = new Uint8Array(0);
    let oemCrypto: Uint8Array = new Uint8Array(0);

    const r = new PbReader(licenseMessage);
    while (!r.eof()) {
      const f: PbField | null = r.next();
      if (f === null) {
        break;
      }
      if (f.field === 1) {
        type = f.varint;
      } else if (f.field === 2) {
        msg = f.bytes;
      } else if (f.field === 3) {
        signature = f.bytes;
      } else if (f.field === 4) {
        sessionKey = f.bytes;
      } else if (f.field === 9) {
        oemCrypto = f.bytes;
      }
    }
    if (type !== 2) {
      throw new Error('不是 LICENSE 消息，type=' + type);
    }
    if (msg.length === 0) {
      throw new Error('license 消息为空');
    }

    // ---- 解析 License 头，取出 request_id ----
    let requestId: Uint8Array = new Uint8Array(0);
    const kr = new PbReader(msg);
    while (!kr.eof()) {
      const f: PbField | null = kr.next();
      if (f === null) {
        break;
      }
      if (f.field === 1) {
        // LicenseIdentification { request_id = 1 }
        const ir = new PbReader(f.bytes);
        while (!ir.eof()) {
          const g: PbField | null = ir.next();
          if (g === null) {
            break;
          }
          if (g.field === 1) {
            requestId = g.bytes;
          }
        }
      }
    }

    const ctxKey: string = toHex(requestId);
    const ctx: ChallengeContext | undefined = WidevineCdm.pending.get(ctxKey);
    if (ctx === undefined) {
      throw new Error('找不到该 license 对应的 challenge 上下文');
    }

    // ---- 解密 session_key，派生密钥 ----
    const sessionKeyPlain: Uint8Array = await rsaOaepSha1Decrypt(this.priKey, this.device.rsaBits, sessionKey);
    const encKey: Uint8Array = await WidevineCdm.derive(sessionKeyPlain, ctx.encContext, 1);
    const mac1: Uint8Array = await WidevineCdm.derive(sessionKeyPlain, ctx.macContext, 1);
    const mac2: Uint8Array = await WidevineCdm.derive(sessionKeyPlain, ctx.macContext, 2);
    const macKeyServer: Uint8Array = concatBytes([mac1, mac2]);

    // ---- 校验 license 签名（HMAC-SHA256）----
    const signedPart: Uint8Array = oemCrypto.length > 0 ? concatBytes([oemCrypto, msg]) : msg;
    const computed: Uint8Array = await hmacSha256(macKeyServer, signedPart);
    if (!bytesEqual(computed, signature)) {
      throw new Error('license 签名校验失败（可能是凭证不被服务端接受）');
    }

    // ---- 解出每个 KeyContainer 的内容密钥 ----
    const result: ContentKey[] = [];
    const br = new PbReader(msg);
    while (!br.eof()) {
      const f: PbField | null = br.next();
      if (f === null) {
        break;
      }
      if (f.field !== 3) {
        continue;
      }
      const kc: RawKeyContainer = WidevineCdm.parseKeyContainer(f.bytes);
      if (kc.key.length === 0 || kc.iv.length === 0) {
        continue;
      }
      const padded: Uint8Array = await aesCbcDecrypt(encKey, kc.iv, kc.key);
      const plain: Uint8Array = WidevineCdm.stripPkcs7(padded);
      const ck = new ContentKey();
      ck.id = kc.id;
      ck.key = plain;
      ck.type = kc.type;
      result.push(ck);
    }

    WidevineCdm.pending.delete(ctxKey);
    return result;
  }

  private static parseKeyContainer(data: Uint8Array): RawKeyContainer {
    const kc = new RawKeyContainer();
    const r = new PbReader(data);
    while (!r.eof()) {
      const f: PbField | null = r.next();
      if (f === null) {
        break;
      }
      if (f.field === 1) {
        kc.id = f.bytes;
      } else if (f.field === 2) {
        kc.iv = f.bytes;
      } else if (f.field === 3) {
        kc.key = f.bytes;
      } else if (f.field === 4) {
        kc.type = f.varint;
      }
    }
    return kc;
  }

  /** 去掉 PKCS#7 填充 */
  private static stripPkcs7(data: Uint8Array): Uint8Array {
    if (data.length === 0) {
      return data;
    }
    const pad: number = data[data.length - 1];
    if (pad <= 0 || pad > 16 || pad > data.length) {
      return data;
    }
    return data.subarray(0, data.length - pad);
  }

  /** 只取 CONTENT 类型的密钥 */
  static contentKeys(keys: ContentKey[]): ContentKey[] {
    const out: ContentKey[] = [];
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].type === KEY_TYPE_CONTENT) {
        out.push(keys[i]);
      }
    }
    return out;
  }
}
