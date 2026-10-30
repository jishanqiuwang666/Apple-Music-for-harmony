/**
 * protobuf wire format 编解码基元（手写，零依赖）
 *
 * 只实现 Widevine 用到的部分：
 *   - varint（wire type 0）
 *   - length-delimited（wire type 2）：bytes / string / 嵌套 message
 *
 * 参考: https://protobuf.dev/programming-guides/encoding/
 */

export class PbWriter {
  private buf: number[] = [];

  /** 写入一个 varint */
  private putVarint(value: number): void {
    let v: number = Math.floor(value);
    if (v < 0) {
      // Widevine 用不到负数；负数按 64 位补码处理（简单起见取模）
      v = v >>> 0;
    }
    while (v > 0x7f) {
      this.buf.push((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    this.buf.push(v & 0x7f);
  }

  private putTag(field: number, wireType: number): void {
    this.putVarint(field * 8 + wireType);
  }

  private putRaw(data: Uint8Array): void {
    for (let i = 0; i < data.length; i++) {
      this.buf.push(data[i] & 0xff);
    }
  }

  /** 写入 uint32/int32/enum */
  uint(field: number, value: number): PbWriter {
    this.putTag(field, 0);
    this.putVarint(value);
    return this;
  }

  /** 写入 int64（用 JS number 表示，精度足够 Widevine 用途） */
  int64(field: number, value: number): PbWriter {
    this.putTag(field, 0);
    this.putVarint(value);
    return this;
  }

  /** 写入 bytes */
  bytes(field: number, value: Uint8Array): PbWriter {
    this.putTag(field, 2);
    this.putVarint(value.length);
    this.putRaw(value);
    return this;
  }

  /** 写入嵌套 message */
  message(field: number, value: Uint8Array): PbWriter {
    return this.bytes(field, value);
  }

  /** 写入 string（UTF-8） */
  str(field: number, value: string): PbWriter {
    const bytes: Uint8Array = utf8Encode(value);
    return this.bytes(field, bytes);
  }

  toUint8Array(): Uint8Array {
    const out = new Uint8Array(this.buf.length);
    for (let i = 0; i < this.buf.length; i++) {
      out[i] = this.buf[i];
    }
    return out;
  }
}

/** 读取一个 protobuf 字段 */
export class PbField {
  field: number = 0;
  wireType: number = 0;
  varint: number = 0;
  bytes: Uint8Array = new Uint8Array(0);
}

export class PbReader {
  private data: Uint8Array;
  private pos: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  eof(): boolean {
    return this.pos >= this.data.length;
  }

  private readVarint(): number {
    let result: number = 0;
    let shift: number = 1;
    while (this.pos < this.data.length) {
      const b: number = this.data[this.pos++];
      result += (b & 0x7f) * shift;
      if ((b & 0x80) === 0) {
        break;
      }
      shift *= 128;
    }
    return result;
  }

  /** 读下一个字段；到达末尾返回 null */
  next(): PbField | null {
    if (this.eof()) {
      return null;
    }
    const f = new PbField();
    const tag: number = this.readVarint();
    f.field = Math.floor(tag / 8);
    f.wireType = tag & 7;

    if (f.wireType === 0) {
      f.varint = this.readVarint();
    } else if (f.wireType === 2) {
      const len: number = this.readVarint();
      const end: number = Math.min(this.pos + len, this.data.length);
      f.bytes = this.data.subarray(this.pos, end);
      this.pos = end;
    } else if (f.wireType === 5) {
      this.pos += 4;
    } else if (f.wireType === 1) {
      this.pos += 8;
    } else {
      // 不认识的 wire type，停止解析
      this.pos = this.data.length;
    }
    return f;
  }
}

/** UTF-8 编码（ArkTS 环境下的最小实现） */
export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c: number = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6));
      out.push(0x80 | (c & 0x3f));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const c2: number = s.charCodeAt(i + 1);
      const cp: number = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
      out.push(0xf0 | (cp >> 18));
      out.push(0x80 | ((cp >> 12) & 0x3f));
      out.push(0x80 | ((cp >> 6) & 0x3f));
      out.push(0x80 | (cp & 0x3f));
      i++;
    } else {
      out.push(0xe0 | (c >> 12));
      out.push(0x80 | ((c >> 6) & 0x3f));
      out.push(0x80 | (c & 0x3f));
    }
  }
  const res = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    res[i] = out[i];
  }
  return res;
}

/** 工具：Uint8Array 拼接 */
export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out = new Uint8Array(total);
  let off: number = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], off);
    off += parts[i].length;
  }
  return out;
}

/** 工具：字节比较 */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 工具：字节转十六进制（调试用） */
export function toHex(a: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < a.length; i++) {
    const h: string = a[i].toString(16);
    s += h.length === 1 ? '0' + h : h;
  }
  return s;
}

/** 工具：hex 字符串转字节 */
export function fromHex(s: string): Uint8Array {
  const clean: string = s.replace(new RegExp('[^0-9a-fA-F]', 'g'), '');
  const out = new Uint8Array(Math.floor(clean.length / 2));
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}
