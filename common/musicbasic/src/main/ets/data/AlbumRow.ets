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
 * Album aggregate row: album name + artist disambiguates the key.
 * Plain data holder (no observation) for DB and list UIs.
 */
export class AlbumRow {
  /** Album primary key in the library DB. */
  public id: number = 0;
  /** Album display name. */
  public name: string = '';
  /** Artist that owns this album. */
  public artist: string = '';
  /** Number of songs in this album. */
  public songCount: number = 0;
  /** Sum of all track durations in milliseconds (pre-aggregated). */
  public totalDuration: number = 0;
  /** Release year (latest song year in the album, 0 if unknown). */
  public year: number = 0;
  /** Cover art cache path (empty if none). */
  public coverPath: string = '';
}
