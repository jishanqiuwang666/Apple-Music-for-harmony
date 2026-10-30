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

/*
 * Moved from common/mediacommon/src/main/ets/utils/SongItemBuilder.ets
 */

import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppRuntime, Logger, SongItem, AppleCache, AppleUi } from 'musicbasic';

/**
 * Resolves the playback source for a SongItem:
 * - Apple Music songs (`apple:<id>`): ensure the decrypted file is in the local
 *   cache (download + Widevine decrypt on miss) and play it through fdSrc;
 * - file URIs (sandbox or authorized public) open via fd and play through fdSrc;
 * - otherwise the value is treated as a rawfile asset opened via getRawFd.
 * Note: AVPlayer.url does NOT accept file:// sandbox URIs (401 invalid
 * parameter), so local files must always go through fdSrc.
 */
export default class SongItemBuilder {
  /** Host UIAbility context used to resolve raw assets. */
  private get abilityContext(): common.UIAbilityContext | undefined {
    return getAppRuntime().context;
  }
  /** Last resolved raw file descriptor for the current build; undefined until getRawFd succeeds. */
  private realUrl?: resourceManager.RawFileDescriptor;
  /** Open file handle of the current library song (fdSrc source). */
  private localFile: fileIo.File | undefined;
  /** Song metadata being prepared; null after release. */
  private songItem: SongItem | null = null;
  /** Apple 音源最近一次失败原因（空串表示没有失败）。 */
  private appleError: string = '';

  /**
   * 串行化所有 build 调用。
   *
   * 以前 build 可以被并发调用（applySongSource 和 AVPlayer 的 idle 回调都会
   * 触发），两次并发会让同一首歌下载两遍、并且互相踩 `localFile` —— 表现就是
   * 「有时能播，有时点了很久都不播」。排成一条链后同一时刻只有一个 build 在
   * 动，并且被新请求取代的旧请求会直接跳过（不白下载）。
   */
  private chain: Promise<void> = Promise.resolve();
  /** 最近一次请求的 src（用来判断排队中的请求是否已经被取代）。 */
  private latestSrc: string = '';

  /**
   * Resolves the playback source for songItem and stores it.
   * 同一时刻只有一个 build 在执行；被更新请求取代的排队请求会直接返回。
   */
  public build(songItem: SongItem): Promise<SongItem> {
    this.latestSrc = songItem.src;
    const run: Promise<SongItem> = this.chain.then(() => {
      if (this.latestSrc !== songItem.src) {
        Logger.info('SongItemBuilder: 请求已被取代，跳过 ' + songItem.src);
        return songItem;
      }
      return this.doBuild(songItem);
    });
    // 让后续 build 排在这一条之后；吞掉异常避免整条链断掉。
    this.chain = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  /** 实际解析播放源（同一时刻只会有一个在跑）。 */
  private async doBuild(songItem: SongItem): Promise<SongItem> {
    this.songItem = songItem;
    this.releaseLocalFile();
    this.realUrl = undefined;
    this.appleError = '';
    if (!this.abilityContext) {
      return songItem;
    }
    const src = songItem.src;

    // ── Apple Music 音源：src = "apple:<songId>" ──
    // 统一走 AppleCache.ensure：命中缓存直接返回路径，未命中则下载 + CENC 解密。
    // 预加载用的也是同一个入口（single-flight），所以「预取中用户正好点了这首」
    // 不会触发第二次下载，也就不会把文件写坏。
    if (src.startsWith('apple:')) {
      const songId: string = src.substring('apple:'.length);
      const hadCache: boolean = AppleCache.getCachedPath(songId).length > 0;
      try {
        if (!hadCache) {
          Logger.info('SongItemBuilder: 未命中缓存，开始下载 ' + songId);
          AppleUi.toast('正在加载并解密歌曲…', 4000);
          AppleUi.setLoading(`正在加载 ${String(songItem.title)}…`);
        }
        const path: string = await AppleCache.ensure(songId, true);
        this.localFile = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        Logger.info(`SongItemBuilder: opened fd=${this.localFile.fd} cached=${hadCache} ${songId}`);
        AppleUi.setLoading('');
      } catch (error) {
        AppleUi.setLoading('');
        const msg: string = (error as Error).message !== undefined
          ? (error as Error).message : JSON.stringify(error);
        this.appleError = msg.length > 0 ? msg : '播放源不可用';
        Logger.error(`SongItemBuilder: apple 源失败 src=${src} ${this.appleError}`);
        AppleUi.toast(`这首歌暂时放不了：${this.appleError}`, 4500);
        // 作废可能损坏的缓存，用户再点一次就会重新下载
        await AppleCache.invalidate(songId);
      }
      return songItem;
    }

    if (src.startsWith('file://')) {
      // User-library song: open the file and play via fdSrc.
      try {
        this.localFile = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
        Logger.info('SongItemBuilder opened local file fd:' + this.localFile.fd);
      } catch (error) {
        Logger.error(`open local file failed src=${src} ${JSON.stringify(error)}`);
      }
      return songItem;
    }
    let rawfileFd = await this.abilityContext.resourceManager.getRawFd(src)
      .catch((error: BusinessError) => {
        Logger.error(`resourceManager error code ${error.code} message ${error.message}`);
      });
    if (rawfileFd) {
      this.realUrl = rawfileFd;
    } else {
      Logger.error('get rawfileFd failed');
    }
    Logger.info('MediaAssetBuilder build realUrl:' + this.realUrl);
    return songItem;
  }

  /** @returns True when the current song plays from a local file (fdSrc). */
  public isLocalFileSource(): boolean {
    return this.localFile !== undefined;
  }

  /**
   * Apple 音源最近一次失败原因（空串表示没有失败）。
   *
   * MediaService 用它区分「真的没有可播的源」和「解析失败」，避免静默地
   * 什么都不播 —— 这正是「点了没反应」的观感来源。
   */
  public getAppleError(): string {
    return this.appleError;
  }

  /** AVFileDescriptor of the opened local file, or undefined. */
  public getLocalFileDescriptor(): media.AVFileDescriptor | undefined {
    if (this.localFile === undefined) {
      return undefined;
    }
    const stat = fileIo.statSync(this.localFile.fd);
    return { fd: this.localFile.fd, offset: 0, length: stat.size };
  }

  /** Descriptor for AVPlayer.fdSrc after a successful build. */
  public getRealUrl(): resourceManager.RawFileDescriptor | undefined {
    Logger.info(`url ${this.realUrl}`);
    return this.realUrl;
  }

  /** Closes the local file handle if open. */
  private releaseLocalFile(): void {
    if (this.localFile !== undefined) {
      try {
        fileIo.closeSync(this.localFile);
      } catch (error) {
        Logger.error('Failed to close local file');
      }
      this.localFile = undefined;
    }
  }

  /** Closes the raw FD or local file for the current songItem and clears internal state. */
  public async release(): Promise<void> {
    if (this.abilityContext && this.songItem !== null && this.localFile === undefined) {
      try {
        await this.abilityContext.resourceManager.closeRawFd(this.songItem.src);
      } catch (error) {
        Logger.error('Failed to closeRawFd');
      }
    }
    this.releaseLocalFile();
    this.songItem = null;
  }
}
