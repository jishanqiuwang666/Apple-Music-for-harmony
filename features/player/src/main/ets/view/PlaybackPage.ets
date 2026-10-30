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

import { AppStorageV2, display, uiObserver } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AppStorageKeys,
  BreakpointConstants,
  getWindowInfoState,
  ImmersiveType,
  isWidthBreakpointLgOrXl,
  Logger,
  StyleConstants,
  WindowInfo,
  WindowUtil
} from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';
import { ColorConversion } from 'musicbasic';
import { PlayerConstants } from '../constant/PlayerConstants';
import { LyricsComponent } from './LyricsComponent';
import { MusicPlayInfoBlock } from './MusicPlayInfoBlock';
import { TopAreaComponent } from './TopAreaComponent';

/** Clamps a numeric RGB channel to an integer byte in [0, 255]. */
function clampRgbByte(n: number): number {
  if (!Number.isFinite(n)) {
    return 0;
  }
  return Math.max(0, Math.min(255, Math.floor(n)));
}

/** Debug snapshot for album cover scale during vertical dismiss gesture. */
/** Minimal shape for probing {@link image.PixelMap.release}; {@link Resource} does not carry this. */
interface PixelMapReleaseProbe {
  release?: () => void;
}

interface CoverScaleDebugInfo {
  /** Linear scale factor applied to the cover (0�?). */
  scale: number;

  /** Reserved vertical anchor (unused in current formula). */
  y0: number;

  /** Finger travel span used to interpolate scale. */
  span: number;

  /** Current vertical pan offset in px. */
  y: number;

  /** Device height in vp used for span calculation. */
  h: number;

  /** True when mapped dismiss percent is still in phase 1 (at or below the phase-one cap, 50). */
  isProgressInPhaseOne: boolean;
}

/**
 * Full-screen playback page: layered background, breakpoint-specific layout, dismiss gestures,
 * and dynamic tint from album art.
 */
@ComponentV2
export struct PlaybackPage {
  /** Window width/height breakpoint for responsive layout branches. */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** Global music UI and queue state. */
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** Status bar / navigation bar metrics for safe padding. */
  @Local windowInfo: WindowInfo = getWindowInfoState();
  /** Normalized dismiss progress 0�?00 mapped from pan gesture. */
  @Local componentHeight: number = 0;
  /** Raw vertical pan offset in px while dragging the sheet. */
  @Local dismissPanOffsetY: number = 0;
  /** Last mapped dismiss percentage from gesture (0�?00). */
  @Local lastPanRawPercent: number = 0;
  /** Screen height in vp for dismiss math. */
  @Local deviceHeight: number = 0;
  /** Background cover image (Resource or blurred PixelMap). */
  @Local imageLabel: image.PixelMap | Resource = $r('app.string.page_show');
  /** Whether compact layout shows transport chrome on the main column. */
  @Local isShowControl: boolean = true;
  /** Whether large / grid layout shows transport in the lyric column. */
  @Local isShowControlLg: boolean = false;
  /** Passed to child components that branch on tablet spacing. */
  @Local isTablet: boolean = true;
  /** Inverse tablet flag for lyric column variants. */
  @Local isTabletFalse: boolean = false;
  /** When true, renders the wide split panel layout (no top bar, custom paddings). */
  @Param panelLayout: boolean = false;
  /** Timer id for page auto-hide sample logic. */
  @Local intervalId: number = 0;
  /** Swiper page index (lyrics vs main stack on some layouts). */
  @Local playbackSwiperIndex: number = 0;
  /** False after teardown to ignore async image callbacks. */
  private isAlive: boolean = true;
  /** Bumps on each {@link getImageColorAsync} run so stale async work skips UI updates and releases pixels. */
  private imageColorJobSeq: number = 0;
  /** Vertical pan configuration for dismiss gesture. */
  private panOption: PanGestureOptions = new PanGestureOptions({ direction: PanDirection.Vertical });
  /** Cached UIAbility context for resource and color extraction. */
  private context: common.UIAbilityContext | undefined = undefined;
  /** Logger tag for this page. */
  private static readonly logTag: string = 'PlaybackPage';
  /** Fallback page background tint when art or color pick fails. */
  private static readonly defaultImageBgColor: string = 'rgba(32, 32, 32, 1)';

