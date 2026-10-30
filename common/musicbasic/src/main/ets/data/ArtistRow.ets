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
 * Artist aggregate row: one row per artist name, with album/song counts.
 * Plain data holder (no observation) for DB and list UIs.
 */
export class ArtistRow {
  /** Artist primary key in the library DB. */
  public id: number = 0;
  /** Artist display name. */
  public name: string = '';
  /** Number of albums owned by this artist. */
  public albumCount: number = 0;
  /** Number of songs owned by this artist. */
  public songCount: number = 0;
  /** Cover art cache path of the first album (empty if none). */
  public coverPath: string = '';
  /** 音乐板块（古典 / 爵士 / 流行…），见 GenreBuckets；空串 = 未归类。 */
  public genre: string = '';
}
