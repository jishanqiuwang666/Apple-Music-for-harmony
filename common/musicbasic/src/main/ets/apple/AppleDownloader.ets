/**
 * Apple Music 下载器：webPlayback → 子清单 → license → 下载 → CENC 解密 → 写 m4a
 *
 * 实测要点（2026-09-11）：
 *   - 整首歌是一个 MP4 文件（约 8-9MB），子清单用 byte-range 切片
 *   - 子清单的 #EXT-X-KEY:URI="data:;base64,<16字节 KID>"
 *   - 用该 URI 既作 license 请求的 uri，也用于重建 Widevine PSSH
 *   - 解密：CENC / AES-CTR，每 sample 16 字节 IV（取前 8 + 补零）
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../util/Logger';
import { AppleDiag } from './AppleDiag';
import { Mp4Cleaner } from './Mp4Cleaner';
import { AppleApi } from './AppleApi';
import { WebPlaybackInfo, AppleAsset } from './AppleModels';
import { HlsParser, HlsMediaInfo, HlsByteRange } from './HlsParser';
import { CencDecryptor, DecryptStats } from './CencDecryptor';
import { PbWriter } from './widevine/Pb';
import { WvdParser, WvdDevice } from './widevine/WvdParser';
import { WidevineCdm, ContentKey } from './widevine/WidevineCdm';
import { BUILTIN_WVD_BASE64 } from './widevine/BuiltinWvd';

const TAG: string = 'AppleDownloader';

/** 下载阶段 */
export enum DlStage {
  RESOLVING = 0,   // 解析播放地址
  LICENSING = 1,   // 获取密钥
  DOWNLOADING = 2, // 下载音频
  DECRYPTING = 3,  // 解密
  WRITING = 4,     // 写文件
  DONE = 5,
  FAILED = 6
}

export type DlProgress = (stage: DlStage, percent: number, note: string) => void;

export class DownloadResult {
  ok: boolean = false;
  filePath: string = '';
  message: string = '';
  bytes: number = 0;
  keyHex: string = '';
}

export class AppleDownloader {
  private static cdm: WidevineCdm | null = null;

  /**
   * 没有 Widevine 设备凭证（WVD）时的统一提示。
   *
   * 为什么不直接把底层异常抛给用户：公开分发包的 `WvdLocal.ets` 是空模板，
   * 走到取密钥那一步时 `Base64Helper.decodeSync('')` 会抛
   * `Parameter error. The type of Parameter must be string and the length greater than 0.`，
   * 而缓存层又会把它兜成「该歌曲没有可用的音频资源（可能需要订阅）」——
   * 用户会以为自己没订阅，实际只是包里没有解密能力。
   */
  static readonly MSG_NO_WVD: string =
    '本安装包不含 Widevine 设备凭证（WVD），无法解密播放；' +
    '请把自己的 WVD 填进 widevine/WvdLocal.ets 后重新构建';

  /** 本包是否带了可用的 WVD（公开分发包里为空） */
  static hasWvd(): boolean {
    return BUILTIN_WVD_BASE64.length > 0;
  }

  /** 懒加载 CDM（内置 Widevine L3 凭证） */
  private static async ensureCdm(): Promise<WidevineCdm> {
    if (AppleDownloader.cdm !== null && AppleDownloader.cdm.isReady()) {
      return AppleDownloader.cdm;
    }
    if (!AppleDownloader.hasWvd()) {
      throw new Error(AppleDownloader.MSG_NO_WVD);
    }
    const dev: WvdDevice = WvdParser.parseBuiltin();
    const cdm = new WidevineCdm(dev);
    await cdm.init();
    AppleDownloader.cdm = cdm;
    Logger.info(TAG, `CDM ready: type=${dev.type} level=${dev.securityLevel} clientId=${dev.clientId.length}B`);
    return cdm;
  }

  private static b64decode(s: string): Uint8Array {
    return new util.Base64Helper().decodeSync(s);
  }

  private static b64encode(d: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(d);
  }

