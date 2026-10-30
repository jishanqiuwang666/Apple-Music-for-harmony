/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { Box, Mp4 } from './Mp4Box';
import { Logger } from '../util/Logger';

const TAG: string = 'Mp4Cleaner';

/**
 * MP4 容器清理工具。
 *
 * ⚠️ 核心背景（真机实测，务必保留这段说明）：
 * Apple Music 下发的部分曲目在 `moov` 里带一个 `pssh`
 * （Protection System Specific Header，Widevine 的 DRM 系统头，约 484 字节），
 * 部分曲目则没有。我们把音频解密成明文后，如果**不删掉这个 pssh**，
 * HarmonyOS 的 AVPlayer 会认为「这是一首受 DRM 保护的曲目」，
 * 于是去等一个永远不会到来的许可授权 —— 表现为 `prepare()` 永不完成、
 * `state` 永远停在 `initialized`、`duration` 恒为 -1，用户看到的就是
 * 「点了歌一直没反应」。而约一半曲目本来就没有 pssh，所以能正常播放，
 * 形成「有的歌能播、有的歌死活不播」的现象。
 *
 * 删除 pssh 只改变 `moov` 的长度（它位于 moov 末尾），**不影响任何相对偏移**：
 * `trun.data_offset` 是相对所在 `moof` 起点计算，`moof` 内部结构不变。
 * 所以这里只清理 `moov` 子树，不去动 `moof`/`traf`（在那些地方删 box
 * 必须同步修正 data_offset，风险大且无必要）。
 */
export class Mp4Cleaner {
  /** 可以安全递归进去重建的容器 box 类型。 */
  private static readonly CONTAINERS: string[] = [
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'dinf', 'udta', 'mvex', 'edts',
    'sinf', 'schi', 'meta', 'ilst'
  ];

  /** 需要从 moov 里剔除的 DRM 相关 box。 */
  private static readonly DROP: string[] = ['pssh'];

  /**
   * 需要「就地改名成 free」的 CENC 描述 box（**只改 4 字节类型名，长度/偏移全不变**）。
   *
   * 背景（2026-09 鸿蒙 7 实测）：
   * - 鸿蒙 6 的媒体解复用器不校验这些描述，留着它们反而更安全；
   * - 鸿蒙 7 换成 FFmpeg 解复用器后会校验 `senc` 的样本数与轨道样本数，
   *   不一致就报 `[FFLogE] Incorrect number of samples in encryption info`，
   *   最终 AVPlayer 抛 5400103（DEM_PARSE_ERR）→ 用户看到「点了没反应/播不了」；
   * - 但**直接删掉**这些 box 会改变长度与相对偏移（早前实测会让 native 层崩溃），
   *   所以这里采用最保守的做法：把类型名原地改成 `free`（MP4 标准里的填充 box，
   *   解析器一律跳过），这样 FFmpeg 既看不到加密描述，文件结构又与原来逐字节等长。
   */
  private static readonly BLANK_TO_FREE: string[] = [
    'senc', 'saiz', 'saio', 'sgpd', 'sbgp', 'sinf'
  ];

  /** 遍历时需要下钻的容器（含 moof/traf，CENC 描述主要就藏在这两级里）。 */
  private static readonly WALK: string[] = [
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'dinf', 'udta', 'mvex', 'edts',
    'sinf', 'schi', 'meta', 'ilst', 'moof', 'traf', 'mfra'
  ];

  /**
   * 把 CENC 加密描述 box 的类型名就地改成 `free`（等长改写，不动任何偏移）。
   *
   * @param data 解密后的 m4a 字节（会被就地修改）
   * @returns 改写过多少个 box（0 表示本来就是干净的）
   */
  static blankCenc(data: Uint8Array): number {
    let n: number = 0;
    const top: Box[] = Mp4.boxes(data, 0, data.length);
    for (let i = 0; i < top.length; i++) {
      n += Mp4Cleaner.blankWalk(data, top[i]);
    }
    return n;
  }

