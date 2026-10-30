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

import { Animator, AnimatorResult } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from 'musicbasic';
import { LrcEntry } from '../model/LrcEntry';
import { angleToRadian, Rectangle } from '../util/LrcUtils';
import { LyricTopPosition, LyricScrollEffect } from '../constant/LyricConst';

const NONE_LINE: number = -1;

const STAR_ANGLE_NUMBER: number = 5;

const GRADIENT_PROGRESS_SPACE = 0.0000001;

const GRADIENT_PROGRESS_MAX = 1 - GRADIENT_PROGRESS_SPACE;

/**
 * Canvas lyric view: timed line highlight, scroll, and optional star / letter-gradient effects.
 */
@Component
export default struct LrcView {
  /** Current playback position in milliseconds; drives active line and scroll. */
  @Prop @Watch('onTimeUpdated') lyricMilliSecondsTime: number;
  /** Parsed lyric model; refresh triggers layout and redraw. */
  @Prop @Watch('onLyricUpdated') mLrcEntryList: Array<LrcEntry> = [];
  /** Visual effect preset for scrolling / gradient rendering. */
  @Prop @Watch('onTimeUpdated') lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  /** When true, lyric animation / auto-scroll is active. */
  @Prop @Watch('playLyrics') isPlay: boolean = false;
  /** Default (non-current) line text color on canvas. */
  private mNormalTextColor: string = '';
  /** Last measured canvas width in px. */
  private viewWidth: number = 360;
  /** Last measured canvas height in px. */
  private viewHeight: number = 500;
  /** Canvas rendering settings (alpha, etc.). */
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  /** 2D drawing context for lyric text and paths. */
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  /** Index of the highlighted line, or NONE_LINE. */
  private mCurrentLine: number = NONE_LINE;
  /** Hit-test bounds for the current line region. */
  private lyricRectangle: Rectangle = new Rectangle(0, 0, 0, 0);
  /** Extra padding added to measured text height. */
  private readonly textAddSize = 2;
  /** Vertical alignment of the first lyric line within the viewport. */
  public readonly lyricTopPosition: LyricTopPosition = LyricTopPosition.Top;
  /** Baseline Y of the first line after layout. */
  private initFirstLineY: number = 0;
  /** Animator used for smooth canvas vertical scrolling between lines. */
  private animator: AnimatorResult = this.getUIContext().createAnimator({
    duration: 400,
    easing: 'linear',
    delay: 0,
    fill: 'forwards',
    direction: 'normal',
    iterations: 1,
    begin: 0,
    end: 1
  });
  /** Body text size for non-current lines (px). */
  public mNormalTextSize: number = 24;
  /** Vertical gap between lyric lines (px). */
  private mDividerHeight = 24;
  /** Current / emphasized line text size (px). */
  public mCurrentTextSize: number = 28;
  /** Typeface name passed to canvas fillText. */
  private fontFamily = 'HarmonyHeiTi';
  /** Highlight color for the active line. */
  private mCurrentTextColor: string = '';
  /** Shown when {@link mLrcEntryList} is empty; resolved from resources in {@link aboutToAppear}. */
  private emptyLyricPlaceholder: string = '';
  /** Font weight string for canvas (e.g. bold). */
  private fontWeight = 'bold';
  /** Content inset from canvas left edge. */
  private paddingLeft = 0;
  /** Content inset from canvas right edge. */
  private paddingRight = 0;
  /** Content inset from canvas top edge. */
  private paddingTop = 0;
  /** Content inset from canvas bottom edge. */
  private paddingBottom = 0;
  /** Drawable lyric column width inside padding. */
  private lrcWidth: number = 0;
  /** Drawable lyric column height inside padding. */
  private lrcHeight: number = 0;
  /** Origin X of lyric text area. */
  private lrcX: number = 0;
  /** Origin Y of lyric text area. */
  private lrcY: number = 0;
  /** Current vertical scroll offset of lyric content on canvas. */
  private curCanvasOffsetY: number = 0;
  /** Base rotation step for star-style lyric decoration. */
  private starAverageAngle: number = 0;
  /** Outer star ring rotation angle. */
  private starOutCircleAngle: number = 0;
  /** Inner star ring rotation angle. */
  private starInCircleAngle: number = 0;
  /** Cached path for starburst decoration behind lyrics. */
  private starsPath2D: Path2D = new Path2D();
  /** Fill color for star decoration. */
  private starsColor: string = '';
  /** Fully transparent mask color string for gradient overlays. */
  private lrcMaskTransparent: string = '';
  /** Opaque white mask color for gradient overlays. */
  private lrcMaskWhite: string = '';
  /** Semi-transparent mask color for gradient overlays. */
  private lrcMaskSemi: string = '';
  /** Minimum allowed canvas offset Y while scrolling lyrics. */
  private canvasMinOffsetY: number = 0;
  /** Maximum allowed canvas offset Y while scrolling lyrics. */
  private canvasMaxOffsetY: number = 0;

