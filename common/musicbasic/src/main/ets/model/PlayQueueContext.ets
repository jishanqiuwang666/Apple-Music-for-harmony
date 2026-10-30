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
 * 播放队列的来源上下文。
 *
 * 同一首歌可能既在专辑里、也在歌单里；「从哪里打开」决定了播放队列的内容，
 * 也决定「继续播放」进度记在谁身上（专辑与歌单各记一份，互不干扰）。
 */
export enum PlaySourceKind {
  /** 专辑详情页 / 专辑卡片。 */
  ALBUM = 'album',
  /** Apple Music 资料库歌单。 */
  PLAYLIST = 'playlist',
  /** 艺人详情页「播放全部」。 */
  ARTIST = 'artist',
  /** 全部歌曲页（含页内搜索结果）。 */
  LIBRARY = 'library',
  /** 搜索页（Apple Music 目录）。 */
  SEARCH = 'search'
}

/** 队列来源上下文：kind + 唯一 id（+ 展示用标题）。 */
export class PlayQueueContext {
  /** 来源类型。 */
  public kind: PlaySourceKind = PlaySourceKind.LIBRARY;
  /**
   * 来源唯一标识：
   * - album：`专辑名\u0001艺人名`
   * - playlist：Apple 歌单 ID（形如 p.xxxx）
   * - artist：艺人名
   * - library / search：空串
   */
  public id: string = '';
  /** 展示用标题（可为空）。 */
  public title: string = '';

  constructor(kind?: PlaySourceKind, id?: string, title?: string) {
    this.kind = kind !== undefined ? kind : PlaySourceKind.LIBRARY;
    this.id = id !== undefined ? id : '';
    this.title = title !== undefined ? title : '';
  }
}

/**
 * 上下文键工具：专辑 / 歌单「继续播放」进度的持久化键。
 *
 * 进度表以字符串主键存储，这里集中生成，避免各页面各写一套分隔符。
 * 分隔符用 \u0001（控制字符，专辑名里不可能出现），避免「专辑名里带 | 」之类的歧义。
 */
export class PlayContextKeys {
  /** 专辑键前缀。 */
  public static readonly ALBUM_PREFIX: string = 'a|';
  /** 歌单键前缀。 */
  public static readonly PLAYLIST_PREFIX: string = 'p|';
  /**
   * 上下文 id 会被写进 Preferences（播放会话快照的 contextId）。
   *
   * 注意：Preferences 底层是 XML 文件，值里只要出现 U+0001 这类控制字符，
   * 整个 store 下次启动就会被框架判定为损坏并改名成 .broken —— 会话直接丢失
   * （本仓库 ArtistAvatarStore 已经踩过一次同样的坑）。
   * 因此这里用 JSON 编码做「专辑 + 艺人」的组合：JSON 会把引号转义成
   * &quot;，对 XML 安全；同时不会因为名字里恰好含有分隔符而产生歧义。
   */
  public static albumId(album: string, artist: string): string {
    return JSON.stringify([album, artist]);
  }

  /** 专辑进度键。 */
  public static albumKey(album: string, artist: string): string {
    return PlayContextKeys.ALBUM_PREFIX + PlayContextKeys.albumId(album, artist);
  }

  /** 歌单进度键。 */
  public static playlistKey(playlistId: string): string {
    return PlayContextKeys.PLAYLIST_PREFIX + playlistId;
  }

  /** 专辑上下文对象。 */
  public static albumContext(album: string, artist: string): PlayQueueContext {
    return new PlayQueueContext(PlaySourceKind.ALBUM, PlayContextKeys.albumId(album, artist), album);
  }

  /** 歌单上下文对象。 */
  public static playlistContext(playlistId: string, name: string): PlayQueueContext {
    return new PlayQueueContext(PlaySourceKind.PLAYLIST, playlistId, name);
  }

  /** 艺人上下文对象。 */
  public static artistContext(artist: string): PlayQueueContext {
    return new PlayQueueContext(PlaySourceKind.ARTIST, artist, artist);
  }

  /** 全部歌曲上下文（不写专辑/歌单进度）。 */
  public static libraryContext(): PlayQueueContext {
    return new PlayQueueContext(PlaySourceKind.LIBRARY, '', '');
  }

  /** 搜索上下文（不写专辑/歌单进度）。 */
  public static searchContext(): PlayQueueContext {
    return new PlayQueueContext(PlaySourceKind.SEARCH, '', '');
  }

  /**
   * 该上下文对应的进度键；只有专辑与歌单需要记「继续播放」进度，
   * 其余一律返回空串（调用方据此跳过读写）。
   */
  public static progressKey(ctx: PlayQueueContext): string {
    if (ctx.kind === PlaySourceKind.ALBUM) {
      return PlayContextKeys.ALBUM_PREFIX + ctx.id;
    }
    if (ctx.kind === PlaySourceKind.PLAYLIST) {
      return PlayContextKeys.PLAYLIST_PREFIX + ctx.id;
    }
    return '';
  }
}