  /** 递归处理一个 box：命中即改名，是容器就继续下钻。 */
  private static blankWalk(data: Uint8Array, b: Box): number {
    let n: number = 0;
    if (Mp4Cleaner.BLANK_TO_FREE.indexOf(b.type) >= 0) {
      Mp4Cleaner.writeType(data, b.start + 4, 'free');
      n++;
      // 已改名，不再下钻（sinf 内部也没有需要处理的）
      return n;
    }
    if (b.type === 'enca' || b.type === 'encv') {
      // 加密采样条目：按 sinf/frma 里的原始格式名改回普通条目（同样是等长改名）
      const frma: Box | null = Mp4.find(data, 'frma', b.bodyStart, b.bodyEnd);
      if (frma !== null && frma.bodyEnd - frma.bodyStart >= 4) {
        const real: string = Mp4.fourcc(data, frma.bodyStart);
        if (real.length === 4 && real !== 'frma') {
          Mp4Cleaner.writeType(data, b.start + 4, real);
          n++;
        }
      }
    }
    if (Mp4Cleaner.WALK.indexOf(b.type) >= 0) {
      const kids: Box[] = Mp4.boxes(data, b.bodyStart, b.bodyEnd);
      for (let i = 0; i < kids.length; i++) {
        n += Mp4Cleaner.blankWalk(data, kids[i]);
      }
    } else if (b.type === 'stsd') {
      n += Mp4Cleaner.blankSampleEntries(data, b);
    }
    return n;
  }

  /**
   * stsd 里的采样条目：条目头之后才是子 box。
   *
   * ISO 音频采样条目头 28 字节、ISO 视频 78 字节（Apple 的 HLS fMP4 用 ISO 布局）。
   * 但 QuickTime 变体的音频条目头是 36 字节 —— 为了不因布局差异漏掉 `sinf`，
   * 子 box 从预期位置解析不出来时，再在条目范围内做一次**保守扫描**
   * （只认「前 4 字节 size 合理」的目标 box，避免被载荷里的偶然字节骗到）。
   */
  private static blankSampleEntries(data: Uint8Array, stsd: Box): number {
    let n: number = 0;
    // stsd 体：version/flags(4) + entry_count(4) 之后是条目
    const entries: Box[] = Mp4.boxes(data, stsd.bodyStart + 8, stsd.bodyEnd);
    for (let i = 0; i < entries.length; i++) {
      const e: Box = entries[i];
      const isVideo: boolean = e.type === 'avc1' || e.type === 'hvc1'
        || e.type === 'encv' || e.type === 'mp4v';
      const head: number = isVideo ? 78 : 28;
      const kidsStart: number = e.start + head;
      let hit: number = 0;
      if (kidsStart < e.bodyEnd) {
        const kids: Box[] = Mp4.boxes(data, kidsStart, e.bodyEnd);
        for (let k = 0; k < kids.length; k++) {
          hit += Mp4Cleaner.blankWalk(data, kids[k]);
        }
      }
      if (hit === 0) {
        hit += Mp4Cleaner.scanTargets(data, e.bodyStart, e.bodyEnd);
      }
      n += hit;
    }
    return n;
  }

  /**
   * 保守扫描：在 [start, end) 内找 BLANK_TO_FREE 里的类型，且要求「前 4 字节 size 合理」。
   * 只用于采样条目内部（`sinf` 在两种布局下的位置差异），不做全局扫。
   */
  private static scanTargets(data: Uint8Array, start: number, end: number): number {
    let n: number = 0;
    for (let off: number = start; off + 8 <= end; off++) {
      const type: string = Mp4.fourcc(data, off);
      if (Mp4Cleaner.BLANK_TO_FREE.indexOf(type) < 0) {
        continue;
      }
      const size: number = Mp4.u32(data, off - 4);
      if (size < 8 || off - 4 + size > end) {
        continue;
      }
      Mp4Cleaner.writeType(data, off, 'free');
      n++;
    }
    return n;
  }

