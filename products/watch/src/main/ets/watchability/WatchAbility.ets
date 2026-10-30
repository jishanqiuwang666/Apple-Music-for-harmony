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

import { UIAbility, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { getAppRuntime, Logger, MusicDatabase, MusicTransferService } from 'musicbasic';
import { MediaService } from 'player';

/**
 * Watch UIAbility: wires app runtime context, loads Index page, and initializes media on window stage.
 */
export default class WatchAbility extends UIAbility {
  /**
   * Stores ability context on app runtime and logs creation.
   * @param want Launch want info.
   * @param launchParam System launch parameters.
   */
  onCreate(): void {
    getAppRuntime().context = this.context;
    Logger.info('WatchAbility: Ability onCreate');
    // Load the local library DB in the background for offline playback.
    MusicDatabase.getInstance().init(this.context).then(() => {
      Logger.info('WatchAbility: music library loaded');
    }).catch((error: Error) => {
      Logger.error(`WatchAbility: music library init failed ${JSON.stringify(error)}`);
    });
    // Receiver side of the phone→watch transfer channel.
    MusicTransferService.getInstance().init(this.context, false).then(() => {
      Logger.info('WatchAbility: transfer channel ready');
    }).catch((error: Error) => {
      Logger.error(`WatchAbility: transfer init failed ${JSON.stringify(error)}`);
    });
    // Distributed data sync is user-granted; request it at launch.
    const atManager = abilityAccessCtrl.createAtManager();
    const permissions: Array<Permissions> = ['ohos.permission.DISTRIBUTED_DATASYNC'];
    atManager.requestPermissionsFromUser(this.context, permissions).then((result) => {
      Logger.info(`WatchAbility: distributed permission granted=${result.authResults[0] === 0}`);
    }).catch((error: Error) => {
      Logger.error(`WatchAbility: permission request failed ${JSON.stringify(error)}`);
    });
  }

  /** Logs ability destruction. */
  onDestroy(): void {
    Logger.info('WatchAbility: Ability onDestroy');
  }

  /**
   * Loads main watch UI, captures UIContext on main window, and creates MediaService.
   * @param windowStage Window stage for this ability.
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info('WatchAbility: Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(`${err.code} + ${err.message}`);
        return;
      }
      try {
        getAppRuntime().uiContext = windowStage.getMainWindowSync().getUIContext();
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(`Failed to get UI Context. Code: ${err.code}, message: ${err.message}`);
      }
      try {
        MediaService.getInstance();
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(`Failed to get media service instance. Code: ${err.code}, message: ${err.message}`);
      }
      Logger.info('Succeeded in loading the content.');
    });
  }

  /** Logs when the window stage is torn down. */
  async onWindowStageDestroy(): Promise<void> {
    Logger.info('WatchAbility: Ability onWindowStageDestroy');
    try {
      await MediaService.getInstance().release();
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(`MediaService release error. Code: ${err.code}, message: ${err.message}`);
    }
  }

  /** Logs transition to foreground. */
  onForeground(): void {
    Logger.info('WatchAbility: Ability onForeground');
  }

  /** Logs transition to background. */
  onBackground(): void {
    Logger.info('WatchAbility: Ability onBackground');
  }
}
