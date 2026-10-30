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

import { preferences } from '@kit.ArkData';
import { curves, LengthMetrics } from '@kit.ArkUI';

import { hdsEffect } from '@kit.UIDesignKit';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions, ScrollEffectType, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import {
  AlbumApiDto,
  AppleAuthState,
  LibrarySignal,
  MusicDatabase,
  MusicDbApi,
  AppleApi,
  AppleAlbum,
  AppleSong,
  Logger
} from 'musicbasic';
import { CoverPlaceholder, formatDuration } from './SongListItem';
import { HeroArtwork } from './HeroArtwork';
import { HeroMotion, HeroSourceRect, HeroTransitionHelper } from '../util/HeroTransition';
import { HomeBack } from '../util/HomeBack';
import { FlowLightRegistry } from '../util/FlowLightRegistry';
import { AlbumRowDataSource } from '../model/ListDataSources';
import { AlbumDetailParam, PlaybackHelper } from '../util/PlaybackHelper';

/**
 * Album grid card: every effect lives on the cover only — frosted glass
 * (backgroundBlurStyle thickens on press), an illuminated body for the
 * parent's fixed point light (feathering rim), and the official spring
 * press-scale. The caption below stays completely clean.
 */
/**
 * 把专辑列表按「每行 2 张」切分，供 List 的行虚拟化使用。
 *
 * @param list 专辑列表
 * @returns 行数组（最后一行可能只有 1 张）
 */
function toAlbumRows(list: AlbumApiDto[]): AlbumApiDto[][] {
  const rows: AlbumApiDto[][] = [];
  for (let i = 0; i < list.length; i += 2) {
    const row: AlbumApiDto[] = [list[i]];
    if (i + 1 < list.length) {
      row.push(list[i + 1]);
    }
    rows.push(row);
  }
  return rows;
}

@ComponentV2
struct AlbumGridCard {
  @Param album: AlbumApiDto = new AlbumApiDto();
  @Event onPlay: () => void = () => {
  };
  @Event onOpenDetail: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  /** Reports the press position (window coords) to the parent light. */
  @Event onLightAt: (x: number, y: number) => void = (x: number, y: number) => {
  };
  /** Turns the parent light off on release. */
  @Event onLightOff: () => void = () => {
  };
  /** Press state thickens the glass; scale drives the spring press. */
  @Local pressed: boolean = false;
  @Local coverScale: number = 1;
  /** Latest window-space snapshot of the cover (hero source frame). */
  @Local coverRect: HeroSourceRect = new HeroSourceRect();

