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

import { AppStorageV2, LengthMetrics } from '@kit.ArkUI';

import { HdsNavigation, HdsNavigationTitleBarOptions, HdsNavigationTitleMode, ScrollEffectType, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import {
  AppStorageKeys,
  getWindowInfoState,
  LibrarySignal,
  MusicAppState,
  MusicDatabase,
  MusicDbApi,
  SongApiDto,
  WindowInfo
} from 'musicbasic';
import { PlaybackHelper } from '../util/PlaybackHelper';
import { FlowLightRegistry } from '../util/FlowLightRegistry';
import { PlayerDataUtil } from 'player';
import { SongListItem } from './SongListItem';
import { SongListDataSource } from '../model/ListDataSources';

/** All-songs section: full library list with in-memory search. */
@ComponentV2
export struct AllSongsPage {
  /** Navigation stack from the phone shell (each tab owns its stack). */
  @Consumer('songNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  @Local allSongs: SongApiDto[] = [];
  @Local filtered: SongApiDto[] = [];
  @Local query: string = '';
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** Library-change signal: refreshes after share-imports while the page stays alive. */
  @Local librarySignal: LibrarySignal = LibrarySignal.getInstance();
  /** Window metrics: status-bar inset for the search bar. */
  @Local windowInfo: WindowInfo = getWindowInfoState();
  /** List scroller shared with the HDS title bar (GRADIENT_BLUR sync). */
  private scroller: Scroller = new Scroller();
  /** Lazy data source: only visible rows are created (official optimization). */
  private songDataSource: SongListDataSource = new SongListDataSource();

  aboutToAppear(): void {
    this.allSongs = MusicDbApi.getInstance().getSongList();
    this.applyFilter();
    // Cold start: refresh directly once the DB is ready (see ArtistsPage).
    MusicDatabase.getInstance().whenReady(() => {
      setTimeout(() => {
        this.allSongs = MusicDbApi.getInstance().getSongList();
        this.applyFilter();
      }, 50);
    });
  }

  aboutToDisappear(): void {
  }

  /** Refreshes the song list when the library changes (e.g. share import). */
  @Monitor('librarySignal.version')
  onLibraryChanged(): void {
    this.allSongs = MusicDbApi.getInstance().getSongList();
    this.applyFilter();
  }

  private applyFilter(): void {
    const q = this.query.trim().toLowerCase();
    if (q === '') {
      this.filtered = this.allSongs;
    } else {
      this.filtered = this.allSongs.filter((song: SongApiDto) => {
        return `${song.title}`.toLowerCase().includes(q) ||
          `${song.singer}`.toLowerCase().includes(q) ||
          song.album.toLowerCase().includes(q);
      });
    }
    this.songDataSource.setRows(this.filtered);
  }

  /** Plays the tapped track; the current filter result is the queue. */
  private playAt(index: number): void {
    PlaybackHelper.playSongList(this.filtered, index, true);
  }

  /**
   * HDS title bar with the official GRADIENT_BLUR (same tuned profile as
   * the artists home); the search bar sits inside the title bar so it
   * stays readable above the blur mask.
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

  /** Apple Music-style library title fade driven by the list scroll. */
  @Local titleFade: number = 1;

  /** Apple Music-style large library title: big bold name over a count
   * subtitle; fades out as the list scrolls under the title bar. */
  @Builder
  private LibraryTitle() {
    Column({ space: 4 }) {
      Text('歌曲')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(`${this.allSongs.length} 首歌曲`)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .opacity(this.titleFade)
  }

  build() {
    Stack() {
      // Default-focus anchor: a transparent 1vp box that takes the page's
      // default focus instead of the search field, so switching to this tab
      // never opens the keyboard by itself (a non-input component does not
      // summon the soft keyboard when focused).
      Column()
        .width(1)
        .height(1)
        .defaultFocus(true)
      HdsNavigation(this.pageIndexInfos) {
      Stack() {
        if (this.filtered.length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.music_note_list'))
              .fontSize(56)
              .fontColor([$r('app.color.library_text_secondary')])
            Text(this.query === '' ? $r('app.string.library_no_music') : '未找到相关歌曲')
              .fontSize(14)
              .fontColor($r('app.color.library_text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // List: native Spring edge effect provides the rubber-band
          // overscroll at both edges (official default, no custom code).
          List({ space: 2, scroller: this.scroller }) {
            // Spacer item: keeps the large title below the toolbar/search
            // row (which starts at 64vp and is ~48vp tall), but scrolls out
            // so rows reach the screen top.
            ListItem() {
            }.height(96)
            ListItem() {
              this.LibraryTitle()
            }
            LazyForEach(this.songDataSource, (song: SongApiDto, index: number) => {
              ListItem() {
                SongListItem({
                  song: song,
                  isCurrent: this.appState.selectIndex === index &&
                    this.appState.playQueueIds.length === this.filtered.length &&
                    this.filtered[index].id === this.appState.playQueueIds[this.appState.selectIndex],
                  isPlaying: this.appState.isPlay,
                  onTogglePlay: (): void => {
                    PlayerDataUtil.togglePlayPause(this.appState);
                  },
                  onPlay: () => {
                    this.playAt(index);
                  }
                })
              }
            }, (song: SongApiDto, index: number) => `${song.id}-${index}`)
          }
          .width('100%')
          .height('100%')
          .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
          // No clipping + cached rows: content keeps scrolling under the
          // title bar into the GRADIENT_BLUR mask without disappearing.
          .clip(false)
          .cachedCount(3, true)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .divider({ strokeWidth: 0.5, color: $r('app.color.library_divider') })
          // Bottom clearance for the floating HDS bar (52vp bar + 34vp
          // bottom margin + 4vp breathing room).
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
        }
      }
      .width('100%')
      .height('100%')
      }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideBackButton(true)
    .hideToolBar(true)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
