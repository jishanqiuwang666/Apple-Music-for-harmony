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

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { MusicSongRow } from '../data/MusicSongRow';
import { ArtistRow } from '../data/ArtistRow';
import { AlbumRow } from '../data/AlbumRow';
import { ApplePlaylistRow } from '../data/ApplePlaylistRow';
import { PlaybackResumeRow } from '../data/PlaybackResumeRow';
import { Logger } from '../util/Logger';
import { GenreBuckets } from '../util/GenreBuckets';

/** Pending cover back-fill entry produced by a merge import. */
interface CoverBackfill {
  uri: string;
  coverPath: string;
}

const TAG = 'MusicDatabase';

/**
 * Library RDB (songs / albums / artists) with an in-memory mirror so the
 * existing synchronous UI/player APIs keep working after startup load.
 * Write paths (import/clear) update both the DB and the mirror.
 */
export class MusicDatabase {
  private static instance: MusicDatabase | undefined = undefined;
  private store: relationalStore.RdbStore | undefined = undefined;
  /** In-memory mirror of the songs table, sorted by title. */
  private songs: MusicSongRow[] = [];
  /** Artist aggregates derived from {@link songs}. */
  private artists: ArtistRow[] = [];
  /** Album aggregates derived from {@link songs}. */
  private albums: AlbumRow[] = [];
  /** Apple Music 资料库歌单元数据（内存镜像）。 */
  private playlists: ApplePlaylistRow[] = [];
  /** 专辑 / 歌单「继续播放」进度镜像（contextKey → 行）。 */
  private resumes: Map<string, PlaybackResumeRow> = new Map();
  /** 收藏的艺人名集合（内存镜像）。 */
  private favoriteArtists: Set<string> = new Set();

  /** 艺人官方头像镜像（艺人名 → 目录头像 URL）。 */
  private artistAvatars: Map<string, string> = new Map();

  private constructor() {
  }

  /** @returns The shared database singleton. */
  public static getInstance(): MusicDatabase {
    if (MusicDatabase.instance === undefined) {
      MusicDatabase.instance = new MusicDatabase();
    }
    return MusicDatabase.instance;
  }

  /** Callbacks fired once the DB finishes loading (late-page refresh path). */
  private readyCallbacks: Array<() => void> = [];

  /**
   * True only after {@link init} finished loading the mirror.
   *
   * 注意：不能用 `store !== undefined` 判断就绪——store 在 createTables/
   * reloadFromDb 之前就赋值了，页面在这个窗口里注册回调会立刻被唤醒，
   * 却读到空的 songs 镜像（表现为「首屏空资料库」）。
   */
  private loaded: boolean = false;