  /** Animates canvas vertical offset toward desOffsetY over a short duration. */
  startAnimator(desOffsetY: number) {
    if (this.animator) {
      this.animator.finish();
    }

    this.animator = this.getUIContext().createAnimator({
      duration: 400,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: this.curCanvasOffsetY,
      end: -desOffsetY
    });
    let that = this;
    Logger.info('[startAnimator] curOffset:' + this.curCanvasOffsetY + ',desOffset:' + (-desOffsetY));
    this.animator.onFrame = (value) => {
      that.drawContent(value);
    };
    this.animator.onCancel = () => {
    };
    this.animator.onFinish = () => {
    };
    this.animator.play();
  }

  /** Starts or pauses the lyric animator when isPlay toggles. */
  playLyrics() {
    if (this.isPlay) {
      this.animator.play();
    } else {
      this.animator.pause();
    }
  }

  /** Debug helper: draws a horizontal mid-line on the canvas. */
  drawMiddle() {
    this.context.translate(0, -this.curCanvasOffsetY);
    this.context.beginPath();
    this.context.strokeStyle = Color.Red;
    this.context.moveTo(0, this.viewHeight / 2);
    this.context.lineTo(this.viewWidth, this.viewHeight / 2);
    this.context.stroke();
    this.context.closePath();
    this.context.translate(0, this.curCanvasOffsetY);
  }

  /** Fills a star-shaped path around (x,y) with inner/outer radii and rotation. */
  private drawStars(x: number, y: number, outRadius: number, inRadius: number, rotateAngle: number) {
    this.starsPath2D = new Path2D();
    this.context.fillStyle = this.starsColor;
    for (let cornerIndex = 0; cornerIndex < STAR_ANGLE_NUMBER; cornerIndex++) {
      let outX = (
        Math.cos(angleToRadian(rotateAngle + this.starOutCircleAngle + cornerIndex * this.starAverageAngle)) *
          outRadius) + x;
      let outY = -(
        Math.sin(angleToRadian(rotateAngle + this.starOutCircleAngle + cornerIndex * this.starAverageAngle)) *
          outRadius) + y;
      let inX = (
        Math.cos(angleToRadian(rotateAngle + this.starInCircleAngle + cornerIndex * this.starAverageAngle)) *
          inRadius) + x;
      let inY = -(
        Math.sin(angleToRadian(rotateAngle + this.starInCircleAngle + cornerIndex * this.starAverageAngle)) *
          inRadius) + y;
      if (cornerIndex === 0) {
        this.starsPath2D.moveTo(outX, outY);
      }
      this.starsPath2D.lineTo(outX, outY);
      this.starsPath2D.lineTo(inX, inY);
    }
    this.starsPath2D.closePath();
    this.context.fill(this.starsPath2D);
  }

  /** Recomputes lyric layout box, first-line Y anchor, center X, and star geometry constants. */
  private calculate() {
    this.lrcWidth = this.viewWidth - this.paddingLeft - this.paddingRight;
    this.lrcHeight = this.viewHeight - this.paddingTop - this.paddingBottom;
    if (this.initFirstLineY === 0) {
      switch (this.lyricTopPosition) {
        case LyricTopPosition.Middle:

          this.initFirstLineY = this.paddingTop + this.lrcHeight / 4;
          break;
        case LyricTopPosition.Top:
          this.initFirstLineY = this.paddingTop;
          break;
        default:
          break;
      }
    }

    this.lrcX = this.paddingLeft + this.lrcWidth / 2;
    this.lrcY = this.initFirstLineY;

    this.starAverageAngle = 360 / STAR_ANGLE_NUMBER;
    this.starOutCircleAngle = 90 - this.starAverageAngle;
    let halfAverageAngle = this.starAverageAngle / 2;
    this.starInCircleAngle = halfAverageAngle + this.starOutCircleAngle;
  }