  /** 就地写 4 字节类型名。 */
  private static writeType(data: Uint8Array, off: number, type: string): void {
    for (let i = 0; i < 4; i++) {
      data[off + i] = type.charCodeAt(i) & 0xFF;
    }
  }

  /**
   * 删掉 `moov` 子树里的 `pssh`。没有 pssh 时原样返回入参。
   * @param data 解密后的完整 m4a 字节
   * @returns 清理后的字节（可能是同一个对象）
   */
  static stripPssh(data: Uint8Array): Uint8Array {
    if (data.length < 16) {
      return data;
    }
    const top: Box[] = Mp4.boxes(data, 0, data.length);
    let hasPssh: boolean = false;
    const parts: Uint8Array[] = [];
    for (let i = 0; i < top.length; i++) {
      const b: Box = top[i];
      if (b.type !== 'moov') {
        parts.push(data.subarray(b.start, b.bodyEnd));
        continue;
      }
      if (Mp4Cleaner.countPssh(data, b.bodyStart, b.bodyEnd) === 0) {
        parts.push(data.subarray(b.start, b.bodyEnd));
        continue;
      }
      hasPssh = true;
      const body: Uint8Array = Mp4Cleaner.rebuild(data, b.bodyStart, b.bodyEnd);
      parts.push(Mp4Cleaner.makeBox('moov', body));
    }
    if (!hasPssh) {
      return data;
    }
    const out: Uint8Array = Mp4Cleaner.concat(parts);
    Logger.info(TAG, `stripPssh: ${data.length} -> ${out.length}`);
    return out;
  }

  /** 统计范围内（递归）的 pssh 数量。 */
  private static countPssh(data: Uint8Array, start: number, end: number): number {
    let n: number = 0;
    const list: Box[] = Mp4.boxes(data, start, end);
    for (let i = 0; i < list.length; i++) {
      const b: Box = list[i];
      if (b.type === 'pssh') {
        n++;
      } else if (Mp4Cleaner.isContainer(b.type)) {
        n += Mp4Cleaner.countPssh(data, b.bodyStart, b.bodyEnd);
      }
    }
    return n;
  }

  /** 递归重建范围内的 box 序列，剔除 DROP 列表里的 box。 */
  private static rebuild(data: Uint8Array, start: number, end: number): Uint8Array {
    const list: Box[] = Mp4.boxes(data, start, end);
    const parts: Uint8Array[] = [];
    for (let i = 0; i < list.length; i++) {
      const b: Box = list[i];
      if (Mp4Cleaner.shouldDrop(b.type)) {
        continue;
      }
      if (Mp4Cleaner.isContainer(b.type)) {
        parts.push(Mp4Cleaner.makeBox(b.type, Mp4Cleaner.rebuild(data, b.bodyStart, b.bodyEnd)));
      } else {
        // 叶子 box（含 stsd 采样条目这类带固定头的）一律原样拷贝
        parts.push(data.subarray(b.start, b.bodyEnd));
      }
    }
    return Mp4Cleaner.concat(parts);
  }

  private static shouldDrop(type: string): boolean {
    return Mp4Cleaner.DROP.indexOf(type) >= 0;
  }

  private static isContainer(type: string): boolean {
    return Mp4Cleaner.CONTAINERS.indexOf(type) >= 0;
  }

  /** 组装一个 box：4 字节 size + 4 字节 type + 内容。 */
  private static makeBox(type: string, payload: Uint8Array): Uint8Array {
    const size: number = payload.length + 8;
    const out = new Uint8Array(size);
    out[0] = (size >> 24) & 0xFF;
    out[1] = (size >> 16) & 0xFF;
    out[2] = (size >> 8) & 0xFF;
    out[3] = size & 0xFF;
    for (let i = 0; i < 4; i++) {
      out[4 + i] = type.charCodeAt(i) & 0xFF;
    }
    out.set(payload, 8);
    return out;
  }

  /** 顺序拼接多段字节。 */
  private static concat(parts: Uint8Array[]): Uint8Array {
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
}
