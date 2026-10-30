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

import { AppStorageV2, uiObserver } from '@kit.ArkUI';
import {
  AppStorageKeys,
  getWindowInfoState,
  ImmersiveType,
  StyleConstants,
  WindowInfo
} from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';

/** Full-screen playback top bar: back action and share affordance. */
@ComponentV2
export struct TopAreaComponent {
  /** Window breakpoint (reserved for future responsive tweaks). */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** Whether full-screen player chrome is visible (passed from parent). */
  @Param isShowPlay: boolean = false;

  /** Invoked when the back affordance is tapped. */
  @Param onBackClick: () => void = (): void => {
  };
  /** Shared app state (read-only usage in this bar). */
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** Window metrics for immersive title padding. */
  @Local windowInfo: WindowInfo = getWindowInfoState();

  /** Renders back and share row with safe-area aware trailing padding. */
  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_down_circle'))
        .fontSize(24)
        .fontColor([$r('app.color.play_text_color')])
        .onClick((): void => {
          this.onBackClick();
        })
      SymbolGlyph($r('sys.symbol.share'))
        .fontSize(24)
        .fontWeight(FontWeight.Regular)
        .fontColor([$r('app.color.play_text_color')])
    }
    .height(56)
    .width(StyleConstants.FULL_WIDTH)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({
      right: this.windowInfo.immersiveDecor === ImmersiveType.IMMERSIVE ?
        Math.max(0, this.windowInfo.titleButtonWidthVp - 24) : 0,
    })
  }
}
