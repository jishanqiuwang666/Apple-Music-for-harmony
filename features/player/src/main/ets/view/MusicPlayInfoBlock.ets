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
import { AppStorageKeys, StyleConstants } from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';
import { PlayerConstants } from '../constant/PlayerConstants';
import { ControlAreaComponent } from './ControlAreaComponent';

/** Album art, title/artist block, and control area for full-screen playback layouts. */
@ComponentV2
export struct MusicPlayInfoBlock {
  /** Window breakpoint for typography and grid layout. */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** Shared playback and queue state. */
  @Param state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** When true, uses album art as a large background layer behind text. */
  @Param useAlbumCoverBackground: boolean = false;
  /** Vertical translation (vp) applied to meta block during dismiss gesture. */
  @Param metaBlockTranslateYvp: number = 0;
  /** True while dismissing past phase-1 threshold (hides some meta chrome). */
  @Param isDismissing: boolean = false;
  /** Linear scale factor (0�?) applied to cover during vertical dismiss. */
  @Param coverLinearScale: number = 1;
  /** When true, use compact panel stacking and hide the auxiliary 4-icon control row. */
  @Param panelLayout: boolean = false;

  /** True on MD width + MD height fold inner layout for compact title sizing. */
  private isMdCompactInfoTypography(): boolean {
    return this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_MD &&
      this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD;
  }

  /** Title and artist column used beside compact square cover. */
  @Builder
  MusicInfoTextsCompactCover() {
    Column() {
      Text(this.state.getCurrentSongItem()?.title ?? '')
        .fontSize($r('app.float.title_font_play'))
        .fontColor($r('app.color.player_text_primary'))
        .opacity(0.86)
        .fontWeight(FontWeight.Bold)
        .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(StyleConstants.FULL_WIDTH)
      Text(this.state.getCurrentSongItem()?.singer ?? '')
        .textAlign(TextAlign.Start)
        .fontSize($r('app.float.font_fourteen'))
        .fontColor($r('app.color.play_text_color'))
        .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
        .margin({ top: 2 })
        .width(StyleConstants.FULL_WIDTH)
        .fontWeight(FontWeight.Regular)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(StyleConstants.FULL_WIDTH)
  }

  /** Linear scale for dismiss gesture; clamped so the cover never measures/render as zero-size. */
  private coverDisplayScale(): number {
    return Math.min(1, Math.max(0.02, this.coverLinearScale));
  }

  /**
   * Square cover in the remaining column height above metadata + controls.
   * Uses layoutWeight so art expands; title/transport stay in the sibling column below.
   */
  @Builder
  CoverInfo() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.state.getCurrentSongItem()?.label ?? $r('app.string.page_show'))
        .constraintSize({ maxWidth: '100%', maxHeight: '100%' })
        .aspectRatio(1)
        .objectFit(ImageFit.Cover)
        .syncLoad(true)
        .borderRadius(8)
    }
    .width(StyleConstants.FULL_WIDTH)
    .layoutWeight(1)
    .borderRadius($r('app.float.cover_radius_label'))
    .clip(true)
    .scale({
      x: this.coverDisplayScale(),
      y: this.coverDisplayScale(),
      z: 1,
      centerX: '0%',
      centerY: '0%'
    })
  }

  /** Title row with like icon and artist line (non-compact layouts). */
  @Builder
  MusicInfoTexts() {
    Column() {
      Flex({ justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.state.getCurrentSongItem()?.title ?? '')
          .layoutWeight(1)
          .fontSize(this.panelLayout ? 24 : (this.isMdCompactInfoTypography() ?
            $r('app.float.title_font_play_md') : $r('app.float.title_font_play')))
          .fontColor($r('app.color.player_text_primary'))
          .opacity(0.86)
          .fontWeight(FontWeight.Bold)
          .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.heart_fill'))
            .fontSize(22)
            .fontColor([$r('app.color.player_text_primary')])
            .opacity(0.86)
        }
      }
      .width(StyleConstants.FULL_WIDTH)

      Text(this.state.getCurrentSongItem()?.singer ?? '')
        .textAlign(TextAlign.Start)
        .fontSize(this.panelLayout ? 22 : (this.isMdCompactInfoTypography() ?
          $r('app.float.title_font_play') : $r('app.float.font_fourteen')))
        .fontColor($r('app.color.play_text_color'))
        .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
        .margin({ top: 2 })
        .width(StyleConstants.FULL_WIDTH)
        .fontWeight(FontWeight.Regular)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .margin({ top: $r('app.float.music_info_margin_top') })
  }

  /** Responsive grid placing cover, texts, and ControlAreaComponent. */
  build() {
    if (this.useAlbumCoverBackground) {
      Column() {
        Column({ space: 0 }) {
          this.MusicInfoTextsCompactCover()
          ControlAreaComponent({ showBottomOtherRow: false })
        }
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .width(StyleConstants.FULL_WIDTH)
        .height(219)
        .padding({
          bottom: $r('app.float.music_component_bottom'),
          left: $r('app.float.common_padding'),
          right: $r('app.float.common_padding')
        })
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.info_scrim_top'), 0.0],
            [$r('app.color.info_scrim_mid'), 0.5],
            [$r('app.color.info_scrim_bottom'), 1.0]
          ]
        })
        .translate({ y: this.metaBlockTranslateYvp })
        .visibility(this.isDismissing ? Visibility.None : Visibility.Visible)
      }
      .height(StyleConstants.FULL_HEIGHT)
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.End)
      .clip(true)
    } else {
      if (this.panelLayout) {
        Column() {
          Column() {
            Image(this.state.getCurrentSongItem()?.label ?? $r('app.string.page_show'))
              .width(StyleConstants.FULL_WIDTH)
              .aspectRatio(1)
              .objectFit(ImageFit.Cover)
              .syncLoad(true)
              .constraintSize({
                maxHeight: '100%'
              })
              .borderRadius($r('app.float.cover_radius_label'))
              .clip(true)
              .scale({
                x: this.coverDisplayScale(),
                y: this.coverDisplayScale(),
                z: 1,
                centerX: '0%',
                centerY: '0%'
              })
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)

          Column() {
            this.MusicInfoTexts()
            ControlAreaComponent({ showBottomOtherRow: false })
          }
          .height(276)
          .justifyContent(FlexAlign.End)
        }
        .height(StyleConstants.FULL_HEIGHT)
        .width(StyleConstants.FULL_WIDTH)
        .alignItems(HorizontalAlign.Center)
        .translate({ y: this.metaBlockTranslateYvp })
        .visibility(this.isDismissing ? Visibility.None : Visibility.Visible)
      } else {
        Column() {
          this.CoverInfo()
          Column() {
            this.MusicInfoTexts()
            ControlAreaComponent({ showBottomOtherRow: true })
          }
          .justifyContent(FlexAlign.SpaceBetween)
          .translate({ y: this.metaBlockTranslateYvp })
          .visibility(this.isDismissing ? Visibility.None : Visibility.Visible)
        }
        .height(StyleConstants.FULL_HEIGHT)
        .width(StyleConstants.FULL_WIDTH)
        .alignItems(HorizontalAlign.Center)
      }
    }
  }
}