  /** Resets vertical lyric cursor to the first-line baseline. */
  private reset() {
    this.lrcY = this.initFirstLineY;
  }

  /** Word-wraps a single lyric line into segments that fit lrcWidth using measureText. */
  private getWrappedLineSegments(text: string): string[] {
    const segments: string[] = [];
    let start = 0;
    while (start < text.length) {
      let end = text.length;
      while (end > start && this.context.measureText(text.substring(start, end)).width > this.lrcWidth) {
        if (end > start + 1) {
          const sub = text.substring(start, end);
          const spaceIdx = sub.lastIndexOf(' ');
          if (spaceIdx > 0) {
            end = start + spaceIdx;
          } else {
            end--;
          }
        } else {
          break;
        }
      }
      if (end <= start) {
        end = start + 1;
      }
      segments.push(text.substring(start, end));
      start = end;
      while (start < text.length && text.charAt(start) === ' ') {
        start++;
      }
    }
    return segments;
  }

  /** Measures wrapped or single-line height in px for the given text style. */
  private getLineHeight(text: string, isCurrent?: boolean): number {
    if (isCurrent) {
      this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
    } else {
      this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
    }
    let textMetrics: TextMetrics = this.context.measureText(text);
    if (textMetrics.width > this.lrcWidth) {
      const segments = this.getWrappedLineSegments(text);
      return segments.length * textMetrics.height;
    }
    return textMetrics.height;
  }

  /** Builds a two-stop linear gradient between current and normal lyric colors at progress. */
  private progressGrad(startX: number, startY: number, endX: number, endY: number, progress: number) {
    let grad = this.context.createLinearGradient(startX, startY, endX, endY);
    grad.addColorStop(progress, this.mCurrentTextColor);
    grad.addColorStop(progress + GRADIENT_PROGRESS_SPACE, this.mNormalTextColor);
    return grad;
  }

  /** Draws a wrapped multi-segment lyric line; returns consumed vertical height. */
  private drawMultipleLine(lyric: LrcEntry, textMetrics: TextMetrics, isCurrent: boolean): number {
    const segments = this.getWrappedLineSegments(lyric.lineWords);
    let lineHeight = 0;
    this.context.textAlign = 'center';
    for (let i = 0; i < segments.length; i++) {
      if (i === 0) {
        this.lrcY = this.lrcY + textMetrics.height + this.mDividerHeight;
      } else {
        this.lrcY = this.lrcY + textMetrics.height;
      }
      lineHeight += textMetrics.height;
      this.context.fillText(segments[i], this.lrcX, this.lrcY, this.lrcWidth);
    }
    return lineHeight;
  }

