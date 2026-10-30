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

import { AppStorageV2 } from '@kit.ArkUI';
import { getAppRuntime } from '../model/AppRuntimeStorage';
import { MusicAppState } from '../model/MusicAppState';
import { AppStorageKeys } from '../constants/Constants';
import { Logger } from '../util/Logger';

const TAG: string = 'AppleUi';

/**
 * Apple Music 音源相关的轻量 UI 反馈。
 *
 * 未命中的曲目要先「下载 + Widevine 解密」再播放（快网 1~2 秒，慢网可能十几秒），
 * 这段时间播控条不会有任何变化，用户会以为点了没反应 —— 用 toast 说明，
 * 并把文案写进 {@link MusicAppState.loadingText}，让播放条显示转圈。
 */
export class AppleUi {
  /** 弹一条 toast（拿不到 UIContext 时静默忽略，不影响播放流程）。 */
  static toast(message: string, duration: number = 2500): void {
    try {
      const uiContext = getAppRuntime().uiContext;
      if (uiContext === undefined) {
        return;
      }
      uiContext.getPromptAction().showToast({ message: message, duration: duration });
    } catch (err) {
      Logger.warn(TAG, `toast failed ${JSON.stringify(err)}`);
    }
  }

  /** 写入「加载中」提示（空串表示结束），播放条据此显示转圈。 */
  static setLoading(text: string): void {
    try {
      const state: MusicAppState =
        AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
      state.loadingText = text;
    } catch (err) {
      Logger.warn(TAG, `setLoading failed ${JSON.stringify(err)}`);
    }
  }
}
