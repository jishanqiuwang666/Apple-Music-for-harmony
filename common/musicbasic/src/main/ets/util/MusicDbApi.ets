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


import { AlbumApiDto, ArtistApiDto, SongApiDto } from '../api/MusicApiDtos';
import { PlaybackResumeRow } from '../data/PlaybackResumeRow';
import { MusicSongRow } from '../data/MusicSongRow';
import { ArtistRow } from '../data/ArtistRow';
import { AlbumRow } from '../data/AlbumRow';
import { ApplePlaylistRow } from '../data/ApplePlaylistRow';
import { MusicDatabase } from '../db/MusicDatabase';

/**
 * Read-only API over {@link MusicDatabase}: songs, artists, albums, and DTO mapping.
 * Synchronous reads come from the in-memory mirror; the database itself is
 * populated by {@link MusicLibraryScanner}.
 */
export class MusicDbApi {
  /** Singleton instance holder. */
  private static instance: MusicDbApi | undefined = undefined;
  /** Backing library database (RDB + in-memory mirror). */
  private readonly database: MusicDatabase;

  /** Wires this API to the shared {@link MusicDatabase}. */
  private constructor() {
    this.database = MusicDatabase.getInstance();
  }

  /**
   * @returns Shared {@link MusicDbApi} instance.
   */
  public static getInstance(): MusicDbApi {
    if (MusicDbApi.instance === undefined) {
      MusicDbApi.instance = new MusicDbApi();
    }
    return MusicDbApi.instance;
  }

  /**
   * @returns 资料库歌曲（Apple Music library）DTO 列表。
   * 不含「只出现在歌单里、不在资料库」的曲目——那些只在歌单详情页出现。
   */
  public getSongList(): SongApiDto[] {
    return this.database.getLibrarySongs().map((row: MusicSongRow) => this.rowToSongApiDto(row));
  }

  /** @returns 已同步的 Apple Music 歌单元数据。 */
  public getApplePlaylists(): ApplePlaylistRow[] {
    return this.database.getApplePlaylists();
  }

  /** @returns 按 uri 取歌曲 DTO（歌单曲目补入本地表后按 uri 回查）。 */
  public getSongByUri(uri: string): SongApiDto | undefined {
    const row = this.database.findSongByUri(uri);
    return row !== undefined ? this.rowToSongApiDto(row) : undefined;
  }

  /** @returns 按稳定 URI 取原始行（队列按 URI 重建 id 镜像时用）。 */
  public getSongRowByUri(uri: string): MusicSongRow | undefined {
    return this.database.findSongByUri(uri);
  }

  /** @returns 是否已收藏该艺人。 */
  public isFavoriteArtist(name: string): boolean {
    return this.database.isFavoriteArtist(name);
  }

  /** 切换收藏状态，@returns 切换后的状态。 */
  public toggleFavoriteArtist(name: string): boolean {
    const next: boolean = !this.database.isFavoriteArtist(name);
    this.database.setFavoriteArtist(name, next);
    return next;
  }

  /** 直接设置收藏状态（心形按钮要「同时写 Apple」，所以需要确定值而不是取反）。 */
  public setFavoriteArtist(name: string, favorite: boolean): void {
    this.database.setFavoriteArtist(name, favorite);
  }

  /**
   * @param name 艺人名
   * @returns 该艺人的 Apple Music 官方头像 URL（没有则空串）
   */
  public getArtistArtwork(name: string): string {
    return this.database.getArtistAvatar(name);
  }

  /** @returns 收藏的艺人名列表（用户手动顺序）。 */
  public getFavoriteArtistNames(): string[] {
    return this.database.getFavoriteArtists();
  }

  /**
   * 保存收藏艺人的手动顺序（拖动排序后调用）。
   *
   * @param names 新顺序的艺人名
   */
  public setFavoriteArtistOrder(names: string[]): void {
    this.database.setFavoriteOrder(names);
  }

  /**
   * 读取专辑 / 歌单的「继续播放」进度。
   * @param contextKey 见 {@link PlayContextKeys}。
   */
  public getResume(contextKey: string): PlaybackResumeRow | undefined {
    if (contextKey === '') {
      return undefined;
    }
    return this.database.getResume(contextKey);
  }

