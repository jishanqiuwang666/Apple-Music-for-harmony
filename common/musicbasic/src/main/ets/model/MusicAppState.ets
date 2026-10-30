import { SongApiDto } from '../api/MusicApiDtos';
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
 * Global observable playback state (AppStorageV2 key: MusicAppState).
 * Playback requests use {@link PlaybackIntentState} and are applied by the product shell, then media services.
 */
import { SongDtoMapper } from '../api/SongDtoMapper';
import { SongItem } from './SongData';
import { MusicDbApi } from '../util/MusicDbApi';
import { Logger } from '../util/Logger';

@ObservedV2
export class  MusicAppState {
  /** Current queue: song ids only; rows resolved on demand via {@link MusicDbApi}. */
  @Trace public playQueueIds: number[] = [];
  /**
   * 队列的稳定 URI 形态（apple:<id>），是队列的**源头**；playQueueIds 是它
   * 在当前 RDB 里的 id 镜像。资料库同步会重建 songs 表（id 全变），所以持久化
   * 必须存 URI，恢复/同步后再 remap 回 id。
   */
  @Trace public playQueueUris: string[] = [];
  /** 队列来源类型（PlaySourceKind 的字符串值），决定「继续播放」进度记在谁身上。 */
  @Trace public playContextKind: string = '';
  /** 队列来源 id（专辑为 `专辑名\u0001艺人名`，歌单为歌单 ID）。 */
  @Trace public playContextId: string = '';
  /** 队列来源标题（展示用，可为空）。 */
  @Trace public playContextTitle: string = '';
  /** Index in {@link playQueueIds} for the current track. */
  @Trace public selectIndex: number = 0;
  /** Whether audio is currently playing. */
  @Trace public isPlay: boolean = false;
  /** Elapsed position for the progress bar (0..progressMax when known). */
  @Trace public progress: number = 0;
  /** Duration for the current track, or 0/1 when unknown. */
  @Trace public progressMax: number = 0;
  /** Formatted current time string for UI. */
  @Trace public currentTime: string = '00:00';
  /** Formatted total duration string for UI. */
  @Trace public totalTime: string = '00:00';
  /** Whether the full-screen player overlay is visible. */
  @Trace public isShowPlay: boolean = false;
  /** Time spent on the now-playing sub-page (e.g. to auto-hide chrome). */
  @Trace public pageShowTime: number = 0;
  /** UI volume in 0..1; mirrored to the player when applied. */
  @Trace public volume: number = 0.4;
  /** Cold-start hint for first-launch UI behavior. */
  @Trace public isFirstLaunch: boolean = true;
  /**
   * 设置抽屉是否展开（由 Index 维护）。各板块**首页**按返回时用它判断语义：
   * 抽屉开着 → 关抽屉；否则回桌面。见 features/library 的 HomeBack。
   */
  @Trace public drawerOpen: boolean = false;
  /**
   * 收藏横排的卡片正在被拖动排序（拖动期间列表不跟着滚、外壳让出热区）。
   */
  @Trace public sortDragActive: boolean = false;
  /**
   * 当前压在栈上的「详情页」层数（艺人/专辑/歌单详情页在 aboutToAppear +
   * aboutToDisappear - 维护）。外壳据此判断「现在是不是主界面」：
   * 主界面上才显示顶部那两颗圆钮（同步 + 资料库搜索）。
   */
  @Trace public detailPageDepth: number = 0;
  /** Full-screen player background color sampled from current artwork. */
  @Trace public imageColor: string = 'rgba(0, 0, 2, 1.00)';
  /**
   * 当前曲目封面的主色（**不透明 hex**，如 `#8E5A3C`）。
   *
   * 供「背景流光」取色用：流光是同色系两个明度之间往返流动，
   * 所以这里只保留一个主色，明度在消费端派生 —— 多方各取一套颜色是
   * 「流光里出现杂色」的根源（蓝、褐混在一起流动，怎么调都像脏色）。
   */
  @Trace public flowColor: string = '';
  /** HdsTabs mini bar expanded (true) vs compact (false). */
  @Trace public miniBarExpanded: boolean = false;
  /**
   * 正在下载/解密时的加载提示（空串 = 没有加载中）。
   * 未命中的 Apple Music 曲目要先「下载 + 解密」才能播，慢网下可能十几秒，
   * 播放条据此显示转圈而不是干等。
   */
  @Trace public loadingText: string = '';

