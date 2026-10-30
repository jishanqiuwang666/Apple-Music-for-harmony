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
 * Cross-feature playback request (AppStorageV2: PlaybackIntentState).
 * View models only bump this; the shell listens and writes {@link MusicAppState} and media.
 */
@ObservedV2
export class PlaybackIntentState {
  /** Incremented on each intent so the shell reacts even when the song id is unchanged. */
  @Trace public requestVersion: number = 0;
  /** Song id to play, matching {@link MusicAppState.playQueueIds}; -1 when unset. */
  @Trace public pendingPlaySongId: number = -1;
  /**
   * 待播歌曲的播放源（形如 apple:<曲目id>）。
   * 用于**不在 songs 表里**的曲目（例如收藏专辑里临时从 Apple 拉取的曲目）：
   * id 查不到时，播放服务改为按这个 src 走既有 Apple 下载解密链路。
   */
  @Trace public pendingPlaySongSrc: string = '';
  /** When true, the shell should present full-screen player UI. */
  @Trace public openPlayerUi: boolean = false;
  /**
   * 起播位置（毫秒），-1 表示从 0 开始。
   * 「继续播放」按钮用它把上次停下的位置交给播放器 seek。
   */
  @Trace public pendingStartPositionMs: number = -1;
}
