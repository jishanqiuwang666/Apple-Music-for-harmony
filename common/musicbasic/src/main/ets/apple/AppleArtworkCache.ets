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

/**
 * Apple 封面图本地缓存。
 *
 * 为什么需要：Apple 的封面是 https 链接，而锁屏 / 灵动岛（实况窗）/ 桌面小组件
 * 这三处都要求**本地文件或 PixelMap**：
 *  - AVSession.setAVMetadata(mediaImage) 要 PixelMap；
 *  - LiveView 的 descPic/icon 要本地文件或 PixelMap；
 *  - FormExtensionAbility 的卡片图片要 fd（memory:// 机制）。
 * 之前直接把 https URL 传进去，解码必然失败 → 三处都没有封面。
 *
 * 缓存策略：一个 URL 一个文件，命中直接返回；总量超过上限时按最后访问时间
 * 淘汰最旧的 10%（封面很小，几百 KB 一张，通常只有几十张）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../util/Logger';

const TAG = 'AppleArtworkCache';
/** 缓存目录名（cacheDir 下）。 */
const DIR_NAME = 'apple_art';
/** 单张封面上限（防止异常大图占满空间）。 */
const MAX_BYTES = 3 * 1024 * 1024;
/** 缓存文件数上限。 */
const MAX_FILES = 400;
/** 淘汰比例：超过上限时删掉最旧的 10%。 */
const TRIM_RATIO = 0.1;

/** 内存索引：URL → 本地绝对路径（'' 表示下载失败过，不再重试）。 */
const INDEX: Map<string, string> = new Map();
/** 进行中的下载（同一个 URL 只下载一次）。 */
const INFLIGHT: Map<string, Promise<string>> = new Map();

export class AppleArtworkCache {
  private static dir: string = '';

  /** 初始化缓存目录（幂等）。 */
  public static init(context: common.Context): void {
    if (AppleArtworkCache.dir !== '') {
      return;
    }
    AppleArtworkCache.dir = `${context.cacheDir}/${DIR_NAME}`;
    try {
      fileIo.mkdirSync(AppleArtworkCache.dir);
    } catch (err) {
      // 目录已存在
    }
    Logger.info(TAG, 'artwork cache dir=' + AppleArtworkCache.dir);
  }

  /** @returns 已缓存的本地路径；未缓存返回空串。 */
  public static getCachedPath(url: string): string {
    if (url === '') {
      return '';
    }
    if (!url.startsWith('http')) {
      // 已经是本地沙箱路径（旧版扫描器的封面缓存）：原样返回。
      return url;
    }
    const hit = INDEX.get(url);
    if (hit !== undefined) {
      return hit;
    }
    // 进程重启后 INDEX 为空：按确定性文件名探测磁盘。
    const path = AppleArtworkCache.pathFor(url);
    if (path !== '' && AppleArtworkCache.isFile(path)) {
      INDEX.set(url, path);
      return path;
    }
    return '';
  }

  /** 确保封面已下载到本地，返回本地路径（失败返回空串）。 */
  public static async ensure(url: string): Promise<string> {
    if (url !== '' && !url.startsWith('http')) {
      return url;
    }
    const cached = AppleArtworkCache.getCachedPath(url);
    if (cached !== '' || url === '') {
      return cached;
    }
    const running = INFLIGHT.get(url);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = AppleArtworkCache.download(url).then((path: string) => {
      INFLIGHT.delete(url);
      INDEX.set(url, path);
      return path;
    }).catch((err: Error) => {
      INFLIGHT.delete(url);
      INDEX.set(url, '');
      Logger.warn(TAG, `download failed ${url}: ${err.message}`);
      return '';
    });
    INFLIGHT.set(url, task);
    return task;
  }

