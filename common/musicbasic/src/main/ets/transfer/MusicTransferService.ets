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

import { distributedKVStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { MusicSongRow } from '../data/MusicSongRow';
import { MusicDatabase } from '../db/MusicDatabase';
import { LibraryMeta, MetaSong, TransferDone, TransferReady, TransferRequest } from './TransferModels';
import { DeviceDiscovery } from './DeviceDiscovery';
import { Logger } from '../util/Logger';

const TAG = 'MusicTransferService';
const STORE_ID = 'music_transfer';
/** KV keys of the cross-device channel. */
const KEY_LIBRARY_META = 'library_meta';
const KEY_TRANSFER_REQ = 'transfer_req';
const KEY_TRANSFER_READY = 'transfer_ready';
const KEY_TRANSFER_DONE = 'transfer_done';
/** Sub-directory of distributedFilesDir used to stage outgoing songs. */
const STAGE_DIR = '/transfer_stage';
/** Sub-directory of filesDir holding pulled songs on the watch. */
const LOCAL_MUSIC_DIR = '/music';
/** Folder marker for locally pulled songs in the watch RDB. */
export const WATCH_LOCAL_FOLDER = 'watch_local';

/** Callback for the phone library snapshot (receiver side). */
export type LibraryMetaListener = (meta: LibraryMeta) => void;
/** Callback for pull progress (receiver side). */
export type TransferProgressListener = (doneCount: number, totalCount: number, currentTitle: string) => void;
/** Callback for transfer completion (sender side, for staging cleanup). */
export type TransferDoneListener = (done: TransferDone) => void;

/**
 * Cross-device music transfer over the distributed soft bus:
 * - KV store: library snapshot (phone → watch), pull requests (watch → phone),
 *   ready/done notifications both ways;
 * - hmdfs: phone stages song files into distributedFilesDir, watch connects and
 *   copies them into its local sandbox with progress callbacks.
 */
export class MusicTransferService {
  private static instance: MusicTransferService | undefined = undefined;
  private context: common.Context | undefined;
  private kvManager: distributedKVStore.KVManager | undefined = undefined;
  private kvStore: distributedKVStore.SingleKVStore | undefined = undefined;
  private requestCounter: number = 0;
  /** Sender-side: staged song files keyed by song id (for cleanup after done). */
  private stagedIds: number[] = [];
  /** Receiver-side: ids of the latest pull request (for staged file enumeration). */
  private lastRequestedIds: number[] = [];
  /** Receiver-side listeners. */
  private libraryMetaListeners: LibraryMetaListener[] = [];
  private progressListeners: TransferProgressListener[] = [];
  /** Sender-side completion listeners. */
  private doneListeners: TransferDoneListener[] = [];

  private constructor() {
  }

  /** @returns The shared transfer service. */
  public static getInstance(): MusicTransferService {
    if (MusicTransferService.instance === undefined) {
      MusicTransferService.instance = new MusicTransferService();
    }
    return MusicTransferService.instance;
  }

  /**
   * Opens the distributed KV store and subscribes to remote changes.
   * @param context Ability context (also used for sandbox paths).
   * @param handleRequest When true (sender side), respond to pull requests.
   */
  public async init(context: common.Context, handleRequest: boolean): Promise<void> {
    this.context = context;
    DeviceDiscovery.getInstance().init(context);
    if (this.kvStore !== undefined) {
      return;
    }
    const config: distributedKVStore.KVManagerConfig = {
      bundleName: context.applicationInfo.name,
      context: context
    };
    this.kvManager = distributedKVStore.createKVManager(config);
    const options: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: false,
      backup: false,
      autoSync: true,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
      securityLevel: distributedKVStore.SecurityLevel.S3
    };
    this.kvStore = await this.kvManager.getKVStore<distributedKVStore.SingleKVStore>(STORE_ID, options);
    this.kvStore.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_ALL,
      (changes: distributedKVStore.ChangeNotification) => {
        const entries: distributedKVStore.Entry[] = changes.insertEntries.concat(changes.updateEntries);
        for (let i = 0; i < entries.length; i++) {
          const entry = entries[i];
          const value = entry.value.value;
          if (typeof value === 'string') {
            this.onRemoteChange(entry.key, value, handleRequest);
          }
        }
      });
  }

  /** Dispatches a remote KV change to the matching handler. */
  private onRemoteChange(key: string, value: string, handleRequest: boolean): void {
    try {
      if (key === KEY_LIBRARY_META) {
        const meta = JSON.parse(value) as LibraryMeta;
        this.emitLibraryMeta(meta);
      } else if (key === KEY_TRANSFER_REQ && handleRequest) {
        const req = JSON.parse(value) as TransferRequest;
        this.stageAndNotify(req);
      } else if (key === KEY_TRANSFER_READY && !handleRequest) {
        const ready = JSON.parse(value) as TransferReady;
        this.pullReadyFiles(ready.requestId);
      } else if (key === KEY_TRANSFER_DONE && handleRequest) {
        const done = JSON.parse(value) as TransferDone;
        this.cleanupStaged(done);
        this.emitDone(done);
      }
    } catch (err) {
      Logger.warn(TAG, `onRemoteChange parse failed key=${key}: ${JSON.stringify(err)}`);
    }
  }

  // ---- Sender side (phone) ----

  /** Publishes the full library snapshot to the KV channel. */
  public async publishLibraryMeta(): Promise<void> {
    const store = this.kvStore;
    if (store === undefined) {
      return;
    }
    const rows = MusicDatabase.getInstance().getSongs();
    const meta = new LibraryMeta();
    meta.version = Date.now();
    meta.songs = rows.map((row: MusicSongRow) => this.toMetaSong(row));
    try {
      await store.put(KEY_LIBRARY_META, JSON.stringify(meta));
      Logger.info(TAG, `published library meta: ${meta.songs.length} songs`);
    } catch (err) {
      Logger.warn(TAG, `publishLibraryMeta failed: ${JSON.stringify(err)}`);
    }
  }

  /** Copies requested songs into the distributed stage dir and notifies the watch. */
  private async stageAndNotify(req: TransferRequest): Promise<void> {
    const store = this.kvStore;
    const context = this.context;
    if (store === undefined || context === undefined) {
      return;
    }
    const db = MusicDatabase.getInstance();
    const stageDir = `${context.distributedFilesDir}${STAGE_DIR}`;
    fileIo.mkdirSync(stageDir);
    this.stagedIds = [];
    for (let i = 0; i < req.songIds.length; i++) {
      const song = db.getSongById(req.songIds[i]);
      if (song === undefined) {
        continue;
      }
      try {
        const dest = fileUri.getUriFromPath(`${stageDir}/${song.id}${this.extensionOf(song.uri)}`);
        await fileIo.copy(song.uri, dest);
        this.stagedIds.push(song.id);
      } catch (err) {
        Logger.warn(TAG, `stage failed for ${song.id}: ${JSON.stringify(err)}`);
      }
    }
    const ready = new TransferReady();
    ready.requestId = req.requestId;
    try {
      await store.put(KEY_TRANSFER_READY, JSON.stringify(ready));
    } catch (err) {
      Logger.warn(TAG, `notify ready failed: ${JSON.stringify(err)}`);
    }
  }

  /** Removes staged files that were successfully pulled. */
  private async cleanupStaged(done: TransferDone): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    const stageDir = `${context.distributedFilesDir}${STAGE_DIR}`;
    const keep = new Set<number>(done.failedIds);
    for (let i = 0; i < this.stagedIds.length; i++) {
      const id = this.stagedIds[i];
      if (keep.has(id)) {
        continue;
      }
      const song = MusicDatabase.getInstance().getSongById(id);
      if (song === undefined) {
        continue;
      }
      try {
        fileIo.unlinkSync(fileUri.getUriFromPath(`${stageDir}/${id}${this.extensionOf(song.uri)}`));
      } catch (err) {
        Logger.warn(TAG, `cleanup failed for ${id}: ${JSON.stringify(err)}`);
      }
    }
    this.stagedIds = [];
  }

  // ---- Receiver side (watch) ----

  /**
   * Requests a pull of the given song ids.
   * @param songIds Library song ids to transfer.
   * @returns The new request id (or -1 on failure).
   */
  public async requestTransfer(songIds: number[]): Promise<number> {
    const store = this.kvStore;
    if (store === undefined || songIds.length === 0) {
      return -1;
    }
    this.requestCounter++;
    this.lastRequestedIds = songIds;
    const req = new TransferRequest();
    req.requestId = this.requestCounter;
    req.songIds = songIds;
    req.timestamp = Date.now();
    try {
      await store.put(KEY_TRANSFER_REQ, JSON.stringify(req));
      return req.requestId;
    } catch (err) {
      Logger.warn(TAG, `requestTransfer failed: ${JSON.stringify(err)}`);
      return -1;
    }
  }

  /** Connects to the phone via hmdfs and copies the staged batch into the local sandbox. */
  private async pullReadyFiles(requestId: number): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    const phone = DeviceDiscovery.getInstance().findPhone();
    if (phone === undefined) {
      Logger.warn(TAG, 'pullReadyFiles: no phone available');
      return;
    }
    const networkId = DeviceDiscovery.getInstance().networkIdOf(phone);
    const db = MusicDatabase.getInstance();
    const remoteDir = `${context.distributedFilesDir}${STAGE_DIR}`;
    const localDir = `${context.filesDir}${LOCAL_MUSIC_DIR}`;
    fileIo.mkdirSync(localDir);
    const success: MusicSongRow[] = [];
    const failedIds: number[] = [];
    let doneCount = 0;
    const requestedIds = this.lastRequestedIds;
    const listeners: fileIo.DfsListeners = {
      onStatus: (nid: string, status: number) => {
        Logger.info(TAG, `dfs status ${nid} = ${status}`);
      }
    };
    try {
      await fileIo.connectDfs(networkId, listeners);
      for (let i = 0; i < requestedIds.length; i++) {
        const id = requestedIds[i];
        const song = db.getSongById(id);
        if (song === undefined) {
          failedIds.push(id);
          continue;
        }
        const ext = this.extensionOf(song.uri);
        const srcUri = fileUri.getUriFromPath(`${remoteDir}/${id}${ext}`);
        const destPath = `${localDir}/${id}${ext}`;
        const destUri = fileUri.getUriFromPath(destPath);
        try {
          await fileIo.copy(srcUri, destUri, {
            progressListener: (progress: fileIo.Progress) => {
              const p = progress as fileIo.Progress;
              if (p !== undefined) {
                Logger.debug(TAG, `copy progress ${p.processedSize}/${p.totalSize}`);
              }
            }
          });
          const row = new MusicSongRow();
          row.id = song.id;
          row.title = song.title;
          row.artist = song.artist;
          row.album = song.album;
          row.duration = song.duration;
          row.uri = fileUri.getUriFromPath(destPath);
          row.coverPath = '';
          row.trackNumber = song.trackNumber;
          row.folder = WATCH_LOCAL_FOLDER;
          success.push(row);
          doneCount++;
          for (let l = 0; l < this.progressListeners.length; l++) {
            this.progressListeners[l](doneCount, requestedIds.length, row.title);
          }
        } catch (err) {
          Logger.warn(TAG, `pull failed for ${id}: ${JSON.stringify(err)}`);
          failedIds.push(id);
        }
      }
      if (success.length > 0) {
        await db.importFolder(WATCH_LOCAL_FOLDER, success);
      }
    } catch (err) {
      Logger.warn(TAG, `pullReadyFiles connect failed: ${JSON.stringify(err)}`);
    } finally {
      try {
        await fileIo.disconnectDfs(networkId);
      } catch (err) {
        Logger.warn(TAG, `disconnectDfs failed: ${JSON.stringify(err)}`);
      }
    }
    // Report completion to the sender for staging cleanup.
    const store = this.kvStore;
    if (store !== undefined) {
      const done = new TransferDone();
      done.requestId = requestId;
      done.successCount = success.length;
      done.failedIds = failedIds;
      try {
        await store.put(KEY_TRANSFER_DONE, JSON.stringify(done));
      } catch (err) {
        Logger.warn(TAG, `report done failed: ${JSON.stringify(err)}`);
      }
    }
  }

  // ---- Listeners ----

  /** Subscribes to phone library snapshot updates (receiver side). */
  public onLibraryMeta(listener: LibraryMetaListener): void {
    if (this.libraryMetaListeners.indexOf(listener) < 0) {
      this.libraryMetaListeners.push(listener);
    }
  }

  /** Subscribes to pull progress (receiver side). */
  public onTransferProgress(listener: TransferProgressListener): void {
    if (this.progressListeners.indexOf(listener) < 0) {
      this.progressListeners.push(listener);
    }
  }

  /** Subscribes to transfer completion (sender side). */
  public onTransferDone(listener: TransferDoneListener): void {
    if (this.doneListeners.indexOf(listener) < 0) {
      this.doneListeners.push(listener);
    }
  }

  private emitLibraryMeta(meta: LibraryMeta): void {
    for (let i = 0; i < this.libraryMetaListeners.length; i++) {
      this.libraryMetaListeners[i](meta);
    }
  }

  private emitDone(done: TransferDone): void {
    for (let i = 0; i < this.doneListeners.length; i++) {
      this.doneListeners[i](done);
    }
  }

  // ---- Helpers ----

  /** Extracts a file extension including the dot from a URI path. */
  private extensionOf(uri: string): string {
    const slash = uri.lastIndexOf('/');
    const tail = slash >= 0 ? uri.substring(slash + 1) : uri;
    const dot = tail.lastIndexOf('.');
    return dot >= 0 ? tail.substring(dot) : '.mp3';
  }

  /** Maps a DB row to the lightweight snapshot entry. */
  private toMetaSong(row: MusicSongRow): MetaSong {
    const meta = new MetaSong();
    meta.id = row.id;
    meta.title = row.title;
    meta.artist = row.artist;
    meta.album = row.album;
    meta.duration = row.duration;
    meta.coverPath = row.coverPath;
    meta.trackNumber = row.trackNumber;
    return meta;
  }
}
