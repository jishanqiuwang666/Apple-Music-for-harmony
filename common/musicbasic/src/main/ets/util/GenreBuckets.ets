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
 * 音乐板块（曲风）归类。
 *
 * 数据来源：Apple 资料库接口的 `attributes.genreNames`（每首歌/每张专辑都带，
 * 现有同步请求里就有，**不需要额外网络请求**）。Apple 返回的是商店曲风树的
 * 顶层名（用户库里实测出现的有：J-Pop / Mandopop / R&B/Soul / Pop / Rock /
 * Alternative / Classical / Jazz / Dance / Soundtrack / Holiday / Chinese /
 * Singer/Songwriter / Hip-Hop/Rap / Anime / New Age / Cantopop/HK-Pop /
 * Electronic / Electronica / Motown）。
 *
 * 归类规则：按关键词匹配（全小写子串），先命中先算，未命中归「其他」。
 * 顺序有讲究：例如 Pop Rock 归摇滚、Dance Pop 归电子/舞曲，所以摇滚/电子
 * 排在流行前面。
 */
export class GenreBuckets {
  public static readonly POP: string = '流行';
  public static readonly CLASSICAL: string = '古典';
  public static readonly JAZZ: string = '爵士';
  public static readonly ROCK: string = '摇滚';
  public static readonly RNB: string = 'R&B/灵魂';
  public static readonly ELECTRONIC: string = '电子/舞曲';
  public static readonly HIPHOP: string = '嘻哈/说唱';
  public static readonly FOLK: string = '民谣/唱作';
  public static readonly SOUNDTRACK: string = '原声/配乐';
  public static readonly WORLD: string = '世界音乐';
  public static readonly OTHER: string = '其他';

  /** 板块在艺人页的展示顺序（只显示非空的板块）。 */
  public static readonly ORDER: string[] = [
    GenreBuckets.POP,
    GenreBuckets.CLASSICAL,
    GenreBuckets.JAZZ,
    GenreBuckets.ROCK,
    GenreBuckets.RNB,
    GenreBuckets.ELECTRONIC,
    GenreBuckets.HIPHOP,
    GenreBuckets.FOLK,
    GenreBuckets.SOUNDTRACK,
    GenreBuckets.WORLD,
    GenreBuckets.OTHER
  ];

  /**
   * 把 Apple 的曲风名（可能是 `J-Pop` 这样的单个，也可能用 `|` 连接多个）
   * 归到一个板块名。
   *
   * @param raw Apple 的曲风名（`attributes.genreNames` 连接串，空串表示未知）
   * @returns 板块名，未知时返回 {@link GenreBuckets.OTHER}
   */
  public static of(raw: string): string {
    if (raw === undefined || raw === null || raw.length === 0) {
      return GenreBuckets.OTHER;
    }
    const parts: string[] = raw.toLowerCase().split('|');
    for (let i = 0; i < parts.length; i++) {
      const bucket: string = GenreBuckets.matchOne(parts[i].trim());
      if (bucket !== '') {
        return bucket;
      }
    }
    return GenreBuckets.OTHER;
  }

  /** 单个曲风名 → 板块名（'' = 没命中）。 */
  private static matchOne(g: string): string {
    if (g.length === 0) {
      return '';
    }
    if (GenreBuckets.has(g, ['classical', 'opera', 'orchestral', 'chamber', 'symphony'])) {
      return GenreBuckets.CLASSICAL;
    }
    if (GenreBuckets.has(g, ['jazz', 'bebop', 'swing', 'bossa'])) {
      return GenreBuckets.JAZZ;
    }
    if (GenreBuckets.has(g, ['hip-hop', 'hip hop', 'rap'])) {
      return GenreBuckets.HIPHOP;
    }
    if (GenreBuckets.has(g, ['r&b', 'rnb', 'soul', 'motown', 'funk'])) {
      return GenreBuckets.RNB;
    }
    if (GenreBuckets.has(g, ['rock', 'metal', 'punk', 'grunge', 'shoegaze', 'alternative', 'indie'])) {
      return GenreBuckets.ROCK;
    }
    if (GenreBuckets.has(g, ['electronic', 'electronica', 'dance', 'house', 'techno', 'trance',
      'edm', 'ambient', 'new age', 'drum and bass', 'dubstep', 'lo-fi', 'chillout'])) {
      return GenreBuckets.ELECTRONIC;
    }
    if (GenreBuckets.has(g, ['folk', 'singer/songwriter', 'songwriter', 'acoustic', 'country', 'americana'])) {
      return GenreBuckets.FOLK;
    }
    if (GenreBuckets.has(g, ['soundtrack', 'score', 'musical', 'stage', 'film'])) {
      return GenreBuckets.SOUNDTRACK;
    }
    if (GenreBuckets.has(g, ['world', 'latin', 'reggae', 'afro', 'chinese', 'enka', 'kayokyoku',
      'celtic', 'gospel'])) {
      return GenreBuckets.WORLD;
    }
    if (GenreBuckets.has(g, ['pop', 'anime', 'idol', 'vocal', 'easy listening', 'holiday', 'christmas'])) {
      return GenreBuckets.POP;
    }
    return '';
  }

  /** @returns 曲风名里是否含任一关键词。 */
  private static has(genre: string, keywords: string[]): boolean {
    for (let i = 0; i < keywords.length; i++) {
      if (genre.indexOf(keywords[i]) >= 0) {
        return true;
      }
    }
    return false;
  }
}