  /** Draws a single-line lyric row; returns consumed vertical height. */
  private drawSingleLine(lyric: LrcEntry, textMetrics: TextMetrics, isCurrent: boolean): number {
    this.lrcY = this.lrcY + this.mDividerHeight + textMetrics.height;
    let text = lyric.lineWords;
    if (isCurrent) {
      switch (this.lyricScrollEffect) {
        case LyricScrollEffect.LetterScaleGradient:
          if (lyric.words && lyric.words.length > 0) {
            let startX = this.lrcX - textMetrics.width / 2;
            let endX = startX + textMetrics.width;
            let gradY = this.lrcY - textMetrics.height / 2;

            let wordX = startX;
            this.context.textAlign = 'start';
            for (let wordIndex = 0; wordIndex < lyric.words.length; wordIndex++) {
              let wordStartTime = lyric.lineStartTime + lyric.words[wordIndex].wordStartTime;
              let wordEndTime =
                lyric.lineStartTime + lyric.words[wordIndex].wordStartTime + lyric.words[wordIndex].duration;
              if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                let wordProgress =
                  (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[wordIndex].duration / lyric.words.length;
                let wordPassedProgress = wordIndex / lyric.words.length;
                let progress = wordPassedProgress + wordProgress;
                this.context.fillStyle = this.progressGrad(startX, gradY, endX, gradY, progress);
                this.context.font =
                  this.fontWeight + ' ' + (this.mCurrentTextSize + this.textAddSize) + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[wordIndex].text, wordX, this.lrcY + this.textAddSize / 2,
                  this.lrcWidth);
              } else {
                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[wordIndex].text, wordX, this.lrcY, this.lrcWidth);
              }
              wordX += this.context.measureText(lyric.words[wordIndex].text).width;
            }
          } else {
            this.context.textAlign = 'center';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        case LyricScrollEffect.Line:
          this.context.textAlign = 'center';
          this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          break;
        case LyricScrollEffect.LetterGradient:
          if (lyric.words && lyric.words.length > 0) {
            this.context.textAlign = 'center';
            let startXg = this.lrcX - textMetrics.width / 2;
            let endXg = startXg + textMetrics.width;
            let gradYg = this.lrcY - textMetrics.height / 2;

            let progress = 0;
            let findPlayingWord = false;
            if (lyric.words && lyric.words.length > 0) {
              for (let wordIndex = 0; wordIndex < lyric.words.length; wordIndex++) {
                let wordStartTime = lyric.lineStartTime + lyric.words[wordIndex].wordStartTime;
                let wordEndTime =
                  lyric.lineStartTime + lyric.words[wordIndex].wordStartTime + lyric.words[wordIndex].duration;
                if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                  let wordProgress =
                    (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[wordIndex].duration /
                      lyric.words.length;
                  let wordPassedProgress = wordIndex / lyric.words.length;
                  progress = wordPassedProgress + wordProgress;
                  findPlayingWord = true;
                  break;
                }
              }
            }
            if (!findPlayingWord) {
              if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                progress = 0;
              } else if (this.lyricMilliSecondsTime >= lyric.lineStartTime + lyric.lineDuration) {
                progress = GRADIENT_PROGRESS_MAX;
              } else {
                Logger.error('This should not be happening.');
              }
            }

            this.context.fillStyle = this.progressGrad(startXg, gradYg, endXg, gradYg, progress);
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          } else {
            this.context.textAlign = 'center';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        case LyricScrollEffect.LetterStar:
          if (lyric.words && lyric.words.length > 0) {
            let textStartX = this.lrcX - textMetrics.width / 2;
            let textEndX = textStartX + textMetrics.width;
            let gradYStar = this.lrcY - textMetrics.height / 2;

            let wordXX = textStartX;
            let starX = textStartX;
            let starRotate = 0;
            this.context.textAlign = 'start';
            let findPlayingWordStar = false;
            if (lyric.words && lyric.words.length > 0) {
              for (let wordIndex = 0; wordIndex < lyric.words.length; wordIndex++) {
                let wordStartTime = lyric.lineStartTime + lyric.words[wordIndex].wordStartTime;
                let wordEndTime =
                  lyric.lineStartTime + lyric.words[wordIndex].wordStartTime + lyric.words[wordIndex].duration;
                if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                  let wordProgress =
                    (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[wordIndex].duration /
                      lyric.words.length;
                  let wordPassedProgress = wordIndex / lyric.words.length;
                  let progress = wordPassedProgress + wordProgress;
                  this.context.fillStyle = this.progressGrad(textStartX, gradYStar, textEndX, gradYStar, progress);
                  this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                  this.context.fillText(lyric.words[wordIndex].text, wordXX, this.lrcY, this.lrcWidth);
                  findPlayingWordStar = true;
                  starX = wordXX + this.context.measureText(lyric.words[wordIndex].text).width / 2;
                } else {
                  this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                  this.context.fillText(lyric.words[wordIndex].text, wordXX, this.lrcY, this.lrcWidth);
                }
                wordXX += this.context.measureText(lyric.words[wordIndex].text).width;
              }
            }

            if (!findPlayingWordStar) {
              if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                starX = textStartX;
              } else if (this.lyricMilliSecondsTime > lyric.lineStartTime + lyric.lineDuration) {
                starX = this.lrcX + textMetrics.width / 2 -
                  this.context.measureText(lyric.words[lyric.words.length-1].text).width / 2;
              } else {
                Logger.error('This should not be happening.');
              }
              let starY = this.lrcY - textMetrics.height;
              this.drawStars(starX, starY, this.mDividerHeight / 2, this.mDividerHeight / 4, 0);
            } else {
              let starY = this.lrcY - textMetrics.height;
              this.drawStars(starX, starY, this.mDividerHeight / 2, this.mDividerHeight / 4, starRotate);
            }
          } else {
            this.context.textAlign = 'center';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        default:
          this.context.textAlign = 'center';
          this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          break;
      }
    } else {
      this.context.textAlign = 'center';
      this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
    }
    return textMetrics.height;
  }

  /** Renders one LrcEntry (wrap-aware) and advances lrcY by returned line height. */
  private drawLyricLine(lyric: LrcEntry, isCurrent: boolean): number {
    let lineHeight = 0;
    if (isCurrent) {
      this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
      this.context.fillStyle = this.mCurrentTextColor;
    } else {
      this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
      this.context.fillStyle = this.mNormalTextColor;
    }
    this.context.textBaseline = 'bottom';
    let textMetrics: TextMetrics = this.context.measureText(lyric.lineWords);
    if (textMetrics.width > this.lrcWidth) {
      lineHeight = this.drawMultipleLine(lyric, textMetrics, isCurrent);
    } else {
      lineHeight = this.drawSingleLine(lyric, textMetrics, isCurrent);
    }
    return lineHeight;
  }


  /** Clears and redraws all lyric lines at vertical offset desOffsetY; applies edge fade mask. */
  private drawContent(desOffsetY: number, change?: boolean) {
    this.context.clearRect(0, 0, this.viewWidth, this.lrcY + this.viewHeight);
    this.reset();

    this.context.globalCompositeOperation = 'source-over';
    this.lrcY = this.initFirstLineY + desOffsetY;
    this.curCanvasOffsetY = desOffsetY;

    if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
      let index = 0;
      for (let mLrcEntryListElement of this.mLrcEntryList) {
        let isCurrentLine = this.mCurrentLine === index ? true : false;
        this.drawLyricLine(mLrcEntryListElement, isCurrentLine);
        index++;
      }
    } else {
      this.drawLyricLine({
        lineStartTime: 0,
        lineDuration: 0,
        lineWords: this.emptyLyricPlaceholder,
        words: []
      }, true);
    }

    this.updateLyricArea(this.paddingLeft, this.paddingTop, this.viewWidth - this.paddingRight,
      this.viewHeight - this.paddingBottom);

    if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
      this.context.globalCompositeOperation = 'source-in';
      let grad = this.context.createLinearGradient(0, 0, 0, this.viewHeight);
      grad.addColorStop(0.0, this.lrcMaskTransparent);
      grad.addColorStop(0.15, this.lrcMaskWhite);
      grad.addColorStop(0.3, this.lrcMaskWhite);
      grad.addColorStop(0.7, this.lrcMaskSemi);
      grad.addColorStop(1.0, this.lrcMaskTransparent);
      this.context.fillStyle = grad;
      this.context.fillRect(0, 0, this.viewWidth, this.viewHeight);
    }
  }

  /** Updates hit-test rectangle for the lyric canvas area. */
  private updateLyricArea(left: number, top: number, right: number, bottom: number) {
    this.lyricRectangle = new Rectangle(left, top, right, bottom);
  }


  /** Whether any lyric lines are loaded (non-instrumental track). */
  hasLrc(): boolean {
    return this.mLrcEntryList && this.mLrcEntryList.length > 0;
  }

  /** Cumulative vertical offset in px to align the given line index under lyricTopPosition. */
  getOffset(line: number): number {
    let offsetY = 0;
    switch (this.lyricTopPosition) {
      case LyricTopPosition.Top:
        for (let entryIndex = 0; entryIndex <= line && entryIndex < this.mLrcEntryList.length; entryIndex++) {
          if (entryIndex === line) {
            offsetY += this.getLineHeight(this.mLrcEntryList[entryIndex].lineWords, true) / 2 -
              this.getLineHeight(this.mLrcEntryList[entryIndex].lineWords, false) / 2;
          } else {
            offsetY += this.getLineHeight(this.mLrcEntryList[entryIndex].lineWords, false) + this.mDividerHeight;
          }
        }
        break;
      case LyricTopPosition.Middle:
        for (let entryIndex = 0; entryIndex <= line && entryIndex < this.mLrcEntryList.length; entryIndex++) {
          if (entryIndex === line) {
            offsetY += this.getLineHeight(this.mLrcEntryList[entryIndex].lineWords, true) / 2 + this.mDividerHeight;
          } else {
            offsetY += this.getLineHeight(this.mLrcEntryList[entryIndex].lineWords, false) + this.mDividerHeight;
          }
        }
        break;
      default:
        break;
    }
    return offsetY;
  }

  /** Scrolls canvas so the given line is centered/top-aligned via startAnimator. */
  smoothScrollTo(line: number) {
    let offset = this.getOffset(line);
    Logger.info('[smoothScrollTo] line:' + line + ',offset:' + offset);
    this.startAnimator(offset);
  }

  /** Watch handler: lyric list changed; resets active line and redraws. */
  onLyricUpdated() {
    this.mCurrentLine = NONE_LINE;
    this.onTimeUpdated();
  }

  /** Watch handler: playback time changed; updates active line and scroll or refresh draw. */
  onTimeUpdated() {
    if (!this.hasLrc()) {
      this.drawContent(0);
      return;
    }
    let line = this.findShowLine(this.lyricMilliSecondsTime);
    if (line !== this.mCurrentLine) {
      this.mCurrentLine = line;
      this.smoothScrollTo(line);
    } else {
      this.drawContent(this.curCanvasOffsetY);
    }
  }

  /** Finds the lyric line index active at milliSeconds based on line time ranges. */
  findShowLine(milliSeconds: number): number {
    if (!this.mLrcEntryList || this.mLrcEntryList.length === 0) {
      return NONE_LINE;
    }
    const list = this.mLrcEntryList;
    for (let index = 0; index < list.length; index++) {
      const e = list[index];
      if (milliSeconds >= e.lineStartTime && milliSeconds <= e.lineStartTime + e.lineDuration) {
        return index;
      }
    }

    for (let index = list.length - 1; index >= 0; index--) {
      if (milliSeconds >= list[index].lineStartTime) {
        return index;
      }
    }
    return 0;
  }

  /**
   * Canvas expects a CSS color string; convert packed ARGB (0xAARRGGBB) to lowercase #aarrggbb.
   */
  private colorUintToCanvasHex(c: number): string {
    const h = (n: number): string => (n & 0xFF).toString(16).padStart(2, '0');
    const a = (c >>> 24) & 0xFF;
    const r = (c >>> 16) & 0xFF;
    const g = (c >>> 8) & 0xFF;
    const b = c & 0xFF;
    return `#${h(a)}${h(r)}${h(g)}${h(b)}`;
  }

  /** Reads a color resource; uses packed ARGB fallback on failure (matches base/color.json). */
  private colorFromTheme(res: Resource, fallbackArgb: number): string {
    try {
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return this.colorUintToCanvasHex(host.resourceManager.getColorSync(res.id));
    } catch {
      return this.colorUintToCanvasHex(fallbackArgb);
    }
  }

  /** Loads theme colors from resources, runs initial layout, and paints first frame. */
  aboutToAppear(): void {
    const host: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const resMgr = host.resourceManager;
    try {
      this.emptyLyricPlaceholder = resMgr.getStringSync($r('app.string.lrc_empty_placeholder').id);
    } catch {
      this.emptyLyricPlaceholder = '';
    }
    this.mNormalTextColor = this.colorFromTheme($r('app.color.play_text_color'), 0x99FFFFFF);
    this.mCurrentTextColor = this.colorFromTheme($r('app.color.player_text_primary'), 0xFFFFFFFF);
    this.starsColor = this.colorFromTheme($r('app.color.lrc_stars'), 0xFF18BBFC);
    this.lrcMaskTransparent = this.colorFromTheme($r('app.color.lrc_mask_transparent'), 0x00FFFFFF);
    this.lrcMaskWhite = this.colorFromTheme($r('app.color.lrc_mask_white'), 0xFFFFFFFF);
    this.lrcMaskSemi = this.colorFromTheme($r('app.color.lrc_mask_semi'), 0x4DFFFFFF);
    this.calculate();
    this.onTimeUpdated();
  }

  /** Canvas host wired to size changes for layout and touch forwarding. */
  build() {
    Canvas(this.context)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.viewWidth = Number.parseFloat(newArea.width.toString());
        this.viewHeight = Number.parseFloat(newArea.height.toString());
        if (oldArea.width.toString() !== newArea.width.toString()) {
          this.calculate();
          let line = this.findShowLine(this.lyricMilliSecondsTime);
          let offset = this.getOffset(line);
          this.drawContent(offset);
        }
        if (oldArea.height.toString() !== newArea.height.toString()) {
          this.calculate();
          let line = this.findShowLine(this.lyricMilliSecondsTime);
          let offset = this.getOffset(line);
          this.drawContent(-offset, true);
        }
      })
  }
}