  /**
   * Resolves a {@link SongItem} for the given queue index without keeping a full table in memory.
   * @param queueIndex Index into playQueueIds.
   * @returns A song item, or undefined if the index is out of range.
   */
  /**
   * 临时曲目登记表（id -> SongItem）：
   * 用于**不在 songs 表里**的曲目（例如收藏专辑从 Apple 目录临时拉取的曲目）。
   * 播放链路各处最终都会走 {@link resolveSongAtQueueIndex}，在这里兜底即可覆盖所有入口。
   */
  public tempSongItems: Map<number, SongItem> = new Map<number, SongItem>();

  /** 登记一首「不在 songs 表里」的临时曲目（src 形如 apple:<id>）。 */
  public registerTempSong(dto: SongApiDto): void {
    if (dto.id < 900000 || !dto.src.startsWith('apple:')) {
      return;
    }
    const item: SongItem = SongDtoMapper.toSongItem(dto);
    this.tempSongItems.set(dto.id, item);
  }

  public resolveSongAtQueueIndex(queueIndex: number): SongItem | undefined {
    const ids = this.playQueueIds;
    if (queueIndex < 0 || queueIndex >= ids.length) {
      return undefined;
    }
    const wantId: number = ids[queueIndex];
    const dto = MusicDbApi.getInstance().getSongById(wantId);
    if (dto !== undefined) {
      return SongDtoMapper.toSongItem(dto);
    }
    // 库里没有：先回退到临时登记（其 src 形如 apple:<曲目id>，走既有下载解密链路）
    const temp: SongItem | undefined = this.tempSongItems.get(wantId);
    if (temp !== undefined) {
      return temp;
    }
    // ★ id 失效兜底（「播完第一首之后整个队列都点不动、只能重启 App」的根因）
    //
    // `syncAppleSongs` 每次资料库同步都会 `DELETE FROM songs WHERE folder='apple'`
    // 再重插，AUTOINCREMENT 让**所有歌曲 id 全部重排**。内存里的 playQueueIds
    // 是同步前抓的，一秒之后就全部悬空：当前这首已经装好了不受影响，但
    // 「自动下一首」和用户点列表都会 resolve 失败 → 静默什么都不播，
    // 只有重启（队列从新表重建）才恢复。
    //
    // 队列同时保存了稳定的 {@link playQueueUris}，这里按 uri 找回并把派生 id
    // 就地修好 —— 一处兜底覆盖所有入口（自动切歌、点列表、小组件、播放历史）。
    const uris: string[] = this.playQueueUris;
    if (queueIndex < uris.length) {
      const row = MusicDbApi.getInstance().getSongByUri(uris[queueIndex]);
      if (row !== undefined) {
        ids[queueIndex] = row.id;
        // 这条日志平时应该看不到；一旦出现就说明队列 id 被重建过（资料库同步），
        // 而按 uri 兜底救回来了。留着它便于日后定位同类问题。
        Logger.warn('QID-HEAL index=' + queueIndex + ' old=' + wantId + ' new=' + row.id
          + ' uri=' + uris[queueIndex]);
        return SongDtoMapper.toSongItem(row);
      }
    }
    return undefined;
  }

  /**
   * @returns The item at {@link selectIndex}, or undefined.
   */
  public getCurrentSongItem(): SongItem | undefined {
    return this.resolveSongAtQueueIndex(this.selectIndex);
  }

  /**
   * @returns The length of playQueueIds.
   */
  public getQueueLength(): number {
    return this.playQueueIds.length;
  }
}
