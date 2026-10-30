/**
 * CENC（ISO/IEC 23001-7）解密器 —— Apple Music 音频
 *
 * 实测格式（2026-09-11 真机分片解析确认）：
 *   schm = 'cenc'（AES-CTR）
 *   tenc.IVSize = 8
 *   senc 里每个 sample 存 16 字节 IV，实际使用前 8 字节（补 8 个 0 作为 128 位计数器）
 *   无 subsample：mdat 中每个 sample 的全部字节都是密文
 *
 * 使用方式：
 *   1) parseFragment(moof 所在数据) 拿到每个 sample 的 size 与 IV
 *   2) decryptSamples() 用 content key 就地解密
 */
import { Mp4, Box } from './Mp4Box';
import { aesCtrDecryptBatch } from './widevine/Crypto';

/** 一个 fragment 的解密信息 */
export class FragmentInfo {
  /** 每个 sample 的密文长度 */
  sizes: number[] = [];
  /** 每个 sample 的 IV（原样 16 字节） */
  ivs: Uint8Array[] = [];
  /** sample 数据在整段 buffer 里的起始偏移 */
  dataOffset: number = 0;
  /** moof box 的结束偏移（= mdat 起始的参考点） */
  moofStart: number = 0;
}

export class CencDecryptor {
  /** 调试：最近一次解密的关键信息 */
  static lastDecryptDebug: string = '';
  static dbg2: string = '';

  /**
   * 解析紧跟在 moof.start 处的一个 fragment，返回解密信息
   * @returns null 表示该处没有可解的 moof
   */
  static parseFragment(buf: Uint8Array, moofStart: number): FragmentInfo | null {
    const moof: Box | null = Mp4.find(buf, 'moof', moofStart, buf.length);
    if (moof === null || moof.start !== moofStart) {
      return null;
    }
    const traf: Box | null = Mp4.find(buf, 'traf', moof.bodyStart, moof.bodyEnd);
    if (traf === null) {
      return null;
    }

    // ── trun：每个 sample 的大小 ──
    const trun: Box | null = Mp4.find(buf, 'trun', traf.bodyStart, traf.bodyEnd);
    if (trun === null) {
      return null;
    }
    const info = new FragmentInfo();
    info.moofStart = moof.start;

    const tOff: number = trun.bodyStart;
    const tFlags: number = Mp4.u32(buf, tOff) & 0xffffff;
    let p: number = tOff + 4;
    const sampleCount: number = Mp4.u32(buf, p);
    p += 4;

    let dataOffsetRel: number = -1;
    if ((tFlags & 0x000001) !== 0) {
      dataOffsetRel = Mp4.i32(buf, p);
      p += 4;
    }
    if ((tFlags & 0x000004) !== 0) {
      p += 4; // first_sample_flags
    }

    const sizes: number[] = [];
    for (let i = 0; i < sampleCount; i++) {
      let size: number = 0;
      if ((tFlags & 0x000100) !== 0) {
        p += 4; // sample_duration
      }
      if ((tFlags & 0x000200) !== 0) {
        size = Mp4.u32(buf, p);
        p += 4;
      }
      if ((tFlags & 0x000400) !== 0) {
        p += 4; // sample_flags
      }
      if ((tFlags & 0x000800) !== 0) {
        p += 4; // composition time offset
      }
      sizes.push(size);
    }
    info.sizes = sizes;
    if (CencDecryptor.dbg2.length === 0) {
      CencDecryptor.dbg2 = 'DBG2 tFlags=0x' + tFlags.toString(16)
        + ' sampleCount=' + sampleCount
        + ' trunStart=' + trun.start + ' trunSize=' + trun.size
        + ' bodyStart=' + trun.bodyStart
        + ' head24=' + CencDecryptor.hexN(buf.subarray(trun.bodyStart, trun.bodyStart + 24))
        + ' sizes[0..3]=' + sizes[0] + ',' + (sizes.length > 1 ? sizes[1] : -1)
        + ',' + (sizes.length > 2 ? sizes[2] : -1);
    }

    // ── senc：每个 sample 的 IV ──
    const senc: Box | null = Mp4.find(buf, 'senc', traf.bodyStart, traf.bodyEnd);
    if (senc === null) {
      return null;
    }
    const sOff: number = senc.bodyStart;
    const sFlags: number = Mp4.u32(buf, sOff) & 0xffffff;
    let sp: number = sOff + 4;
    const sencCount: number = Mp4.u32(buf, sp);
    sp += 4;

    // ── senc 记录布局（CENC 规范）──
    // 每个 sample 一条记录：IV(default_Per_Sample_IV_Size 字节)
    //                       + [仅当 flags & 0x2：subsample_count(u16) + n×(clear u16 + enc u32)]
    //
    // 这里以前写死了「每 sample 16 字节」，对 Apple 的部分曲目恰好蒙对
    // （8 字节 IV + 2 字节 subsample 计数 + 6 字节 subsample = 16），
    // 但**没有 subsample 的曲目每 sample 只有 8 字节**，固定步长会让后面
    // 一半样本读到越界/错位的 IV（全零），那些样本根本没被解密 ——
    // 结果就是「有的歌能播、有的歌 AAC 解码全错、点了一直不播」。
    const hasSubsample: boolean = (sFlags & 0x000002) !== 0;
    let ivSize: number = 0;
    if (hasSubsample) {
      // 有 subsample 时必须靠 tenc 的 default_Per_Sample_IV_Size 才知道步长
      ivSize = CencDecryptor.tencIvSize(buf);
    } else {
      // 无 subsample：整块就是 count × ivSize，直接按剩余长度反推最稳
      const per: number = sencCount > 0 ? Math.floor((senc.bodyEnd - sp) / sencCount) : 0;
      ivSize = (per === 8 || per === 16) ? per : CencDecryptor.tencIvSize(buf);
    }

    const ivs: Uint8Array[] = [];
    for (let i = 0; i < sencCount; i++) {
      const iv = new Uint8Array(16);
      if (sp + ivSize <= senc.bodyEnd) {
        for (let k = 0; k < ivSize; k++) {
          iv[k] = buf[sp + k];
        }
      }
      sp += ivSize;
      if (hasSubsample && sp + 2 <= senc.bodyEnd) {
        const subs: number = Mp4.u16(buf, sp);
        sp += 2 + subs * 6;
      }
      ivs.push(iv);
    }
    info.ivs = ivs;

    // ── sample 数据起始位置 ──
    if (dataOffsetRel >= 0) {
      info.dataOffset = moof.start + dataOffsetRel;
    } else {
      const mdat: Box | null = Mp4.find(buf, 'mdat', moof.bodyEnd, buf.length);
      info.dataOffset = (mdat !== null) ? mdat.bodyStart : moof.bodyEnd;
    }
    return info;
  }

