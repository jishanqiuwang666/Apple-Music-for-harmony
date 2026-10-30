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
 * DB-level song row: pure primitive fields, no UI resource references.
 * Mirrors the `songs` table of the library RDB.
 */
export class MusicSongRow {
  /** Primary key (AUTOINCREMENT in RDB). */
  public id: number = 0;
  /** Track title from metadata (fallback: cleaned file name). */
  public title: string = '';
  /** Artist name from metadata (fallback: 未知艺人). */
  public artist: string = '';
  /** Album name from metadata (fallback: 未知专辑). */
  public album: string = '';
  /** Duration in milliseconds (0 if unknown). */
  public duration: number = 0;
  /** Release year from audio metadata (0 if unknown). */
  public year: number = 0;
  /** Authorized file URI for playback. */
  public uri: string = '';
  /** Cached album-cover JPEG path in sandbox (empty if none). */
  public coverPath: string = '';
  /** Track number within the album (0 if unknown). */
  public trackNumber: number = 0;
  /** Parent folder URI this song was scanned from. */
  public folder: string = '';

  // ───────── Apple Music 音源相关字段 ─────────
  /** Apple Music 歌曲 ID（本地扫描的歌曲为空） */
  public appleId: string = '';
  /** 解密后的本地缓存文件路径（未下载为空） */
  public cachedPath: string = '';
  /** 封面网络地址（Apple 的 artwork URL，已替换为 600x600） */
  public coverUrl: string = '';
  /** 是否「保留」：被打标的不参与缓存自动清理 */
  public pinned: boolean = false;
  /** 是否来自资料库（library） */
  public isLibrary: boolean = false;
  /** Apple 曲风（`|` 连接，如 `J-Pop`）；空串 = 未知 */
  public genre: string = '';
}
