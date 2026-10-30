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

import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { Logger } from 'musicbasic';

/**
 * Watch product backup extension: handles backup/restore lifecycle hooks for the wearable bundle.
 */
export default class WatchBackupAbility extends BackupExtensionAbility {
  /** Invoked when a backup operation runs; logs success placeholder. */
  async onBackup() {
    Logger.info('WatchBackupAbility: onBackup ok');
    await Promise.resolve();
  }

  /**
   * Invoked when restoring from backup.
   * @param bundleVersion Version metadata supplied by the system.
   */
  async onRestore(bundleVersion: BundleVersion) {
    Logger.info(`WatchBackupAbility: onRestore ok ${JSON.stringify(bundleVersion)}`);
    await Promise.resolve();
  }
}
