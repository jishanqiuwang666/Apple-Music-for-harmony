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

import { AlbumApiDto, ArtistApiDto } from 'musicbasic';

/**
 * Window-space snapshot of the tapped row / cover. The detail page uses it
 * as the growth anchor so its non-hero content expands out of the exact
 * item the user tapped, instead of an arbitrary screen position.
 */
export class HeroSourceRect {
  /** Global x of the item's top-left corner (vp). */
  public x: number = 0;
  /** Global y of the item's top-left corner (vp). */
  public y: number = 0;
  /** Item width (vp). */
  public width: number = 0;
  /** Item height (vp). */
  public height: number = 0;

  /** Horizontal center of the snapshot (vp). */
  public centerX(): number {
    return this.x + this.width / 2;
  }

  /** Vertical center of the snapshot (vp). */
  public centerY(): number {
    return this.y + this.height / 2;
  }

  /** Copies an ArkUI area measurement into a serializable snapshot. */
  public static fromArea(area: Area): HeroSourceRect {
    const rect = new HeroSourceRect();
    rect.x = area.globalPosition.x !== undefined
      ? Number.parseFloat(area.globalPosition.x.toString())
      : 0;
    rect.y = area.globalPosition.y !== undefined
      ? Number.parseFloat(area.globalPosition.y.toString())
      : 0;
    rect.width = Number.parseFloat(area.width.toString());
    rect.height = Number.parseFloat(area.height.toString());
    return rect;
  }
}

/** Shared timing constants for the app-launch-style hero transition. */
export class HeroMotion {
  /** Push duration: spring motion approximating a 450ms app-open feel. */
  public static readonly ENTER_MS: number = 450;
  /** Pop duration: clean, friction-based return. */
  public static readonly EXIT_MS: number = 350;
  /** Delay before the play button grows out of the tapped row. */
  public static readonly BUTTON_DELAY_MS: number = 60;
  /** Delay before the body content (grid / song list) grows out. */
  public static readonly BODY_DELAY_MS: number = 120;
  /** Guard window after push before the source page accepts another tap. */
  public static readonly OPEN_GUARD_MS: number = 1000;
}

/**
 * Hero-id generator. Ids are namespaced per navigation stack on purpose:
 * tab pages may stay alive while another tab is on top, and a duplicate
 * geometryTransition id across two live components would pair the wrong
 * elements. A database id plus the source scope keeps every pair unique.
 */
export class HeroTransitionHelper {
  /** Scope for album cards shown on the Albums tab. */
  public static readonly SOURCE_ALBUM_TAB: string = 'album-tab';
  /** Scope for album cards shown inside the artist detail page. */
  public static readonly SOURCE_ARTIST_DETAIL: string = 'artist-detail-album';
  /** Scope for catalog search results shown on the search tab. */
  public static readonly SOURCE_SEARCH: string = 'search-tab';
  /** Scope for album cards inside an artist detail opened from the search tab. */
  public static readonly SOURCE_SEARCH_ARTIST: string = 'search-artist-album';

  /**
   * Shared id for a catalog artist portrait. The catalog id is the stable
   * key; the name is only the last-resort fallback.
   */
  public static catalogArtistHeroId(scope: string, catalogId: string, name: string): string {
    const key = catalogId !== '' ? catalogId : name;
    return `${scope}-artist-${key}`;
  }

  /**
   * Shared id for a catalog album cover. The card component builds the very
   * same string from its heroScope, so both ends must use one scope value.
   */
  public static catalogAlbumHeroId(scope: string, name: string, artist: string): string {
    return `${scope}-hero-${name}|${artist}`;
  }

  /** Shared id for an artist row portrait. */
  public static artistHeroId(artist: ArtistApiDto): string {
    // The in-memory aggregate mirror currently leaves artist.id at 0 for
    // every row, so multiple rows would bind the same geometry id and the
    // framework would animate from an arbitrary row. The display name is
    // the stable aggregate key; fall back to it whenever id is unset.
    const key = artist.id !== 0 ? `${artist.id}` : artist.name;
    return `artist-hero-${key}`;
  }

  /**
   * 收藏横排里那张卡片的共享元素 id。必须与下方列表行的 id 区分开：
   * 同一位艺人会同时出现在「收藏横排」和「列表」里，同一时刻在屏的两个源
   * 组件绑同一个 geometryTransition id 会配对到错误的那一个。
   */
  public static favoriteArtistHeroId(artist: ArtistApiDto): string {
    const key = artist.id !== 0 ? `${artist.id}` : artist.name;
    return `artist-hero-fav-${key}`;
  }

  /** Shared id for an album cover in the given source scope. */
  public static albumHeroId(scope: string, album: AlbumApiDto): string {
    // Same id=0 issue as artists; album aggregates are keyed by
    // name + artist, which is unique across the library mirror.
    const key = album.id !== 0 ? `${album.id}` : `${album.name}|${album.artist}`;
    return `${scope}-hero-${key}`;
  }
}