  /**
   * 由 #EXT-X-KEY 的 URI 构造 Widevine PSSH
   * 规则同 gamdl：>30 字节视为完整 PSSH box，否则视为 KID 并包进 WidevinePsshData
   */
  static buildPssh(keyUri: string): Uint8Array {
    const parts: string[] = keyUri.split(',');
    const b64: string = parts[parts.length - 1];
    const decoded: Uint8Array = AppleDownloader.b64decode(b64);
    if (decoded.length > 30) {
      return decoded;
    }
    // WidevinePsshData { algorithm = 1; repeated bytes key_ids = 2; }
    return new PbWriter().uint(1, 1).bytes(2, decoded).toUint8Array();
  }

  /**
   * 下载并解密一首歌
   * @param songId Apple Music 歌曲 ID
   * @param isLibrary 是否资料库歌曲
   * @param outPath 目标文件绝对路径（沙箱内）
   * @param onProgress 进度回调
   */
  static async downloadSong(songId: string, isLibrary: boolean, outPath: string,
                            onProgress?: DlProgress): Promise<DownloadResult> {
    const res = new DownloadResult();
    const report: DlProgress = onProgress ?? ((s: DlStage, p: number, n: string) => {
    });
    try {
      // ⓪ 前置检查：包里没带 WVD 时立刻给出可读原因，
      //    不必先白跑一次 webPlayback + 清单请求再在取密钥处失败。
      if (!AppleDownloader.hasWvd()) {
        throw new Error(AppleDownloader.MSG_NO_WVD);
      }
      // ① 拿播放资产
      report(DlStage.RESOLVING, 2, '解析播放地址');
      const wb: WebPlaybackInfo = await AppleApi.getWebPlayback(songId, isLibrary);
      const target: AppleAsset | null = AppleDownloader.pickAsset(wb.assets);
      if (target === null || target.url.length === 0) {
        throw new Error('该歌曲没有可用的音频资源（可能需要订阅）');
      }
      // webPlayback 的 songList[0].songId 是 **catalog id**（数字）：
      // 资料库歌曲（id 形如 i.xxx）也会在这里被换回 catalog id。
      // license 交换必须用这个 id 且 isLibrary=false —— 用资料库 id 会拿到
      // {"status":-1003}。与 gamdl `_get_web_stream_info` 的处理一致。
      const catalogId: string = wb.songId.length > 0 ? wb.songId : songId;
      Logger.info(TAG, `asset flavor=${target.flavor} libraryId=${songId} catalogId=${catalogId}`);

      // ② 子清单
      report(DlStage.RESOLVING, 6, '解析音频清单');
      const subText: string = await AppleApi.downloadText(target.url);
      const media: HlsMediaInfo = HlsParser.parseMedia(subText, target.url);
      if (media.keyUri.length === 0) {
        throw new Error('清单里没有密钥信息');
      }
      Logger.info(TAG, `子清单: method=${media.keyMethod} init=${media.initUri} segs=${media.segments.length}`);

      // ③ 取密钥
      report(DlStage.LICENSING, 12, '获取解密密钥');
      const key: Uint8Array = await AppleDownloader.fetchKey(catalogId, false, media.keyUri);
      res.keyHex = AppleDownloader.hex(key);
      Logger.info(TAG, 'content key = ' + res.keyHex);

      // ④ 下载整段音频
      report(DlStage.DOWNLOADING, 20, '下载音频数据');
      const mediaUrl: string = HlsParser.absolute(media.baseUrl, media.mediaUri);
      const totalLen: number = AppleDownloader.totalLength(media);
      const data: Uint8Array = await AppleDownloader.downloadMedia(mediaUrl, media, totalLen,
        (p: number) => {
          report(DlStage.DOWNLOADING, 20 + Math.floor(p * 0.45), '下载音频数据');
        });
      // data 可能被后续步骤（删 pssh）替换成新数组，因此这里用 let 保存
      let out: Uint8Array = data;

      // ⑤ 解密
      report(DlStage.DECRYPTING, 68, '解密中');
      const headBefore: string = AppleDownloader.hex(data.subarray(0, 24));
      const stats: DecryptStats = await CencDecryptor.decryptWholeFile(key, data);
      const headAfter: string = AppleDownloader.hex(data.subarray(0, 24));
      Logger.info(TAG, 'decrypt before=' + headBefore + ' after=' + headAfter +
        ' changed=' + (headBefore === headAfter ? 'NO(!!)' : 'yes'));
      Logger.info(TAG, `解密完成: fragments=${stats.fragments} samples=${stats.samples} bytes=${stats.bytes}`);
      if (stats.samples === 0) {
        throw new Error('没有解出任何音频数据（格式可能变了）');
      }

      // ⑥ 写文件前的容器处理（两步，顺序不能颠倒）：
      //
      //    ① blankCenc：把 senc/saiz/saio/sgpd/sbgp/sinf 的类型名**就地改成 free**
      //       （等长改写，长度与偏移一律不变）。
      //       为什么必须做：鸿蒙 7 的媒体解复用器换成 FFmpeg 后会校验 `senc`
      //       的样本数与轨道样本数，对不上就报
      //       `[FFLogE] Incorrect number of samples in encryption info`，
      //       AVPlayer 随后抛 5400103（DEM_PARSE_ERR）→ 表现就是「播不了」。
      //       为什么是「改名」而不是「删除」：早前在鸿蒙 6 上实测直接删这些 box
      //       会改变长度/相对偏移，导致 AVPlayer native 层崩溃；改名则零结构变化。
      //
      //    ② stripPssh：Apple 给部分曲目下发了 Widevine 的 pssh（约 484 字节），
      //       解密成明文后若留着，AVPlayer 会去等永远不会到来的 DRM 授权，
      //       prepare() 永不完成（「有的歌点了完全没反应」）。它位于 moov 末尾，
      //       删除只改 moov 长度、不动任何相对偏移。
      report(DlStage.WRITING, 92, '写入文件');
      const blanked: number = Mp4Cleaner.blankCenc(out);
      out = Mp4Cleaner.stripPssh(out);
      Logger.info(TAG, `CENC 描述清理：改名 ${blanked} 个 box → free`);
      AppleDownloader.normalizeFtyp(out);
      AppleDownloader.writeFile(outPath, out);
      res.ok = true;
      res.filePath = outPath;
      res.bytes = out.length;
      res.message = 'frags=' + stats.fragments + ' samples=' + stats.samples + ' decBytes=' + stats.bytes + ' changed=' + (headBefore === headAfter ? 'NO' : 'yes');
      report(DlStage.DONE, 100, '完成');
      Logger.info(TAG, `已写出 ${outPath} (${out.length} bytes)`);
    } catch (e) {
      const msg: string = (e as Error).message ?? JSON.stringify(e);
      res.ok = false;
      res.message = msg;
      report(DlStage.FAILED, 0, msg);
      Logger.error(TAG, 'downloadSong failed: ' + msg);
      // 清掉可能残留的临时文件
      try {
        fileIo.unlinkSync(outPath + '.part');
      } catch (err) {
        // 忽略
      }
    }
    return res;
  }

