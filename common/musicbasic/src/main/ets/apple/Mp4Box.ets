/**
 * MP4（ISO BMFF）box 解析工具
 *
 * 只实现解密链路需要的部分：
 *   - box 遍历（size + type）
 *   - 大端整数读取
 *   - 定位 moof/traf/trun/senc/saiz/saio/mdat/stsd/enca/sinf/schi/tenc
 */

export class Box {
  /** 4 字符类型 */
  type: string = '';
  /** box 起始偏移 */
  start: number = 0;
  /** box 总长度（含 8 字节头） */
  size: number = 0;
  /** 内容起始偏移 */
  bodyStart: number = 0;
  /** 内容结束偏移（不含） */
  bodyEnd: number = 0;
}

export class Mp4 {
  /** 读大端 u32 */
  static u32(d: Uint8Array, off: number): number {
    return ((d[off] << 24) | (d[off + 1] << 16) | (d[off + 2] << 8) | d[off + 3]) >>> 0;
  }

  /** 读大端 i32 */
  static i32(d: Uint8Array, off: number): number {
    const v: number = Mp4.u32(d, off);
    return v > 0x7fffffff ? v - 0x100000000 : v;
  }

  /** 读大端 u16 */
  static u16(d: Uint8Array, off: number): number {
    return (d[off] << 8) | d[off + 1];
  }

  /** 读大端 u64（拆成 number，精度足够本用途） */
  static u64(d: Uint8Array, off: number): number {
    const hi: number = Mp4.u32(d, off);
    const lo: number = Mp4.u32(d, off + 4);
    return hi * 4294967296 + lo;
  }

  /** 读 4 字符类型 */
  static fourcc(d: Uint8Array, off: number): string {
    return String.fromCharCode(d[off], d[off + 1], d[off + 2], d[off + 3]);
  }

  /** 遍历 [start, end) 范围内的同级 box */
  static boxes(d: Uint8Array, start: number, end: number): Box[] {
    const out: Box[] = [];
    let off: number = start;
    while (off + 8 <= end) {
      let size: number = Mp4.u32(d, off);
      const type: string = Mp4.fourcc(d, off + 4);
      let header: number = 8;
      if (size === 1) {
        // 64 位长度
        size = Mp4.u64(d, off + 8);
        header = 16;
      } else if (size === 0) {
        size = end - off;
      }
      if (size < header || off + size > end) {
        break;
      }
      const b = new Box();
      b.type = type;
      b.start = off;
      b.size = size;
      b.bodyStart = off + header;
      b.bodyEnd = off + size;
      out.push(b);
      off += size;
    }
    return out;
  }

  /** 在 [start, end) 找第一个指定类型的 box */
  static find(d: Uint8Array, type: string, start: number, end: number): Box | null {
    const list: Box[] = Mp4.boxes(d, start, end);
    for (let i = 0; i < list.length; i++) {
      if (list[i].type === type) {
        return list[i];
      }
    }
    return null;
  }

  /** 在整段数据里找指定类型的 box（浅层遍历） */
  static findTop(d: Uint8Array, type: string): Box | null {
    return Mp4.find(d, type, 0, d.length);
  }

  /** 按路径逐层查找，如 ['moov','trak','mdia','minf','stbl','stsd'] */
  static findPath(d: Uint8Array, path: string[], start: number, end: number): Box | null {
    let s: number = start;
    let e: number = end;
    let found: Box | null = null;
    for (let i = 0; i < path.length; i++) {
      found = Mp4.find(d, path[i], s, e);
      if (found === null) {
        return null;
      }
      s = found.bodyStart;
      e = found.bodyEnd;
    }
    return found;
  }

  /** 在字节流中搜索 4 字符标记（用于 mdat 内部定位，如 senc 落在数据区时） */
  static indexOf(d: Uint8Array, tag: string, from: number): number {
    const a: number = tag.charCodeAt(0);
    const b: number = tag.charCodeAt(1);
    const c: number = tag.charCodeAt(2);
    const e2: number = tag.charCodeAt(3);
    for (let i = from; i + 4 <= d.length; i++) {
      if (d[i] === a && d[i + 1] === b && d[i + 2] === c && d[i + 3] === e2) {
        return i;
      }
    }
    return -1;
  }
}
