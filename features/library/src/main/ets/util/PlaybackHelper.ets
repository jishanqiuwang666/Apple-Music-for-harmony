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
import {
  AlbumApiDto,
  AppStorageKeys,
  MusicAppState,
  MusicDbApi,
  PlaybackIntentState,
  PlaybackResumeRow,
  PlayContextKeys,
  PlayQueueContext,
  PlayQueueUtil,
  PlaySourceKind,
  SongApiDto
} from 'musicbasic';
import { HeroSourceRect } from './HeroTransition';

/** Route parameter for the artist detail page. */
export interface ArtistDetailParam {
  artistName?: string;
  /** geometryTransition id matching the tapped artist row portrait. */
  heroId?: string;
  /** Window-space snapshot of the tapped row (growth anchor). */
  sourceRect?: HeroSourceRect;
  /** User-picked avatar override already known by the source page. */
  artistAvatarPath?: string;
  /** 从搜索板块推入（返回时 pop 搜索栈）。 */
  fromSearch?: boolean;
  /** 目录艺人 id：直接按 id 取全部作品，不依赖名字解析。 */
  catalogArtistId?: string;
}

/** Route parameter for the album detail page. */
export interface AlbumDetailParam {
  albumName?: string;
  artistName?: string;
  /** geometryTransition id matching the tapped album cover. */
  heroId?: string;
  /** Window-space snapshot of the tapped cover (growth anchor). */
  sourceRect?: HeroSourceRect;
  /** True when pushed from the artist detail page's navigation stack. */
  fromArtistDetail?: boolean;
  /** 从搜索板块推入（返回时要 pop 搜索板块自己的栈）。 */
  fromSearch?: boolean;
  /** 目录专辑 id：专辑还没加入资料库时，详情页用它现拉曲目（可直接试听）。 */
  catalogAlbumId?: string;
  /**
   * 资料库专辑 id（形如 `l.xxxx`）：收藏专辑卡片点进来时带上，
   * 详情页直接 `/v1/me/library/albums/{id}/tracks` 拉曲目，
   * 不再依赖「专辑名 + 艺人名」匹配（Apple 与本地名称口径经常对不上 ⇒ 空白页）。
   */
  libraryAlbumId?: string;
  /**
   * 目录封面 URL：专辑还没入库时，详情页的大图与毛玻璃背景先用它，
   * 避免推入瞬间显示空占位图的闪帧（搜索页点封面进来时带）。
   */
  coverUrl?: string;
}

/** Route parameter for the playlist detail page. */
export interface PlaylistDetailParam {
  /** Apple Music 歌单 ID（形如 p.xxxx）。 */
  playlistId?: string;
  /** 歌单名称。 */
  name?: string;
  /** 封面 URL。 */
  coverUrl?: string;
  /** Apple 侧的曲目数（进入后以实际拉取结果为准）。 */
  trackCount?: number;
  /** geometryTransition id：与歌单行的封面配对（和专辑/艺人页同一套转场）。 */
  heroId?: string;
  /** 点击位置快照：详情页内容从这一行长出来 / 缩回去。 */
  sourceRect?: HeroSourceRect;
}

/**
 * 播放请求的唯一入口：页面只描述「听哪一批歌、从哪首开始、来自哪里」，
 * 真正的队列写入与播放器调度由 {@link PlaybackIntentState} + 播放壳层完成。
 *
 * 队列规则（用户 2026-09-12 定）：
 * - 点专辑（或专辑里的某首）→ 队列 = 该专辑全部曲目，播到最后一首停止；
 * - 点歌单（或歌单里的某首）→ 队列 = 该歌单曲目顺序，播完停止；
 * - 同一首歌既在专辑又在歌单时，「从哪里打开」决定队列 —— 用 context 表达，
 *   而不是反查歌曲所属专辑；
 * - 全部歌曲页 → 队列 = 当前列表（含页内搜索结果），播完停止。
 */
export class PlaybackHelper {
  private static getAppState(): MusicAppState {
    return AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  }

  private static getIntent(): PlaybackIntentState {
    return AppStorageV2.connect(PlaybackIntentState, AppStorageKeys.PLAYBACK_INTENT_STATE,
      () => new PlaybackIntentState())!;
  }

  /**
   * Replaces the play queue with the given songs and starts playback at an index.
   * @param songs Song DTOs that form the new queue.
   * @param startIndex Index of the first song to play.
   * @param openPlayerUi Whether to present the full-screen player.
   * @param context Queue source context (defaults to the all-songs list).
   * @param startPositionMs Position to seek to once prepared (0 = from the start).
   */
  public static playSongList(songs: SongApiDto[], startIndex: number, openPlayerUi: boolean,
    context?: PlayQueueContext, startPositionMs?: number): void {
    if (songs.length === 0) {
      return;
    }
    const appState = PlaybackHelper.getAppState();
    const intent = PlaybackHelper.getIntent();
    const ctx: PlayQueueContext = context !== undefined ? context : PlayContextKeys.libraryContext();
    // 登记临时曲目（不在 songs 表里，id 走 900000+ 区间）：
    // 播放链路按下标解析队列时，DB 查不到就回退到这张表，从而能播（含上/下一首）。
    for (let i = 0; i < songs.length; i++) {
      appState.registerTempSong(songs[i]);
    }
    PlayQueueUtil.apply(appState, songs, ctx);
    const clamped = startIndex < 0 ? 0 : (startIndex >= songs.length ? songs.length - 1 : startIndex);
    appState.selectIndex = clamped;
    intent.pendingPlaySongId = songs[clamped].id;
    intent.pendingPlaySongSrc = songs[clamped].src;
    intent.pendingStartPositionMs =
      startPositionMs !== undefined && startPositionMs > 0 ? startPositionMs : -1;
    intent.openPlayerUi = openPlayerUi;
    intent.requestVersion++;
  }