  /** 从 assets 里挑 256kbps 的 aac-web（28:ctrp256），退而求其次选任意 aac */
  private static pickAsset(assets: AppleAsset[]): AppleAsset | null {
    if (assets.length === 0) {
      return null;
    }
    for (let i = 0; i < assets.length; i++) {
      if (assets[i].flavor.indexOf('ctrp256') >= 0) {
        return assets[i];
      }
    }
    for (let i = 0; i < assets.length; i++) {
      if (assets[i].flavor.indexOf('256') >= 0) {
        return assets[i];
      }
    }
    return assets[0];
  }

  /** 走 Widevine 取 content key */
  private static async fetchKey(songId: string, isLibrary: boolean, keyUri: string): Promise<Uint8Array> {
    const cdm: WidevineCdm = await AppleDownloader.ensureCdm();
    const pssh: Uint8Array = AppleDownloader.buildPssh(keyUri);
    const challenge: Uint8Array = await cdm.buildChallenge(pssh, 1);
    Logger.info(TAG, 'challenge debug: ' + WidevineCdm.lastDebug);
    const challengeB64: string = AppleDownloader.b64encode(challenge);
    const chHead: string = challengeB64.substring(0, 32);
    const chTail: string = challengeB64.substring(challengeB64.length - 8);
    WidevineCdm.lastDebug = WidevineCdm.lastDebug
      + ' b64Len=' + challengeB64.length
      + ' b64Head=' + chHead
      + ' b64Tail=' + chTail;
    const licB64: string = await AppleApi.getLicense(challengeB64, keyUri, songId, isLibrary);
    const licBytes: Uint8Array = AppleDownloader.b64decode(licB64);
    const keys: ContentKey[] = await cdm.parseLicense(licBytes);
    const content: ContentKey[] = WidevineCdm.contentKeys(keys);
    if (content.length === 0) {
      throw new Error('license 里没有 CONTENT 类型的密钥');
    }
    return content[0].key;
  }

