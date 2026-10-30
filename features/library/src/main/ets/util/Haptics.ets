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

import { vibrator } from '@kit.SensorServiceKit';
import { Logger } from 'musicbasic';

const TAG = 'Haptics';

/**
 * 轻震动反馈（官方 vibrator，`ohos.permission.VIBRATE` 是 system_grant 普通权限）。
 *
 * 用途：收藏艺人拖动排序时「拿起 / 放下」的触觉提示。
 * 任何失败（设备不支持、权限未授予、马达被占用）都静默忽略 —— 触觉反馈不该
 * 影响交互本身，也不该刷错误日志。
 */
export class Haptics {
  /**
   * 震动一小下。
   *
   * @param durationMs 时长（毫秒），拖动拿起建议 40、落下建议 20
   */
  public static tick(durationMs: number): void {
    try {
      const effect: vibrator.VibrateTime = { type: 'time', duration: durationMs };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute).catch((e: Error) => {
        Logger.debug(TAG, 'vibrate failed: ' + (e.message ?? ''));
      });
    } catch (e) {
      Logger.debug(TAG, 'vibrate threw: ' + ((e as Error).message ?? ''));
    }
  }
}
