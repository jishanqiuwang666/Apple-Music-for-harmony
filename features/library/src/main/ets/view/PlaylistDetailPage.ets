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
 * 歌单详情页：大封面 + 名称 + 曲目列表 + 「播放全部」。
 *
 * 曲目在进入本页时按需从 Apple Music 拉取，并确保它们已进入本地 songs 表
 * （见 {@link AppleLibrarySync.loadPlaylistSongs}），这样就能复用现有的
 * 「按歌曲 id 播放」链路，不需要改动播放器。
 */
import { AppStorageV2, curves, LengthMetrics } from '@kit.ArkUI';

import { HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions,
  ScrollEffectType, TitleBarContentOptions, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import { AppStorageKeys, AppleLibrarySync, Logger, MusicAppState, SongApiDto, WindowUtil } from 'musicbasic';
import { PlayerDataUtil } from 'player';
import { SongListItem, formatDuration } from './SongListItem';
import { HeroArtwork } from './HeroArtwork';
import { HeroMotion, HeroSourceRect } from '../util/HeroTransition';
import { PlaybackHelper, PlaylistDetailParam } from '../util/PlaybackHelper';
import { SongListDataSource } from '../model/ListDataSources';

const TAG: string = 'PlaylistDetail';

/** 歌单详情页（NavDestination）。 */
@ComponentV2
export struct PlaylistDetailPage {
  @Consumer('playlistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  /** 路由参数。 */
  @Param playlistId: string = '';
  @Param playlistName: string = '';
  @Param coverUrl: string = '';
  @Param declaredCount: number = 0;
  /** geometryTransition id：与歌单行的封面配对（与专辑/艺人页同一套共享元素）。 */
  @Param heroId: string = '';
  /** 点击位置快照：内容从这一行长出来 / 缩回去。 */
  @Param sourceRect: HeroSourceRect = new HeroSourceRect();
  /** 详情页大封面在窗口中的中心 y（生长动画的落点）。 */
  private targetCenterY: number = 0;
  private measured: boolean = false;
  /** 内容生长 / 收缩状态。 */
  @Local growDy: number = 0;
  @Local buttonDy: number = 0;
  @Local buttonOpacity: number = 0;
  @Local buttonScale: number = 0.96;
  @Local listDy: number = 0;
  @Local listOpacity: number = 0;
  /** 退出中：忽略重复返回。 */
  @Local isExiting: boolean = false;
  @Local songs: SongApiDto[] = [];
  @Local loading: boolean = true;
  @Local errorText: string = '';
  @Local titleFade: number = 1;
  @Local appState: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  private scroller: Scroller = new Scroller();
  private dataSource: SongListDataSource = new SongListDataSource();
  /** Handles the async load of this route's playlist. */
  private loadedId: string = '';
  /** 「继续播放」：上次停在这个歌单的哪一首（空串 = 没有进度）。 */
  @Local resumeUri: string = '';
  /** 黄色按钮的按压缩放（官方 spring）。 */
  @Local resumeScale: number = 1;
  /** 蓝色「播放全部」的按压缩放（与专辑详情页同款）。 */
  @Local playAllScale: number = 1;

  aboutToAppear(): void {
    this.appState.detailPageDepth += 1;
    this.load();
  }

  aboutToDisappear(): void {
    // 详情页层数 -1：外壳据此恢复顶部那两颗圆钮（主界面才显示）
    if (this.appState.detailPageDepth > 0) {
      this.appState.detailPageDepth -= 1;
    }
  }

  /** 量出大封面的位置，然后错峰生长（与专辑/艺人详情页完全同一套节奏）。 */
  private onHeroMeasured(area: Area): void {
    if (this.measured) {
      return;
    }
    this.measured = true;
    const y: number = area.globalPosition.y !== undefined
      ? Number.parseFloat(area.globalPosition.y.toString()) : 0;
    const height: number = Number.parseFloat(area.height.toString());
    this.targetCenterY = y + height / 2;
    this.growDy = this.sourceRect.width > 0 && this.sourceRect.height > 0
      ? this.sourceRect.centerY() - this.targetCenterY : 0;
    this.buttonDy = this.growDy;
    this.listDy = this.growDy;
    setTimeout(() => {
      if (this.isExiting) {
        return;
      }
      this.getUIContext().animateTo({
        duration: HeroMotion.ENTER_MS,
        curve: curves.springMotion(0.45, 0.75, 0.1)
      }, () => {
        this.buttonDy = 0;
        this.buttonOpacity = 1;
        this.buttonScale = 1;
      });
    }, HeroMotion.BUTTON_DELAY_MS);
    setTimeout(() => {
      if (this.isExiting) {
        return;
      }
      this.getUIContext().animateTo({
        duration: HeroMotion.ENTER_MS,
        curve: curves.springMotion(0.45, 0.75, 0.1)
      }, () => {
        this.listDy = 0;
        this.listOpacity = 1;
      });
    }, HeroMotion.BODY_DELAY_MS);
  }

  /** 共享元素返回：内容缩回被打的那一行，封面经 geometryTransition 飞回去。 */
  private animatedBack(): boolean {
    if (this.isExiting) {
      return true;
    }
    this.isExiting = true;
    this.getUIContext().animateTo({
      duration: HeroMotion.EXIT_MS,
      curve: Curve.Friction
    }, () => {
      this.buttonDy = this.growDy;
      this.buttonOpacity = 0;
      this.buttonScale = 0.96;
      this.listDy = this.growDy;
      this.listOpacity = 0;
      this.pageIndexInfos.pop(false);
    });
    return true;
  }

  /** 拉取歌单曲目（含把曲目补进本地表）。 */
  private async load(): Promise<void> {
    if (this.loadedId === this.playlistId) {
      return;
    }
    this.loadedId = this.playlistId;
    this.loading = true;
    this.errorText = '';
    try {
      const list: SongApiDto[] = await AppleLibrarySync.loadPlaylistSongs(this.playlistId);
      this.songs = list;
      this.dataSource.setRows(list);
      if (list.length === 0) {
        this.errorText = '这个歌单里没有可播放的歌曲';
      }
    } catch (err) {
      const message: string = (err as Error).message !== undefined ? (err as Error).message : '';
      Logger.error(TAG, `load failed ${message}`);
      this.errorText = message.length > 0 ? message : '加载歌单失败，请检查网络后重试';
      this.songs = [];
      this.dataSource.setRows([]);
    } finally {
      this.loading = false;
      this.refreshResume();
    }
  }

  /** 播放整张歌单（队列 = 歌单顺序，播完停止）。 */
  private playAll(): void {
    if (this.songs.length === 0) {
      return;
    }
    PlaybackHelper.playPlaylist(this.songs, this.playlistId, this.playlistName);
  }

  private playAt(index: number): void {
    PlaybackHelper.playPlaylistAt(this.songs, index, this.playlistId, this.playlistName);
  }

  /** 读取这个歌单的「继续播放」进度。 */
  private refreshResume(): void {
    this.resumeUri = PlaybackHelper.resumeSongUri(PlaybackHelper.playlistKey(this.playlistId));
  }

  /** 黄色按钮：回到上次停下的那一首与位置。 */
  private continuePlaylist(): void {
    if (this.resumeUri === '' || this.songs.length === 0) {
      return;
    }
    PlaybackHelper.resumePlaylist(this.songs, this.playlistId, this.playlistName);
  }

  /** 当前是否有正在播放的行（用于高亮）。 */
  private isCurrentRow(index: number): boolean {
    if (this.appState.selectIndex < 0 || this.appState.selectIndex >= this.appState.playQueueIds.length) {
      return false;
    }
    if (this.songs.length === 0 || index >= this.songs.length) {
      return false;
    }
    return this.appState.playQueueIds[this.appState.selectIndex] === this.songs[index].id;
  }

  private totalDuration(): number {
    let sum: number = 0;
    for (let i = 0; i < this.songs.length; i++) {
      sum += this.songs[i].duration;
    }
    return sum;
  }

  /** 官方返回手势：标题栏 MINI + 返回按钮。 */
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
    const content: TitleBarContentOptions = {
      // Official HDS title bar structure: system back button (built-in
      // press/highlight feedback) + main title over subtitle.
      title: {
        mainTitle: this.playlistName,
        subTitle: this.loading ? '正在读取…'
          : `${this.songs.length} 首` +
            (this.totalDuration() > 0 ? ' · ' + formatDuration(this.totalDuration()) : '')
      },
      backIcon: {
        icon: $r('sys.symbol.chevron_left'),
        action: (): void => {
          this.animatedBack();
        }
      }
    };
    return { enableComponentSafeArea: true, avoidLayoutSafeArea: true, style: style, content: content };
  }

  build() {
    // playlistDetailAlbumStyle：结构与「专辑详情页」逐项对齐 ——
    // 36vp 顶部留白 → 居中的 210 大方封面（共享元素）→ 两个圆形按钮（蓝播放全部 /
    // 黄继续播放）→ 曲目列表（每行一条分割线、整段跟着长出来，节奏与专辑页一致）。
    HdsNavDestination() {
      Stack() {
        Column() {
          List({ space: 2, scroller: this.scroller }) {
            // 标题栏（MINI 56vp）下方的留白，与专辑详情页同为 36vp
            ListItem() {
            }.height(36)

            // ── 大封面 + 两个圆形按钮 ──
            ListItem() {
              Column({ space: 20 }) {
                Stack() {
                  HeroArtwork({
                    coverPath: this.coverUrl,
                    seed: this.playlistName,
                    symbol: $r('sys.symbol.music_note_list'),
                    radius: 16,
                    heroWidth: 210,
                    heroHeight: 210,
                    heroId: this.heroId
                  })
                }
                .width(210)
                .height(210)
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.onHeroMeasured(newArea);
                })

                Row({ space: 16 }) {
                  // 蓝色「播放全部」
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r('sys.symbol.play_round_triangle_fill'))
                      .fontSize(26)
                      .fontColor([Color.White])
                  }
                  .width(52)
                  .height(52)
                  .padding(0)
                  .backgroundColor($r('app.color.library_accent'))
                  .enabled(this.songs.length > 0)
                  .opacity(this.songs.length > 0 ? 1 : 0.5)
                  .scale({ x: this.playAllScale * this.buttonScale, y: this.playAllScale * this.buttonScale })
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.playAllScale = 0.92;
                      });
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.playAllScale = 1;
                      });
                    }
                  })
                  .onClick(() => {
                    this.playAll();
                  })

                  // 黄色「继续播放」（回到上次停下的那一首与位置；没有进度时置灰）
                  Button({ type: ButtonType.Circle }) {
                    SymbolGlyph($r('sys.symbol.clock_arrow_2_circlepath_fill'))
                      .fontSize(24)
                      .fontColor(['#FF1A1A1A'])
                  }
                  .width(52)
                  .height(52)
                  .padding(0)
                  .backgroundColor($r('app.color.library_resume'))
                  .enabled(this.songs.length > 0 && this.resumeUri !== '')
                  .opacity(this.songs.length > 0 && this.resumeUri !== '' ? 1 : 0.4)
                  .scale({ x: this.resumeScale * this.buttonScale, y: this.resumeScale * this.buttonScale })
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.resumeScale = 0.92;
                      });
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                        this.resumeScale = 1;
                      });
                    }
                  })
                  .onClick(() => {
                    this.continuePlaylist();
                  })
                }
                .translate({ y: this.buttonDy })
                .opacity(this.buttonOpacity)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 16, right: 16, bottom: 18 })
            }

            // 读取中 / 出错：与专辑详情页的「占位行」同款，不做整页 spinner
            if (this.loading || this.errorText !== '') {
              ListItem() {
                Row({ space: 10 }) {
                  if (this.loading) {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color($r('app.color.library_accent'))
                  }
                  Text(this.loading ? '正在读取歌单曲目…' : this.errorText)
                    .fontSize(14)
                    .fontColor($r('app.color.library_text_secondary'))
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 18, bottom: 18 })
                .translate({ y: this.listDy })
                .opacity(this.listOpacity)
              }
            }

            LazyForEach(this.dataSource, (song: SongApiDto, index: number) => {
              ListItem() {
                Column() {
                  // 每行一条分割线，跳过第一条（与专辑详情页一致：封面下方不出线）
                  if (index > 0) {
                    Divider()
                      .strokeWidth(0.5)
                      .color($r('app.color.library_divider'))
                  }
                  SongListItem({
                    song: song,
                    isCurrent: this.isCurrentRow(index),
                    isPlaying: this.appState.isPlay,
                    isResume: this.resumeUri !== '' && song.src === this.resumeUri,
                    showCover: false,
                    onTogglePlay: (): void => {
                      PlayerDataUtil.togglePlayPause(this.appState);
                    },
                    onPlay: () => {
                      this.playAt(index);
                    }
                  })
                }
                .translate({ y: this.listDy })
                .opacity(this.listOpacity)
              }
            }, (song: SongApiDto, index: number) => `${song.id}-${index}`)
          }
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .clip(false)
          .cachedCount(3, true)
          .padding({ bottom: 90 })
          .onDidScroll((offset: number, state: ScrollState) => {
            const y = this.scroller.currentOffset().yOffset;
            this.titleFade = Math.max(0, Math.min(1, y / 130));
          })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    // 与专辑/艺人详情页同一套背景：封面铺满 + 毛玻璃，整页反射封面颜色
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .backgroundImage(this.coverUrl, ImageRepeat.NoRepeat)
    .backgroundImageSize({ width: '100%', height: '100%' })
    .backgroundBlurStyle(BlurStyle.Regular, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    // 共享元素转场取代系统转场；系统返回手势走同一套收缩动画
    .systemTransition(NavigationSystemTransitionType.NONE)
    .onBackPressed((): boolean => {
      return this.animatedBack();
    })
    .bindToScrollable([this.scroller])
    // Official window-mode handover: detail pages leave the immersive
    // full-screen layout so the HDS title bar (title + back icon) sits
    // below the status bar / camera cutout; returning to home restores
    // the immersive bleed-to-top layout.
    // （歌单详情页原先漏了这一段，标题栏就顶到屏幕最上沿 —— 用户反馈
    //   「注意左上角标签太高了」，与专辑/艺人详情页对齐）
    .onShown(() => {
      WindowUtil.getInstance().setImmersiveMode(false);
    })
    .onHidden(() => {
      WindowUtil.getInstance().setImmersiveMode(true);
    })
    // 与专辑详情页一致：不再 ignoreLayoutSafeArea(TOP)，
    // 否则标题栏会画进状态栏区域（专辑页没有这一句）。
    .width('100%')
    .height('100%')
  }
}

/** 歌单详情路由入口。 */
@Builder
export function PlaylistDetailPageBuilder(name: string, param: Object) {
  PlaylistDetailPage({
    playlistId: (param as PlaylistDetailParam)?.playlistId ?? '',
    playlistName: (param as PlaylistDetailParam)?.name ?? '',
    coverUrl: (param as PlaylistDetailParam)?.coverUrl ?? '',
    declaredCount: (param as PlaylistDetailParam)?.trackCount ?? 0,
    heroId: (param as PlaylistDetailParam)?.heroId ?? '',
    sourceRect: (param as PlaylistDetailParam)?.sourceRect ?? new HeroSourceRect()
  })
}
