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
import { BusinessError } from '@kit.BasicServicesKit';
import { MediaService } from '../model/MediaService';
import { AppStorageKeys, Logger, MusicAppState, StyleConstants } from 'musicbasic';

@Builder
export function SongPageBuilder() {
  SongPage();
}

@ComponentV2
struct SongPage {
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  readonly halfWidth: string = '50%';
  private static readonly CROWN_STEP_DEGREE: number = 20;

  aboutToAppear(): void {
    if (this.state.isFirstLaunch) {
      MediaService.getInstance().loadAsset(0, true);
    }
    this.state.isFirstLaunch = false;
  }

  private handleCrownVolume(event: CrownEvent): void {
    event.stopPropagation();
    let newVolume = this.state.volume * 100 + event.degree / SongPage.CROWN_STEP_DEGREE;
    newVolume = Math.max(0, Math.min(100, newVolume));
    this.state.volume = newVolume / 100;
    try {
      Logger.info(`SongPage crown setVolume ${this.state.volume}`);
      MediaService.getInstance().avPlayer?.setVolume(this.state.volume);
    } catch (error) {
      Logger.error(`SongPage crown setVolume failed code: ${(error as BusinessError).code}`);
    }
  }

  build() {
    NavDestination() {
      Stack() {
        Image(this.state.getCurrentSongItem()?.label ?? $r('app.string.page_show'))
          .width(StyleConstants.FULL_WIDTH)
          .height(StyleConstants.FULL_HEIGHT)
          .objectFit(ImageFit.Cover)
          .blur(200)
          .opacity(0.4)
        Column() {}
        .backgroundColor('#8042181f')

        Column() {
          Column() {
          Text(this.state.getCurrentSongItem()?.title ?? '')
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_color'))
            .maxLines(1)
            .width(StyleConstants.FULL_WIDTH)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .shaderStyle({
              direction: GradientDirection.Right,
              colors: [
                ['#00FFFFFF', 0.0],
                ['#FFFFFFFF', 0.5],
                ['#00FFFFFF', 1.0]
              ]
            })
            .marqueeOptions({
              start: true,
              fromStart: true,
              step: 6,
              loop: -1,
              delay: 0,
              fadeout: false,
              marqueeStartPolicy: MarqueeStartPolicy.DEFAULT
            })
          Text(this.state.getCurrentSongItem()?.singer ?? '')
            .fontColor($r('app.color.play_singer_color'))
          }
          .width('85%')
          Row() {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize($r('app.float.play_song_img'))
            .fontWeight(FontWeight.Regular)
            .height($r('app.float.play_song_img'))
            .fontColor([$r('app.color.font_color')])
            .onClick(() => {
              MediaService.getInstance().playPrevious();
            })
          Stack() {
            Image(this.state.getCurrentSongItem()?.label ?? $r('app.string.page_show'))
              .width($r('app.float.play_circle_img'))
              .height($r('app.float.play_circle_img'))
              .borderRadius(StyleConstants.CIRCLE_BORDER_RADIUS)

            Progress({ value: this.state.progress, total: this.state.progressMax, type: ProgressType.Ring })
              .width($r('app.float.play_progress_width'))
              .backgroundColor(Color.Transparent)
              .color($r('app.color.font_color'))

            Image($r('app.media.play_btn'))
              .width($r('app.float.play_song_img'))
              .visibility(this.state.isPlay === true ? Visibility.None : Visibility.Visible)
              .onClick(() => {
                if (MediaService.getInstance().getFirst()) {
                  MediaService.getInstance().loadAsset(0);
                } else {
                    this.state.isPlay ? MediaService.getInstance().pause() : MediaService.getInstance().play();
                }
              })

            Image($r('app.media.pause_btn'))
              .width($r('app.float.play_song_img'))
              .visibility(this.state.isPlay === true ? Visibility.Visible : Visibility.None)
              .onClick(() => {
                MediaService.getInstance().pause();
              })
          }
          .width(this.halfWidth)
          .align(Alignment.Center)

          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize($r('app.float.play_song_img'))
            .fontWeight(FontWeight.Regular)
            .height($r('app.float.play_song_img'))
            .fontColor([$r('app.color.font_color')])
            .onClick(() => {
              MediaService.getInstance().playNextAuto(true);
            })
          }
          .justifyContent(FlexAlign.SpaceAround)
          .width('85%')

          Row() {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize($r('app.float.play_icon_width'))
            .fontWeight(FontWeight.Regular)
            .height($r('app.float.play_icon_width'))
            .fontColor([$r('app.color.font_color')])
          SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize($r('app.float.play_icon_width'))
            .height($r('app.float.play_icon_width'))
            .fontColor([$r('app.color.font_color')])
          }
          .width('60%')
          .justifyContent(FlexAlign.SpaceAround)
        }
        .width(StyleConstants.FULL_WIDTH)
        .height(StyleConstants.FULL_HEIGHT)
        .padding({ top: $r('app.float.play_column_padding'), bottom: $r('app.float.play_column_padding') })
        .justifyContent(FlexAlign.SpaceAround)
      }
      .width(StyleConstants.FULL_WIDTH)
      .height(StyleConstants.FULL_HEIGHT)
    }
    .hideTitleBar(true)
    .focusable(true)
    .focusOnTouch(true)
    .defaultFocus(true)
    .backgroundColor('#000000')
    .onDigitalCrown((event: CrownEvent) => {
      this.handleCrownVolume(event);
    })
  }
}