  build() {
    Column({ space: 8 }) {
      // Cover-only button: frosted glass + illuminated body + spring scale.
      Button() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          HeroArtwork({
            coverPath: this.album.coverPath,
            seed: `${this.album.name}${this.album.artist}`,
            radius: 10,
            fillWidth: true,
            heroId: HeroTransitionHelper.albumHeroId(HeroTransitionHelper.SOURCE_ALBUM_TAB, this.album)
          })
          Row() {
            SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#B3000000')
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.onPlay();
          })
        }
        .width('100%')
        .aspectRatio(1)
        .borderRadius(10)
        .clip(true)
      }
      .type(ButtonType.Normal)
      .stateEffect(false)
      .backgroundColor(Color.Transparent)
      .borderRadius(10)
      .padding(0)
      .width('100%')
      .aspectRatio(1)
      .scale({ x: this.coverScale, y: this.coverScale })
      // Frosted glass on the cover; pressing thickens it.
      .backgroundBlurStyle(BlurStyle.Regular, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: this.pressed ? 1 : 0.2
      })
      // Illuminated body: lit by the parent's fixed point light.
      .visualEffect(new hdsEffect.HdsEffectBuilder()
        .pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
        })
        .buildEffect())
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.coverRect = HeroSourceRect.fromArea(newArea);
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 0.94;
          });
        } else if (event.type === TouchType.Move) {
          const touch = event.touches.length > 0 ? event.touches[0] : undefined;
          if (touch !== undefined) {
            this.onLightAt(touch.windowX, touch.windowY);
          }
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
          this.onLightOff();
          this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
            this.coverScale = 1;
          });
        }
      })
      .onClick(() => {
        this.onOpenDetail(this.coverRect);
      })

      // Clean caption: no effects extend below the cover.
      Column({ space: 2 }) {
        Text(this.album.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.library_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.album.artist} · ${this.album.songCount} 首 · ${formatDuration(this.album.totalDuration)}`)
          .fontSize(12)
          .fontColor($r('app.color.library_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .onClick(() => {
        this.onOpenDetail(this.coverRect);
      })
    }
    .width('100%')
  }
}

/** Albums section: grid of all albums, tap to open detail. */
@ComponentV2
export struct AlbumsPage {
  @Consumer('albumNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  @Local albums: AlbumApiDto[] = [];
  /** 来自 Apple Music 资料库的收藏专辑（专辑页顶部网格）。 */
  @Local favAlbums: AppleAlbum[] = [];
  /**
   * 收藏专辑的「曲目数 / 总时长」：资料库专辑接口不返回时长，
   * 所以按专辑 id 单独拉一次曲目算出来，落盘缓存（key = 资料库专辑 id）。
   */
  @Local favMeta: Map<string, number[]> = new Map<string, number[]>();
  @Local filteredAlbums: AlbumApiDto[] = [];
  /** Album-only search query (album name / artist). */
  @Local query: string = '';
  /** Library-change signal: refreshes after share-imports while the page stays alive. */
  @Local librarySignal: LibrarySignal = LibrarySignal.getInstance();
  /** Apple Music 登录态（未登录时空态展示「登录 Apple Music」）。 */
  @Local authState: AppleAuthState = AppleAuthState.getInstance();
  /** Grid scroller shared with the HDS title bar (GRADIENT_BLUR sync). */
  private scroller: Scroller = new Scroller();
  /** Lazy data source: only visible grid items are created (official optimization). */
  /** 行数据源（每行 2 张）——List 会按可视区惰性创建，避免一次性建 327 张卡片。 */
  private albumDataSource: AlbumRowDataSource = new AlbumRowDataSource();
  /** 当前的行切分结果（换过滤条件时重建）。 */
  @Local albumRows: AlbumApiDto[][] = [];
  /** Fixed overlay point light: position follows the pressed cover (window
   * coords). The source never scrolls with the grid, so it cannot jitter. */
  @Local lightX: number = -100;
  @Local lightY: number = -100;
  @Local lightOn: boolean = false;
  /** Ignores repeated cover taps while the hero push transition runs. */
  @Local isOpening: boolean = false;

  /** 收藏网格当前要渲染的条目：折叠时前 6 张，展开时全部。 */
  /** 收藏专辑按「每行 2 张」切分，交给外层 List 渲染。 */
  /** AppleAlbum -> AlbumApiDto（用于复用专辑网格卡片，样式/动画与普通专辑一致）。 */
  private favDto(fav: AppleAlbum): AlbumApiDto {
    const dto = new AlbumApiDto();
    dto.id = 0;
    dto.name = fav.name;
    dto.artist = fav.artistName;
    const meta: number[] | undefined = this.favMeta.get(fav.id);
    const cached: number = this.cachedPlayableCount(fav.name, fav.artistName);
    if (meta !== undefined) {
      // 曲目数与总时长都来自 Apple 的实际曲目列表（只算可播曲目），最准
      dto.songCount = meta[0];
      dto.totalDuration = meta[1];
    } else {
      dto.songCount = cached > 0 ? cached : fav.trackCount;
      dto.totalDuration = 0;
    }
    dto.coverPath = fav.artworkUrl;
    return dto;
  }

  /** 在本地专辑里找这张收藏专辑（按 名称+艺人），找不到返回 null。 */
  private matchLocalAlbum(fav: AppleAlbum): AlbumApiDto | null {
    const k: string = (fav.name + '|' + fav.artistName).toLowerCase();
    for (let i = 0; i < this.albums.length; i++) {
      const a: AlbumApiDto = this.albums[i];
      if ((a.name + '|' + a.artist).toLowerCase() === k) {
        return a;
      }
    }
    // 兜底：Apple 与本地库的艺人名口径可能不同（目录规范名 vs 本地化名），
    // 只按专辑名再匹配一次，保证收藏卡片仍能打开/播放本地那张专辑。
    const n: string = fav.name.toLowerCase().trim();
    if (n !== '') {
      for (let i = 0; i < this.albums.length; i++) {
        if (this.albums[i].name.toLowerCase().trim() === n) {
          return this.albums[i];
        }
      }
    }
    return null;
  }

  /** 收藏卡片：点播放（本地有对应专辑就播它；没有则进详情页，由详情页处理）。 */
  private playFav(fav: AppleAlbum): void {
    const local: AlbumApiDto | null = this.matchLocalAlbum(fav);
    if (local !== null) {
      PlaybackHelper.playAlbum(local);
      return;
    }
    this.openAlbumDetail(this.favDto(fav), new HeroSourceRect(), fav.id, fav.artworkUrl);
  }

  /** 收藏卡片：点封面打开专辑详情（本地有对应专辑用本地那条，保证曲目/封面一致）。 */
  private openFavDetail(fav: AppleAlbum, rect: HeroSourceRect): void {
    const local: AlbumApiDto | null = this.matchLocalAlbum(fav);
    // 关键：把资料库专辑 id（l.xxx）一起带进详情页 —— 详情页本地查不到曲目时
    // 直接 `/v1/me/library/albums/{id}/tracks` 拉，不再靠「专辑名+艺人名」匹配。
    this.openAlbumDetail(local !== null ? local : this.favDto(fav), rect, fav.id, fav.artworkUrl);
  }

  /** 收藏专辑缓存键（Preferences，由 AppleLibrarySync.syncFavorites 写入）。 */
  private static readonly FAV_CACHE_KEY: string = 'apple_fav_albums_v1';

  /** 启动时先读缓存（秒显，不必等网络）。 */
  private loadFavCache(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync(AlbumsPage.FAV_CACHE_KEY, '') as string;
      if (txt === '') {
        return;
      }
      const arr: AppleAlbum[] = JSON.parse(txt) as AppleAlbum[];
      if (arr.length > 0) {
        this.favAlbums = arr;
        this.ensureFavMeta(arr);
        this.applyFilter();
      }
    } catch (e) {
    }
  }

  /** 收藏专辑「曲目数 / 总时长」缓存键（Preferences，值 = { 资料库专辑id: [曲目数, 总时长ms] }）。 */
  private static readonly FAV_META_KEY: string = 'apple_fav_meta_v1';

  /** 启动时读「曲目数 / 总时长」缓存，让卡片副标题立即完整（含总时长）。 */
  private loadFavMeta(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const txt: string = store.getSync(AlbumsPage.FAV_META_KEY, '') as string;
      if (txt === '') {
        return;
      }
      const rec: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const keys: string[] = Object.keys(rec);
      const map: Map<string, number[]> = new Map<string, number[]>();
      for (let i = 0; i < keys.length; i++) {
        const arr: Object[] | undefined = rec[keys[i]] as Object[] | undefined;
        if (arr === undefined || arr.length < 2) {
          continue;
        }
        map.set(keys[i], [Number(arr[0] ?? 0), Number(arr[1] ?? 0)]);
      }
      this.favMeta = map;
    } catch (e) {
    }
  }

  private saveFavMeta(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const rec: Record<string, Object> = {};
      this.favMeta.forEach((v: number[], k: string) => {
        rec[k] = v;
      });
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      store.putSync(AlbumsPage.FAV_META_KEY, JSON.stringify(rec));
      store.flush();
    } catch (e) {
    }
  }

  /**
   * 补齐缺失的「曲目数 / 总时长」。
   *
   * 资料库专辑接口没有时长字段，只能按专辑 id 拉一次曲目（`extend` 也拿不到）。
   * 逐张串行、算完即写缓存，所以每张专辑一辈子只会拉一次；
   * 缓存齐了就是 0 个请求（冷启动不再有额外请求）。
   */
  private ensureFavMeta(list: AppleAlbum[]): void {
    const missing: AppleAlbum[] = [];
    for (let i = 0; i < list.length; i++) {
      if (this.favMeta.get(list[i].id) === undefined) {
        missing.push(list[i]);
      }
    }
    if (missing.length === 0) {
      return;
    }
    this.fetchFavMeta(list, missing, 0);
  }

  private fetchFavMeta(list: AppleAlbum[], missing: AppleAlbum[], index: number): void {
    if (index >= missing.length) {
      this.saveFavMeta();
      // 全部补齐后整体刷一次，卡片上「N 首 · 时长」一起出现
      this.favAlbums = list.slice();
      return;
    }
    const fav: AppleAlbum = missing[index];
    AppleApi.getAlbumTracks(fav.id, '', 100).then((tracks: AppleSong[]) => {
      let ms: number = 0;
      for (let i = 0; i < tracks.length; i++) {
        ms += tracks[i].durationMs;
      }
      const map: Map<string, number[]> = new Map<string, number[]>();
      this.favMeta.forEach((v: number[], k: string) => {
        map.set(k, v);
      });
      map.set(fav.id, [tracks.length, ms]);
      this.favMeta = map;
      this.fetchFavMeta(list, missing, index + 1);
    }).catch(() => {
      this.fetchFavMeta(list, missing, index + 1);
    });
  }

  /** 网络刷新成功后回写缓存。 */
  private saveFavCache(list: AppleAlbum[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      store.putSync(AlbumsPage.FAV_CACHE_KEY, JSON.stringify(list));
      // 时间戳：启动同步（比页面晚）看到刚拉过就不再重复拉一遍
      store.putSync('apple_fav_at_v1', new Date().getTime());
      store.flush();
    } catch (e) {
    }
  }

  /** 收藏专辑按「每行 2 张」切分，交给外层 List 渲染（不再有折叠/展开）。 */
  private favRows(): AppleAlbum[][] {
    const list: AppleAlbum[] = this.favAlbums;
    const rows: AppleAlbum[][] = [];
    for (let i = 0; i < list.length; i += 2) {
      const row: AppleAlbum[] = [list[i]];
      if (i + 1 < list.length) {
        row.push(list[i + 1]);
      }
      rows.push(row);
    }
    return rows;
  }

  /** Same normalization used by the album detail page for its playable cache key. */
  private normAlbumNameForCache(name: string): string {
    let t: string = name.toLowerCase().trim();
    const suffixes: string[] = [' - ep', ' - single', ' - deluxe', ' (deluxe)', ' - deluxe edition',
      ' (ep)', ' (single)', ' - complete', ' (complete)'];
    for (let i = 0; i < suffixes.length; i++) {
      if (t.endsWith(suffixes[i])) {
        t = t.substring(0, t.length - suffixes[i].length).trim();
      }
    }
    return t;
  }

  /** Cached playable track count for an album (0 when the detail page never cached it). */
  private cachedPlayableCount(name: string, artist: string): number {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return 0;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_playable' });
      const key: string = this.normAlbumNameForCache(name) + '|' + artist.toLowerCase().trim();
      const raw: string = store.getSync(key, '') as string;
      if (raw === '') {
        return 0;
      }
      const keys: string[] = JSON.parse(raw) as string[];
      return keys.length;
    } catch (e) {
      return 0;
    }
  }

  aboutToAppear(): void {
    this.albums = MusicDbApi.getInstance().getAlbums();
    // 收藏专辑：先读缓存（秒显，含曲目数/总时长），再联网刷新一次
    this.loadFavMeta();
    this.loadFavCache();
    this.applyFilter();
    this.refreshFavorites();
    // Cold start: refresh directly once the DB is ready (see ArtistsPage).
    MusicDatabase.getInstance().whenReady(() => {
      setTimeout(() => {
        this.albums = MusicDbApi.getInstance().getAlbums();
        this.applyFilter();
      }, 50);
    });
  }

  /**
   * 联网刷新「收藏的专辑」（Apple Music 的 ⭐）。
   *
   * 收藏状态只能通过 `extend=inFavorites` 读到，页面进入时刷一次即可；
   * 同步链（AppleLibrarySync.syncFavorites）也会写同一份缓存。
   */
  private refreshFavorites(): void {
    // 启动同步刚拉过收藏（同一份 Preferences，带时间戳）⇒ 直接吃缓存，不再重复拉 4 页
    if (this.favCacheFresh()) {
      Logger.info('AlbumsPage', '收藏专辑缓存新鲜，跳过联网刷新');
      return;
    }
    AppleApi.getFavoriteAlbums(5).then((list: AppleAlbum[]) => {
      this.favAlbums = list;
      this.saveFavCache(list);
      this.ensureFavMeta(list);
      this.applyFilter();
      let matched: number = 0;
      let missing: string = '';
      for (let i = 0; i < list.length; i++) {
        if (this.matchLocalAlbum(list[i]) !== null) {
          matched++;
        } else {
          missing += (missing === '' ? '' : ' / ') + list[i].name;
        }
      }
      Logger.info('AlbumsPage',
        `收藏专辑刷新完成：${list.length} 张（本地命中 ${matched}；未命中：${missing}）`);
    }).catch(() => {
    });
  }

  /** 收藏缓存是否刚被启动同步刷新过（5 分钟内）：是的话页面就不用再拉一遍。 */
  private favCacheFresh(): boolean {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return false;
      }
      const store = preferences.getPreferencesSync(ctx, { name: 'musichome_fav' });
      const at: number = store.getSync('apple_fav_at_v1', 0) as number;
      if (at <= 0) {
        return false;
      }
      return (new Date().getTime() - at) < 5 * 60 * 1000;
    } catch (e) {
      return false;
    }
  }

  aboutToDisappear(): void {
  }

  /** Refreshes the album grid when the library changes (e.g. share import). */
  @Monitor('librarySignal.version')
  onLibraryChanged(): void {
    this.albums = MusicDbApi.getInstance().getAlbums();
    // 详情页点心形改了 Apple 收藏后会广播信号：这里重读缓存，秒级跟随（不再打网络）
    this.loadFavCache();
    this.applyFilter();
  }

  /** Album-only search over the current album list. */
  private applyFilter(): void {
    const q = this.query.trim().toLowerCase();
    if (q === '') {
      this.filteredAlbums = this.albums;
    } else {
      this.filteredAlbums = this.albums.filter((a: AlbumApiDto) => {
        return a.name.toLowerCase().includes(q) || a.artist.toLowerCase().includes(q);
      });
    }
    // 去重：已在收藏里的专辑从「全部专辑」移除（按 名称+艺人）
    if (this.favAlbums.length > 0) {
      const favKeys: Set<string> = new Set<string>();
      for (let i = 0; i < this.favAlbums.length; i++) {
        favKeys.add((this.favAlbums[i].name + '|' + this.favAlbums[i].artistName).toLowerCase());
      }
      this.filteredAlbums = this.filteredAlbums.filter((a: AlbumApiDto) =>
        !favKeys.has((a.name + '|' + a.artist).toLowerCase()));
    }
    this.albumRows = toAlbumRows(this.filteredAlbums);
    this.albumDataSource.setRows(this.albumRows);
  }

  /** 在收藏列表里找这张本地专辑对应的资料库专辑（先 名称+艺人，再退化到只按名称）。 */
  private matchFavForAlbum(album: AlbumApiDto): AppleAlbum | null {
    const k: string = (album.name + '|' + album.artist).toLowerCase();
    for (let i = 0; i < this.favAlbums.length; i++) {
      const f: AppleAlbum = this.favAlbums[i];
      if ((f.name + '|' + f.artistName).toLowerCase() === k) {
        return f;
      }
    }
    const n: string = album.name.toLowerCase().trim();
    if (n !== '') {
      for (let i = 0; i < this.favAlbums.length; i++) {
        if (this.favAlbums[i].name.toLowerCase().trim() === n) {
          return this.favAlbums[i];
        }
      }
    }
    return null;
  }

  /**
   * Opens the album detail page with the shared-element hero transition.
   * Official recipe: pushPathByName(..., false) inside animateTo so the
   * system default transition never stacks with geometryTransition.
   */
  private openAlbumDetail(album: AlbumApiDto, sourceRect: HeroSourceRect,
    libraryAlbumId: string = '', coverUrl: string = ''): void {
    if (this.isOpening) {
      return;
    }
    // 从专辑墙进来时没有资料库 id：如果这张正好在收藏列表里，就顺手带上，
    // 详情页的收藏状态（心形）就能一次请求拿到，不必再去搜目录。
    let libId: string = libraryAlbumId;
    if (libId === '') {
      const hit: AppleAlbum | null = this.matchFavForAlbum(album);
      if (hit !== null) {
        libId = hit.id;
      }
    }
    this.isOpening = true;
    const param: AlbumDetailParam = {
      albumName: album.name,
      artistName: album.artist,
      heroId: HeroTransitionHelper.albumHeroId(HeroTransitionHelper.SOURCE_ALBUM_TAB, album),
      sourceRect: sourceRect,
      fromArtistDetail: false,
      libraryAlbumId: libId,
      coverUrl: coverUrl
    };
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.pageIndexInfos.pushPathByName('AlbumDetail', param, false);
    });
    setTimeout(() => {
      this.isOpening = false;
    }, HeroMotion.OPEN_GUARD_MS);
  }

  /**
   * HDS title bar with the official GRADIENT_BLUR (same tuned profile as
   * the artists home). No stackBuilder content: the bar is a pure blur
   * mask over the top edge.
   */
  private titleBarOptions(): HdsNavigationTitleBarOptions {
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(72)
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
          maskExtraHeight: 88,
          blurRadius: 16
        }
      }
    };
    return { style: style };
  }

  /** Apple Music-style library title fade driven by the grid scroll. */
  @Local titleFade: number = 1;

  /** Apple Music-style large library title: big bold name over a count
   * subtitle; fades out as the grid scrolls under the title bar. */
  @Builder
  private LibraryTitle() {
    Column({ space: 4 }) {
      Text('专辑')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(`${this.albums.length} 张专辑`)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .opacity(this.titleFade)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        // Default-focus anchor: a transparent 1vp box that takes the page's
        // default focus instead of the search field, so switching to this tab
        // never opens the keyboard by itself (a non-input component does not
        // summon the soft keyboard when focused).
        Column()
          .width(1)
          .height(1)
          .defaultFocus(true)
        Column() {
          if (this.query !== '' && this.filteredAlbums.length === 0) {
            // Search with no hits.
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(56)
                .fontColor([$r('app.color.library_text_secondary')])
              Text('未找到相关专辑')
                .fontSize(14)
                .fontColor($r('app.color.library_text_secondary'))
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.albums.length === 0) {
            Column({ space: 12 }) {
              CoverPlaceholder({ seed: 'albums', radius: 28, symbol: $r('sys.symbol.dot_grid_2x2') })
                .width(110)
                .height(110)
              Text($r('app.string.library_no_music'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.library_text_primary'))
              Text($r('app.string.library_no_music_hint'))
                .fontSize(13)
                .fontColor($r('app.color.library_text_secondary'))
                .textAlign(TextAlign.Center)
                .padding({ left: 32, right: 32 })
              if (!this.authState.authorized) {
                Button({ type: ButtonType.Capsule }) {
                  Text($r('app.string.library_login_apple_music'))
                    .fontSize(15)
                    .fontColor(Color.White)
                }
                .height(42)
                .padding({ left: 28, right: 28 })
                .backgroundColor($r('app.color.library_accent'))
                .onClick(() => {
                  this.authState.openLogin();
                })
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            // Scroll wraps the title + grid so the large title scrolls away
            // with the content (grid columns cannot span the title reliably);
            // Spring edge effect gives the official rubber-band overscroll.
            // 用 List（而不是 Scroll+Grid）承载专辑网格：
            //   Scroll 里的 Grid 拿不到确定高度 → LazyForEach 退化为全量构建
            //   （327 张卡片 + 每张的点光源效果 → 首建 1~2 秒、切页掉帧）。
            //   这里每行两张卡，List 只创建可视区的行；大标题作为第 0 项一起滚走。
            List({ space: 18, scroller: this.scroller }) {
              ListItem() {
                Column() {
                  // 同搜索页：Blank 会自动填充剩余空间，内容少时把标题挤下去，
                  // 用固定高度的 Column 更稳。
                  Column().height(96)
                  this.LibraryTitle()
                }
                .width('100%')
              }

              // ① Apple Music 收藏（⭐）的专辑：无分区标题，直接排在最上面，
              //    与下方「全部专辑」同一套卡片/间距 —— 收藏的那几张已从下方去重移除，
              //    所以整页就是一面连续的专辑墙（用户要求：进来直接一屏全部专辑）。

              ForEach(this.favRows(), (row: AppleAlbum[], rowIndex: number) => {
                ListItem() {
                  Row({ space: 14 }) {
                    ForEach(row, (fav: AppleAlbum) => {
                      Column() {
                        AlbumGridCard({
                          album: this.favDto(fav),
                          onPlay: () => {
                            this.playFav(fav);
                          },
                          onOpenDetail: (sourceRect: HeroSourceRect) => {
                            this.openFavDetail(fav, sourceRect);
                          },
                          onLightAt: (x: number, y: number) => {
                            this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                              this.lightX = x;
                              this.lightY = y;
                              this.lightOn = true;
                            });
                          },
                          onLightOff: () => {
                            this.lightOn = false;
                          }
                        })
                      }
                      .layoutWeight(1)
                    }, (fav: AppleAlbum) => 'fav-' + fav.id)
                    if (row.length < 2) {
                      Column()
                        .layoutWeight(1)
                    }
                  }
                  .width('100%')
                  // 与专辑行保持一致的内边距（卡片大小/位置才一致）
                  .padding({ left: 16, right: 16 })
                }
              }, (row: AppleAlbum[], rowIndex: number) => 'favrow-' + rowIndex)

              // 收藏与其余专辑之间留一段空隙，空隙里标出「全部专辑」
              // （只在有收藏时出现；没有收藏时整页就是从第一张开始的专辑墙）
              if (this.favAlbums.length > 0) {
                ListItem() {
                  Text('全部专辑')
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.library_text_primary'))
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 12, bottom: 2 })
                }
              }

              LazyForEach(this.albumDataSource, (row: AlbumApiDto[], index: number) => {
                ListItem() {
                  Row({ space: 14 }) {
                    if (row.length > 0) {
                      Column() {
                        AlbumGridCard({
                          album: row[0],
                          onPlay: () => {
                            PlaybackHelper.playAlbum(row[0]);
                          },
                          onOpenDetail: (sourceRect: HeroSourceRect) => {
                            this.openAlbumDetail(row[0], sourceRect);
                          },
                          onLightAt: (x: number, y: number) => {
                            // Spring-animate the fixed light to the press point.
                            this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                              this.lightX = x;
                              this.lightY = y;
                              this.lightOn = true;
                            });
                          },
                          onLightOff: () => {
                            this.lightOn = false;
                          }
                        })
                      }
                      .layoutWeight(1)
                    }
                    if (row.length > 1) {
                      Column() {
                        AlbumGridCard({
                          album: row[1],
                          onPlay: () => {
                            PlaybackHelper.playAlbum(row[1]);
                          },
                          onOpenDetail: (sourceRect: HeroSourceRect) => {
                            this.openAlbumDetail(row[1], sourceRect);
                          },
                          onLightAt: (x: number, y: number) => {
                            this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                              this.lightX = x;
                              this.lightY = y;
                              this.lightOn = true;
                            });
                          },
                          onLightOff: () => {
                            this.lightOn = false;
                          }
                        })
                      }
                      .layoutWeight(1)
                    }
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16 })
                }
              }, (row: AlbumApiDto[], index: number) =>
                `row-${index}-${row.length > 0 ? row[0].name : ''}-${row.length > 0 ? row[0].artist : ''}`)
            }
            .cachedCount(3, true)
            .width('100%')
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .scrollBar(BarState.Off)
            // No clipping: content keeps scrolling under the title bar into
            // the GRADIENT_BLUR mask without disappearing.
            .clip(false)
            // 底部给悬浮 HDS 栏留位（52vp 栏 + 34vp 底距 + 4vp 呼吸）；
            // 左右内边距放在每一行上（放在 List 上会和大标题自带的 16vp 叠加成 32vp）。
            .padding({ bottom: 90 })
            // Large-title fade: fully visible at top, eased out over 130vp
            // (onDidScroll reports per-frame deltas; read the cumulative
            // offset from the official Scroller instead).
            .onDidScroll((offset: number, state: ScrollState) => {
            // 滚动时让全屏流光让位（停手 220ms 自动恢复），发热降频时更顺。
            FlowLightRegistry.beginScroll();
              const y = this.scroller.currentOffset().yOffset;
              this.titleFade = Math.max(0, Math.min(1, 1 - y / 130));
            })
            .layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')

        // Fixed point-light source overlay inside the page Stack: never
        // scrolls with the grid, so it cannot jitter; position follows the
        // pressed cover (window coords — the Stack starts at window origin).
        // Official preset sourceType (SOFT = gentle, wide-ish light) driven
        // by press, instead of custom options.
        Column()
          .width(2)
          .height(2)
          .position({ x: this.lightX, y: this.lightY })
          .visualEffect(new hdsEffect.HdsEffectBuilder()
            .pointLight({
              sourceType: this.lightOn
                ? hdsEffect.PointLightSourceType.BRIGHT
                : hdsEffect.PointLightSourceType.NONE
            })
            .buildEffect())
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideBackButton(true)
    .hideToolBar(true)
    .bindToScrollable([this.scroller])
    // geometryTransition only runs between NavDestination pages; the home
    // page itself must not add a system page transition on top of it.
    .systemTransition(NavigationSystemTransitionType.NONE)
    // 首页是这条栈的第一页：系统返回默认会把它也弹掉 → 栈空 → 只剩底色
    // （深色模式下就是用户看到的「黑屏，只能重启」）。这里统一消费返回事件：
    // 抽屉开着先关抽屉，否则回桌面（音乐继续后台播放）。
    .onBackPressed((): boolean => {
      return HomeBack.handle(this.getUIContext());
    })

    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/**
 * HdsNavigation shell for the albums tab. Its home content stays blank:
 * the album grid itself is pushed immediately as the first NavDestination,
 * because geometryTransition only works between two NavDestination pages
 * (never between Navigation home content and a NavDestination).
 */
@ComponentV2
export struct AlbumsTabShell {
  @Consumer('albumNavStack') pageIndexInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // Album-tab transitions are driven by geometryTransition + the detail
    // page growth animations, so the system default page transition stays
    // disabled for the whole stack.
    this.pageIndexInfos.disableAnimation(true);
    if (this.pageIndexInfos.size() === 0) {
      this.pageIndexInfos.pushPathByName('AlbumHome', undefined, false);
    }
  }

  build() {
    HdsNavigation(this.pageIndexInfos) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
    }
    .mode(NavigationMode.Stack)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideTitleBar(true)
    .hideBackButton(true)
    .hideToolBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/** Global builder entry for the albums home route. */
@Builder
export function AlbumHomePageBuilder(name: string, param: Object) {
  AlbumsPage()
}