  /** 计算整段媒体的总长度（init + 全部分片） */
  private static totalLength(media: HlsMediaInfo): number {
    let max: number = media.initRange.offset + media.initRange.length;
    for (let i = 0; i < media.segments.length; i++) {
      const s: HlsByteRange = media.segments[i];
      const end: number = s.offset + s.length;
      if (end > max) {
        max = end;
      }
    }
    return max;
  }

  /**
   * 并发分片下载的并发度（1 = 整段单请求）。
   *
   * 实测瓶颈分析：Apple 的同一段音频，整段单请求用时在不同网络下波动极大
   * （0.16s ~ 19s），并发 Range 分片实测能到 2.3 倍。HLS 子清单本来就给了
   * 每片的字节范围，直接并发取回来按偏移拼进整段缓冲即可。
   */
  static parallelChunks: number = 4;

  /**
   * 下载媒体：默认按 HLS 分片并发 Range 拉取并拼成整段；分片信息不可用时
   * 回退成一次整段 GET。
   */
  /**
   * 校验 HLS 分片能否无缝铺满 [initEnd, totalLen)。
   *
   * 拼装式下载只有在分片**不重叠、不空洞、且用完整个文件**时才安全；
   * 一旦清单格式有变（比如 offset 语义变了），宁可回退整段单请求，
   * 也不能悄悄拼出一个 AVPlayer 打不开的文件。
   */
  private static rangesCover(init: HlsByteRange, segs: HlsByteRange[], totalLen: number): boolean {
    let expect: number = init.offset + init.length;
    for (let i = 0; i < segs.length; i++) {
      const seg: HlsByteRange = segs[i];
      if (seg.length <= 0) {
        return false;
      }
      if (seg.offset !== expect) {
        return false;
      }
      expect = seg.offset + seg.length;
    }
    return expect === totalLen;
  }

  private static async downloadMedia(url: string, media: HlsMediaInfo, totalLen: number,
                                     onProgress: (p: number) => void): Promise<Uint8Array> {
    const segs: HlsByteRange[] = media.segments;
    if (AppleDownloader.parallelChunks <= 1 || segs.length <= 1 ||
      !AppleDownloader.rangesCover(media.initRange, segs, totalLen)) {
      // 分片信息不可用/不连续时保守回退：宁可慢一点，也不能拼出一个坏文件。
      AppleDiag.log('downloadMedia: 分片不连续，回退整段单请求');
      onProgress(0.05);
      const whole: Uint8Array = await AppleApi.downloadRange(url, -1, -1);
      onProgress(1.0);
      return whole;
    }
    const buf = new Uint8Array(totalLen);
    let done: number = 0;
    // init segment（ftyp+moov）单独取一次，它不在分片列表里。
    const initLen: number = media.initRange.length;
    if (initLen > 0) {
      const head: Uint8Array =
        await AppleApi.downloadRange(url, media.initRange.offset, media.initRange.offset + initLen - 1);
      const hn: number = Math.min(head.length, initLen);
      buf.set(head.subarray(0, hn), media.initRange.offset);
      done += hn;
    }
    let next: number = 0;
    let aborted: boolean = false;
    const worker = async (): Promise<void> => {
      while (true) {
        if (aborted) {
          return;
        }
        const i: number = next;
        if (i >= segs.length) {
          return;
        }
        next++;
        const seg: HlsByteRange = segs[i];
        const part: Uint8Array =
          await AppleApi.downloadRange(url, seg.offset, seg.offset + seg.length - 1);
        const n: number = Math.min(part.length, seg.length);
        buf.set(part.subarray(0, n), seg.offset);
        done += n;
        onProgress(Math.min(1, done / totalLen));
      }
    };
    const workers: Promise<void>[] = [];
    const n: number = Math.min(AppleDownloader.parallelChunks, segs.length);
    for (let k = 0; k < n; k++) {
      workers.push(worker());
    }
    try {
      await Promise.all(workers);
    } catch (err) {
      aborted = true;
      throw err as Error;
    }
    return buf;
  }

