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
 * 歌单板块：账号里自己建的 Apple Music 资料库歌单。
 *
 * 只同步元数据（{@link ApplePlaylistRow}），曲目在打开歌单时按需拉取
 * （{@link AppleLibrarySync.loadPlaylistSongs}），避免启动时为一个歌单
 * 发一次请求。
 */
import { curves, LengthMetrics } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions, ScrollEffectType, TitleBarStyleOptions } from '@hms.hds.hdsBaseComponent';
import {
  AppleAuthState,
  AppleLibrarySync,
  ApplePlaylistRow,
  LibrarySignal,
  MusicDatabase,
  MusicDbApi,
  getWindowInfoState,
  Logger,
  SyncResult,
  WindowInfo
} from 'musicbasic';
import { HeroMotion, HeroSourceRect } from '../util/HeroTransition';
import { HeroArtwork } from './HeroArtwork';
import { CoverPlaceholder } from './SongListItem';
import { HomeBack } from '../util/HomeBack';
import { FlowLightRegistry } from '../util/FlowLightRegistry';
import { PlaylistDetailParam } from '../util/PlaybackHelper';

const TAG: string = 'PlaylistsPage';

/** 歌单列表行的数据源（懒加载，只创建可见行）。 */
class PlaylistDataSource implements IDataSource {
  private rows: ApplePlaylistRow[] = [];
  private listeners: DataChangeListener[] = [];

  public setRows(rows: ApplePlaylistRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): ApplePlaylistRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
}

/** 歌单封面的共享元素 id（行与详情页必须用同一个字符串）。 */
function playlistHeroIdOf(id: string): string {
  return `playlist-hero-${id}`;
}

/** 歌单行：封面 + 名称 + 曲目数 + 展开箭头；按压有官方 pressShadow。 */
@ComponentV2
struct PlaylistRowItem {
  @Param playlist: ApplePlaylistRow = new ApplePlaylistRow();
  @Event onOpen: (sourceRect: HeroSourceRect) => void = (sourceRect: HeroSourceRect) => {
  };
  @Local pressed: boolean = false;
  /** 行在窗口中的位置（详情页生长/缩回的锚点）。 */
  @Local rowRect: HeroSourceRect = new HeroSourceRect();

  build() {
    Button() {
      Row({ space: 12 }) {
        HeroArtwork({
          coverPath: this.playlist.coverUrl,
          seed: this.playlist.name,
          symbol: $r('sys.symbol.music_note_list'),
          radius: 8,
          heroWidth: 52,
          heroHeight: 52,
          heroId: playlistHeroIdOf(this.playlist.id)
        })
        Column({ space: 2 }) {
          Text(this.playlist.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.library_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.playlist.trackCount > 0 ? `${this.playlist.trackCount} 首歌曲` : '打开查看曲目')
            .fontSize(13)
            .fontColor($r('app.color.library_text_secondary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.library_text_secondary')])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
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
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rowRect = HeroSourceRect.fromArea(newArea);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onOpen(this.rowRect);
    })
  }
}

/** 歌单板块首页（NavDestination）。 */
@ComponentV2
export struct PlaylistsPage {
  /** 转场守卫：动画期间忽略重复点击。 */
  private isOpening: boolean = false;

  /** 本 tab 自己的导航栈。 */
  @Consumer('playlistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();
  @Local playlists: ApplePlaylistRow[] = [];
  @Local filtered: ApplePlaylistRow[] = [];
  @Local query: string = '';
  @Local loading: boolean = false;
  @Local syncing: boolean = false;
  @Local authState: AppleAuthState = AppleAuthState.getInstance();
  @Local librarySignal: LibrarySignal = LibrarySignal.getInstance();
  @Local windowInfo: WindowInfo = getWindowInfoState();
  @Local titleFade: number = 1;
  @Local searchLit: boolean = false;
  @Local searchScale: number = 1;
  private scroller: Scroller = new Scroller();
  private dataSource: PlaylistDataSource = new PlaylistDataSource();

  aboutToAppear(): void {
    this.refresh();
    MusicDatabase.getInstance().whenReady(() => {
      setTimeout(() => {
        this.refresh();
      }, 50);
    });
  }

  aboutToDisappear(): void {
  }

  /** 资料库变化（同步完成）后刷新歌单列表。 */
  @Monitor('librarySignal.version')
  onLibraryChanged(): void {
    this.refresh();
  }

  /** 从内存镜像读歌单并套用搜索过滤。 */
  private refresh(): void {
    this.playlists = MusicDbApi.getInstance().getApplePlaylists();
    this.applyFilter();
  }

  private applyFilter(): void {
    const q = this.query.trim().toLowerCase();
    if (q === '') {
      this.filtered = this.playlists;
    } else {
      this.filtered = this.playlists.filter((p: ApplePlaylistRow) => p.name.toLowerCase().includes(q));
    }
    this.dataSource.setRows(this.filtered);
  }

  /** 打开歌单详情：与专辑/艺人页同一套共享元素 + 生长动画。 */
  private openPlaylist(playlist: ApplePlaylistRow, sourceRect: HeroSourceRect): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    const param: PlaylistDetailParam = {
      playlistId: playlist.id,
      name: playlist.name,
      coverUrl: playlist.coverUrl,
      trackCount: playlist.trackCount,
      heroId: playlistHeroIdOf(playlist.id),
      sourceRect: sourceRect
    };
    this.getUIContext().animateTo({
      duration: HeroMotion.ENTER_MS,
      curve: curves.springMotion(0.45, 0.75, 0.1)
    }, () => {
      this.pageIndexInfos.pushPathByName('PlaylistDetail', param, false);
    });
    setTimeout(() => {
      this.isOpening = false;
    }, HeroMotion.OPEN_GUARD_MS);
  }

