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

import { SongApiDto } from '../api/MusicApiDtos';
import { MusicSongRow } from '../data/MusicSongRow';
import { MusicDbApi } from '../util/MusicDbApi';
import { MusicAppState } from './MusicAppState';
import { PlayQueueContext, PlaySourceKind } from './PlayQueueContext';

/**
 * 播放队列的工具集。
 *
 * 队列有两份表示：
 * - {@link MusicAppState.playQueueUris}：稳定 URI（apple:<id>），持久化用，**源头**；
 * - {@link MusicAppState.playQueueIds}：当前 RDB 的自增 id，播放/查询用，**派生**。
 *
 * 之所以不直接持久化 id：`syncAppleSongs` 每次同步都会 `DELETE FROM songs WHERE
 * folder = 'apple'` 再重插，AUTOINCREMENT 使所有 id 全部改变 —— 之前持久化数字
 * id 的队列在每次启动同步后都会整体失效（表现：播放条空白、队列被整库顶替、
 * 小组件只播一首）。
 */
export class PlayQueueUtil {
  /** 把歌曲列表写进 AppState（队列 + 来源上下文），返回当前行 id 数组。 */
  public static apply(appState: MusicAppState, songs: SongApiDto[], ctx: PlayQueueContext): number[] {
    const uris: string[] = [];
    const ids: number[] = [];
    for (let i = 0; i < songs.length; i++) {
      uris.push(songs[i].src);
      ids.push(songs[i].id);
    }
    appState.playQueueUris = uris;
    appState.playQueueIds = ids;
    appState.playContextKind = ctx.kind;
    appState.playContextId = ctx.id;
    appState.playContextTitle = ctx.title;
    return ids;
  }

  /** 当前队列的来源上下文。 */
  public static contextOf(appState: MusicAppState): PlayQueueContext {
    const ctx = new PlayQueueContext();
    const kind: string = appState.playContextKind;
    if (kind === PlaySourceKind.ALBUM) {
      ctx.kind = PlaySourceKind.ALBUM;
    } else if (kind === PlaySourceKind.PLAYLIST) {
      ctx.kind = PlaySourceKind.PLAYLIST;
    } else if (kind === PlaySourceKind.ARTIST) {
      ctx.kind = PlaySourceKind.ARTIST;
    } else if (kind === PlaySourceKind.SEARCH) {
      ctx.kind = PlaySourceKind.SEARCH;
    } else {
      ctx.kind = PlaySourceKind.LIBRARY;
    }
    ctx.id = appState.playContextId;
    ctx.title = appState.playContextTitle;
    return ctx;
  }

  /** 队首到队尾的歌曲 URI 快照（用于持久化）。 */
  public static queueUris(appState: MusicAppState): string[] {
    if (appState.playQueueUris.length > 0) {
      return [...appState.playQueueUris];
    }
    // 兜底：早期版本只写 id，这里按 id 反查 URI。
    const out: string[] = [];
    for (let i = 0; i < appState.playQueueIds.length; i++) {
      const dto = MusicDbApi.getInstance().getSongById(appState.playQueueIds[i]);
      if (dto !== undefined) {
        out.push(dto.src);
      }
    }
    return out;
  }

  /** 当前曲目的 URI（未知时返回空串）。 */
  public static currentUri(appState: MusicAppState): string {
    const uris = appState.playQueueUris;
    const idx = appState.selectIndex;
    if (idx >= 0 && idx < uris.length) {
      return uris[idx];
    }
    const dto = appState.resolveSongAtQueueIndex(idx);
    return dto !== undefined ? dto.src : '';
  }

  /**
   * 用稳定 URI 重建 id 镜像，并尽量把 selectIndex 落在同一首歌上。
   *
   * 两个调用时机：
   * 1. 冷启动恢复快照（此时 id 已经是新的）；
   * 2. 资料库同步完成（songs 表被重建，内存里的 id 全部悬空）。
   *
   * @returns 重建后仍有效的曲目数。
   */
  public static remapIds(appState: MusicAppState): number {
    const uris = appState.playQueueUris;
    if (uris.length === 0) {
      return 0;
    }
    const currentUri: string = PlayQueueUtil.currentUri(appState);
    const api = MusicDbApi.getInstance();
    const ids: number[] = [];
    const keptUris: string[] = [];
    let newIndex = -1;
    for (let i = 0; i < uris.length; i++) {
      const row: MusicSongRow | undefined = api.getSongRowByUri(uris[i]);
      if (row === undefined) {
        continue;
      }
      if (uris[i] === currentUri) {
        newIndex = ids.length;
      }
      ids.push(row.id);
      keptUris.push(uris[i]);
    }
    appState.playQueueUris = keptUris;
    appState.playQueueIds = ids;
    if (newIndex >= 0) {
      appState.selectIndex = newIndex;
    } else if (appState.selectIndex >= ids.length) {
      appState.selectIndex = ids.length > 0 ? ids.length - 1 : 0;
    }
    return ids.length;
  }
}
