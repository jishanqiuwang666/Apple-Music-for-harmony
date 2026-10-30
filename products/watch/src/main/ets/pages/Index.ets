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

import { AppStorageV2, ArcDotIndicator, ArcSwiperController } from '@kit.ArkUI';
import { AppStorageKeys, MusicDbApi, MusicAppState } from 'musicbasic';
import { MediaService } from 'player';
import { WatchHomePage } from './WatchHomePage';

/** Watch entry: dual-view music library (local / phone) with local playback. */
@Entry
@ComponentV2
struct Index {
  @Provider() pageStack: NavPathStack = new NavPathStack();
  @Local innerSelectedIndex: number = 0;
  private wearableSwiperController: ArcSwiperController = new ArcSwiperController();
  private arcDotIndicator: ArcDotIndicator = new ArcDotIndicator();

  aboutToAppear(): void {
    const state = AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
    state.playQueueIds = MusicDbApi.getInstance().getSongList().map((dto) => dto.id);
    MediaService.getInstance();
  }

  build() {
    Navigation(this.pageStack) {
      WatchHomePage()
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
  }
}