  /** Seeds cover Resource from the current queue item. */
  aboutToAppear(): void {
    const song = this.state.getCurrentSongItem();
    this.releaseBackgroundCoverIfPixelMap();
    this.imageLabel = song !== undefined ? song.label : $r('app.string.page_show');
  }

  /** True when value looks like a decoded PixelMap ({@link Resource} has no release). */
  private isPixelMapCover(value: image.PixelMap | Resource): boolean {
    if (typeof value !== 'object' || value === null) {
      return false;
    }
    const probe = value as PixelMapReleaseProbe;
    return typeof probe.release === 'function';
  }

  /** Releases native PixelMap backing if {@link imageLabel} is a decoded bitmap (not a Resource). */
  private releaseBackgroundCoverIfPixelMap(): void {
    if (!this.isPixelMapCover(this.imageLabel)) {
      return;
    }
    try {
      (this.imageLabel as image.PixelMap).release();
    } catch (error) {
      const err = error as BusinessError;
      Logger.warn(PlaybackPage.logTag,
        `background cover PixelMap.release failed, code=${err?.code}, message=${err?.message}`);
    }
  }

  /** Safe PixelMap.release for locals (blur/decoded temps). */
  private releasePixelMapQuiet(pm: image.PixelMap | undefined | null): void {
    if (pm === undefined || pm === null) {
      return;
    }
    try {
      pm.release();
    } catch (error) {
      const err = error as BusinessError;
      Logger.warn(PlaybackPage.logTag,
        `pixelMap.release failed, code=${err?.code}, message=${err?.message}`);
    }
  }

  /**
   * 请求关闭全屏播放页（下拉超过阈值 / 点收起）。
   *
   * 2026-10-03 改：收起动画统一交给宿主壳层（products/default 的 Index）——
   * 那里用官方 springMotion 把整页 translate 回屏幕下方再卸载。这里只置标记，
   * 宿主 @Monitor 到 false 就启动收起动画。
   * 以前这里自己跑 350ms EaseInOut 改 isShowPlay，会和宿主的位移动画叠成
   * 「先缩一下、再滑一下」的两段式。
   */
  private closeFullScreenPlayback(): void {
    this.state.isShowPlay = false;
  }

  /** True when dismiss progress passed phase 1 so meta block can hide chrome. */
  private isDismissPhase2HideMeta(): boolean {
    return this.componentHeight > PlaybackPage.dismissPhase1PMax;
  }

  /** Multiplier of device height defining how far the user must drag to fully shrink the cover. */
  private static readonly coverScaleShrinkDistanceMult: number = 2.4;

  /** Album cover linear scale derived from dismiss pan distance. */
  private coverLinearScaleByFinger(): number {
    return this.getCoverScaleDebugInfo().scale;
  }

  /** Computes scale and geometry inputs for cover shrink during dismiss. */
  private getCoverScaleDebugInfo(): CoverScaleDebugInfo {
    const isProgressInPhaseOne: boolean = this.componentHeight <= PlaybackPage.dismissPhase1PMax;
    if (this.deviceHeight <= 0) {
      return {
        scale: 1.0,
        y0: 0,
        span: 0,
        y: 0,
        h: 0,
        isProgressInPhaseOne: isProgressInPhaseOne
      };
    }
    const h: number = this.deviceHeight;
    const y: number = Math.max(0, this.dismissPanOffsetY);
    const span: number = h * PlaybackPage.coverScaleShrinkDistanceMult;
    const scale: number = span > 0 ? Math.max(0, 1 - y / span) : 0;
    return {
      scale: scale,
      y0: 0,
      span: span,
      y: y,
      h: h,
      isProgressInPhaseOne: isProgressInPhaseOne
    };
  }