  /** 手动重新同步歌单（首次同步后新增的歌单）。 */
  private async syncPlaylists(): Promise<void> {
    if (this.syncing) {
      return;
    }
    if (!this.authState.authorized) {
      this.authState.openLogin();
      return;
    }
    this.syncing = true;
    try {
      const result: SyncResult = await AppleLibrarySync.syncPlaylists();
      this.refresh();
      const message = result.ok ? `歌单已同步：${result.songs} 个` : `同步失败：${result.message}`;
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.error('PlaylistsPage', `syncPlaylists failed ${JSON.stringify(err)}`);
      this.getUIContext().getPromptAction().showToast({ message: '歌单同步失败，请检查网络' });
    } finally {
      this.syncing = false;
    }
  }

  /** 标题栏：搜索框 + 同步按钮，官方 GRADIENT_BLUR。 */
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

  @Builder
  private LibraryTitle() {
    Column({ space: 4 }) {
      Text('歌单')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(`${this.playlists.length} 个歌单`)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .opacity(this.titleFade)
  }

  @Builder
  private EmptyState() {
    Column({ space: 16 }) {
      CoverPlaceholder({ seed: 'playlists', radius: 32, symbol: $r('sys.symbol.music_note_list') })
        .width(120)
        .height(120)
      Text(this.query === '' ? '还没有歌单' : '未找到相关歌单')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(this.query === ''
        ? '在 Apple Music 里建的歌单会同步到这里'
        : '换个关键词试试')
        .fontSize(14)
        .fontColor($r('app.color.library_text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(20)
        .padding({ left: 32, right: 32 })
      if (this.query === '') {
        Button({ type: ButtonType.Capsule }) {
          Text(this.authState.authorized ? '同步歌单' : '登录 Apple Music')
            .fontSize(15)
            .fontColor(Color.White)
        }
        .height(42)
        .padding({ left: 28, right: 28 })
        .backgroundColor($r('app.color.library_accent'))
        .onClick(() => {
          if (this.authState.authorized) {
            this.syncPlaylists();
          } else {
            this.authState.openLogin();
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    HdsNavDestination() {
      Stack() {
        Column()
          .width(1)
          .height(1)
          .defaultFocus(true)
        Stack() {
          if (this.filtered.length === 0) {
            this.EmptyState()
          } else {
            List({ space: 2, scroller: this.scroller }) {
              ListItem() {
              }.height(96)
              ListItem() {
                this.LibraryTitle()
              }
              LazyForEach(this.dataSource, (playlist: ApplePlaylistRow, index: number) => {
                ListItem() {
                  Column() {
                    if (index > 0) {
                      Divider()
                        .strokeWidth(0.5)
                        .color($r('app.color.library_divider'))
                    }
                    PlaylistRowItem({
                      playlist: playlist,
                      onOpen: () => {
                        this.openPlaylist(playlist, new HeroSourceRect());
                      }
                    })
                  }
                }
              }, (playlist: ApplePlaylistRow, index: number) => `${playlist.id}-${index}`)
            }
            .width('100%')
            .height('100%')
            .clip(false)
            .cachedCount(3, true)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .padding({ bottom: 90 })
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
      .width('100%')
      .height('100%')
    }
    .titleBar(this.titleBarOptions())
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .backgroundColor($r('sys.color.ohos_id_color_background_transparent'))
    .hideBackButton(true)
    .hideToolBar(true)
    .bindToScrollable([this.scroller])
    .systemTransition(NavigationSystemTransitionType.NONE)
    // 首页是这条栈的第一页：系统返回默认会把它也弹掉 → 栈空 → 只剩底色
    // （深色模式下就是用户看到的「黑屏，只能重启」）。这里统一消费返回事件：
    // 抽屉开着先关抽屉，否则回桌面（音乐继续后台播放）。
    .onBackPressed((): boolean => {
      return HomeBack.handle(this.getUIContext());
    })
    // 页面重新可见时刷新歌单（流光已由 App 根层统一持有，不在这里管）。
    .onShown(() => {
      this.refresh();
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}

/** 歌单 tab 的 HdsNavigation 壳层（home 内容为空，首屏直接 push NavDestination）。 */
@ComponentV2
export struct PlaylistTabShell {
  @Consumer('playlistNavStack') pageIndexInfos: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.pageIndexInfos.disableAnimation(true);
    if (this.pageIndexInfos.size() === 0) {
      this.pageIndexInfos.pushPathByName('PlaylistHome', undefined, false);
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

/** 歌单首页路由入口。 */
@Builder
export function PlaylistHomePageBuilder(name: string, param: Object) {
  PlaylistsPage()
}
