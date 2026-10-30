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
import { hdsEffect } from '@kit.UIDesignKit';
import {
  AlbumApiDto,
  ApplePlaylistRow,
  AppStorageKeys,
  ArtistApiDto,
  MusicAppState,
  MusicDbApi,
  PlayContextKeys,
  SongApiDto
} from 'musicbasic';
import { PlayerDataUtil } from 'player';
import { CoverPlaceholder, SongListItem } from './SongListItem';
import { PlaybackHelper } from '../util/PlaybackHelper';

/** 每个板块最多展示多少条（其余用「还有 N 条」提示）。 */
const MAX_PER_SECTION: number = 30;
/** 输入防抖（毫秒）。 */
const DEBOUNCE_MS: number = 120;

/**
 * 资料库统一搜索浮层（用户 2026-09-13 定）。
 *
 * 取代原来各板块顶端各自的搜索条（搜索艺人 / 搜索专辑 / 搜索歌曲）：外壳上只有一个
 * 固定的圆形搜索按钮，点开就是这个浮层，**只搜本机资料库**（艺人 / 专辑 / 歌曲 / 歌单
 * 合一）。点结果：歌曲直接播，艺人/专辑/歌单交给外壳切到对应板块再打开详情页。
 */
@ComponentV2
export struct LibrarySearchOverlay {
  /** MusicAppState：列表行右侧播放/暂停键要切播放状态，需要它。 */
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;

  /** 关闭浮层。 */
  @Event onClose: () => void = () => {
  };
  /** 打开艺人主页（外壳负责切 tab + push）。 */
  @Event onOpenArtist: (name: string) => void = (name: string) => {
  };
  /** 打开专辑详情页。 */
  @Event onOpenAlbum: (name: string, artist: string) => void = (name: string, artist: string) => {
  };
  /** 打开歌单详情页。 */
  @Event onOpenPlaylist: (id: string, name: string) => void = (id: string, name: string) => {
  };

  @Local query: string = '';
  @Local artists: ArtistApiDto[] = [];
  @Local albums: AlbumApiDto[] = [];
  @Local songs: SongApiDto[] = [];
  @Local playlists: ApplePlaylistRow[] = [];
  /** 命中总数（用于「还有 N 条」提示）。 */
  @Local totalArtists: number = 0;
  @Local totalAlbums: number = 0;
  @Local totalSongs: number = 0;
  @Local totalPlaylists: number = 0;
  /** 搜索框按压缩放（与其它页面同款弹簧）。 */
  @Local searchScale: number = 1;
  private debounceId: number = -1;

  aboutToDisappear(): void {
    if (this.debounceId !== -1) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
  }

  /** 输入变化：防抖后过滤本机资料库。 */
  private onQueryChange(value: string): void {
    this.query = value;
    if (this.debounceId !== -1) {
      clearTimeout(this.debounceId);
    }
    this.debounceId = setTimeout(() => {
      this.runSearch();
    }, DEBOUNCE_MS);
  }

  /** 在内存镜像里过滤（资料库已全量在内存，不需要 IO）。 */
  private runSearch(): void {
    const q: string = this.query.trim().toLowerCase();
    if (q === '') {
      this.artists = [];
      this.albums = [];
      this.songs = [];
      this.playlists = [];
      this.totalArtists = 0;
      this.totalAlbums = 0;
      this.totalSongs = 0;
      this.totalPlaylists = 0;
      return;
    }
    const allArtists: ArtistApiDto[] = MusicDbApi.getInstance().getArtists()
      .filter((a: ArtistApiDto) => a.name.toLowerCase().includes(q));
    const allAlbums: AlbumApiDto[] = MusicDbApi.getInstance().getAlbums()
      .filter((a: AlbumApiDto) => a.name.toLowerCase().includes(q) || a.artist.toLowerCase().includes(q));
    const allSongs: SongApiDto[] = MusicDbApi.getInstance().getSongList()
      .filter((s: SongApiDto) => `${s.title}`.toLowerCase().includes(q)
        || `${s.singer}`.toLowerCase().includes(q)
        || s.album.toLowerCase().includes(q));
    const allPlaylists: ApplePlaylistRow[] = MusicDbApi.getInstance().getApplePlaylists()
      .filter((p: ApplePlaylistRow) => p.name.toLowerCase().includes(q));

    this.totalArtists = allArtists.length;
    this.totalAlbums = allAlbums.length;
    this.totalSongs = allSongs.length;
    this.totalPlaylists = allPlaylists.length;
    this.artists = allArtists.slice(0, MAX_PER_SECTION);
    this.albums = allAlbums.slice(0, MAX_PER_SECTION);
    this.songs = allSongs.slice(0, MAX_PER_SECTION);
    this.playlists = allPlaylists.slice(0, MAX_PER_SECTION);
  }

  /** 播放命中的某一首（队列 = 当前搜索结果）。 */
  private playSong(index: number): void {
    PlaybackHelper.playSongList(this.songs, index, true, PlayContextKeys.searchContext());
  }