  /**
   * 就地解密一个 fragment 的所有 sample
   * @param key 16 字节内容密钥
   * @param buf 整段 buffer（含 moof 与 mdat）
   * @param info parseFragment 的结果
   */
  static async decryptFragment(key: Uint8Array, buf: Uint8Array, info: FragmentInfo): Promise<number> {
    let cursor: number = info.dataOffset;
    const n: number = Math.min(info.sizes.length, info.ivs.length);
    // 先把本分片内所有 sample 的密文与 IV 收齐，再交给批量接口一次解密。
    // 逐 sample 调 aesCtrDecrypt 时，每个 sample 都要重建 symKey + cipher，
    // 5162 个 sample 光固定开销就要 4.6 秒（实测），批量后降到几百毫秒。
    const ivs: Uint8Array[] = [];
    const datas: Uint8Array[] = [];
    const offsets: number[] = [];
    for (let i = 0; i < n; i++) {
      const size: number = info.sizes[i];
      if (size <= 0) {
        continue;
      }
      if (cursor + size > buf.length) {
        break;
      }
      ivs.push(CencDecryptor.expandIv(info.ivs[i]));
      // 用 slice 拷一份：批量解密期间不能受后续写回影响。
      datas.push(buf.slice(cursor, cursor + size));
      offsets.push(cursor);
      cursor += size;
    }
    const plains: Uint8Array[] = await aesCtrDecryptBatch(key, ivs, datas);
    let total: number = 0;
    for (let i = 0; i < plains.length; i++) {
      buf.set(plains[i], offsets[i]);
      total += plains[i].length;
    }
    return total;
  }

  /**
   * 整个文件解密：按 MP4 box 结构顺序遍历所有 moof，逐个解密对应 mdat
   * （不用字节搜索，避免 mdat 数据里出现 "moof" 假标记导致误判）
   */
  static async decryptWholeFile(key: Uint8Array, buf: Uint8Array): Promise<DecryptStats> {
    CencDecryptor.lastDecryptDebug = '';
    CencDecryptor.dbg2 = '';
    const stats = new DecryptStats();
    const top: Box[] = Mp4.boxes(buf, 0, buf.length);
    for (let i = 0; i < top.length; i++) {
      if (top[i].type !== 'moof') {
        continue;
      }
      const info: FragmentInfo | null = CencDecryptor.parseFragment(buf, top[i].start);
      if (info === null) {
        continue;
      }
      const bytes: number = await CencDecryptor.decryptFragment(key, buf, info);
      stats.fragments++;
      stats.samples += info.sizes.length;
      stats.bytes += bytes;
    }
    return stats;
  }

  /**
   * 读 init segment 里 tenc 盒子的 default_Per_Sample_IV_Size（偏移 3）。
   *
   * tenc body: reserved(1) crypt/skip(1) isProtected(1) ivSize(1) KID(16)
   * 取不到时返回 8（Apple HLS 的实测值）。
   */
  private static tencIvSize(buf: Uint8Array): number {
    const idx: number = Mp4.indexOf(buf, 'tenc', 0);
    if (idx < 4) {
      return 8;
    }
    const body: number = idx + 4;
    if (body + 4 > buf.length) {
      return 8;
    }
    const size: number = buf[body + 3];
    return (size === 8 || size === 16) ? size : 8;
  }


  static sumSizes(a: number[]): number {
    let t: number = 0;
    for (let i = 0; i < a.length; i++) { t += a[i]; }
    return t;
  }

  static hexN(d: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < d.length; i++) {
      const h: string = d[i].toString(16);
      out += h.length === 1 ? '0' + h : h;
    }
    return out;
  }

  /** senc 里 16 字节 IV → 128 位 CTR 计数器（前 8 字节 + 8 个 0） */
  static expandIv(iv16: Uint8Array): Uint8Array {
    const out = new Uint8Array(16);
    out[0] = iv16[0];
    out[1] = iv16[1];
    out[2] = iv16[2];
    out[3] = iv16[3];
    out[4] = iv16[4];
    out[5] = iv16[5];
    out[6] = iv16[6];
    out[7] = iv16[7];
    return out;
  }
}

export class DecryptStats {
  fragments: number = 0;
  samples: number = 0;
  bytes: number = 0;
}
