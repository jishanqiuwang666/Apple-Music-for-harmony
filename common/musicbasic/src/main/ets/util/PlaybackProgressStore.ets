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

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREF_NAME = 'playback_progress_store';
const KEY_SONG_URI = 'last_song_uri';
const KEY_POSITION_MS = 'last_position_ms';
const KEY_QUEUE_URIS = 'last_queue_uris';
const KEY_SELECT_INDEX = 'last_select_index';
const KEY_CONTEXT_KIND = 'last_context_kind';
const KEY_CONTEXT_ID = 'last_context_id';
const KEY_CONTEXT_TITLE = 'last_context_title';

/**
 * 上一次播放会话的完整快照：队列（稳定 URI）、队列内索引、当前曲目、播放位置，
 * 以及队列来源上下文（专辑 / 歌单 / 艺人 / 全部歌曲 / 搜索）。
 *
 * 队列存 URI 而不是数字 id：`syncAppleSongs` 每次同步都会删除并重插 songs 表，
 * AUTOINCREMENT 让所有 id 改变，存 id 的队列在下次启动同步后必然全部失效
 * （表现就是「小组件只播一首」「恢复的专辑队列被整库顶替」）。
 */
export class PlaybackProgressSnapshot {
  /** 当前曲目 URI（apple:<id>），空串表示没有会话。 */
  public songUri: string = '';
  /** 播放位置（毫秒）。 */
  public positionMs: number = 0;
  /** 队列的稳定 URI 列表。 */
  public queueUris: string[] = [];
  /** 当前曲目在队列中的索引。 */
  public selectIndex: number = 0;
  /** 队列来源类型（PlaySourceKind 的字符串值）。 */
  public contextKind: string = '';
  /** 队列来源 id（专辑 `专辑名\u0001艺人名` / 歌单 ID）。 */
  public contextId: string = '';
  /** 队列来源标题（展示用）。 */
  public contextTitle: string = '';

  /** @returns 是否有可恢复的会话。 */
  public hasSession(): boolean {
    return this.songUri !== '' || this.queueUris.length > 0;
  }
}

/**
 * Preferences 后端的播放会话存储。写入时机：切歌、暂停、停止、进度节流
 * （5 秒一次）、进后台 —— 进程被杀也能恢复到秒级。
 */
export class PlaybackProgressStore {
  private static instance: PlaybackProgressStore | undefined = undefined;
  private pref: preferences.Preferences | undefined = undefined;

  public static getInstance(): PlaybackProgressStore {
    if (PlaybackProgressStore.instance === undefined) {
      PlaybackProgressStore.instance = new PlaybackProgressStore();
    }
    return PlaybackProgressStore.instance;
  }

  /** 打开 Preferences（幂等）。 */
  public async init(context: common.Context): Promise<void> {
    if (this.pref !== undefined) {
      return;
    }
    this.pref = await preferences.getPreferences(context, PREF_NAME);
  }

  /** 写入完整会话快照（立即 flush）。 */
  public async saveSession(snapshot: PlaybackProgressSnapshot): Promise<void> {
    const pref = this.pref;
    if (pref === undefined) {
      return;
    }
    const pos = snapshot.positionMs < 0 ? 0 : Math.floor(snapshot.positionMs);
    await pref.put(KEY_SONG_URI, snapshot.songUri);
    await pref.put(KEY_POSITION_MS, pos);
    await pref.put(KEY_QUEUE_URIS, JSON.stringify(snapshot.queueUris));
    await pref.put(KEY_SELECT_INDEX, snapshot.selectIndex);
    await pref.put(KEY_CONTEXT_KIND, snapshot.contextKind);
    await pref.put(KEY_CONTEXT_ID, snapshot.contextId);
    await pref.put(KEY_CONTEXT_TITLE, snapshot.contextTitle);
    await pref.flush();
  }

  /** 只更新曲目与位置（进度节流路径，队列/上下文沿用已存值）。 */
  public async save(songUri: string, positionMs: number): Promise<void> {
    const pref = this.pref;
    if (pref === undefined) {
      return;
    }
    const pos = positionMs < 0 ? 0 : Math.floor(positionMs);
    await pref.put(KEY_SONG_URI, songUri);
    await pref.put(KEY_POSITION_MS, pos);
    await pref.flush();
  }

  /** 读取会话快照（从未写过时返回空快照）。 */
  public load(): PlaybackProgressSnapshot {
    const snapshot = new PlaybackProgressSnapshot();
    const pref = this.pref;
    if (pref === undefined) {
      return snapshot;
    }
    snapshot.songUri = pref.getSync(KEY_SONG_URI, '') as string;
    snapshot.positionMs = pref.getSync(KEY_POSITION_MS, 0) as number;
    snapshot.selectIndex = pref.getSync(KEY_SELECT_INDEX, 0) as number;
    snapshot.contextKind = pref.getSync(KEY_CONTEXT_KIND, '') as string;
    snapshot.contextId = pref.getSync(KEY_CONTEXT_ID, '') as string;
    snapshot.contextTitle = pref.getSync(KEY_CONTEXT_TITLE, '') as string;
    const raw = pref.getSync(KEY_QUEUE_URIS, '') as string;
    if (raw !== '') {
      try {
        snapshot.queueUris = JSON.parse(raw) as string[];
      } catch (err) {
        snapshot.queueUris = [];
      }
    }
    return snapshot;
  }

  /** 清空会话（设置页「清空本地数据」用）。 */
  public async clear(): Promise<void> {
    const pref = this.pref;
    if (pref === undefined) {
      return;
    }
    await pref.delete(KEY_SONG_URI);
    await pref.delete(KEY_POSITION_MS);
    await pref.delete(KEY_QUEUE_URIS);
    await pref.delete(KEY_SELECT_INDEX);
    await pref.delete(KEY_CONTEXT_KIND);
    await pref.delete(KEY_CONTEXT_ID);
    await pref.delete(KEY_CONTEXT_TITLE);
    await pref.flush();
  }

  /** 毫秒 → m:ss（超过一小时为 h:mm:ss）。 */
  public static formatMs(ms: number): string {
    if (ms <= 0) {
      return '00:00';
    }
    const totalSeconds = Math.floor(ms / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    const mm = minutes < 10 ? '0' + minutes : String(minutes);
    const ss = seconds < 10 ? '0' + seconds : String(seconds);
    if (hours > 0) {
      const hh = hours < 10 ? '0' + hours : String(hours);
      return `${hh}:${mm}:${ss}`;
    }
    return `${mm}:${ss}`;
  }
}