  /** 板块标题 + 命中总数 / 截断提示。 */
  @Builder
  private SectionTitle(text: string, total: number, shown: number) {
    Row({ space: 8 }) {
      Text(text)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(shown < total ? `${total} 条（显示前 ${shown}）` : `${total} 条`)
        .fontSize(12)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 18, bottom: 6 })
  }

  /** 通用一行（艺人 / 专辑 / 歌单共用）：圆角封面 + 标题 + 副标题。 */
  @Builder
  private RowCard(coverPath: string, seed: string, symbol: Resource, title: string, subtitle: string,
    onTap: () => void) {
    Row({ space: 12 }) {
      if (coverPath !== '') {
        Image(coverPath)
          .width(48)
          .height(48)
          .borderRadius(8)
          .draggable(false)
          .interpolation(ImageInterpolation.High)
      } else {
        CoverPlaceholder({ seed: seed, radius: 8, symbol: symbol })
          .width(48)
          .height(48)
      }
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.library_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.library_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.library_text_secondary')])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Column() {
      // ── 顶部：搜索框 + 取消 ──
      Row({ space: 10 }) {
        Row() {
          Search({ placeholder: '搜索资料库（艺人 / 专辑 / 歌曲 / 歌单）', value: this.query })
            .width('100%')
            .height(42)
            .defaultFocus(true)
            .onChange((value: string) => {
              this.onQueryChange(value);
            })
            .backgroundColor(Color.Transparent)
            .backgroundBlurStyle(BlurStyle.Thin)
        }
        .layoutWeight(1)
        .height(42)
        .borderRadius(21)
        .backgroundBlurStyle(BlurStyle.Thin)
        .scale({ x: this.searchScale, y: this.searchScale })
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pointLight({
            illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
          })
          .buildEffect())

        Text('取消')
          .fontSize(16)
          .fontColor($r('app.color.library_accent'))
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 56, bottom: 8 })

      // ── 结果 ──
      Scroll() {
        Column() {
          if (this.query.trim() === '') {
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(48)
                .fontColor([$r('app.color.library_text_secondary')])
              Text('搜索本机资料库')
                .fontSize(16)
                .fontColor($r('app.color.library_text_primary'))
              Text('艺人 / 专辑 / 歌曲 / 歌单 一起搜；这里的内容都已经在你本机')
                .fontSize(13)
                .fontColor($r('app.color.library_text_secondary'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: 90, left: 40, right: 40 })
          } else if (this.artists.length === 0 && this.albums.length === 0
            && this.songs.length === 0 && this.playlists.length === 0) {
            Column({ space: 8 }) {
              Text('资料库里没有找到相符的内容')
                .fontSize(15)
                .fontColor($r('app.color.library_text_secondary'))
            }
            .width('100%')
            .padding({ top: 90 })
          }

          if (this.artists.length > 0) {
            this.SectionTitle('艺人', this.totalArtists, this.artists.length)
            ForEach(this.artists, (artist: ArtistApiDto) => {
              this.RowCard(artist.coverPath, artist.name, $r('sys.symbol.person_crop_circle_fill_1'),
                artist.name, `${artist.albumCount} 张专辑 · ${artist.songCount} 首歌曲`, (): void => {
                  this.onOpenArtist(artist.name);
                })
            }, (artist: ArtistApiDto) => `sa-${artist.name}`)
          }

          if (this.albums.length > 0) {
            this.SectionTitle('专辑', this.totalAlbums, this.albums.length)
            ForEach(this.albums, (album: AlbumApiDto) => {
              this.RowCard(album.coverPath, `${album.name}${album.artist}`, $r('sys.symbol.dot_grid_2x2'),
                album.name, `${album.artist} · ${album.songCount} 首`, (): void => {
                  this.onOpenAlbum(album.name, album.artist);
                })
            }, (album: AlbumApiDto) => `sal-${album.name}|${album.artist}`)
          }

          if (this.songs.length > 0) {
            this.SectionTitle('歌曲', this.totalSongs, this.songs.length)
            ForEach(this.songs, (song: SongApiDto, index: number) => {
              SongListItem({
                song: song,
                onTogglePlay: (): void => {
                  PlayerDataUtil.togglePlayPause(this.appState);
                },
                onPlay: (): void => {
                  this.playSong(index);
                }
              })
            }, (song: SongApiDto, index: number) => `sso-${song.id}-${index}`)
          }

          if (this.playlists.length > 0) {
            this.SectionTitle('歌单', this.totalPlaylists, this.playlists.length)
            ForEach(this.playlists, (pl: ApplePlaylistRow) => {
              this.RowCard(pl.coverUrl, pl.name, $r('sys.symbol.list_checkmask'), pl.name,
                `${pl.trackCount} 首`, (): void => {
                  this.onOpenPlaylist(pl.id, pl.name);
                })
            }, (pl: ApplePlaylistRow) => `spl-${pl.id}`)
          }

          Blank().height(120)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    // 半透明材质浮层：透出下面的页面色彩，同时压一层淡色保证可读性
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundColor('#73000000')
  }
}
