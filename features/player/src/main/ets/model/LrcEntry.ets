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

/** One timed syllable or character inside a KRC line. */
export interface Word {
  /** Visible glyph(s) for this word span. */
  text: string;

  /** Offset from the parent line start time, in milliseconds. */
  wordStartTime: number;

  /** Duration of this word span, in milliseconds. */
  duration: number;
}

/** One lyric line with optional per-character timing (LRC has empty words[]). */
export interface LrcEntry {
  /** Line start time in milliseconds from track start. */
  lineStartTime: number;

  /** Line duration in milliseconds (often derived from next line start). */
  lineDuration: number;

  /** Full line text without timing tags. */
  lineWords: string;

  /** Per-character timing entries (KRC); empty for plain LRC. */
  words: Word[];
}