  /** 单个封面的下载（原子写：先写 .part 再改名）。 */
  private static async download(url: string): Promise<string> {
    if (!url.startsWith('http')) {
      return '';
    }
    const path = AppleArtworkCache.pathFor(url);
    if (path === '') {
      return '';
    }
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode !== 200 || resp.result === undefined) {
        throw new Error('HTTP ' + resp.responseCode);
      }
      const raw: string | Object | ArrayBuffer = resp.result;
      if (typeof raw === 'string') {
        throw new Error('unexpected text response');
      }
      const bytes: ArrayBuffer = raw as ArrayBuffer;
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_BYTES) {
        throw new Error('bad size ' + bytes.byteLength);
      }
      const part = path + '.part';
      const file = fileIo.openSync(part,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes);
      } finally {
        fileIo.closeSync(file);
      }
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        // 首次下载时目标不存在
      }
      fileIo.renameSync(part, path);
      AppleArtworkCache.trim();
      Logger.info(TAG, `cached ${bytes.byteLength}B -> ${path}`);
      return path;
    } finally {
      req.destroy();
    }
  }

  /** 确定性文件名：URL 的哈希 + .jpg（URL 里的 {w}x{h} 已在上游替换）。 */
  private static pathFor(url: string): string {
    if (AppleArtworkCache.dir === '') {
      return '';
    }
    let h = 5381;
    for (let i = 0; i < url.length; i++) {
      h = ((h << 5) + h + url.charCodeAt(i)) >>> 0;
    }
    return `${AppleArtworkCache.dir}/${h.toString(16)}.jpg`;
  }

  /** 文件是否存在。 */
  private static isFile(path: string): boolean {
    try {
      return fileIo.statSync(path).size > 0;
    } catch (err) {
      return false;
    }
  }

  /** 超过上限时按修改时间淘汰最旧的一批。 */
  private static trim(): void {
    try {
      const names: string[] = fileIo.listFileSync(AppleArtworkCache.dir);
      if (names.length <= MAX_FILES) {
        return;
      }
      const entries: Array<string> = names.slice();
      entries.sort((a: string, b: string) => {
        const ta = AppleArtworkCache.mtime(`${AppleArtworkCache.dir}/${a}`);
        const tb = AppleArtworkCache.mtime(`${AppleArtworkCache.dir}/${b}`);
        return ta - tb;
      });
      const remove = Math.max(1, Math.floor(entries.length * TRIM_RATIO));
      for (let i = 0; i < remove; i++) {
        try {
          fileIo.unlinkSync(`${AppleArtworkCache.dir}/${entries[i]}`);
        } catch (err) {
          // 忽略单个文件失败
        }
      }
      Logger.info(TAG, `trim: removed ${remove} of ${entries.length}`);
    } catch (err) {
      // 目录不可读：忽略
    }
  }

  /** 文件修改时间（取不到时返回 0）。 */
  private static mtime(path: string): number {
    try {
      return fileIo.statSync(path).mtime * 1000;
    } catch (err) {
      return 0;
    }
  }

  /** 缓存占用（字节）。设置页展示用。 */
  public static sizeBytes(): number {
    if (AppleArtworkCache.dir === '') {
      return 0;
    }
    let total = 0;
    try {
      const names: string[] = fileIo.listFileSync(AppleArtworkCache.dir);
      for (let i = 0; i < names.length; i++) {
        total += AppleArtworkCache.sizeOf(`${AppleArtworkCache.dir}/${names[i]}`);
      }
    } catch (err) {
      // 目录不存在
    }
    return total;
  }

  /** 文件大小。 */
  private static sizeOf(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (err) {
      return 0;
    }
  }

  /** 清空封面缓存。 */
  public static clear(): number {
    INDEX.clear();
    if (AppleArtworkCache.dir === '') {
      return 0;
    }
    let removed = 0;
    try {
      const names: string[] = fileIo.listFileSync(AppleArtworkCache.dir);
      for (let i = 0; i < names.length; i++) {
        try {
          fileIo.unlinkSync(`${AppleArtworkCache.dir}/${names[i]}`);
          removed++;
        } catch (err) {
          // 忽略
        }
      }
    } catch (err) {
      // 目录不存在
    }
    return removed;
  }

  /** 把 BusinessError 转成可读文案（供调用方记录日志）。 */
  public static describe(err: Object): string {
    const be = err as BusinessError;
    return be !== undefined && be.message !== undefined ? be.message : JSON.stringify(err);
  }
}
