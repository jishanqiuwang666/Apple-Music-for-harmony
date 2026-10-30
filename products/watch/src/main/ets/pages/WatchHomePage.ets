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

import {
  AlbumApiDto,
  ArtistApiDto,
  LibraryMeta,
  MetaSong,
  MusicDbApi,
  MusicTransferService,
  SongApiDto
} from 'musicbasic';
import { PlaybackHelper } from 'library';

/** Navigation stack of the watch home page. */
enum WatchPage {
  ROOT = 0,
  ARTISTS = 1,
  ALBUMS = 2,
  SONGS = 3,
  ARTIST = 4,
  ALBUM = 5
}

/** Watch home: dual-view library (local / phone) with the same hierarchy as the phone. */
@ComponentV2
export struct WatchHomePage {
  /** true = browsing the phone library (via distributed snapshot). */
  @Local showPhoneSource: boolean = false;
  /** Navigation stack state. */
  @Local page: WatchPage = WatchPage.ROOT;
  /** Selected artist for the artist detail page. */
  @Local selectedArtist: string = '';
  /** Selected album (name + artist) for the album detail page. */
  @Local selectedAlbumName: string = '';
  @Local selectedAlbumArtist: string = '';
  /** Phone library snapshot (populated by the KV channel). */
  @Local phoneMeta: LibraryMeta = new LibraryMeta();
  /** Transfer progress state. */
  @Local transferring: boolean = false;
  @Local transferText: string = '';
  @Local transferPercent: number = 0;

  aboutToAppear(): void {
    const service = MusicTransferService.getInstance();
    service.onLibraryMeta((meta: LibraryMeta) => {
      this.phoneMeta = meta;
    });
    service.onTransferProgress((doneCount: number, totalCount: number, currentTitle: string) => {
      this.transferring = true;
      this.transferPercent = totalCount > 0 ? Math.round(doneCount * 100 / totalCount) : 0;
      this.transferText = `${doneCount}/${totalCount} ${currentTitle}`;
      if (doneCount >= totalCount) {
        setTimeout(() => {
          this.transferring = false;
        }, 1500);
      }
    });
  }

  /** Local artists from the RDB mirror. */
  private localArtists(): ArtistApiDto[] {
    return MusicDbApi.getInstance().getArtists();
  }

  /** Local albums from the RDB mirror. */
  private localAlbums(): AlbumApiDto[] {
    return MusicDbApi.getInstance().getAlbums();
  }

  /** Local songs from the RDB mirror. */
  private localSongs(): SongApiDto[] {
    return MusicDbApi.getInstance().getSongList();
  }

  /** Phone artists grouped from the snapshot. */
  private phoneArtists(): string[] {
    const names = new Set<string>();
    for (let i = 0; i < this.phoneMeta.songs.length; i++) {
      names.add(this.phoneMeta.songs[i].artist);
    }
    const out: string[] = [];
    names.forEach((name: string) => out.push(name));
    out.sort((a: string, b: string) => a.localeCompare(b));
    return out;
  }

  /** Phone albums grouped from the snapshot. */
  private phoneAlbums(): AlbumApiDto[] {
    const keys = new Set<string>();
    for (let i = 0; i < this.phoneMeta.songs.length; i++) {
      keys.add(`${this.phoneMeta.songs[i].album}|||${this.phoneMeta.songs[i].artist}`);
    }
    const out: AlbumApiDto[] = [];
    keys.forEach((key: string) => {
      const sep = key.lastIndexOf('|||');
      const album = new AlbumApiDto();
      album.name = key.substring(0, sep);
      album.artist = key.substring(sep + 3);
      out.push(album);
    });
    out.sort((a: AlbumApiDto, b: AlbumApiDto) => a.name.localeCompare(b.name));
    return out;
  }

  /** Phone songs of an album. */
  private phoneSongsOfAlbum(album: string, artist: string): MetaSong[] {
    return this.phoneMeta.songs.filter((song: MetaSong) => song.album === album && song.artist === artist);
  }

  /** Phone songs of an artist. */
  private phoneSongsOfArtist(artist: string): MetaSong[] {
    return this.phoneMeta.songs.filter((song: MetaSong) => song.artist === artist);
  }

  /** Phone albums of an artist. */
  private phoneAlbumsOfArtist(artist: string): AlbumApiDto[] {
    const keys = new Set<string>();
    for (let i = 0; i < this.phoneMeta.songs.length; i++) {
      const song = this.phoneMeta.songs[i];
      if (song.artist === artist) {
        keys.add(`${song.album}|||${song.artist}`);
      }
    }
    const out: AlbumApiDto[] = [];
    keys.forEach((key: string) => {
      const sep = key.lastIndexOf('|||');
      const album = new AlbumApiDto();
      album.name = key.substring(0, sep);
      album.artist = key.substring(sep + 3);
      out.push(album);
    });
    out.sort((a: AlbumApiDto, b: AlbumApiDto) => a.name.localeCompare(b.name));
    return out;
  }

