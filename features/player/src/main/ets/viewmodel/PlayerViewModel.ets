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

import { AppStorageV2 } from '@kit.ArkUI';
import { AppStorageKeys, RouterUrlConstants } from 'musicbasic';
import { MusicAppState, PlayerTrackUi } from '../model/PlayerModels';
import { PlayerDataUtil } from '../util/PlayerDataUtil';

/** Observable façade for inline / mini player UI: track text, cover, and transport actions. */
@ObservedV2
export class PlayerViewModel {
  /** Global playback and queue state shared with the rest of the app. */
  @Trace public appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;

  /** Current queue item projected to PlayerTrackUi, or undefined when queue empty. */
  public currentTrack(): PlayerTrackUi | undefined {
    return PlayerDataUtil.getCurrentTrackUi(this.appState);
  }

  /** Title string for the current track, or empty when none. */
  public songTitle(): string | Resource {
    const track = this.currentTrack();
    return track !== undefined ? track.title : '';
  }

  /** Artist line for the current track, or empty when none. */
  public songSinger(): string | Resource {
    const track = this.currentTrack();
    return track !== undefined ? track.singer : '';
  }

  /** Cover Resource for the current track, or a placeholder resource. */
  public songCover(): Resource {
    const track = this.currentTrack();
    return track !== undefined ? track.cover : $r('app.string.page_show');
  }

  /** Sandbox cover path of the current track, or empty when none. */
  public songCoverPath(): string {
    const track = this.currentTrack();
    return track !== undefined ? track.coverPath : '';
  }

  /** Skips to previous track according to MediaService play mode. */
  public playPrevious(): void {
    PlayerDataUtil.playPrevious();
  }

  /** Advances to next track from explicit user control. */
  public playNext(): void {
    PlayerDataUtil.playNext();
  }

  /** Seeks current playback to ms (delegates to MediaService). */
  public seek(ms: number): void {
    PlayerDataUtil.seek(ms);
  }

  /** Toggles play/pause using current appState and MediaService first-load rules. */
  public togglePlayPause(): void {
    PlayerDataUtil.togglePlayPause(this.appState);
  }

  /** Navigates the given stack to the playlist detail route by name. */
  public pushPlaylistDetail(pageIndexInfos: NavPathStack): void {
    pageIndexInfos.replacePathByName(RouterUrlConstants.PLAYLIST_DETAIL, null);
  }
}
