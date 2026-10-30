/**
 * WVD（Widevine Device）文件解析
 *
 * 二进制布局（v2）：
 *   "WVD"(3) | version(1)=2 | type(1) | security_level(1) | flags(1) |
 *   private_key_len(2, BE) | private_key(DER, PKCS#1) |
 *   client_id_len(2, BE) | client_id(protobuf ClientIdentification)
 */
import { util } from '@kit.ArkTS';
import { BUILTIN_WVD_BASE64 } from './BuiltinWvd';
import { detectRsaBits } from './Crypto';

export class WvdDevice {
  type: number = 2;               // 1 = CHROME, 2 = ANDROID
  securityLevel: number = 3;      // 1/2/3
  privateKeyDer: Uint8Array = new Uint8Array(0);
  privateKeyPem: string = '';     // 便于 convertPemKey 使用
  clientId: Uint8Array = new Uint8Array(0);
  /** RSA 位数（与私钥一致） */
  rsaBits: number = 2048;
}

export class WvdParser {
  private static base64(): util.Base64Helper {
    return new util.Base64Helper();
  }

  /** DER → PEM（PKCS#1 RSA PRIVATE KEY） */
  private static derToPem(der: Uint8Array): string {
    const b64: string = WvdParser.base64().encodeToStringSync(der);
    let body: string = '';
    for (let i = 0; i < b64.length; i += 64) {
      body += b64.substring(i, Math.min(i + 64, b64.length)) + '\n';
    }
    return '-----BEGIN RSA PRIVATE KEY-----\n' + body + '-----END RSA PRIVATE KEY-----\n';
  }

  /** 解析 WVD 二进制 */
  static parse(data: Uint8Array): WvdDevice {
    const dev = new WvdDevice();
    if (data.length < 12) {
      throw new Error('WVD 数据太短');
    }
    const magic: string = String.fromCharCode(data[0]) + String.fromCharCode(data[1]) + String.fromCharCode(data[2]);
    if (magic !== 'WVD') {
      throw new Error('WVD 魔数不正确: ' + magic);
    }
    const version: number = data[3];
    dev.type = data[4];
    dev.securityLevel = data[5];

    let off: number = 7; // 跳过 magic(3) + version(1) + type(1) + security(1) + flags(1)
    const pkLen: number = (data[off] << 8) | data[off + 1];
    off += 2;
    dev.privateKeyDer = data.subarray(off, off + pkLen);
    off += pkLen;
    const cidLen: number = (data[off] << 8) | data[off + 1];
    off += 2;
    dev.clientId = data.subarray(off, off + cidLen);
    dev.privateKeyPem = WvdParser.derToPem(dev.privateKeyDer);
    dev.rsaBits = detectRsaBits(dev.privateKeyDer);

    if (dev.privateKeyDer.length === 0 || dev.clientId.length === 0) {
      throw new Error('WVD 缺少私钥或 client_id（version=' + version + '）');
    }
    return dev;
  }

  /** 用内置凭证构建设备对象 */
  static parseBuiltin(): WvdDevice {
    const raw: Uint8Array = WvdParser.base64().decodeSync(BUILTIN_WVD_BASE64);
    return WvdParser.parse(raw);
  }
}
