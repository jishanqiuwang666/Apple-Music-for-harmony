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

import { hdsEffect } from '@kit.UIDesignKit';
import { AppleApi } from 'musicbasic';
import { SongApiDto } from 'musicbasic';

/** Formats milliseconds as mm:ss. */
export function formatDuration(ms: number): string {
  if (ms <= 0) {
    return '--:--';
  }
  const totalSec = Math.floor(ms / 1000);
  const min = Math.floor(totalSec / 60);
  const sec = totalSec % 60;
  return `${min < 10 ? '0' : ''}${min}:${sec < 10 ? '0' : ''}${sec}`;
}

/** Converts hsv degrees/percent to an #RRGGBB string for gradient stops. */
function hsvToHex(h: number, s: number, v: number): string {
  const c = v * s;
  const x = c * (1 - Math.abs((h / 60) % 2 - 1));
  const m = v - c;
  let r = 0;
  let g = 0;
  let b = 0;
  if (h < 60) {
    r = c; g = x;
  } else if (h < 120) {
    r = x; g = c;
  } else if (h < 180) {
    g = c; b = x;
  } else if (h < 240) {
    g = x; b = c;
  } else if (h < 300) {
    r = x; b = c;
  } else {
    r = c; b = x;
  }
  const toHex = (channel: number): string => {
    const n = Math.round((channel + m) * 255);
    const hex = n.toString(16);
    return hex.length === 1 ? `0${hex}` : hex;
  };
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

/** Renders a cover placeholder image (gradient block) when no cover file exists. */
@ComponentV2
export struct CoverPlaceholder {
  /** Seed used to pick a stable gradient hue for the placeholder. */
  @Param seed: string = '';
  /** Rounded-corner radius in vp. */
  @Param radius: number = 8;
  /** Icon symbol shown in the center. */
  @Param symbol: Resource = $r('sys.symbol.music_note_list');

  private hue(): number {
    let h = 0;
    for (let i = 0; i < this.seed.length; i++) {
      h = (h * 31 + this.seed.charCodeAt(i)) % 360;
    }
    return h;
  }

  build() {
    Stack() {
      Row()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [[hsvToHex(this.hue(), 0.30, 0.92), 0.0], [hsvToHex((this.hue() + 40) % 360, 0.45, 0.72), 1.0]]
        })
      SymbolGlyph(this.symbol)
        .fontSize(24)
        .fontColor(['#66FFFFFF'])
    }
    .borderRadius(this.radius)
    .clip(true)
  }
}

/** Single song row: cover, title/artist, duration, play indicator. */
@ComponentV2
export struct SongListItem {
  /** Song row model. */
  @Param song: SongApiDto = new SongApiDto();
  /** True when this row is the currently playing song. */
  @Param isCurrent: boolean = false;
  /** True while this row's audio is playing. */
  @Param isPlaying: boolean = false;
  /** False hides the row cover (album detail keeps only its big header art). */
  @Param showCover: boolean = true;
  /**
   * 专辑 / 歌单页的「上次停在这里」标记：标题用黄色显示。
   * 与 isCurrent（正在播放，蓝色）互斥显示：正在播的那首仍按蓝色处理。
   */
  @Param isResume: boolean = false;
  /** Called when the row is tapped. */
  @Event onPlay: () => void = () => {
  };
  /**
   * 点「正在播放」那一行时走这里：播放 / 暂停切换。
   *
   * 为什么不是行内图标各自处理：图标若单独带 onClick，能不能冒泡到行是不确定的，
   * 之前用过的 `glyphTapped` 标记会在「不冒泡」时残留，导致下一次点击被吞（要点两次）；
   * 而且行本身的 onPlay 会重新加载曲目 → 暂停后继续会从头播。现在统一由行决定。
   */
  @Event onTogglePlay: () => void = () => {
  };
  /** Press state drives the official pressShadow (Button only). */
  @Local pressed: boolean = false;

  build() {
    Button() {
      Row({ space: 12 }) {
        if (this.showCover) {
          if (this.song.coverPath !== '') {
            Image(AppleApi.artworkAt(this.song.coverPath, 200))
              .width(44)
              .height(44)
              .borderRadius(6)
              .draggable(false)
          } else {
            CoverPlaceholder({ seed: `${this.song.title}`, radius: 6, symbol: $r('sys.symbol.music_note_list') })
              .width(44)
              .height(44)
          }
        }
        Column({ space: 2 }) {
          Text(`${this.song.title}`)
            .fontSize(16)
            .fontWeight(this.isCurrent || this.isResume ? FontWeight.Bold : FontWeight.Regular)
            // 正在播放 = 品牌蓝；上次停在这里 = 琥珀黄（用户 2026-09-12 定）。
            .fontColor(this.isCurrent ? $r('app.color.library_accent')
              : (this.isResume ? $r('app.color.library_resume_text')
                : $r('app.color.library_text_primary')))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.song.album !== '' ? `${this.song.singer} · ${this.song.album}` : `${this.song.singer}`)
            .fontSize(13)
            .fontColor($r('app.color.library_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(formatDuration(this.song.duration))
          .fontSize(12)
          .fontColor($r('app.color.library_text_secondary'))
          .margin({ left: 4 })
        if (this.isCurrent && this.isPlaying) {
          SymbolGlyph($r('sys.symbol.pause_round_triangle_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.library_accent')])
            // Official hierarchical fill loop: the playing row breathes
            // (Apple Music-style now-playing indication via SymbolGlyph).
            .symbolEffect(new HierarchicalSymbolEffect(EffectFillStyle.ITERATIVE), true)
        } else {
          SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.library_text_secondary')])
            .opacity(0.7)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
    // Official press-shadow recipe: Button + stateEffect off + pressShadow
    // driven by touch (down → soft white blend, up/cancel → none).
    .type(ButtonType.Normal)
    .stateEffect(false)
    .backgroundColor(Color.Transparent)
    .borderRadius(0)
    .padding(0)
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pressShadow(this.pressed
        ? hdsEffect.PressShadowType.BLEND_WHITE
        : hdsEffect.PressShadowType.NONE)
      .buildEffect())
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      // 抽屉手势刚过去 → 吞掉这次点击（整屏透明层会让触摸同时落到这里）
      // 正在播放的那一行：一次点击就切播放/暂停，且暂停后继续**接着上次进度**
      //（toggle 走 MediaService.play()，不会重新加载曲目）；
      // 其它行：从这首歌开始播。
      if (this.isCurrent) {
        this.onTogglePlay();
      } else {
        this.onPlay();
      }
    })
  }
}
