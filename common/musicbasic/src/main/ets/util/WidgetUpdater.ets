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

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Logger } from './Logger';
import { WidgetStateStore } from './WidgetStateStore';

const TAG = 'WidgetUpdater';

/**
 * Builds card binding data from the persisted widget state and refreshes
 * all installed widgets. Used by both the FormExtensionAbility (initial
 * data) and the UIAbility (after playback control/state changes).
 */
export class WidgetUpdater {
  public static buildBindingData(context: common.Context): formBindingData.FormBindingData {
    const snapshot = WidgetStateStore.load(context);

    class WidgetFormData {
      public title: string = snapshot.title;
      public artist: string = snapshot.artist;
      public isPlaying: boolean = snapshot.isPlaying;
      public imgName: string = '';
      public formImages: Record<string, number> = {};
    }

    const data = new WidgetFormData();
    if (snapshot.coverPath !== '') {
      try {
        const file = fileIo.openSync(snapshot.coverPath, fileIo.OpenMode.READ_ONLY);
        // A unique key per update is required by the widget image mechanism
        // so the card knows the image content actually changed.
        const key = `cover_${Date.now()}`;
        data.imgName = key;
        data.formImages[key] = file.fd;
      } catch (err) {
        Logger.warn(TAG, `open widget cover failed: ${JSON.stringify(err)}`);
      }
    }
    return formBindingData.createFormBindingData(data);
  }

  /** Refreshes every widget currently installed for this bundle. */
  public static async refreshAll(context: common.Context): Promise<void> {
    try {
      const formData = WidgetUpdater.buildBindingData(context);
      const forms: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
      for (let i = 0; i < forms.length; i++) {
        const formId = forms[i].formId;
        await formProvider.updateForm(formId, formData);
      }
    } catch (err) {
      Logger.warn(TAG, `refresh widgets failed: ${JSON.stringify(err)}`);
    }
  }
}
