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

import { AppleApi } from 'musicbasic';
import { CoverPlaceholder } from './SongListItem';

/**
 * Shared hero artwork container for the cross-page geometry transition.
 *
 * Both the source list item and the detail header render this exact
 * component with the same heroId, so the official geometryTransition can
 * smoothly move and resize the container (and its border radius) between
 * the two pages. Children always fill the container with relative layout,
 * as required by the official geometryTransition container example.
 */
@ComponentV2
export struct HeroArtwork {
  /** Cached cover-art path; empty falls back to the gradient placeholder. */
  @Param coverPath: string = '';
  /** Seed for the stable placeholder gradient. */
  @Param seed: string = '';
  /** Placeholder icon symbol. */
  @Param symbol: Resource = $r('sys.symbol.music_note_list');
  /** Corner radius in vp, synced by geometryTransition on the container. */
  @Param radius: number = 0;
  /** Fixed width in vp (ignored when fillWidth is true). */
  @Param heroWidth: number = 0;
  /** Fixed height in vp (ignored when fillWidth is true). */
  @Param heroHeight: number = 0;
  /**
   * True for grid cards: width follows the grid column (100%) and the
   * height follows aspectRatio(1), matching the old card layout.
   */
  @Param fillWidth: boolean = false;
  /** geometryTransition id; empty string disables the shared transition. */
  @Param heroId: string = '';

  /**
   * 按显示尺寸算出该请求的封面边长（像素）。
   * 列表里的小图（≤120vp）按 2 倍密度请求即可，避免下 600×600 再缩小的浪费；
   * 大图（详情页/网格）保持 600，保证清晰度与共享元素转场观感。
   */
  private requestSize(): number {
    if (this.fillWidth) {
      return 600;
    }
    const vp: number = this.heroWidth > 0 ? this.heroWidth : 600;
    if (vp <= 120) {
      const px: number = this.getUIContext().vp2px(vp) * 2;
      return px > 320 ? 320 : px;
    }
    return 600;
  }

  @Builder
  private ArtworkContent() {
    if (this.coverPath !== '') {
      Image(AppleApi.artworkAt(this.coverPath, this.requestSize()))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        // Image.draggable 自 API 11 起默认 true：不关掉的话长按会先起「图片拖拽」，
        // 把列表项拖拽（换位）的 onItemDragStart/onItemDrop 全部抢掉。
        .draggable(false)
    } else {
      CoverPlaceholder({ seed: this.seed, radius: this.radius, symbol: this.symbol })
        .width('100%')
        .height('100%')
    }
  }

  build() {
    if (this.fillWidth) {
      Stack() {
        this.ArtworkContent()
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius(this.radius)
      .clip(true)
      .geometryTransition(this.heroId)
    } else {
      Stack() {
        this.ArtworkContent()
      }
      .width(this.heroWidth)
      .height(this.heroHeight)
      .borderRadius(this.radius)
      .clip(true)
      .geometryTransition(this.heroId)
    }
  }
}
