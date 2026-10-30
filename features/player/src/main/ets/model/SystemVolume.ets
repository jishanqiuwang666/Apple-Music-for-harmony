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
 * 系统媒体音量读取器。
 *
 * 用户 2026-10-19 要求：「播放页的音量始终与系统音量一致，不要单独调节」。
 * 官方《音量面板》文档写得很明确：**应用不能直接调节系统音量**，
 * 只能通过 `AVVolumePanel` 让用户在面板上调节；同时建议自定义音量条时
 * 用音频框架的音量变化监听（`streamVolumeChange`）取真实音量来画自己的 UI。
 *
 * 所以这里只做两件事：
 * 1. 读：按 `STREAM_USAGE_MUSIC` 读系统音量档位（API 20 起为同步接口）；
 * 2. 听：订阅同一个 stream 的音量变化，把档位换算成 0~1 交给页面。
 *
 * 换算用 `getMinVolumeByStream / getMaxVolumeByStream` 的真实档位区间，
 * 而不是写死 0~15（不同设备/不同音频设备的最大档位并不相同）。
 */
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'musicbasic';

const TAG: string = 'SystemVolume';

/** 本应用只关心「媒体」这一路音量（音乐播放走的是它）。 */
const STREAM: audio.StreamUsage = audio.StreamUsage.STREAM_USAGE_MUSIC;

export class SystemVolume {
  private static manager: audio.AudioVolumeManager | undefined = undefined;
  private static listener: ((event: audio.StreamVolumeEvent) => void) | undefined = undefined;

  /** 音量管理器（懒加载，失败返回 undefined，所有接口据此降级为空操作）。 */
  private static vm(): audio.AudioVolumeManager | undefined {
    if (SystemVolume.manager === undefined) {
      try {
        SystemVolume.manager = audio.getAudioManager().getVolumeManager();
      } catch (err) {
        Logger.warn(TAG, `getVolumeManager failed: ${(err as BusinessError).message ?? ''}`);
        SystemVolume.manager = undefined;
      }
    }
    return SystemVolume.manager;
  }

  /** 当前系统媒体音量档位（设备原始档位，如 0~15）。 */
  static level(): number {
    const manager: audio.AudioVolumeManager | undefined = SystemVolume.vm();
    if (manager === undefined) {
      return 0;
    }
    try {
      return manager.getVolumeByStream(STREAM);
    } catch (err) {
      Logger.warn(TAG, `getVolumeByStream failed: ${(err as BusinessError).message ?? ''}`);
      return 0;
    }
  }

  /** 档位上限（多数手机是 15，但以系统返回为准）。 */
  static maxLevel(): number {
    const manager: audio.AudioVolumeManager | undefined = SystemVolume.vm();
    if (manager === undefined) {
      return 15;
    }
    try {
      const max: number = manager.getMaxVolumeByStream(STREAM);
      return max > 0 ? max : 15;
    } catch (err) {
      Logger.warn(TAG, `getMaxVolumeByStream failed: ${(err as BusinessError).message ?? ''}`);
      return 15;
    }
  }

  /** 档位下限（通常为 0）。 */
  static minLevel(): number {
    const manager: audio.AudioVolumeManager | undefined = SystemVolume.vm();
    if (manager === undefined) {
      return 0;
    }
    try {
      const min: number = manager.getMinVolumeByStream(STREAM);
      return min >= 0 ? min : 0;
    } catch (err) {
      Logger.warn(TAG, `getMinVolumeByStream failed: ${(err as BusinessError).message ?? ''}`);
      return 0;
    }
  }

  /** 档位 → 0~1（给 UI 用；静音时正好是 0）。 */
  static ratioOf(level: number): number {
    const max: number = SystemVolume.maxLevel();
    const min: number = SystemVolume.minLevel();
    const span: number = max - min;
    if (span <= 0) {
      return 0;
    }
    const r: number = (level - min) / span;
    return r < 0 ? 0 : (r > 1 ? 1 : r);
  }

  /** 0~1 → 档位（四舍五入并钳制到合法区间，交给音量面板用）。 */
  static levelOf(ratio: number): number {
    const max: number = SystemVolume.maxLevel();
    const min: number = SystemVolume.minLevel();
    const span: number = max - min;
    const clamped: number = ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
    return Math.min(max, Math.max(min, Math.round(min + clamped * span)));
  }

  /** 当前 0~1 音量。 */
  static ratio(): number {
    return SystemVolume.ratioOf(SystemVolume.level());
  }

  /**
   * 订阅系统媒体音量变化（硬件侧键、播控中心、音量面板都会触发）。
   *
   * 回调参数是 0~1 比例。重复调用会先解绑上一个监听，避免叠加。
   */
  static watch(onChange: (ratio: number) => void): void {
    const manager: audio.AudioVolumeManager | undefined = SystemVolume.vm();
    if (manager === undefined) {
      return;
    }
    SystemVolume.unwatch();
    const listener = (event: audio.StreamVolumeEvent): void => {
      onChange(SystemVolume.ratioOf(event.volume));
    };
    try {
      manager.on('streamVolumeChange', STREAM, listener);
      SystemVolume.listener = listener;
      Logger.info(TAG, `watch system volume ok, level=${SystemVolume.level()}, max=${SystemVolume.maxLevel()}`);
    } catch (err) {
      Logger.warn(TAG, `watch system volume failed: ${(err as BusinessError).message ?? ''}`);
      SystemVolume.listener = undefined;
    }
  }

  /** 解绑（页面销毁时调用，避免回调打到已卸载的页面上）。 */
  static unwatch(): void {
    const manager: audio.AudioVolumeManager | undefined = SystemVolume.vm();
    const listener = SystemVolume.listener;
    SystemVolume.listener = undefined;
    if (manager === undefined || listener === undefined) {
      return;
    }
    try {
      // 注意：off 只接受 2 个参数（type + callback），传 streamUsage 会编译报错
      manager.off('streamVolumeChange', listener);
    } catch (err) {
      Logger.warn(TAG, `unwatch system volume failed: ${(err as BusinessError).message ?? ''}`);
    }
  }
}
