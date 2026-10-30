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
 * 专辑 / 歌单的「继续播放」进度行（RDB 表 playback_resume）。
 *
 * 一个来源一条：上次停在哪首歌（歌曲 URI，形如 apple:<id>，
 * 不用数字 id —— 每次资料库同步都会重建 songs 表，数字 id 会变）、
 * 停在第几毫秒、以及最后一次更新的时间（用于超出上限时淘汰最旧的）。
 */
export class PlaybackResumeRow {
  /** 上下文键，见 {@link PlayContextKeys}。 */
  public contextKey: string = '';
  /** 上下文类型（album / playlist）。 */
  public kind: string = '';
  /** 上次停留的曲目 URI。 */
  public songUri: string = '';
  /** 上次停留的位置（毫秒）。 */
  public positionMs: number = 0;
  /** 最后更新时间戳（毫秒）。 */
  public updatedAt: number = 0;
}
