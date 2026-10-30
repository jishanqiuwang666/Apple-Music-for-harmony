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

import { uiObserver } from '@kit.ArkUI';
import { BreakpointType, isWidthBreakpointLgOrXl, StyleConstants } from 'musicbasic';
import { PlayerConstants } from '../constant/PlayerConstants';
import { MusicPlayMode } from '../model/MusicData';
import { PlayerDataUtil } from '../util/PlayerDataUtil';
import { PlayerViewModel } from '../viewmodel/PlayerViewModel';

/** Full-screen transport: progress, main controls, and auxiliary icon row inside a single bottom panel. */
@ComponentV2
export struct ControlAreaComponent {
  /** Navigation stack from shell for opening playlist / song list routes. */
  @Consumer('pageIndexInfos') pageIndexInfos: NavPathStack = new NavPathStack();
  /** Window breakpoint for responsive control sizing. */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** View model for seek and transport delegation. */
  @Local playerViewModel: PlayerViewModel = new PlayerViewModel();
  /** Mirrors MediaService play mode for SymbolGlyph (order / single cycle / shuffle). */
  @Local playMode: MusicPlayMode = MusicPlayMode.ORDER;
  /** When false, hides the bottom “other actions�?placeholder row (e.g. album-gradient full-screen layout). */
  @Param showBottomOtherRow: boolean = true;

  /** sys.symbol.repeat | repeat_1 | shuffle per MusicPlayMode. */
  private playModeSymbol(): Resource {
    switch (this.playMode) {
      case MusicPlayMode.ORDER:
        return $r('sys.symbol.repeat');
      case MusicPlayMode.SINGLE_CYCLE:
        return $r('sys.symbol.repeat_1');
      case MusicPlayMode.RANDOM:
        return $r('sys.symbol.shuffle');
      default:
        return $r('sys.symbol.repeat');
    }
  }

  @Builder
  private bottomOtherGlyph(symbol: Resource) {
    SymbolGlyph(symbol)
      .fontSize(22)
      .fontWeight(FontWeight.Regular)
      .fontColor([$r('app.color.play_text_color')])
  }

  /** Progress, transport, and optional auxiliary icons grouped per playback-page layout spec. */
  @Builder
  bottomPanel() {
    Column() {
      Column() {
        Slider({
          min: 0,
          max: this.playerViewModel.appState.progressMax,
          step: 1,
          value: this.playerViewModel.appState.progress
        })
          .blockColor($r('app.color.slider_block'))
          .selectedColor($r('app.color.slider_select'))
          .trackColor($r('app.color.slider_track'))
          .blockSize({
            width: $r('app.float.slider_block'),
            height: $r('app.float.slider_block')
          })
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Begin) {
              this.playerViewModel.seek(value);
            }
            this.playerViewModel.appState.pageShowTime = 0;
          })
          .height($r('app.float.slider_height'))
          .margin({
            left: new BreakpointType(
              $r('app.float.slider_margin_sm'),
              $r('app.float.slider_margin_md'),
              $r('app.float.slider_margin_lg'),
              $r('app.float.slider_margin_lg')
            ).getValue(this.breakpointEnv.widthBreakpoint),
            right: new BreakpointType(
              $r('app.float.slider_margin_sm'),
              $r('app.float.slider_margin_md'),
              $r('app.float.slider_margin_lg'),
              $r('app.float.slider_margin_lg')
            ).getValue(this.breakpointEnv.widthBreakpoint)
          })
          .hitTestBehavior(HitTestMode.Block)
        Row() {
          Text(this.playerViewModel.appState.currentTime)
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
          Text(this.playerViewModel.appState.totalTime)
            .fontColor($r('app.color.play_text_color'))
            .fontSize($r('app.float.singer_title_sm'))
            .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
            .lineHeight('14vp')
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .margin({
        top: this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
          this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD ? 0 : $r('app.float.slider_margin_top'),
        bottom: isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ?
          $r('app.float.slider_margin_bottom_lg') : this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
            this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD ? 8 : $r('app.float.slider_margin_bottom')
      })

      Row() {
        SymbolGlyph(this.playModeSymbol())
          .fontSize(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 26 : 24)
          .fontWeight(FontWeight.Regular)
          .fontColor([$r('app.color.play_text_color')])
          .onClick(() => {
            this.playMode = PlayerDataUtil.cyclePlayMode();
            this.playerViewModel.appState.pageShowTime = 0;
          })
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 30 : 28)
          .fontColor([$r('app.color.play_text_color')])
          .onClick(() => {
            this.playerViewModel.playPrevious();
            this.playerViewModel.appState.pageShowTime = 0;
          })
        SymbolGlyph(this.playerViewModel.appState.isPlay ?
          $r('sys.symbol.pause_round_triangle_fill') : $r('sys.symbol.play_round_triangle_fill'))
          .fontSize(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 40 : 36)
          .fontColor([$r('app.color.play_text_color')])
          .onClick(() => {
            this.playerViewModel.togglePlayPause();
            this.playerViewModel.appState.pageShowTime = 0;
          })
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 30 : 28)
          .fontColor([$r('app.color.play_text_color')])
          .onClick(() => {
            this.playerViewModel.playNext();
            this.playerViewModel.appState.pageShowTime = 0;
          })
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 26 : 24)
          .fontWeight(FontWeight.Regular)
          .fontColor([$r('app.color.play_text_color')])
          .onClick(() => {
            this.playerViewModel.pushPlaylistDetail(this.pageIndexInfos);
            this.playerViewModel.appState.isShowPlay = false;
            this.playerViewModel.appState.pageShowTime = 0;
          })
      }
      .width(StyleConstants.FULL_WIDTH)
      .justifyContent(FlexAlign.SpaceBetween)

      if (this.showBottomOtherRow) {
        Row({ space: 0 }) {
          this.bottomOtherGlyph($r('sys.symbol.shareplay'))
          this.bottomOtherGlyph($r('sys.symbol.bell'))
          this.bottomOtherGlyph($r('sys.symbol.arrow_down_circle'))
          this.bottomOtherGlyph($r('sys.symbol.dot_grid_1x2_circle'))
        }
        .width(StyleConstants.FULL_WIDTH)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({
          top: 32
        })
      }
    }
    .width(StyleConstants.FULL_WIDTH)
    .borderRadius(16)
    .padding({
      top: 8,
      left: 4,
      right: 4
    })
  }

  build() {
    Column() {
      this.bottomPanel()
    }
    .onAppear(() => {
      this.playMode = PlayerDataUtil.getPlayMode();
    })
  }
}

@Extend(Image)
function controlImageBuilder() {
  .aspectRatio(1)
  .opacity(0.86)
  .objectFit(ImageFit.Contain)
}