  /**
   * 把 fMP4 的 `ftyp` major_brand 归一化成 `iso5`（等长字节替换，不移动任何偏移）。
   *
   * 实测：Apple 给不同曲目下发的 fMP4 容器 brand 不统一，部分是 `mp42`。
   * 这里只改 brand 这 4/8 个字节，绝不碰其他 box —— 试过剥离 senc/saiz/sinf
   * 等 DRM 元数据，结果是从「AVPlayer 卡住」恶化成「native 崩溃退进程」。
   */
  private static normalizeFtyp(data: Uint8Array): void {
    if (data.length < 16 || data[4] !== 0x66 || data[5] !== 0x74 ||
      data[6] !== 0x79 || data[7] !== 0x70) {
      return;
    }
    const size: number = (data[0] << 24 | data[1] << 16 | data[2] << 8 | data[3]) >>> 0;
    if (size < 16 || size > data.length) {
      return;
    }
    if (data[8] === 0x6d && data[9] === 0x70 && data[10] === 0x34) {
      data[8] = 0x69;
      data[9] = 0x73;
      data[10] = 0x6f;
      data[11] = 0x35;
    }
    let off: number = 16;
    while (off + 4 <= size) {
      if (data[off] === 0x6d && data[off + 1] === 0x70 && data[off + 2] === 0x34) {
        if (data[off + 3] === 0x31) {
          data[off] = 0x69;
          data[off + 1] = 0x73;
          data[off + 2] = 0x6f;
          data[off + 3] = 0x35;
        } else if (data[off + 3] === 0x32) {
          data[off] = 0x69;
          data[off + 1] = 0x73;
          data[off + 2] = 0x6f;
          data[off + 3] = 0x6d;
        }
      }
      off += 4;
    }
    Logger.info(TAG, 'ftyp normalized to iso5');
  }

  /** 字符串 → 字节数组 */
  private static ascii(s: string): number[] {
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      out.push(s.charCodeAt(i));
    }
    return out;
  }

  /**
   * 原子写入：先写 `<path>.part`，落盘后再改名到目标路径。
   *
   * 直接 TRUNC 写目标路径的话，一旦进程被杀 / 并发写，会在缓存路径上留下
   * 一个半截的 m4a，而它会被当成有效缓存长期命中 —— 对应歌曲就再也播不出来。
   * 先写临时文件再 rename 可以保证「缓存路径上出现的文件一定是完整的」。
   */
  private static writeFile(path: string, data: Uint8Array): void {
    const tmp: string = path + '.part';
    const f = fileIo.openSync(tmp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(f.fd, data.buffer);
      try {
        fileIo.fsyncSync(f.fd);
      } catch (err) {
        // 部分设备不支持 fsync，忽略
      }
    } finally {
      fileIo.closeSync(f);
    }
    try {
      fileIo.unlinkSync(path);
    } catch (err) {
      // 目标不存在时忽略
    }
    fileIo.renameSync(tmp, path);
  }

  private static hex(d: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < d.length; i++) {
      const h: string = d[i].toString(16);
      s += h.length === 1 ? '0' + h : h;
    }
    return s;
  }
}