  /**
   * Opens (or creates) the library DB and loads all songs into memory.
   * @param context Ability context used to resolve the store.
   */
  public async init(context: common.Context): Promise<void> {
    if (this.store !== undefined) {
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: 'music_library.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.createTables();
    await this.reloadFromDb();
    await this.reloadResumes();
    await this.reloadFavorites();
    this.loaded = true;
    // Flush waiters that registered before the load finished (e.g. pages
    // bootstrapped ahead of the DB and rendered an empty library).
    const callbacks = this.readyCallbacks;
    this.readyCallbacks = [];
    for (let i = 0; i < callbacks.length; i++) {
      try {
        callbacks[i]();
      } catch (err) {
        Logger.warn(TAG, `ready callback failed: ${JSON.stringify(err)}`);
      }
    }
  }

  /**
   * Registers a callback for when the library mirror is loaded. Fires
   * immediately when the DB is already ready.
   */
  public whenReady(callback: () => void): void {
    if (this.loaded) {
      callback();
      return;
    }
    this.readyCallbacks.push(callback);
  }

  /** @returns 内存镜像是否已经加载完成。 */
  public isLoaded(): boolean {
    return this.loaded;
  }

  /** Creates the songs/albums/artists tables and their indexes. */
  private async createTables(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS songs (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'title TEXT NOT NULL, ' +
      'artist TEXT NOT NULL, ' +
      'album TEXT NOT NULL, ' +
      'duration INTEGER DEFAULT 0, ' +
      'year INTEGER DEFAULT 0, ' +
      'uri TEXT NOT NULL UNIQUE, ' +
      'cover_path TEXT DEFAULT \'\', ' +
      'track_number INTEGER DEFAULT 0, ' +
      'folder TEXT DEFAULT \'\', ' +
      'created_at INTEGER DEFAULT 0, ' +
      'apple_id TEXT DEFAULT \'\', ' +
      'cached_path TEXT DEFAULT \'\', ' +
      'cover_url TEXT DEFAULT \'\', ' +
      'pinned INTEGER DEFAULT 0, ' +
      'is_library INTEGER DEFAULT 0, ' +
      'genre TEXT DEFAULT \'\')');
    // Migration for libraries created before the year column existed.
    try {
      await store.executeSql('ALTER TABLE songs ADD COLUMN year INTEGER DEFAULT 0');
    } catch (err) {
      // Column already exists on fresh/newer schemas: ignore.
    }
    // Migration: Apple Music 音源字段
    const migrations: string[] = [
      'ALTER TABLE songs ADD COLUMN apple_id TEXT DEFAULT \'\'',
      'ALTER TABLE songs ADD COLUMN cached_path TEXT DEFAULT \'\'',
      'ALTER TABLE songs ADD COLUMN cover_url TEXT DEFAULT \'\'',
      'ALTER TABLE songs ADD COLUMN pinned INTEGER DEFAULT 0',
      'ALTER TABLE songs ADD COLUMN is_library INTEGER DEFAULT 0',
      'ALTER TABLE songs ADD COLUMN genre TEXT DEFAULT \'\''
    ];
    for (let i = 0; i < migrations.length; i++) {
      try {
        await store.executeSql(migrations[i]);
      } catch (err) {
        // 列已存在，忽略
      }
    }
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS albums (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'name TEXT NOT NULL, ' +
      'artist TEXT NOT NULL, ' +
      'cover_path TEXT DEFAULT \'\', ' +
      'song_count INTEGER DEFAULT 0, ' +
      'UNIQUE(name, artist))');
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS artists (' +
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
      'name TEXT UNIQUE NOT NULL, ' +
      'album_count INTEGER DEFAULT 0, ' +
      'song_count INTEGER DEFAULT 0)');
    // Apple Music 资料库歌单（只存元数据，曲目按需拉取）
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS apple_playlists (' +
      'id TEXT PRIMARY KEY, ' +
      'name TEXT NOT NULL, ' +
      'description TEXT DEFAULT \'\', ' +
      'cover_url TEXT DEFAULT \'\', ' +
      'track_count INTEGER DEFAULT 0)');
    // 艺人官方头像（Apple Music 目录头像 URL，每次资料库同步覆盖刷新）。
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS artist_avatars (' +
      'name TEXT PRIMARY KEY, ' +
      'artwork_url TEXT DEFAULT \'\', ' +
      'updated_at INTEGER DEFAULT 0)');
    // 收藏的艺人（本地标记，与资料库同步解耦：同步不会清掉收藏）。
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS favorite_artists (' +
      'name TEXT PRIMARY KEY, ' +
      'created_at INTEGER DEFAULT 0, ' +
      // 用户手动排序（拖动调换）：数字小的在前；0 = 还没排过（按收藏时间）
      'sort_order INTEGER DEFAULT 0)');
    // 专辑 / 歌单「继续播放」进度：一个来源一条，key 见 PlayContextKeys。
    // 迁移：老的收藏表没有排序字段
    try {
      await store.executeSql('ALTER TABLE favorite_artists ADD COLUMN sort_order INTEGER DEFAULT 0');
    } catch (err) {
      // 列已存在，忽略
    }
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS playback_resume (' +
      'context_key TEXT PRIMARY KEY, ' +
      'kind TEXT DEFAULT \'\', ' +
      'song_uri TEXT DEFAULT \'\', ' +
      'position_ms INTEGER DEFAULT 0, ' +
      'updated_at INTEGER DEFAULT 0)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS idx_albums_artist ON albums(artist)');
  }

  /** Loads every song row into {@link songs} and rebuilds aggregates. */
  private async reloadFromDb(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const rows = await store.querySql('SELECT * FROM songs ORDER BY title COLLATE NOCASE');
    this.songs = [];
    while (rows.goToNextRow()) {
      this.songs.push(this.rowToSong(rows));
    }
    rows.close();
    // 先载入艺人官方头像镜像，再重建聚合（聚合里的艺人头像取自它）
    await this.reloadArtistAvatars();
    await this.reloadPlaylists();
  }

  /** 重新载入歌单元数据镜像。 */
  private async reloadPlaylists(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const rs = await store.querySql('SELECT * FROM apple_playlists ORDER BY name COLLATE NOCASE');
    this.playlists = [];
    while (rs.goToNextRow()) {
      const row = new ApplePlaylistRow();
      row.id = rs.getString(rs.getColumnIndex('id'));
      row.name = rs.getString(rs.getColumnIndex('name'));
      row.description = rs.getString(rs.getColumnIndex('description'));
      row.coverUrl = rs.getString(rs.getColumnIndex('cover_url'));
      row.trackCount = rs.getLong(rs.getColumnIndex('track_count'));
      this.playlists.push(row);
    }
    rs.close();
  }

  /** Maps the current RDB result-set row to a {@link MusicSongRow}. */
  private rowToSong(rs: relationalStore.ResultSet): MusicSongRow {
    const row = new MusicSongRow();
    row.id = rs.getLong(rs.getColumnIndex('id'));
    row.title = rs.getString(rs.getColumnIndex('title'));
    row.artist = rs.getString(rs.getColumnIndex('artist'));
    row.album = rs.getString(rs.getColumnIndex('album'));
    row.duration = rs.getLong(rs.getColumnIndex('duration'));
    row.year = rs.getLong(rs.getColumnIndex('year'));
    row.uri = rs.getString(rs.getColumnIndex('uri'));
    row.coverPath = rs.getString(rs.getColumnIndex('cover_path'));
    row.trackNumber = rs.getLong(rs.getColumnIndex('track_number'));
    row.folder = rs.getString(rs.getColumnIndex('folder'));
    try {
      row.appleId = rs.getString(rs.getColumnIndex('apple_id'));
      row.cachedPath = rs.getString(rs.getColumnIndex('cached_path'));
      row.coverUrl = rs.getString(rs.getColumnIndex('cover_url'));
      row.pinned = rs.getLong(rs.getColumnIndex('pinned')) === 1;
      row.isLibrary = rs.getLong(rs.getColumnIndex('is_library')) === 1;
      row.genre = rs.getString(rs.getColumnIndex('genre'));
    } catch (err) {
      // 老库可能没有这些列，忽略
    }
    return row;
  }

  /**
   * Recomputes artists/albums aggregates from **全部曲目**（资料库 + 歌单）。
   *
   * 2026-09-13 修正：以前只聚合 is_library=1 的曲目，导致「只存在于歌单、
   * 没有单独加入资料库」的曲目（用户导入过的那批音乐人：坂本龙一、Brian Eno、
   * Sigur Rós、Ólafur Arnalds…）在三个板块里整块消失。用户期望看到它们，
   * 所以改为并集；is_library 仍然保留（用于区分来源与歌单页展示）。
   */
  private rebuildAggregates(): void {
    const artistCounts = new Map<string, number>();
    const artistAlbums = new Map<string, Set<string>>();
    const albumSongs = new Map<string, number>();
    const albumDuration = new Map<string, number>();
    const albumCover = new Map<string, string>();
    const albumYear = new Map<string, number>();
    /** 艺人 → (板块 → 曲目数)：取众数作为这位艺人的板块。 */
    /**
     * 专辑 → 曲风：歌单带进来的曲目（/playlists/.../tracks）有时不带 genreNames，
     * 借同专辑其它曲目的曲风补上，避免整位艺人掉进「其他」。
     */
    const albumGenreOf = new Map<string, string>();
    for (let i = 0; i < this.songs.length; i++) {
      const sg = this.songs[i];
      if (sg.genre !== '' && sg.album !== '') {
        const k = `${sg.album}|||${sg.artist}`;
        if (!albumGenreOf.has(k)) {
          albumGenreOf.set(k, sg.genre);
        }
      }
    }
    const artistGenre = new Map<string, Map<string, number>>();

    for (let i = 0; i < this.songs.length; i++) {
      const song = this.songs[i];
      const artistKey = song.artist;
      const albumKey = `${song.album}|||${song.artist}`;
      artistCounts.set(artistKey, (artistCounts.get(artistKey) ?? 0) + 1);
      const rawGenre: string = song.genre !== ''
        ? song.genre
        : (albumGenreOf.get(albumKey) ?? '');
      const bucketName: string = GenreBuckets.of(rawGenre);
      let genreCounts = artistGenre.get(artistKey);
      if (genreCounts === undefined) {
        genreCounts = new Map<string, number>();
        artistGenre.set(artistKey, genreCounts);
      }
      genreCounts.set(bucketName, (genreCounts.get(bucketName) ?? 0) + 1);
      let albumSet = artistAlbums.get(artistKey);
      if (albumSet === undefined) {
        albumSet = new Set<string>();
        artistAlbums.set(artistKey, albumSet);
      }
      albumSet.add(albumKey);
      albumSongs.set(albumKey, (albumSongs.get(albumKey) ?? 0) + 1);
      albumDuration.set(albumKey, (albumDuration.get(albumKey) ?? 0) + song.duration);
      // Album release year: newest known song year (unknowns ignored).
      if (song.year > 0) {
        albumYear.set(albumKey, Math.max(albumYear.get(albumKey) ?? 0, song.year));
      }
      if (song.coverPath !== '' && !albumCover.has(albumKey)) {
        albumCover.set(albumKey, song.coverPath);
      }
    }

    // 艺人头像只用 Apple Music 官方艺人图（用户 2026-09-14 定）：
    // 旧的「最早专辑封面 / 手动选图」逻辑已全部删除；没有官方图就用渐变占位。

    this.artists = [];
    artistCounts.forEach((songCount: number, name: string) => {
      const artist = new ArtistRow();
      artist.name = name;
      artist.songCount = songCount;
      artist.albumCount = artistAlbums.get(name)?.size ?? 0;
      artist.coverPath = this.artistAvatars.get(name) ?? '';
      artist.genre = MusicDatabase.dominantGenre(artistGenre.get(name));
      this.artists.push(artist);
    });
    this.artists.sort((a: ArtistRow, b: ArtistRow) => a.name.localeCompare(b.name));
    Logger.info(TAG, '艺人板块分布: ' + MusicDatabase.genreSummary(this.artists));

    this.albums = [];
    albumSongs.forEach((songCount: number, key: string) => {
      const sep = key.lastIndexOf('|||');
      const album = new AlbumRow();
      album.name = key.substring(0, sep);
      album.artist = key.substring(sep + 3);
      album.songCount = songCount;
      album.totalDuration = albumDuration.get(key) ?? 0;
      album.year = albumYear.get(key) ?? 0;
      album.coverPath = albumCover.get(key) ?? '';
      this.albums.push(album);
    });
    // Sort top-to-bottom by release year (oldest first); unknown years go
    // last by name.
    this.albums.sort((a: AlbumRow, b: AlbumRow) => {
      if (a.year === 0 && b.year === 0) {
        return a.name.localeCompare(b.name);
      }
      if (a.year === 0) {
        return 1;
      }
      if (b.year === 0) {
        return -1;
      }
      return a.year - b.year;
    });
  }

  /**
   * 艺人板块分布摘要（形如 `流行 210 / 古典 13 / 爵士 11 / 其他 5`）。
   * 一行日志，用来确认曲风归类是否真的生效、各板块有多少人。
   *
   * @param artists 已算好 genre 的艺人聚合
   * @returns 摘要文本
   */
  private static genreSummary(artists: ArtistRow[]): string {
    const counts = new Map<string, number>();
    for (let i = 0; i < artists.length; i++) {
      const g: string = artists[i].genre !== '' ? artists[i].genre : GenreBuckets.OTHER;
      counts.set(g, (counts.get(g) ?? 0) + 1);
    }
    const parts: string[] = [];
    for (let i = 0; i < GenreBuckets.ORDER.length; i++) {
      const bucket: string = GenreBuckets.ORDER[i];
      const n: number = counts.get(bucket) ?? 0;
      if (n > 0) {
        parts.push(`${bucket} ${n}`);
      }
    }
    return parts.join(' / ');
  }

  /**
   * 取某位艺人出现最多的音乐板块（并列时按 GenreBuckets.ORDER 的先后）。
   *
   * @param counts 板块 → 曲目数
   * @returns 板块名，无数据时为「其他」
   */
  private static dominantGenre(counts: Map<string, number> | undefined): string {
    if (counts === undefined || counts.size === 0) {
      return GenreBuckets.OTHER;
    }
    let best: string = GenreBuckets.OTHER;
    let bestCount: number = -1;
    for (let i = 0; i < GenreBuckets.ORDER.length; i++) {
      const bucket: string = GenreBuckets.ORDER[i];
      const n: number = counts.get(bucket) ?? 0;
      if (n > bestCount) {
        best = bucket;
        bestCount = n;
      }
    }
    return bestCount > 0 ? best : GenreBuckets.OTHER;
  }

  // ---- Synchronous reads (in-memory mirror) ----

  /** @returns All songs sorted by title（含歌单带进来的资料库外曲目）。 */
  public getSongs(): MusicSongRow[] {
    return this.songs;
  }

  /**
   * @returns 三个板块（艺人 / 专辑 / 全部歌曲）展示的曲目：资料库 + 歌单并集。
   * 歌单曲目在「全部歌曲」里也可见（用户 2026-09-13 定的规则），去重由
   * songs.uri 的 UNIQUE 约束保证（同一首歌既是资料库又在歌单时只存一行，
   * 且 is_library 为 1）。
   */
  public getLibrarySongs(): MusicSongRow[] {
    return this.songs;
  }

  /** @returns 已同步的 Apple Music 歌单元数据。 */
  public getApplePlaylists(): ApplePlaylistRow[] {
    return this.playlists;
  }

  /** @returns A song by id, or undefined. */
  public getSongById(id: number): MusicSongRow | undefined {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === id) {
        return this.songs[i];
      }
    }
    return undefined;
  }

  /** @returns All artists with aggregate counts. */
  public getArtists(): ArtistRow[] {
    return this.artists;
  }

  // ---- 专辑 / 歌单「继续播放」进度 ----

  /** 重新载入进度镜像（条数很少，全量读入内存）。 */
  private async reloadResumes(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const rs = await store.querySql('SELECT * FROM playback_resume');
    this.resumes = new Map();
    while (rs.goToNextRow()) {
      const row = new PlaybackResumeRow();
      row.contextKey = rs.getString(rs.getColumnIndex('context_key'));
      row.kind = rs.getString(rs.getColumnIndex('kind'));
      row.songUri = rs.getString(rs.getColumnIndex('song_uri'));
      row.positionMs = rs.getLong(rs.getColumnIndex('position_ms'));
      row.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
      this.resumes.set(row.contextKey, row);
    }
    rs.close();
    Logger.info(TAG, `reloadResumes: ${this.resumes.size} 条继续播放进度`);
  }

  /**
   * 重新载入艺人官方头像镜像（艺人名 → Apple Music 目录头像 URL）。
   * 头像随资料库同步整体覆盖刷新，本地不再有「自选头像」那套逻辑。
   */
  private async reloadArtistAvatars(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const rs = await store.querySql('SELECT name, artwork_url FROM artist_avatars');
    const map: Map<string, string> = new Map();
    while (rs.goToNextRow()) {
      const name: string = rs.getString(rs.getColumnIndex('name'));
      const url: string = rs.getString(rs.getColumnIndex('artwork_url'));
      if (name !== '' && url !== '') {
        map.set(name, url);
      }
    }
    rs.close();
    this.artistAvatars = map;
    Logger.info(TAG, `reloadArtistAvatars: ${map.size} 位艺人有官方头像`);
    this.rebuildAggregates();
  }

  /**
   * 覆盖写入艺人官方头像（同步完成后调用）。
   *
   * @param entries 艺人名 → 头像 URL
   */
  public async syncArtistAvatars(entries: Map<string, string>): Promise<void> {
    const store = this.store;
    if (store === undefined || entries.size === 0) {
      return;
    }
    await store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM artist_avatars');
      const now: number = new Date().getTime();
      entries.forEach((url: string, name: string) => {
        const bucket: relationalStore.ValuesBucket = {
          'name': name,
          'artwork_url': url,
          'updated_at': now
        };
        store.insert('artist_avatars', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)
          .catch((err: Error) => {
            Logger.warn(TAG, `artist avatar insert failed ${name}: ${err.message}`);
          });
      });
      await store.commit();
    } catch (err) {
      await store.rollBack();
      Logger.warn(TAG, 'syncArtistAvatars failed: ' + JSON.stringify(err));
    }
    await this.reloadArtistAvatars();
  }

  /** @returns 某位艺人的官方头像 URL（没有则空串）。 */
  public getArtistAvatar(name: string): string {
    return this.artistAvatars.get(name) ?? '';
  }

  /** 重新载入收藏艺人镜像。 */
  private async reloadFavorites(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    // 手动排序优先（sort_order 小的在前），没排过的按收藏时间（新的在前）
    const rs = await store.querySql(
      'SELECT name FROM favorite_artists ORDER BY sort_order ASC, created_at DESC');
    this.favoriteArtists = new Set();
    while (rs.goToNextRow()) {
      this.favoriteArtists.add(rs.getString(rs.getColumnIndex('name')));
    }
    rs.close();
    Logger.info(TAG, `reloadFavorites: ${this.favoriteArtists.size} 位收藏艺人`);
  }

  /** @returns 是否已收藏该艺人。 */
  public isFavoriteArtist(name: string): boolean {
    return this.favoriteArtists.has(name);
  }

  /**
   * 保存收藏艺人的手动顺序（拖动调换后调用）。
   *
   * @param names 新顺序的艺人名（前面的在前）
   */
  public setFavoriteOrder(names: string[]): void {
    if (names.length === 0) {
      return;
    }
    // 内存镜像按新顺序重建（Set 保持插入顺序，getFavoriteArtists 直接用）
    const ordered = new Set<string>();
    for (let i = 0; i < names.length; i++) {
      ordered.add(names[i]);
    }
    this.favoriteArtists.forEach((name: string) => {
      if (!ordered.has(name)) {
        ordered.add(name);
      }
    });
    this.favoriteArtists = ordered;
    const store = this.store;
    if (store === undefined) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      store.executeSql('UPDATE favorite_artists SET sort_order = ? WHERE name = ?', [i, names[i]])
        .catch((err: Error) => {
          Logger.warn(TAG, `setFavoriteOrder failed for ${names[i]}: ${err.message}`);
        });
    }
  }

  /** @returns 收藏的艺人名（用户手动顺序，没排过的按收藏时间倒序）。 */
  public getFavoriteArtists(): string[] {
    const out: string[] = [];
    this.favoriteArtists.forEach((name: string) => {
      out.push(name);
    });
    return out;
  }

  /** 设置/取消收藏（同步更新镜像，异步落库）。 */
  public setFavoriteArtist(name: string, favorite: boolean): void {
    if (name === '') {
      return;
    }
    if (favorite) {
      this.favoriteArtists.add(name);
    } else {
      this.favoriteArtists.delete(name);
    }
    const store = this.store;
    if (store === undefined) {
      return;
    }
    if (favorite) {
      const bucket: relationalStore.ValuesBucket = {
        'name': name,
        'created_at': new Date().getTime(),
        // 新收藏排在最后：手动排序用的是 0..N 小数字，时间戳一定更大
        'sort_order': new Date().getTime()
      };
      store.insert('favorite_artists', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)
        .catch((err: Error) => {
          Logger.warn(TAG, `setFavoriteArtist failed: ${err.message}`);
        });
    } else {
      store.executeSql('DELETE FROM favorite_artists WHERE name = ?', [name])
        .catch((err: Error) => {
          Logger.warn(TAG, `unsetFavoriteArtist failed: ${err.message}`);
        });
    }
  }

  /** @returns 某来源的继续播放进度，没有则 undefined。 */
  public getResume(contextKey: string): PlaybackResumeRow | undefined {
    return this.resumes.get(contextKey);
  }

  /** 写入（或覆盖）某来源的继续播放进度：同步更新镜像，异步落库。 */
  public saveResume(contextKey: string, kind: string, songUri: string, positionMs: number): void {
    const row: PlaybackResumeRow = this.resumes.get(contextKey) ?? new PlaybackResumeRow();
    const changed: boolean = row.songUri !== songUri ||
      Math.abs(row.positionMs - positionMs) > 3000;
    row.contextKey = contextKey;
    row.kind = kind;
    row.songUri = songUri;
    row.positionMs = positionMs < 0 ? 0 : Math.floor(positionMs);
    row.updatedAt = new Date().getTime();
    this.resumes.set(contextKey, row);
    // 同一首歌 3 秒内的位置抖动不必每次都落库（播放中每 5 秒节流写一次已足够）。
    if (!changed) {
      return;
    }
    void this.persistResume(row);
  }

  /** 删除某来源的继续播放进度（整张播完 / 清空数据时调用）。 */
  public clearResume(contextKey: string): void {
    if (!this.resumes.has(contextKey)) {
      return;
    }
    this.resumes.delete(contextKey);
    const store = this.store;
    if (store === undefined) {
      return;
    }
    store.executeSql('DELETE FROM playback_resume WHERE context_key = ?', [contextKey])
      .catch((err: Error) => {
        Logger.warn(TAG, `clearResume failed: ${err.message}`);
      });
  }

  /** 单条进度的落库（UPSERT）。 */
  private async persistResume(row: PlaybackResumeRow): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'context_key': row.contextKey,
      'kind': row.kind,
      'song_uri': row.songUri,
      'position_ms': row.positionMs,
      'updated_at': row.updatedAt
    };
    try {
      await store.insert('playback_resume', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (err) {
      Logger.warn(TAG, `persistResume failed: ${JSON.stringify(err)}`);
    }
  }

  /** 进度条数（设置页展示用）。 */
  public getResumeCount(): number {
    return this.resumes.size;
  }

  /** 清空全部进度（设置页「清空本地数据」用）。 */
  public async clearAllResumes(): Promise<void> {
    this.resumes = new Map();
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      await store.executeSql('DELETE FROM playback_resume');
    } catch (err) {
      Logger.warn(TAG, `clearAllResumes failed: ${JSON.stringify(err)}`);
    }
  }

  /** @returns All albums with aggregate counts. */
  public getAlbums(): AlbumRow[] {
    return this.albums;
  }

  /** @returns Albums owned by the given artist name. */
  public getAlbumsByArtist(artist: string): AlbumRow[] {
    const out: AlbumRow[] = [];
    for (let i = 0; i < this.albums.length; i++) {
      if (this.albums[i].artist === artist) {
        out.push(this.albums[i]);
      }
    }
    return out;
  }

  /** @returns Songs by the given artist name, album/track ordered（资料库 + 歌单）。 */
  public getSongsByArtist(artist: string): MusicSongRow[] {
    const out: MusicSongRow[] = [];
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].artist === artist) {
        out.push(this.songs[i]);
      }
    }
    out.sort((a: MusicSongRow, b: MusicSongRow) => {
      const albumCmp = a.album.localeCompare(b.album);
      return albumCmp !== 0 ? albumCmp : a.trackNumber - b.trackNumber;
    });
    return out;
  }

  /** @returns Songs of the given album (name + artist disambiguates), track ordered（资料库 + 歌单）. */
  public getSongsByAlbum(album: string, artist: string): MusicSongRow[] {
    const out: MusicSongRow[] = [];
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].album === album && this.songs[i].artist === artist) {
        out.push(this.songs[i]);
      }
    }
    out.sort((a: MusicSongRow, b: MusicSongRow) => a.trackNumber - b.trackNumber);
    return out;
  }

  // ---- Write paths ----

  /**
   * Replaces the library content of the given folder with the scanned rows.
   * Runs in one transaction, then rebuilds aggregates and the memory mirror.
   * @param folder Parent folder URI being imported.
   * @param rows Newly scanned songs (no id assigned yet).
   */
  /**
   * Imports scanned rows for a folder marker.
   * @param folder Folder marker of the imported rows.
   * @param rows Scanned song rows.
   * @param merge When true, keeps existing rows of the same folder and only
   *   inserts new URIs (multi-select imports accumulate across picker
   *   sessions, whose single-selection limit is 500 files). When false
   *   (default), replaces the folder's previous rows.
   */
  /**
   * Apple Music 资料库全量同步：
   *  - 用 apple_id 作为身份，保留已下载缓存路径（cachedPath）与 pinned 标记
   *  - 删除已从资料库消失的歌
   *  - 事务内完成，然后重建聚合与内存镜像
   * @param rows 从 Apple Music 拉取并转换好的歌曲行（uri 形如 apple:<id>）
   */
  public async syncAppleSongs(rows: MusicSongRow[]): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    // 保留旧的缓存路径 / pinned / 本地 id
    const keep = new Map<string, MusicSongRow>();
    for (let i = 0; i < this.songs.length; i++) {
      const old = this.songs[i];
      if (old.appleId.length > 0) {
        keep.set(old.appleId, old);
      }
    }
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      const old = keep.get(r.appleId);
      if (old !== undefined) {
        r.cachedPath = old.cachedPath;
        r.pinned = old.pinned;
      }
    }

    await store.beginTransaction();
    try {
      // 清掉旧的 Apple 行（folder 标记为 apple）
      await store.executeSql("DELETE FROM songs WHERE folder = 'apple'");
      // 批量插入（一次几百行）—— 以前是 2900 次单条 insert，事务里也要好几秒
      const CHUNK: number = 400;
      let written: number = 0;
      for (let start = 0; start < rows.length; start += CHUNK) {
        const end: number = Math.min(start + CHUNK, rows.length);
        const buckets: relationalStore.ValuesBucket[] = [];
        for (let i = start; i < end; i++) {
          const r: MusicSongRow = rows[i];
          buckets.push({
            'title': r.title,
            'artist': r.artist,
            'album': r.album,
            'duration': r.duration,
            'year': r.year,
            'uri': r.uri,
            'cover_path': r.coverPath,
            'track_number': r.trackNumber,
            'folder': 'apple',
            'created_at': new Date().getTime(),
            'apple_id': r.appleId,
            'cached_path': r.cachedPath,
            'cover_url': r.coverUrl,
            'pinned': r.pinned ? 1 : 0,
            'is_library': r.isLibrary ? 1 : 0,
            'genre': r.genre
          });
        }
        written += await store.batchInsertWithConflictResolution(
          'songs', buckets, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      await store.commit();
      Logger.info(TAG, 'syncAppleSongs: ' + written + ' 首已批量写入');
    } catch (err) {
      await store.rollBack();
      Logger.error(TAG, 'syncAppleSongs failed: ' + JSON.stringify(err));
      throw new Error('syncAppleSongs failed: ' + JSON.stringify(err));
    }
    await this.reloadFromDb();
  }

  /**
   * 全量替换 Apple Music 歌单元数据（资料库歌单列表）。
   * @param rows 从 /v1/me/library/playlists 拉取并转换好的行。
   */
  public async syncApplePlaylists(rows: ApplePlaylistRow[]): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    await store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM apple_playlists');
      for (let i = 0; i < rows.length; i++) {
        const r = rows[i];
        const bucket: relationalStore.ValuesBucket = {
          'id': r.id,
          'name': r.name,
          'description': r.description,
          'cover_url': r.coverUrl,
          'track_count': r.trackCount
        };
        await store.insert('apple_playlists', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      await store.commit();
      Logger.info(TAG, `syncApplePlaylists: ${rows.length} 个歌单已写入`);
    } catch (err) {
      await store.rollBack();
      Logger.error(TAG, 'syncApplePlaylists failed: ' + JSON.stringify(err));
      throw new Error('syncApplePlaylists failed: ' + JSON.stringify(err));
    }
    await this.reloadPlaylists();
  }

  /**
   * 确保给定的曲目都存在于 songs 表（uri 已存在则原样保留，不覆盖资料库行）。
   * 主要用于「打开歌单时把其中的曲目补进本地表，好让播放器按 id 播放」。
   * @param rows 待补入的曲目行（uri 形如 apple:<id>）。
   */
  public async ensureSongs(rows: MusicSongRow[]): Promise<void> {
    const store = this.store;
    if (store === undefined || rows.length === 0) {
      return;
    }
    const existing = new Set<string>();
    /** 已存在但曲风为空的 uri → 曲风（老库升级用，见下方注释）。 */
    const genreFixUri: string[] = [];
    const genreFixValue: string[] = [];
    const existingGenre = new Map<string, string>();
    for (let i = 0; i < this.songs.length; i++) {
      existing.add(this.songs[i].uri);
      existingGenre.set(this.songs[i].uri, this.songs[i].genre);
    }
    const buckets: Array<relationalStore.ValuesBucket> = [];
    const now = new Date().getTime();
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (existing.has(r.uri)) {
        // 老库升级：genre 列是后加的，早先落库的歌单曲目行曲风是空的。
        // 这批行（folder='apple_playlist'）不会走 syncAppleSongs 的重写，
        // 所以在这里把新拿到的曲风补写进去，否则它们永远归在「其他」。
        if (r.genre !== '' && (existingGenre.get(r.uri) ?? '') === '') {
          genreFixUri.push(r.uri);
          genreFixValue.push(r.genre);
        }
        continue;
      }
      existing.add(r.uri);
      buckets.push({
        'title': r.title,
        'artist': r.artist,
        'album': r.album,
        'duration': r.duration,
        'year': r.year,
        'uri': r.uri,
        'cover_path': r.coverPath,
        'track_number': r.trackNumber,
        'folder': r.folder,
        'created_at': now,
        'apple_id': r.appleId,
        'cached_path': '',
        'cover_url': r.coverUrl,
        'pinned': 0,
        'is_library': r.isLibrary ? 1 : 0,
        'genre': r.genre
      } as relationalStore.ValuesBucket);
    }
    // 先补曲风（不新增行），再插新行
    for (let i = 0; i < genreFixUri.length; i++) {
      try {
        await store.executeSql('UPDATE songs SET genre = ? WHERE uri = ?',
          [genreFixValue[i], genreFixUri[i]]);
      } catch (err) {
        Logger.warn(TAG, `genre backfill failed: ${JSON.stringify(err)}`);
      }
    }
    if (genreFixUri.length > 0) {
      Logger.info(TAG, `ensureSongs: 补写 ${genreFixUri.length} 条曲风`);
    }
    if (buckets.length === 0) {
      if (genreFixUri.length > 0) {
        await this.reloadFromDb();
      }
      return;
    }
    try {
      await store.batchInsert('songs', buckets);
      Logger.info(TAG, `ensureSongs: 新增 ${buckets.length} 首歌单曲目`);
    } catch (err) {
      Logger.warn(TAG, `ensureSongs failed: ${JSON.stringify(err)}`);
    }
    await this.reloadFromDb();
  }

  /** 按 uri 查歌曲（同步，走内存镜像）。 */
  public findSongByUri(uri: string): MusicSongRow | undefined {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].uri === uri) {
        return this.songs[i];
      }
    }
    return undefined;
  }

  /** 更新某首歌的缓存路径（下载完成后调用） */  public async updateCachedPath(appleId: string, cachedPath: string): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    await store.executeSql('UPDATE songs SET cached_path = ? WHERE apple_id = ?', [cachedPath, appleId]);
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].appleId === appleId) {
        this.songs[i].cachedPath = cachedPath;
        break;
      }
    }
  }

  /** 标记/取消「保留」 */
  public async setPinnedByAppleId(appleId: string, pinned: boolean): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    await store.executeSql('UPDATE songs SET pinned = ? WHERE apple_id = ?', [pinned ? 1 : 0, appleId]);
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].appleId === appleId) {
        this.songs[i].pinned = pinned;
        break;
      }
    }
  }

  public async importFolder(folder: string, rows: MusicSongRow[], merge: boolean = false): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    // Deduplicate against the songs that survive the import (the songs.uri
    // column is UNIQUE): replace mode must keep songs of OTHER folders;
    // merge mode must keep every existing song so repeats are skipped.
    const existingUris = new Set<string>();
    for (let i = 0; i < this.songs.length; i++) {
      if (merge || this.songs[i].folder !== folder) {
        existingUris.add(this.songs[i].uri);
      }
    }
    const fresh: MusicSongRow[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (!existingUris.has(rows[i].uri)) {
        fresh.push(rows[i]);
      }
    }
    // Merge mode: back-fill covers for songs imported before the cover
    // extraction fix (uri exists, old cover empty, new cover extracted).
    const coverUpdates: CoverBackfill[] = [];
    if (merge) {
      const coverByUri = new Map<string, string>();
      for (let i = 0; i < this.songs.length; i++) {
        coverByUri.set(this.songs[i].uri, this.songs[i].coverPath);
      }
      for (let i = 0; i < rows.length; i++) {
        const oldCover = coverByUri.get(rows[i].uri) ?? '';
        // Back-fill when the old cover is missing OR still a raw sandbox path
        // (pre-URI format that Image cannot load).
        if (rows[i].coverPath !== '' && (oldCover === '' || !oldCover.startsWith('file://'))) {
          coverUpdates.push({ uri: rows[i].uri, coverPath: rows[i].coverPath });
        }
      }
    }
    await store.beginTransaction();
    try {
      if (!merge) {
        const predicates = new relationalStore.RdbPredicates('songs');
        predicates.equalTo('folder', folder);
        await store.delete(predicates);
      }
      if (coverUpdates.length > 0) {
        for (const u of coverUpdates) {
          const predicates = new relationalStore.RdbPredicates('songs');
          predicates.equalTo('uri', u.uri);
          const bucket: relationalStore.ValuesBucket = { 'cover_path': u.coverPath };
          await store.update(bucket, predicates);
        }
      }
      if (fresh.length > 0) {
        const buckets: Array<relationalStore.ValuesBucket> = [];
        const now = Date.now();
        for (let i = 0; i < fresh.length; i++) {
          const row = fresh[i];
          buckets.push({
            'title': row.title,
            'artist': row.artist,
            'album': row.album,
            'duration': row.duration,
            'year': row.year,
            'uri': row.uri,
            'cover_path': row.coverPath,
            'track_number': row.trackNumber,
            'folder': row.folder,
            'created_at': now
          } as relationalStore.ValuesBucket);
        }
        await store.batchInsert('songs', buckets);
      }
      await store.commit();
    } catch (err) {
      await store.rollBack();
      Logger.error(TAG, `importFolder failed: ${JSON.stringify(err)}`);
      throw err as Error;
    }
    await this.reloadFromDb();
  }

  /**
   * 删除全部「导入外部音乐」时代遗留的本地歌曲（apple_id 为空的行），
   * 并重建聚合与内存镜像。
   *
   * 音源已切换为 Apple Music，本地导入功能与扫描器已从工程中移除，因此
   * 这个清理是幂等的：第一次启动删干净后再调用不会有任何行被删除。
   * Apple Music 的歌曲（资料库 + 歌单曲目）apple_id 都非空，不会被误删。
   *
   * @returns 实际删除的行数。
   */
  public async purgeImportedSongs(): Promise<number> {
    const store = this.store;
    if (store === undefined) {
      return 0;
    }
    const rows = await store.querySql(
      "SELECT COUNT(*) AS c FROM songs WHERE apple_id = ''");
    let count = 0;
    if (rows.goToFirstRow()) {
      count = rows.getLong(rows.getColumnIndex('c'));
    }
    rows.close();
    if (count === 0) {
      return 0;
    }
    await store.executeSql("DELETE FROM songs WHERE apple_id = ''");
    await this.reloadFromDb();
    Logger.info(TAG, `purgeImportedSongs: 已删除 ${count} 首导入歌曲`);
    return count;
  }

  /** Deletes every row and clears the mirror (full rescan path). */
  public async clearAll(): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    await store.executeSql('DELETE FROM songs');
    await store.executeSql('DELETE FROM albums');
    await store.executeSql('DELETE FROM artists');
    this.songs = [];
    this.rebuildAggregates();
  }

  /** Legacy rows whose URI points into the public docs tree (sandbox-copy migration candidates). */
  public getPublicDocsSongs(): MusicSongRow[] {
    const out: MusicSongRow[] = [];
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].uri.startsWith('file://docs/')) {
        out.push(this.songs[i]);
      }
    }
    return out;
  }

  /**
   * Points a song row at a new URI (sandbox migration). If the new URI is
   * already taken (UNIQUE conflict — the copy belongs to an existing row),
   * the old row is removed instead.
   */
  public async updateSongUri(oldUri: string, newUri: string): Promise<void> {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      const predicates = new relationalStore.RdbPredicates('songs');
      predicates.equalTo('uri', oldUri);
      const bucket: relationalStore.ValuesBucket = { 'uri': newUri };
      await store.update(bucket, predicates);
      for (let i = 0; i < this.songs.length; i++) {
        if (this.songs[i].uri === oldUri) {
          this.songs[i].uri = newUri;
          break;
        }
      }
    } catch (err) {
      Logger.warn(TAG, `updateSongUri conflict ${oldUri}: ${JSON.stringify(err)}`);
      await this.deleteSongsByUris([oldUri]);
    }
  }

  /** Deletes the given song rows from the DB and reloads the mirror. */
  public async deleteSongsByUris(uris: string[]): Promise<void> {
    const store = this.store;
    if (store === undefined || uris.length === 0) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('songs');
    predicates.in('uri', uris);
    await store.delete(predicates);
    await this.reloadFromDb();
  }
}
