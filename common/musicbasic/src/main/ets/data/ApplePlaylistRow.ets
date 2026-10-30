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
 * Apple Music 资料库歌单行，对应 RDB 的 {@code apple_playlists} 表。
 * 只存元数据；曲目在打开歌单时按需拉取（见 ApplePlaylistStore）。
 */
export class ApplePlaylistRow {
  /** Apple Music 歌单 ID（资料库歌单形如 p.xxxx）。 */
  public id: string = '';
  /** 歌单名称。 */
  public name: string = '';
  /** 歌单描述（可为空）。 */
  public description: string = '';
  /** 封面 URL（Apple artwork，已替换为 600x600）。 */
  public coverUrl: string = '';
  /** 曲目数（Apple 给的统计值）。 */
  public trackCount: number = 0;
  /** 是否用户自建（Apple 的 library 歌单都是）。 */
  public isLibrary: boolean = true;
}
