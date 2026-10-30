/**
 * HLS（m3u8）解析 —— Apple Music 音频清单
 *
 * Apple 的形态（实测）：
 *   主清单：变体列表 + #EXT-X-SESSION-KEY（Widevine PSSH）
 *   子清单：#EXT-X-KEY:METHOD=ISO-23001-7,URI="data:;base64,..."
 *           #EXT-X-MAP:URI="xxx.mp4",BYTERANGE="1006@0"
 *           #EXT-X-BYTERANGE:324055@1006   ← 分片都在同一个 mp4 文件里
 */

/** byte-range（长度 @ 偏移） */
export class HlsByteRange {
  length: number = 0;
  offset: number = 0;
}

/** 子清单解析结果 */
export class HlsMediaInfo {
  /** 密钥 URI（Apple 给的是 data:;base64,<16字节KID>） */
  keyUri: string = '';
  /** 密钥方法（ISO-23001-7 = CENC） */
  keyMethod: string = '';
  /** init segment 的文件名 */
  initUri: string = '';
  /** init segment 的字节范围 */
  initRange: HlsByteRange = new HlsByteRange();
  /** 分片所属媒体文件名（通常和 init 同文件） */
  mediaUri: string = '';
  /** 各分片的字节范围 */
  segments: HlsByteRange[] = [];
  /** 清单所在目录（用于拼绝对地址） */
  baseUrl: string = '';
}

/** 主清单解析结果 */
export class HlsMasterInfo {
  /** 各变体清单地址 */
  variants: string[] = [];
  /** Widevine 的 PSSH（data: 形式的 URI） */
  widevinePssh: string = '';
  /** skd 形式的密钥 URI（备用） */
  skdUris: string[] = [];
  baseUrl: string = '';
}

export class HlsParser {
  /** 目录前缀 */
  private static dirOf(url: string): string {
    const i: number = url.lastIndexOf('/');
    return i >= 0 ? url.substring(0, i + 1) : url;
  }

  private static abs(base: string, uri: string): string {
    if (uri.startsWith('http://') || uri.startsWith('https://') || uri.startsWith('data:')) {
      return uri;
    }
    return base + uri;
  }

  /**
   * 解析 `#EXT-X-BYTERANGE:<长度>[@偏移]`。
   *
   * HLS 规范：**`@偏移` 可以省略**，省略时表示「紧接上一个 sub-range 之后」，
   * 即 offset = 上一段的 offset + length。以前省略时默认成 0，导致同一清单里
   * 所有分片的偏移都是 0 —— 整段拼装时后写的分片全部覆盖在文件开头，
   * 下出来的文件完全是坏的（AVPlayer 打不开，表现为「点了歌一直不播」）。
   *
   * @param s 清单里的原始值
   * @param prevEnd 上一段结束位置（offset + length），首段传 0
   */
  private static parseRange(s: string, prevEnd: number): HlsByteRange {
    const r = new HlsByteRange();
    const parts: string[] = s.split('@');
    const len: number = parseInt(parts[0], 10);
    r.length = isNaN(len) ? 0 : len;
    if (parts.length > 1) {
      const off: number = parseInt(parts[1], 10);
      r.offset = isNaN(off) ? prevEnd : off;
    } else {
      r.offset = prevEnd;
    }
    return r;
  }

  /** 解析主清单 */
  static parseMaster(text: string, url: string): HlsMasterInfo {
    const info = new HlsMasterInfo();
    info.baseUrl = HlsParser.dirOf(url);
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const l: string = lines[i].trim();
      if (l.startsWith('#EXT-X-SESSION-KEY')) {
        const m: RegExpMatchArray | null = l.match(/URI="([^"]+)"/);
        const fmt: RegExpMatchArray | null = l.match(/KEYFORMAT="([^"]+)"/);
        if (m !== null) {
          const uri: string = m[1];
          if (fmt !== null && fmt[1].indexOf('edef8ba9') >= 0) {
            info.widevinePssh = uri;
          } else if (uri.startsWith('skd://')) {
            info.skdUris.push(uri);
          }
        }
      } else if (l.length > 0 && !l.startsWith('#')) {
        info.variants.push(HlsParser.abs(info.baseUrl, l));
      }
    }
    return info;
  }

  /** 解析子清单（音频清单） */
  static parseMedia(text: string, url: string): HlsMediaInfo {
    const info = new HlsMediaInfo();
    info.baseUrl = HlsParser.dirOf(url);
    const lines: string[] = text.split('\n');
    let pendingRange: HlsByteRange | null = null;
    /** 上一段 byte-range 的结束位置（省略 @offset 时用它累加）。 */
    let prevEnd: number = 0;

    for (let i = 0; i < lines.length; i++) {
      const l: string = lines[i].trim();

      if (l.startsWith('#EXT-X-KEY')) {
        const mm: RegExpMatchArray | null = l.match(/METHOD=([^,]+)/);
        if (mm !== null) {
          info.keyMethod = mm[1];
        }
        const mu: RegExpMatchArray | null = l.match(/URI="([^"]+)"/);
        if (mu !== null) {
          info.keyUri = mu[1];
        }
      } else if (l.startsWith('#EXT-X-MAP')) {
        const mu: RegExpMatchArray | null = l.match(/URI="([^"]+)"/);
        if (mu !== null) {
          info.initUri = mu[1];
          info.mediaUri = mu[1];
        }
        const mr: RegExpMatchArray | null = l.match(/BYTERANGE="([^"]+)"/);
        if (mr !== null) {
          info.initRange = HlsParser.parseRange(mr[1], 0);
          prevEnd = info.initRange.offset + info.initRange.length;
        }
      } else if (l.startsWith('#EXT-X-BYTERANGE')) {
        const v: string = l.substring('#EXT-X-BYTERANGE:'.length);
        pendingRange = HlsParser.parseRange(v, prevEnd);
      } else if (l.length > 0 && !l.startsWith('#')) {
        // 媒体分片行
        if (info.mediaUri.length === 0) {
          info.mediaUri = l;
        }
        if (pendingRange !== null) {
          info.segments.push(pendingRange);
          prevEnd = pendingRange.offset + pendingRange.length;
          pendingRange = null;
        } else {
          // 没有 byterange：整文件作为一个分片
          const r = new HlsByteRange();
          r.length = 0;
          r.offset = 0;
          info.segments.push(r);
        }
      }
    }
    return info;
  }

  /** 把相对 URI 拼成绝对地址 */
  static absolute(baseUrl: string, uri: string): string {
    return HlsParser.abs(baseUrl, uri);
  }
}
