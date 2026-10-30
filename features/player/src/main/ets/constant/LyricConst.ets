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

/**
 * Lyrics scrolling effect.
 */
export const enum LyricScrollEffect {
  /**
   * Full line scrolling
   */
  Line,

  /**
   * Gradient Color
   */
  LetterGradient,

  /**
   * Single character scaling and gradation.
   */
  LetterScaleGradient,

  /**
   * Star scrolling style.
   */
  LetterStar
}

/**
 * Lyrics initial position
 */
export const enum LyricTopPosition {
  Top,
  Middle,
}

/** Common lyric file suffixes. */
export class LyricFile {
  /** Kugou-style KRC lyric extension. */
  public static readonly krc: string = '.krc';
  /** Standard LRC lyric extension. */
  public static readonly lrc: string = '.lrc';
}