  /** Maps raw gesture percent to eased dismiss progress 0�?00. */
  private mapGestureRawToDismissP(raw: number): number {
    if (raw <= 0) {
      return 0;
    }
    if (raw >= 100) {
      return 100;
    }
    return 100 * Math.pow(raw / 100, PlaybackPage.dismissPMapExp);
  }

  /** Dismiss progress (%) below which only the sheet translates; above blends to phase 2. */
  private static readonly dismissPhase1PMax: number = 50;
  /** Blend span in percent units between phase 1 and 2 sheet height interpolation. */
  private static readonly dismissSheetBlendP: number = 8;
  /** Exponent for non-linear mapping of raw dismiss percent. */
  private static readonly dismissPMapExp: number = 1.42;

  /** Vertical translation (vp) for title/meta block during dismiss. */
  private dismissMetaBlockTranslateYvp(p: number): number {
    if (p <= 0) {
      return 0;
    }
    const cap = this.deviceHeight > 0 ? this.deviceHeight * 0.4 : 300;
    if (p <= PlaybackPage.dismissPhase1PMax) {
      return 0;
    }
    const span: number = 100 - PlaybackPage.dismissPhase1PMax;
    if (p >= 100) {
      return cap;
    }
    return ((p - PlaybackPage.dismissPhase1PMax) / span) * cap;
  }

  /** Blend factor 0�? between phase-1 and phase-2 dismiss sheet behavior. */
  private phase1To2SheetBlendB(p: number): number {
    if (p <= PlaybackPage.dismissPhase1PMax) {
      return 0;
    }
    return Math.min(1, (p - PlaybackPage.dismissPhase1PMax) / PlaybackPage.dismissSheetBlendP);
  }

  /** Bottom sheet height as percent string while dismissing (shrinks in phase 2). */
  private dismissSheetHeightPercent(p: number): string {
    if (p <= PlaybackPage.dismissPhase1PMax) {
      return '100%';
    }
    const b: number = this.phase1To2SheetBlendB(p);
    const h: number = 100 * (1 - b) + (100 - p) * b;
    return h + '%';
  }

  /** Bottom sheet vertical translation in vp during dismiss drag. */
  private dismissSheetTranslateYvp(p: number): number {
    if (p <= 0) {
      return 0;
    }
    const h: number = this.deviceHeight > 0 ? this.deviceHeight : 640;
    const capY: number = h * 0.5;
    if (p <= PlaybackPage.dismissPhase1PMax) {
      return (p / PlaybackPage.dismissPhase1PMax) * capY;
    }
    const b: number = this.phase1To2SheetBlendB(p);
    return (1 - b) * capY;
  }

  /** True for small-width + medium-height window (phone landscape-ish). */
  private isSmHeightMdLayout(): boolean {
    return this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
      this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD;
  }


  /** Blurred cover tile + imageColor (phone Swiper); same for album page and lyrics page. */
  @Builder
  phoneSwiperBackdropImage() {
    Image(this.imageLabel)
      .size(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ?
        {
          width: PlayerConstants.BACK_IMAGE
        } :
        {
          height: PlayerConstants.BACK_IMAGE
        })
      .aspectRatio(1)
      .objectFit(ImageFit.Cover)
      .opacity(0.5)
  }

