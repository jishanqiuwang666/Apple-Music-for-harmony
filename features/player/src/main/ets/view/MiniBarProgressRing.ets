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
 * Progress ring for the mini player cover, built on the official Progress
 * component (Ring type) so it renders through the standard component
 * pipeline — self-drawn Canvas and Path variants were dropped by the HDS
 * miniBar container. The ring starts at 12 o'clock and sweeps clockwise.
 */
@ComponentV2
export struct MiniBarProgressRing {
  /** Playback position in ms. */
  @Param progress: number = 0;
  /** Track duration in ms (>= 1 to avoid division by zero). */
  @Param total: number = 1;
  /** Square side length in vp (must match the cover). */
  @Param side: number = 44;
  /** Progress arc color (hex string). */
  @Param arcColor: string = '#0A59F7';
  /** Track color (hex string). */
  @Param trackColor: string = '#00000000';

  /** Played ratio in 0..1. */
  private ratio(): number {
    return this.total > 0 ? Math.min(this.progress / this.total, 1) : 0;
  }

  build() {
    Progress({ value: this.ratio() * 100, total: 100, type: ProgressType.Ring })
      .width(this.side)
      .height(this.side)
      .color(this.arcColor)
      .backgroundColor(this.trackColor)
      .style({ strokeWidth: 2 })
  }
}