  // ---- Transfer actions ----

  /** Requests pulling every song of the given artist from the phone. */
  private async sendArtist(artist: string): Promise<void> {
    const songs = this.phoneSongsOfArtist(artist);
    const ids = songs.map((song: MetaSong) => song.id);
    await MusicTransferService.getInstance().requestTransfer(ids);
  }

  /** Requests pulling one album from the phone. */
  private async sendAlbum(album: string, artist: string): Promise<void> {
    const songs = this.phoneSongsOfAlbum(album, artist);
    const ids = songs.map((song: MetaSong) => song.id);
    await MusicTransferService.getInstance().requestTransfer(ids);
  }

  // ---- Playback actions (local only) ----

  private playLocalSongList(songs: SongApiDto[], index: number): void {
    PlaybackHelper.playSongList(songs, index, false);
  }

  // ---- Navigation ----

  private push(page: WatchPage): void {
    this.page = page;
  }

  private pop(): void {
    this.page = WatchPage.ROOT;
  }

  @Builder
  private SectionEntry(icon: Resource, title: string, target: WatchPage) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor(['#FFFFFF'])
      Text(title)
        .fontSize(17)
        .fontColor('#FFFFFF')
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor(['#80FFFFFF'])
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      this.push(target);
    })
  }

  /** Top switcher + progress bar. */
  @Builder
  private Header() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('本机音乐')
          .fontSize(14)
          .fontColor(this.showPhoneSource ? '#80FFFFFF' : '#FFFFFF')
          .fontWeight(this.showPhoneSource ? FontWeight.Regular : FontWeight.Bold)
          .onClick(() => {
            this.showPhoneSource = false;
            this.pop();
          })
        Text('手机音乐')
          .fontSize(14)
          .fontColor(this.showPhoneSource ? '#FFFFFF' : '#80FFFFFF')
          .fontWeight(this.showPhoneSource ? FontWeight.Bold : FontWeight.Regular)
          .onClick(() => {
            this.showPhoneSource = true;
            this.pop();
          })
        Blank()
        if (this.transferring) {
          Progress({ value: this.transferPercent, total: 100, type: ProgressType.Ring })
            .width(26)
            .height(26)
            .color('#0A59F7')
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10 })

      if (this.transferring) {
        Text(this.transferText)
          .fontSize(11)
          .fontColor('#80FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 14, right: 14 })
      }
    }
  }

  @Builder
  private BackRow(title: string) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(18)
        .fontColor(['#FFFFFF'])
        .onClick(() => {
          this.pop();
        })
      Text(title)
        .fontSize(15)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
  }

  build() {
    Column() {
      if (this.page !== WatchPage.ROOT) {
        this.BackRow(this.pageTitle())
      } else {
        this.Header()
      }

      List({ space: 2 }) {
        this.renderPageContent()
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  private pageTitle(): string {
    if (this.page === WatchPage.ARTIST) {
      return this.selectedArtist;
    }
    if (this.page === WatchPage.ALBUM) {
      return this.selectedAlbumName;
    }
    return this.showPhoneSource ? '手机音乐' : '本机音乐';
  }

  @Builder
  private renderPageContent() {
    if (this.page === WatchPage.ROOT) {
      this.SectionEntry($r('sys.symbol.person_crop_circle_fill_1'), '艺人', WatchPage.ARTISTS)
      this.SectionEntry($r('sys.symbol.dot_grid_2x2'), '专辑', WatchPage.ALBUMS)
      this.SectionEntry($r('sys.symbol.music_note_list'), '全部歌曲', WatchPage.SONGS)
    } else if (this.page === WatchPage.ARTISTS) {
      if (this.showPhoneSource) {
        ForEach(this.phoneArtists(), (artist: string) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(artist)
                .fontSize(16)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Button('发送全部', { type: ButtonType.Capsule })
                .height(26)
                .fontSize(11)
                .backgroundColor('#0A59F7')
                .onClick(() => {
                  this.sendArtist(artist);
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .onClick(() => {
              this.selectedArtist = artist;
              this.push(WatchPage.ARTIST);
            })
          }
        }, (artist: string) => `pa-${artist}`)
      } else {
        ForEach(this.localArtists(), (artist: ArtistApiDto) => {
          ListItem() {
            Text(artist.name)
              .fontSize(16)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .onClick(() => {
                this.selectedArtist = artist.name;
                this.push(WatchPage.ARTIST);
              })
          }
        }, (artist: ArtistApiDto) => `la-${artist.name}`)
      }
    } else if (this.page === WatchPage.ALBUMS) {
      if (this.showPhoneSource) {
        ForEach(this.phoneAlbums(), (album: AlbumApiDto) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(album.name)
                .fontSize(16)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Button('发送', { type: ButtonType.Capsule })
                .height(26)
                .fontSize(11)
                .backgroundColor('#0A59F7')
                .onClick(() => {
                  this.sendAlbum(album.name, album.artist);
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .onClick(() => {
              this.selectedAlbumName = album.name;
              this.selectedAlbumArtist = album.artist;
              this.push(WatchPage.ALBUM);
            })
          }
        }, (album: AlbumApiDto) => `pa-${album.name}-${album.artist}`)
      } else {
        ForEach(this.localAlbums(), (album: AlbumApiDto) => {
          ListItem() {
            Text(album.name)
              .fontSize(16)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .onClick(() => {
                this.selectedAlbumName = album.name;
                this.selectedAlbumArtist = album.artist;
                this.push(WatchPage.ALBUM);
              })
          }
        }, (album: AlbumApiDto) => `la-${album.name}-${album.artist}`)
      }
    } else if (this.page === WatchPage.SONGS) {
      if (this.showPhoneSource) {
        ForEach(this.phoneMeta.songs, (song: MetaSong) => {
          ListItem() {
            Text(`${song.title} · ${song.artist}`)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          }
        }, (song: MetaSong) => `ps-${song.id}`)
      } else {
        ForEach(this.localSongs(), (song: SongApiDto, index: number) => {
          ListItem() {
            Text(`${song.title} · ${song.singer}`)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .onClick(() => {
                this.playLocalSongList(this.localSongs(), index);
              })
          }
        }, (song: SongApiDto, index: number) => `ls-${song.id}-${index}`)
      }
    } else if (this.page === WatchPage.ARTIST) {
      if (this.showPhoneSource) {
        ForEach(this.phoneAlbumsOfArtist(this.selectedArtist), (album: AlbumApiDto) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(album.name)
                .fontSize(15)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Button('发送', { type: ButtonType.Capsule })
                .height(24)
                .fontSize(11)
                .backgroundColor('#0A59F7')
                .onClick(() => {
                  this.sendAlbum(album.name, this.selectedArtist);
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .onClick(() => {
              this.selectedAlbumName = album.name;
              this.selectedAlbumArtist = this.selectedArtist;
              this.push(WatchPage.ALBUM);
            })
          }
        }, (album: AlbumApiDto) => `pd-${album.name}-${album.artist}`)
      } else {
        // Local artist: play all of the artist's songs.
        ListItem() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
              .fontSize(20)
              .fontColor(['#0A59F7'])
            Text('播放全部')
              .fontSize(15)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .onClick(() => {
            const songs = MusicDbApi.getInstance().getSongsByArtist(this.selectedArtist);
            this.playLocalSongList(songs, 0);
          })
        }
        ForEach(this.localAlbums().filter((album: AlbumApiDto) => album.artist === this.selectedArtist),
          (album: AlbumApiDto) => {
            ListItem() {
              Text(album.name)
                .fontSize(15)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .onClick(() => {
                  this.selectedAlbumName = album.name;
                  this.selectedAlbumArtist = album.artist;
                  this.push(WatchPage.ALBUM);
                })
            }
          }, (album: AlbumApiDto) => `lad-${album.name}-${album.artist}`)
      }
    } else if (this.page === WatchPage.ALBUM) {
      if (this.showPhoneSource) {
        // Phone album: pull action only (files live on the phone).
        ListItem() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.arrow_down_circle'))
              .fontSize(20)
              .fontColor(['#0A59F7'])
            Text('发送到手表')
              .fontSize(15)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .onClick(() => {
            this.sendAlbum(this.selectedAlbumName, this.selectedAlbumArtist);
          })
        }
        ForEach(this.phoneSongsOfAlbum(this.selectedAlbumName, this.selectedAlbumArtist), (song: MetaSong) => {
          ListItem() {
            Text(song.title)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          }
        }, (song: MetaSong) => `pas-${song.id}`)
      } else {
        // Local album: play tracks in order.
        ListItem() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
              .fontSize(20)
              .fontColor(['#0A59F7'])
            Text('播放全部')
              .fontSize(15)
              .fontColor('#FFFFFF')
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .onClick(() => {
            const songs = MusicDbApi.getInstance().getSongsByAlbum(this.selectedAlbumName, this.selectedAlbumArtist);
            this.playLocalSongList(songs, 0);
          })
        }
        ForEach(MusicDbApi.getInstance().getSongsByAlbum(this.selectedAlbumName, this.selectedAlbumArtist),
          (song: SongApiDto) => {
            ListItem() {
              Text(song.title)
                .fontSize(14)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            }
          }, (song: SongApiDto) => `las-${song.id}`)
      }
    }
  }
}