  /** Main Stack: background art, breakpoint-specific controls and lyrics grid. */
  @Builder
  buildControlStack() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
      if (this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
        this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_MD && this.playbackSwiperIndex === 0) {
        Image(this.state.getCurrentSongItem()?.label)
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Fill)
      } else {
        Image(this.imageLabel)
          .size(isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ?
            {
              width: PlayerConstants.BACK_IMAGE
            } :
            {
              height: PlayerConstants.BACK_IMAGE
            })
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
          .opacity(0.4)
          .blur(300)
          .colorBlend('#42181f')
      }
      if (this.panelLayout) {
        this.panelControlContent()
      } else {
        Row() {
          if (!(this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_SM ||
            (this.breakpointEnv.widthBreakpoint === WidthBreakpoint.WIDTH_MD &&
              this.breakpointEnv.heightBreakpoint === HeightBreakpoint.HEIGHT_SM))) {
            Column() {
              TopAreaComponent({
                isShowPlay: this.state.isShowPlay,
                onBackClick: (): void => {
                  this.closeFullScreenPlayback();
                }
              })
                .margin({
                  bottom: $r('app.float.music_info_margin_top')
                })
              GridRow({
                columns: { md: BreakpointConstants.COLUMN_MD },
                gutter: 48
              }) {
                GridCol({
                  span: { md: BreakpointConstants.SPAN_SM }
                }) {
                  MusicPlayInfoBlock({
                    state: this.state,
                    metaBlockTranslateYvp: this.dismissMetaBlockTranslateYvp(this.componentHeight),
                    isDismissing: this.isDismissPhase2HideMeta(),
                    coverLinearScale: this.coverLinearScaleByFinger()
                  })
                }
                .margin({
                  bottom: 20
                })
                .padding({
                  left: isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 48 : 0,
                  right: isWidthBreakpointLgOrXl(this.breakpointEnv.widthBreakpoint) ? 48 : 0
                })

                GridCol({
                  span: { md: BreakpointConstants.SPAN_SM }
                }) {
                  LyricsComponent({ isShowControl: this.isShowControlLg, isTablet: this.isTabletFalse })
                }
                .translate({ y: this.dismissMetaBlockTranslateYvp(this.componentHeight) })
                .margin({
                  bottom: 20
                })
              }
              .layoutWeight(1)
              .clip(true)
            }
            .layoutWeight(1)
            .padding({
              left: $r('app.float.common_padding'),
              right: $r('app.float.common_padding')
            })
          } else {
            Stack({ alignContent: Alignment.TopStart }) {
              Swiper() {
                Column() {
                  MusicPlayInfoBlock({
                    state: this.state,
                    useAlbumCoverBackground: this.isSmHeightMdLayout(),
                    metaBlockTranslateYvp: this.dismissMetaBlockTranslateYvp(this.componentHeight),
                    isDismissing: this.isDismissPhase2HideMeta(),
                    coverLinearScale: this.coverLinearScaleByFinger()
                  })
                }
                .width(StyleConstants.FULL_WIDTH)
                .margin({
                  top: this.isSmHeightMdLayout() ? 0 : $r('app.float.music_component_top'),
                  bottom: this.isSmHeightMdLayout() ? 0 : $r('app.float.music_component_bottom')
                })
                .padding({
                  left: this.isSmHeightMdLayout() ? 0 : $r('app.float.common_padding'),
                  right: this.isSmHeightMdLayout() ? 0 : $r('app.float.common_padding')
                })

                Column() {
                  LyricsComponent({
                    isShowControl: this.isShowControl,
                    isTablet: this.isTabletFalse,
                    hideLyricsMetaHeader: this.isSmHeightMdLayout()
                  })
                }
                .width(StyleConstants.FULL_WIDTH)
                .height(StyleConstants.FULL_HEIGHT)
                .margin({
                  top: this.isSmHeightMdLayout() ? 0 : $r('app.float.margin_lyric')
                })
                .padding({
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
                .translate({ y: this.dismissMetaBlockTranslateYvp(this.componentHeight) })
              }
              .height(StyleConstants.FULL_HEIGHT)
              .indicator(
                new DotIndicator()
                  .top($r('app.float.options_padding'))
                  .selectedColor($r('app.color.select_swiper'))
                  .color($r('app.color.slider_track'))
              )
              .clip(false)
              .loop(false)
              .onChange((index: number) => {
                this.playbackSwiperIndex = index;
                if (index === 1) {
                  if (this.isSmHeightMdLayout()) {
                    this.isShowControl = false;
                    clearInterval(this.intervalId);
                    this.intervalId = 0;
                  } else {
                    this.isShowControl = true;
                    this.intervalId = setInterval(() => {
                      if (!this.isAlive) {
                        clearInterval(this.intervalId);
                        return;
                      }
                      this.state.pageShowTime += 1;
                      if (this.state.pageShowTime > 5) {
                        this.isShowControl = false;
                        clearInterval(this.intervalId);
                      }
                    }, 1000);
                  }
                } else {
                  this.state.pageShowTime = 0;
                  clearInterval(this.intervalId);
                }
              })

              TopAreaComponent({
                isShowPlay: this.state.isShowPlay,
                onBackClick: (): void => {
                  this.closeFullScreenPlayback();
                }
              })
                .padding({
                  left: $r('app.float.common_padding'),
                  right: $r('app.float.common_padding')
                })
                .zIndex(2)
            }
            .height(StyleConstants.FULL_HEIGHT)
          }
        }
        .padding({
          bottom: this.windowInfo.navigationBarBottomVp,
          top: this.windowInfo.statusBarTopVp
        })
      }
    }
    .height(StyleConstants.FULL_HEIGHT)
    .width(StyleConstants.FULL_WIDTH)
    .backgroundColor(this.state.imageColor)
  }

  /** Wide split panel layout: cover + controls on the left, lyrics + dual-action bar on the right. */
  @Builder
  private panelControlContent() {
    Row({ space: 56 }) {
      Column() {
        MusicPlayInfoBlock({
          state: this.state,
          metaBlockTranslateYvp: 0,
          isDismissing: false,
          coverLinearScale: 1,
          panelLayout: true
        })
      }
      .layoutWeight(1)
      .padding({ top: 80, bottom: 48 })

      Column() {
        LyricsComponent({
          isShowControl: false,
          isTablet: this.isTabletFalse,
          panelBottomBar: true
        })
      }
      .layoutWeight(1)
      .padding({ top: 72, bottom: 74 })
    }
    .width(StyleConstants.FULL_WIDTH)
    .height(StyleConstants.FULL_HEIGHT)
    .padding({
      left: 56,
      right: 56,
      top: this.windowInfo.statusBarTopVp,
      bottom: this.windowInfo.navigationBarBottomVp
    })
  }

  /** True when PC window uses immersive free-form decor (affects title button styling). */
  private isPcFreeWindowDecor(): boolean {
    return this.windowInfo.immersiveDecor === ImmersiveType.IMMERSIVE;
  }

  /** Applies playback-specific window chrome and optional PC decor button style. */
  private applyWindowSafeAreas(): void {
    const wu = WindowUtil.getInstance();
    wu.applyPlaybackWindowChrome(true);
    if (this.isPcFreeWindowDecor()) {
      wu.applyPcPlaybackDecorButtonStyle(true);
    }
  }

  /** Refreshes dynamic background tint when the current track or queue changes. */
  @Monitor('state.selectIndex', 'state.playQueueIds')
  onCurrentTrackForBackground(): void {
    if (this.context === undefined) {
      return;
    }
    this.getImageColor();
  }

  /** Entry point: kicks off async album-color extraction without blocking UI. */
  getImageColor(): void {
    void this.getImageColorAsync();
  }

  /** Loads cover bytes, derives theme background color, and builds blurred background PixelMap. */
  private async getImageColorAsync(): Promise<void> {
    const jobSeq: number = ++this.imageColorJobSeq;
    const ctx = this.context;
    if (!ctx) {
      return;
    }
    const song = this.state.getCurrentSongItem();
    if (!song || !song.label) {
      return;
    }
    this.releaseBackgroundCoverIfPixelMap();
    this.imageLabel = song.label;

    let mediaData: Uint8Array;
    try {
      mediaData = await ctx.resourceManager.getMediaContent(song.label.id);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(PlaybackPage.logTag,
        `getMediaContent failed, code=${err?.code}, message=${err?.message}`);
      if (this.isAlive) {
        this.state.imageColor = PlaybackPage.defaultImageBgColor;
      }
      return;
    }
    if (!mediaData || mediaData.byteLength === 0) {
      Logger.error(PlaybackPage.logTag, 'getMediaContent returned empty buffer');
      if (this.isAlive) {
        this.state.imageColor = PlaybackPage.defaultImageBgColor;
      }
      return;
    }

    let pixelMap: image.PixelMap | undefined = undefined;
    const imageSource = image.createImageSource(mediaData.buffer as ArrayBuffer);
    try {
      pixelMap = await imageSource.createPixelMap();
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(PlaybackPage.logTag,
        `createPixelMap failed, code=${err?.code}, message=${err?.message}`);
      if (this.isAlive) {
        this.state.imageColor = PlaybackPage.defaultImageBgColor;
      }
      return;
    } finally {
      try {
        imageSource.release();
      } catch (error) {
        const err = error as BusinessError;
        Logger.warn(PlaybackPage.logTag,
          `imageSource.release failed, resourceId=${song.label.id}, code=${err?.code}, message=${err?.message}`);
      }
    }

    if (pixelMap === undefined) {
      return;
    }

    if (!this.isAlive || jobSeq !== this.imageColorJobSeq) {
      this.releasePixelMapQuiet(pixelMap);
      return;
    }

    await new Promise<void>((resolve: () => void) => {
      effectKit.createColorPicker(pixelMap,
        (error: Error | undefined, colorPicker: effectKit.ColorPicker | undefined) => {
          try {
            if (!this.isAlive || jobSeq !== this.imageColorJobSeq) {
              return;
            }
            if (error || colorPicker === undefined) {
              const msg =
                error ? `${(error as BusinessError).code} ${(error as BusinessError).message}` : 'no picker';
              Logger.error(PlaybackPage.logTag, `createColorPicker failed: ${msg}`);
              this.state.imageColor = PlaybackPage.defaultImageBgColor;
              return;
            }
            const color = colorPicker.getLargestProportionColor();
            const colorArr = ColorConversion.dealColor(color.red, color.green, color.blue);
            const r = clampRgbByte(colorArr[0]);
            const g = clampRgbByte(colorArr[1]);
            const b = clampRgbByte(colorArr[2]);
            this.state.imageColor = `rgba(${r}, ${g}, ${b}, 0.4)`;
          } finally {
            resolve();
          }
        });
    });

    if (!this.isAlive || jobSeq !== this.imageColorJobSeq) {
      this.releasePixelMapQuiet(pixelMap);
      return;
    }

    try {
      const headFilter = effectKit.createEffect(pixelMap);
      if (headFilter !== null) {
        headFilter.blur(PlayerConstants.IMAGE_BLUR);
        const blurred = await headFilter.getEffectPixelMap();
        if (this.isAlive && jobSeq === this.imageColorJobSeq) {
          this.imageLabel = blurred;
        } else {
          this.releasePixelMapQuiet(blurred);
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(PlaybackPage.logTag,
        `blur effect failed, code=${err?.code}, message=${err?.message}`);
    } finally {
      this.releasePixelMapQuiet(pixelMap);
    }
  }

  /** Root column with dismiss transform, pan-to-close, and lifecycle hooks. */
  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#42181f')

      Column() {
        Column() {
          this.buildControlStack()
        }
        .height(this.dismissSheetHeightPercent(this.componentHeight))
        .translate({ y: this.dismissSheetTranslateYvp(this.componentHeight) })
      }
      .width(StyleConstants.FULL_WIDTH)
      .height(StyleConstants.FULL_HEIGHT)
      .backgroundColor(this.state.imageColor)
      .justifyContent(FlexAlign.End)
      .clip(true)
      .onAppear(() => {
        this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.isAlive = true;
        try {
          const defaultDisplay = display.getDefaultDisplaySync();
          this.deviceHeight = this.getUIContext().px2vp(defaultDisplay.height);
        } catch (error) {
          const err = error as BusinessError;
          Logger.warn(PlaybackPage.logTag,
            `getDefaultDisplaySync failed, fallback deviceHeight=640, code=${err?.code}, message=${err?.message}`);
          this.deviceHeight = 640;
        }
        this.getImageColor();
        this.applyWindowSafeAreas();
        this.playbackSwiperIndex = 0;
        if (this.isSmHeightMdLayout()) {
          this.isShowControl = false;
        }
      })
      .onDisAppear(() => {
        this.isAlive = false;
        this.imageColorJobSeq++;
        this.releaseBackgroundCoverIfPixelMap();
        this.imageLabel = $r('app.string.page_show');
        clearInterval(this.intervalId);
        this.intervalId = 0;
        this.componentHeight = 0;
        this.dismissPanOffsetY = 0;
        this.lastPanRawPercent = 0;
        this.state.isShowPlay = false;
        const wu = WindowUtil.getInstance();
        wu.applyPlaybackWindowChrome(false);
        wu.applyPcPlaybackDecorButtonStyle(false);
      })
      .gesture(
        PanGesture(this.panOption)
          .onActionStart(() => {
            Logger.debug(PlaybackPage.logTag, 'coverDismiss panStart');
          })
          .onActionUpdate((event?: GestureEvent) => {
            if (event && this.deviceHeight > 0) {
              this.dismissPanOffsetY = event.offsetY >= 0 ? event.offsetY : 0;
              let raw: number = event.offsetY / this.deviceHeight * 100;
              if (raw < 0) {
                raw = 0;
              } else if (raw > 100) {
                raw = 100;
              }
              this.lastPanRawPercent = raw;
              this.componentHeight = this.mapGestureRawToDismissP(raw);
              const d = this.getCoverScaleDebugInfo();
              const pStr: string = this.componentHeight.toFixed(1);
              const yStr: string = d.y.toFixed(1);
              const hStr: string = d.h.toFixed(1);
              const sStr: string = d.scale.toFixed(3);
              const spanStr: string = d.span.toFixed(1);
              const rawStr: string = raw.toFixed(1);
              const inPhaseOneStr: string = d.isProgressInPhaseOne ? '1' : '0';
              Logger.debug(
                PlaybackPage.logTag,
                `coverDismiss y=${yStr}vp H=${hStr}vp shrinkTotal=${spanStr}vp mult=${
                PlaybackPage.coverScaleShrinkDistanceMult.toFixed(2)
                } ` + `raw%=${rawStr} p=${pStr} coverScale=${sStr} inPhase1=${inPhaseOneStr}`
              );
            }
          })
          .onActionEnd(() => {
            const d = this.getCoverScaleDebugInfo();
            Logger.debug(
              PlaybackPage.logTag,
              'coverDismiss panEnd ' +
                `raw%=${this.lastPanRawPercent.toFixed(1)} p=${this.componentHeight.toFixed(1)} ` +
                `close=${this.lastPanRawPercent > 40 ? '1' : '0'} ` +
                `lastScale=${d.scale.toFixed(3)}`
            );
            this.dismissPanOffsetY = 0;
            if (this.lastPanRawPercent > 40) {
              this.closeFullScreenPlayback();
            } else {
              this.componentHeight = 0;
            }
          })
      )
    }

  }
}

/** Builder used by product shells to mount PlaybackPage inside a modal content cover. */
@Builder
export function PlaybackPageCoverContent() {
  Column() {
    PlaybackPage()
  }
  .width(StyleConstants.FULL_WIDTH)
  .height(StyleConstants.FULL_HEIGHT)
}

/** Panel-style cover content (wide split layout) for product shells that opt into the panel layout. */
@Builder
export function PlaybackPagePanelCoverContent() {
  Column() {
    PlaybackPage({ panelLayout: true })
  }
  .width(StyleConstants.FULL_WIDTH)
  .height(StyleConstants.FULL_HEIGHT)
}