  /** 播放整张专辑（从第一首开始）。 */
  public static playAlbum(album: AlbumApiDto): void {
    const songs = MusicDbApi.getInstance().getSongsByAlbum(album.name, album.artist);
    PlaybackHelper.playSongList(songs, 0, true, PlayContextKeys.albumContext(album.name, album.artist));
  }

  /** 从专辑里某一首开始播（队列仍是整张专辑）。 */
  public static playAlbumAt(albumName: string, artist: string, index: number): void {
    const songs = MusicDbApi.getInstance().getSongsByAlbum(albumName, artist);
    PlaybackHelper.playSongList(songs, index, true, PlayContextKeys.albumContext(albumName, artist));
  }

  /**
   * 「继续播放」：回到上次停下的那首与位置。
   *
   * 传 `songs` 时按**页面当前显示的列表**定位（与 playAt 的队列完全一致）；
   * 不传则回落到「按专辑名 + 艺人名查库」。
   * @returns 该专辑是否有可续播的进度。
   */
  public static resumeAlbum(albumName: string, artist: string, songs?: SongApiDto[]): boolean {
    const list: SongApiDto[] = songs !== undefined && songs.length > 0
      ? songs : MusicDbApi.getInstance().getSongsByAlbum(albumName, artist);
    if (list.length === 0) {
      return false;
    }
    const resume: PlaybackResumeRow | undefined =
      MusicDbApi.getInstance().getResume(PlayContextKeys.albumKey(albumName, artist));
    const index: number = PlaybackHelper.indexOfUri(list, resume);
    const position: number = resume !== undefined ? resume.positionMs : 0;
    PlaybackHelper.playSongList(list, index, true,
      PlayContextKeys.albumContext(albumName, artist), position);
    return true;
  }

  /** 播放整个歌单（从第一首开始）。 */
  public static playPlaylist(songs: SongApiDto[], playlistId: string, name: string): void {
    PlaybackHelper.playSongList(songs, 0, true, PlayContextKeys.playlistContext(playlistId, name));
  }

  /** 从歌单里某一首开始播（队列仍是整个歌单）。 */
  public static playPlaylistAt(songs: SongApiDto[], index: number, playlistId: string, name: string): void {
    PlaybackHelper.playSongList(songs, index, true, PlayContextKeys.playlistContext(playlistId, name));
  }

  /** 「继续播放」歌单：回到上次停下的那首与位置。 */
  public static resumePlaylist(songs: SongApiDto[], playlistId: string, name: string): boolean {
    if (songs.length === 0) {
      return false;
    }
    const resume: PlaybackResumeRow | undefined =
      MusicDbApi.getInstance().getResume(PlayContextKeys.playlistKey(playlistId));
    const index: number = PlaybackHelper.indexOfUri(songs, resume);
    const position: number = resume !== undefined ? resume.positionMs : 0;
    PlaybackHelper.playSongList(songs, index, true,
      PlayContextKeys.playlistContext(playlistId, name), position);
    return true;
  }

  /** Plays every song of an artist (queue = that artist's library songs). */
  public static playArtistSongs(artist: string): void {
    const songs = MusicDbApi.getInstance().getSongsByArtist(artist);
    PlaybackHelper.playSongList(songs, 0, true, PlayContextKeys.artistContext(artist));
  }

  /**
   * 「继续播放」按钮可用性 / 黄标用：某来源上次停下的曲目 URI（无进度返回空串）。
   * @param contextKey 见 {@link PlayContextKeys}。
   */
  public static resumeSongUri(contextKey: string): string {
    const row: PlaybackResumeRow | undefined = MusicDbApi.getInstance().getResume(contextKey);
    return row !== undefined ? row.songUri : '';
  }

  /** 该来源是否有继续播放进度。 */
  public static hasResume(contextKey: string): boolean {
    return PlaybackHelper.resumeSongUri(contextKey) !== '';
  }

  /** 专辑键（页面生成 contextKey 用）。 */
  public static albumKey(albumName: string, artist: string): string {
    return PlayContextKeys.albumKey(albumName, artist);
  }

  /** 歌单键。 */
  public static playlistKey(playlistId: string): string {
    return PlayContextKeys.playlistKey(playlistId);
  }

  /** 队列来源类型常量（用于 UI 判断当前是否正在播某专辑/歌单）。 */
  public static isPlayingContext(kind: PlaySourceKind, id: string): boolean {
    const appState = PlaybackHelper.getAppState();
    return appState.playContextKind === kind && appState.playContextId === id;
  }

  /** 在曲目列表里找上次停下的那首的索引。 */
  private static indexOfUri(songs: SongApiDto[], resume: PlaybackResumeRow | undefined): number {
    if (resume === undefined || resume.songUri === '') {
      return 0;
    }
    for (let i = 0; i < songs.length; i++) {
      if (songs[i].src === resume.songUri) {
        return i;
      }
    }
    return 0;
  }
}