  /** 写入专辑 / 歌单的「继续播放」进度。 */
  public saveResume(contextKey: string, kind: string, songUri: string, positionMs: number): void {
    if (contextKey === '' || songUri === '') {
      return;
    }
    this.database.saveResume(contextKey, kind, songUri, positionMs);
  }

  /** 清掉专辑 / 歌单的「继续播放」进度（整张播完时调用）。 */
  public clearResume(contextKey: string): void {
    if (contextKey === '') {
      return;
    }
    this.database.clearResume(contextKey);
  }

  /**
   * @param id Song primary key.
   * @returns DTO or undefined if not found.
   */
  public getSongById(id: number): SongApiDto | undefined {
    const row = this.database.getSongById(id);
    return row !== undefined ? this.rowToSongApiDto(row) : undefined;
  }

  /**
   * Playlist feature is not part of this product; kept as a no-op stub so
   * existing consumers keep compiling.
   * @param playlistId Playlist id (ignored).
   * @returns Empty list.
   */
  public getPlaylistSongItems(playlistId: number): SongApiDto[] {
    return [];
  }

  /**
   * @returns All artists sorted by name.
   */
  public getArtists(): ArtistApiDto[] {
    return this.database.getArtists().map((row: ArtistRow) => this.rowToArtistApiDto(row));
  }

  /**
   * @returns All albums sorted by name.
   */
  public getAlbums(): AlbumApiDto[] {
    return this.database.getAlbums().map((row: AlbumRow) => this.rowToAlbumApiDto(row));
  }

  /**
   * @param artist Artist display name.
   * @returns Albums owned by the artist.
   */
  public getAlbumsByArtist(artist: string): AlbumApiDto[] {
    return this.database.getAlbumsByArtist(artist).map((row: AlbumRow) => this.rowToAlbumApiDto(row));
  }

  /**
   * @param artist Artist display name.
   * @returns All songs of the artist, album/track ordered.
   */
  public getSongsByArtist(artist: string): SongApiDto[] {
    return this.database.getSongsByArtist(artist).map((row: MusicSongRow) => this.rowToSongApiDto(row));
  }

  /**
   * @param album Album display name.
   * @param artist Artist display name (disambiguates same-named albums).
   * @returns Songs of the album, track ordered.
   */
  public getSongsByAlbum(album: string, artist: string): SongApiDto[] {
    return this.database.getSongsByAlbum(album, artist).map((row: MusicSongRow) => this.rowToSongApiDto(row));
  }

  /**
   * @returns Number of songs in the library.
   */
  public getSongCount(): number {
    return this.database.getSongs().length;
  }

  /** Maps a {@link MusicSongRow} to {@link SongApiDto}. */
  private rowToSongApiDto(row: MusicSongRow): SongApiDto {
    const dto = new SongApiDto();
    dto.id = row.id;
    dto.title = row.title;
    dto.singer = row.artist;
    dto.src = row.uri;
    dto.index = row.trackNumber;
    dto.album = row.album;
    dto.duration = row.duration;
    dto.coverPath = row.coverPath;
    dto.trackNumber = row.trackNumber;
    return dto;
  }

  /** Maps an {@link ArtistRow} to {@link ArtistApiDto}. */
  private rowToArtistApiDto(row: ArtistRow): ArtistApiDto {
    const dto = new ArtistApiDto();
    dto.id = row.id;
    dto.name = row.name;
    dto.albumCount = row.albumCount;
    dto.songCount = row.songCount;
    dto.coverPath = row.coverPath;
    dto.genre = row.genre;
    return dto;
  }

  /** Maps an {@link AlbumRow} to {@link AlbumApiDto}. */
  private rowToAlbumApiDto(row: AlbumRow): AlbumApiDto {
    const dto = new AlbumApiDto();
    dto.id = row.id;
    dto.name = row.name;
    dto.artist = row.artist;
    dto.songCount = row.songCount;
    dto.totalDuration = row.totalDuration;
    dto.coverPath = row.coverPath;
    return dto;
  }
}
