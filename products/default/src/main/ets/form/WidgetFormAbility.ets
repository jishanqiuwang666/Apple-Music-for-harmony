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

import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Logger, WidgetUpdater } from 'musicbasic';

const TAG = 'WidgetFormAbility';

/**
 * FormExtensionAbility for the 2x2 music widget. Runs in the card process;
 * it only reads the persisted widget state and forwards updates to the
 * card UI. Playback controls are handled by the main UIAbility through
 * the postCardAction 'call' event.
 */
export default class WidgetFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    Logger.info(TAG, 'onAddForm');
    return WidgetUpdater.buildBindingData(this.context);
  }

  onUpdateForm(formId: string): void {
    Logger.info(TAG, `onUpdateForm ${formId}`);
    const data = WidgetUpdater.buildBindingData(this.context);
    formProvider.updateForm(formId, data).then(() => {
      Logger.info(TAG, `updateForm success ${formId}`);
    }).catch((err: Error) => {
      Logger.warn(TAG, `updateForm failed ${formId}: ${JSON.stringify(err)}`);
    });
  }
}
