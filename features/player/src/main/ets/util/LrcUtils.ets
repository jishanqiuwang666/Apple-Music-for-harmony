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

import { Logger } from 'musicbasic';
import { LrcEntry, Word } from '../model/LrcEntry';

/** Matches LRC timestamp tags like [00:21.98] on each line. */
const lrcLineRegex: RegExp = new RegExp('\\[\\d{2,}:\\d{2}((\\.|:)\\d{2,})\\]', 'g');
/** Extracts minutes portion from an LRC timestamp bracket. */
const lrcTimeRegex1: RegExp = new RegExp('\\[\\d{2,}', 'i');
/** Extracts seconds.fraction portion from an LRC timestamp bracket. */
const lrcTimeRegex2: RegExp = new RegExp('\\d{2}\\.\\d{2,}', 'i');

/** Matches one KRC line header [startMs,durationMs]... */
const krcLineRegex = new RegExp('\\[(\\d+),(\\d+)\\](.*)');
/** Iterates KRC word spans <start,duration,flags>text. */
const krcWordRegex1 = new RegExp('<(\\d+),(\\d+),(\\d+)>([^<]*)', 'g');
/** Parses a single KRC word span capture groups. */
const krcWordRegex2 = new RegExp('<(\\d+),(\\d+),(\\d+)>(.*)');

/**
 * Parses standard LRC text into timed LrcEntry lines (no per-character words).
 *
 * @param text Full .lrc file contents.
 * @returns Sorted lines with inferred lineDuration from the following line.
 */
export function parseLrcLyric(text: string): Array<LrcEntry> {
  if (!text || text.length > 100 * 1024 * 1024) {
    return [];
  }
  const normalizedText: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  let lyric: string[] = normalizedText.split('\n');
  let lrc: LrcEntry[] = [];
  for (let lineIndex = 0; lineIndex < lyric.length; lineIndex++) {
    let lineTime = lyric[lineIndex].match(lrcLineRegex);
    let lineText = lyric[lineIndex].replace(lrcLineRegex, '');
    if (lineTime && lineText) {
      for (let timeIndex = 0; timeIndex < lineTime.length; timeIndex++) {
        const tag: string = lineTime[timeIndex];
        const minMatch: RegExpMatchArray | null = tag.match(lrcTimeRegex1);
        const secMatch: RegExpMatchArray | null = tag.match(lrcTimeRegex2);
        if (!minMatch || minMatch.length === 0 || !secMatch || secMatch.length === 0) {
          continue;
        }
        const min: number = Number(minMatch[0].slice(1));
        const sec: number = Number.parseFloat(secMatch[0]);
        if (!Number.isFinite(min) || !Number.isFinite(sec)) {
          continue;
        }
        let timeInSeconds = (min * 60 + sec) * 1000;
        lrc.push({
          lineStartTime: timeInSeconds,
          lineDuration: 0,
          lineWords: lineText,
          words: []
        });
      }
    }
  }
  if (lrc && lrc.length > 0) {
    lrc.sort((left, right) => {
      return left.lineStartTime - right.lineStartTime;
    });
    for (let entryIndex = 0; entryIndex < lrc.length; entryIndex++) {
      if (entryIndex === lrc.length - 1) {
        lrc[entryIndex].lineDuration = Number.MAX_VALUE;
      } else {
        lrc[entryIndex].lineDuration = lrc[entryIndex + 1].lineStartTime - lrc[entryIndex].lineStartTime;
      }
    }
  } else {
    Logger.error('Failed to parse the lyrics.');
  }
  return lrc;
}

/**
 * Parses Kugou-style KRC lyric text into LrcEntry lines with per-word timing.
 *
 * @param lyricText Full .krc file contents.
 * @returns Lines sorted by lineStartTime.
 */
export function parseKrcLyric(lyricText: string): LrcEntry[] {
  const lines: string[] = lyricText.split('\n');
  const lyricLines: LrcEntry[] = [];

  for (const line of lines) {
    const matches = line.match(krcLineRegex);
    if (matches) {
      const lineStartTime = Number.parseInt(matches[1]);
      const lineDuration = Number.parseInt(matches[2]);
      const lineWordsText = matches[3];
      const words: Word[] = [];
      const wordsMatches = lineWordsText.match(krcWordRegex1);
      let lineWords: string = '';
      if (wordsMatches) {
        for (const wordMatch of wordsMatches) {
          const wordMatches = wordMatch.match(krcWordRegex2);
          if (wordMatches) {
            const wordStartTime = Number.parseInt(wordMatches[1]);
            const wordDuration = Number.parseInt(wordMatches[2]);
            const wordText = wordMatches[4];
            lineWords += wordText;
            words.push({
              text: wordText,
              wordStartTime: wordStartTime,
              duration: wordDuration
            });
          }
        }
      }
      lyricLines.push({
        lineStartTime: lineStartTime,
        lineDuration: lineDuration,
        lineWords: lineWords,
        words: words
      });
    }
  }
  lyricLines.sort((left, right) => {
    return left.lineStartTime - right.lineStartTime;
  });
  return lyricLines;
}

/**
 * Converts degrees to radians for Math trigonometry (deg * π / 180).
 *
 * @param angle Angle in degrees.
 * @returns Same angle in radians.
 */
export function angleToRadian(angle: number): number {
  return angle * Math.PI / 180;
}

/** Axis-aligned rectangle in lyric hit-testing helpers. */
export class Rectangle {
  /** Left edge x. */
  public left: number;
  /** Top edge y. */
  public top: number;
  /** Right edge x. */
  public right: number;
  /** Bottom edge y. */
  public bottom: number;

  /** Builds a rectangle from edge coordinates (inclusive bounds for isIn). */
  public constructor(left: number, top: number, right: number, bottom: number) {
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
  }

  /** True if (x,y) lies inside the closed rectangle. */
  public isIn(x: number, y: number): boolean {
    return x >= this.left && x <= this.right && y >= this.top && y <= this.bottom;
  }

  /** Debug string listing all four edges. */
  public toString(): string {
    return `[Rectangle] = ${this.left}, ${this.top}, ${this.right},${this.bottom}`;
  }
}