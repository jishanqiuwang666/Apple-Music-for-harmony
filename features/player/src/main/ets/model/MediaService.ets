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

/*
 * Moved from common/mediacommon/src/main/ets/utils/MediaService.ets
 */

import { AppStorageV2 } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resourceManager } from '@kit.LocalizationKit';

import {
  AppStorageKeys,
  AppleCache,
  AppleUi,
  getAppRuntime,
  Logger,
  MusicAppState,
  MusicDbApi,
  PlaybackProgressStore,
  SongApiDto,
  SongItem,
  StringResourceUtil,
  WidgetStateSnapshot,
  WidgetStateStore,
  WidgetUpdater,
  PlaybackProgressSnapshot,
  AppleArtworkCache,
  PlayContextKeys,
  PlayQueueContext,
  PlayQueueUtil
} from 'musicbasic';
import SongItemBuilder from '../util/SongItemBuilder';
import { AudioPlayerState, MusicPlayMode } from './MusicData';
import { BackgroundUtil } from '../util/BackgroundUtil';
import { LiveViewController } from '../util/LiveViewController';
import { MediaTools } from '../util/MediaTools';

const TAG = 'MediaService';

/**
 * Coordinates local audio playback (AVPlayer), shared UI state (MusicAppState), and system AVSession.
 */
export class MediaService {
  /** UIAbility context from application runtime; used for resources, want agent, and background task. */
  private get abilityContext(): common.UIAbilityContext | undefined {
    return getAppRuntime().context;
  }
  /** Underlying Harmony AVPlayer; undefined until createAVPlayer succeeds. */
  public avPlayer?: media.AVPlayer;
  /** Active AV session for lock screen / headset / system media controls. */
  private session?: avSession.AVSession;
  /** Builds SongItem and fd/url descriptor for AVPlayer.fdSrc. */
  private songItemBuilder: SongItemBuilder = new SongItemBuilder();
  /** Resolved current track metadata for internal use. */
  private songItem: SongItem = new SongItem();
  /** Current repeat / shuffle mode. */
  private playMode: MusicPlayMode = MusicPlayMode.ORDER;
  /** AVPlayer high-level lifecycle state mirror. */
  private state: AudioPlayerState = AudioPlayerState.IDLE;
  /** True until the first fdSrc has been applied on this player instance. */
  private isFirst: boolean = true;
  /**
   * 正在由 loadAsset 显式加载新音源。
   *
   * 设 fdSrc 前必须先 reset 到 idle，而 reset 会触发 stateCall('idle')。
   * 那个回调需要 await build()（Apple 音源未命中缓存时要下载+解密几秒），
   * 期间这次切歌会被 AVPlayer 状态机丢掉 —— 表现就是「点了歌一直没反应」。
   * 因此显式加载期间让 idle 回调直接让路。
   */
  private explicitLoad: boolean = false;
  /**
   * 换轨请求序号：只有最新一次装载才允许把结果应用到播放器上。
   *
   * 换轨是「建新实例 → 装源 → prepare」一串异步动作，期间用户可能又点了别的歌，
   * 或者自动切歌与上/下一首撞在一起。旧实现没有序号，晚到的旧链会把新实例
   * 覆盖成旧歌（日志表现为「点了 A 却在放 B」，甚至两边互相 reset）。
   */
  private loadToken: number = 0;
  /** True after successful prepare() for the current fdSrc. */
  private isPrepared: boolean = false;
  /** Current index within the play queue (aligned with MusicAppState.selectIndex after update). */
  private musicIndex: number = 0;
  /** True when displayed progress should track AVPlayer time updates (false during seek). */
  private isCurrent: boolean = true;
  /** seek 后 isCurrent 的自愈定时器（seekDone 偶发丢失时兜底）。 */
  private isCurrentRecoverTimer: number = 0;
  /** When false, prepared state will not auto-start play (e.g. load-only). */
  private isNeedPlay: boolean = true;
  /** Queue index to load once AVPlayer is ready; -1 means none. */
  private pendingLoadIndex: number = -1;
  /** 待播的「按源」曲目（播放器尚未创建时暂存）。 */
  private pendingLoadBySrc: SongItem | undefined = undefined;
  /** Whether the pending load should skip starting playback. */
  private pendingLoadOnly: boolean = false;
  /** True while playback is suspended due to an audio interrupt (resume on share-end). */
  private interruptPaused: boolean = false;
  /** Consecutive playback errors; auto-skip stops after this many. */
  private errorCount: number = 0;
  /** Position (ms) to seek to right after the next prepare (restart resume); -1 = none. */
  private pendingResumeMs: number = -1;
  /** Play after the pending resume seek completes (restart auto-resume path). */
  private pendingPlayAfterSeek: boolean = false;
  /** Timestamp of the last throttled progress persist (5s cadence). */
  private lastPersistAt: number = 0;
  /** True when a widget play request arrived before the library/queue was ready. */
  private widgetPlayPending: boolean = false;
  /**
   * 队列已经播到队尾并停止（用户要求：播完最后一首直接停止，不循环、不回第一首、
   * 不接着放别的）。
   *
   * 必须显式置位：队列结束时 playNext 会 reset()，reset 让 AVPlayer 回到 idle，
   * 而 idle 回调原本会「把当前索引重新装载一遍」，于是最后一首被自动重播
   * （日志实证：queue finished → reset → idle → loadAsset → playing）。
   * 下一次真正的 loadAsset 会清掉这个标记。
   */
  private queueFinished: boolean = false;

  /** AVPlayer seekDone: marks seek finished and updates AVSession position. */
  private seekCall: (seekDoneTime: number) => void = (seekDoneTime: number) => {
    this.isCurrent = true;
    if (this.isCurrentRecoverTimer !== 0) {
      clearTimeout(this.isCurrentRecoverTimer);
      this.isCurrentRecoverTimer = 0;
    }
    Logger.info(TAG, `AVPlayer seek succeeded, seek time is ${seekDoneTime}`);
    if (this.pendingPlayAfterSeek) {
      this.pendingPlayAfterSeek = false;
      if (this.avPlayer && this.isNeedPlay) {
        this.ensureBackgroundAudioTask();
        this.avPlayer.play();
      }
    }
    this.setPlayState({
      position: {
        elapsedTime: this.getCurrentTime(),
        updateTime: new Date().getTime()
      }
    });
  };
  /** AVPlayer error: logs, auto-skips to the next track (bounded), and resets on failure. */
  private errorCall: (err: BusinessError) => void = (err: BusinessError) => {
    Logger.error(TAG, `Invoke avPlayer failed, code is ${err.code}, message is ${err.message}`);
    this.errorCount++;
    if (this.errorCount >= 3) {
      Logger.error(TAG, 'Too many playback errors, stop auto-skip.');
      this.errorCount = 0;
      this.updateIsPlay(false);
      return;
    }
    const len = this.getQueueLength();
    if (len > 0 && this.getAppState().isPlay) {
      this.playNextAuto(true);
    }
  };
  /** AVPlayer audioInterrupt: pauses on forced interrupts, resumes when shared audio releases. */
  private audioInterruptCall: (info: audio.InterruptEvent) => void = (info: audio.InterruptEvent) => {
    Logger.info(TAG, `audioInterrupt force=${info.forceType} hint=${info.hintType} type=${info.eventType}`);
    if (info.forceType === audio.InterruptForceType.INTERRUPT_FORCE &&
      (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
      info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP)) {
      // Forced interruption (e.g. incoming call): pause and remember to resume later.
      if (this.state === AudioPlayerState.PLAY) {
        this.interruptPaused = true;
        this.pause();
      }
    } else if (info.forceType === audio.InterruptForceType.INTERRUPT_SHARE &&
      info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      // Shared audio released the channel: resume if we were interrupted.
      if (this.interruptPaused) {
        this.interruptPaused = false;
        this.play();
      }
    }
  };
  /**
   * AVPlayer 进入 prepared 后要做的事：记录时长、按需 seek、启动播放、写播控元数据。
   *
   * 抽出来是因为「prepare() 成功」和「收到 stateChange('prepared')」不保证都发生：
   * 实测切换曲目时出现过 prepare 成功却没有 prepared 事件的情况，表现是既不
   * 开始播放、isPrepared 也一直是 false（下一次切换又走错分支）。所以
   * {@link stateCall} 和 prepare() 的成功回调都会调用它，用 isPrepared 去重。
   */
  private onPrepared(): void {
    if (this.isPrepared) {
      return;
    }
    this.state = AudioPlayerState.PREPARED;
    this.isPrepared = true;
    const appState = this.getAppState();
    appState.totalTime = MediaTools.msToCountdownTime(this.getDuration());
    appState.progressMax = this.getDuration();
    if (this.pendingResumeMs > 0 && this.avPlayer) {
      // Restart resume: seek to the stored position; when playback was
      // requested, start it only after seekDone lands (no 0-position blip).
      const resumeMs = this.pendingResumeMs;
      this.pendingResumeMs = -1;
      if (this.isNeedPlay) {
        this.pendingPlayAfterSeek = true;
      }
      this.seek(resumeMs);
    }
    if (this.avPlayer && this.isNeedPlay && !this.pendingPlayAfterSeek) {
      this.ensureBackgroundAudioTask();
      this.avPlayer.play();
    }
    this.setAVMetadata();
    this.isNeedPlay = true;
    // 就绪了：把看门狗的自愈计数清零，下次异常重新给满额度。
    this.healCount = 0;
    this.notReadySince = 0;
    Logger.info(TAG, 'AVPlayer prepared succeeded.');
  }

  /** AVPlayer timeUpdate: refreshes countdown label and progress in MusicAppState when active. */
  private updateTimeCall: (updateTime: number) => void = (updateTime: number) => {
    if (this.isCurrent) {
      const appState = this.getAppState();
      appState.currentTime = MediaTools.msToCountdownTime(updateTime);
      appState.progress = updateTime;
      // Throttled persist (5s): keeps the restart-resume position fresh.
      const now = Date.now();
      if (now - this.lastPersistAt >= 5000) {
        this.lastPersistAt = now;
        this.persistProgress(this.songItem.src, updateTime);
      }
    }
  };
  /**
   * AVPlayer 状态机回调。
   *
   * 以前是 `async` 的（因为 idle 分支里要 await build），现在所有异步动作都
   * 下发给 switchTrack / applySongSource，这里保持同步 —— 状态回调里不做
   * 长耗时操作，时序才可预测。
   */
  private stateCall: (state: string) => void = (state: string) => {
    switch (state) {
      case 'idle':
        Logger.info(TAG, 'AVPlayer state idle called.');
        if (this.queueFinished) {
          // 队列播完后的 reset 也会回到 idle：这里必须收手，否则最后一首被重播。
          Logger.info(TAG, 'idle after queue finished: stay stopped');
          break;
        }
        if (this.explicitLoad) {
          // 显式换轨进行中：新音源由 switchTrack 那条线负责设 fdSrc。
          break;
        }
        // 播放器意外回到 idle（被系统回收 / 被 stop）：把当前曲目重新装一遍。
        // 这里复用 applySongSource，别再把「build + 设 fdSrc + 起轮询」抄一遍。
        this.state = AudioPlayerState.IDLE;
        {
          const idleSong: SongItem | undefined = this.getSongItemAtQueueIndex(this.musicIndex);
          if (idleSong !== undefined) {
            this.applySongSource(idleSong, false).catch((err: Error) => {
              Logger.error(TAG, `idle reload failed ${err.message}`);
            });
          }
        }
        break;
      case 'initialized':
        Logger.info(TAG, 'AVPlayer state initialized called.');
        this.state = AudioPlayerState.INITIALIZED;
        if (this.avPlayer) {
          try {
            this.avPlayer.prepare().then(() => {
              Logger.info(TAG, 'AVPlayer prepare succeeded.');
              // 只记日志，不在这里置 isPrepared：prepare() 的 Promise resolve
              // 并不代表播放器已经进入 prepared（实测 duration 仍是 -1），
              // 提前置位会让后续所有逻辑走错分支。真正就绪由状态轮询判定。
            }, (err: BusinessError) => {
              Logger.error(TAG, `Invoke prepare failed, code is ${err.code}, message is ${err.message}`);
              this.onPrepareFailed();
            });
          } catch (err) {
            // prepare() 同步抛异常时 .then/.catch 都不会执行，整条链会静默中断。
            const e = err as BusinessError;
            Logger.error(TAG, `prepare throw ${e.code} ${e.message}`);
            this.onPrepareFailed();
          }
        }
        break;
      case 'prepared':
        Logger.info(TAG, 'AVPlayer state prepared called.');
        this.onPrepared();
        break;
      case 'playing':
        Logger.info(TAG, 'AVPlayer state playing called.');
        this.state = AudioPlayerState.PLAY;
        this.ensureBackgroundAudioTask();
        break;
      case 'paused':
        Logger.info(TAG, 'AVPlayer state paused called.');
        this.state = AudioPlayerState.PAUSE;
        break;
      case 'completed':
        Logger.info(TAG, 'AVPlayer state completed called.');
        this.state = AudioPlayerState.COMPLETED;
        // **必须跳出本实例的回调栈再换轨**：换轨要建新实例、释放旧实例，
        // 在旧实例自己的 stateChange 回调里做这些会在真机上偶发卡死
        // （release() 等回调返回，而这里正等着 release()）——表现就是
        // 「第一首播完，第二首永远不播，只能重启 App」。挪到下一个宏任务。
        setTimeout(() => {
          this.playNextAuto(false);
        }, 0);
        break;
      case 'stopped':
        Logger.info(TAG, 'AVPlayer state stopped called.');
        this.state = AudioPlayerState.STOP;
        // 这里**不能**再 reset()：reset 会连锁触发 idle，而 idle 又会去装载
        // 当前索引（旧实现因此和 loadAsset 抢同一首歌，两个装载链互相踩）。
        // 换轨一律走 switchTrack()，旧实例最后统一异步释放。
        break;
      case 'released':
        Logger.info(TAG, 'AVPlayer state released called.');
        this.state = AudioPlayerState.RELEASED;
        break;
      default:
        Logger.info(TAG, 'AVPlayer state unknown called.');
        this.state = AudioPlayerState.UNKNOWN;
        break;
    }
    this.updateIsPlay(this.state === AudioPlayerState.PLAY);
  };
  /** AVSession remote play: loads first asset or resumes local play. */
  private playCall: () =>void = () => {
    Logger.info(TAG, `on play , do play task`);
    if (this.isFirst) {
      this.loadAsset(this.getValidSelectIndex());
    } else {
      this.play();
    }
  };
  /** AVSession remote pause. */
  private pauseCall: () =>void = () => {
    Logger.info(TAG, `on pause , do pause task`);
    this.pause();
  };
  /** AVSession remote next track. */
  private playNextCall: () =>void = () => {
    Logger.info(TAG, `on playNext , do playNext task`);
    this.playNextAuto(true);
  };
  /** AVSession remote previous track. */
  private playPreviousCall: () =>void = () => {
    Logger.info(TAG, `on playPrevious , do playPrevious task`);
    this.playPrevious();
  };
  /** AVPlayer volumeChange: mirrors volume into MusicAppState. */
  private volumeChangeCall: (volume: number) => void = (volume: number) => {
    Logger.info(TAG, `on volumeChangeCall, do volumeChange task`);
    this.getAppState().volume = volume;
  };

  /** Shared observable app state (queue, play flag, progress) bound to AppStorageV2. */
  private getAppState(): MusicAppState {
    return AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  }

  /** Persists the current track + position (lazy-inits the store; skips empty URIs). */
  private persistProgress(songUri: string, positionMs: number): void {
    if (songUri === '') {
      return;
    }
    const ctx = this.abilityContext;
    if (ctx === undefined) {
      return;
    }
    const store = PlaybackProgressStore.getInstance();
    store.init(ctx).then(() => {
      store.save(songUri, positionMs).catch((err: BusinessError) => {
        Logger.warn(TAG, `persist progress failed: ${err.message}`);
      });
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, `progress store init failed: ${err.message}`);
    });
    // 专辑 / 歌单的「继续播放」进度：只有这两种来源记录（用户定的规则：
    // 在歌单里播不会打乱专辑进度，反之亦然）。
    this.saveContextProgress(songUri, positionMs);
  }

  /** 写入当前来源（专辑 / 歌单）的继续播放进度。 */
  private saveContextProgress(songUri: string, positionMs: number): void {
    const context: PlayQueueContext = PlayQueueUtil.contextOf(this.getAppState());
    const key: string = PlayContextKeys.progressKey(context);
    if (key === '') {
      return;
    }
    MusicDbApi.getInstance().saveResume(key, context.kind, songUri, positionMs);
  }

  /** 整张专辑 / 歌单播完：清掉该来源的继续播放进度。 */
  private clearContextProgress(): void {
    const context: PlayQueueContext = PlayQueueUtil.contextOf(this.getAppState());
    const key: string = PlayContextKeys.progressKey(context);
    if (key === '') {
      return;
    }
    MusicDbApi.getInstance().clearResume(key);
    Logger.info(TAG, `clearContextProgress: ${key}`);
  }

  /**
   * 持久化完整会话：队列 URI + 索引 + 当前曲目 + 位置 + 来源上下文。
   * 队列存 URI 而不是 id —— songs 表每次同步都会重建，id 会全部改变。
   */
  private saveSessionSnapshot(): void {
    const ctx = this.abilityContext;
    if (ctx === undefined) {
      return;
    }
    const appState = this.getAppState();
    const context: PlayQueueContext = PlayQueueUtil.contextOf(appState);
    const snapshot = new PlaybackProgressSnapshot();
    snapshot.queueUris = PlayQueueUtil.queueUris(appState);
    snapshot.selectIndex = appState.selectIndex;
    snapshot.songUri = PlayQueueUtil.currentUri(appState);
    snapshot.positionMs = this.getCurrentTime();
    snapshot.contextKind = context.kind;
    snapshot.contextId = context.id;
    snapshot.contextTitle = context.title;
    const store = PlaybackProgressStore.getInstance();
    store.init(ctx).then(() => store.saveSession(snapshot)).catch((err: BusinessError) => {
      Logger.warn(TAG, `save session failed: ${err.message}`);
    });
  }

  /**
   * 资料库同步完成后重建队列的 id 镜像。
   *
   * syncAppleSongs 会 DELETE + 重插 songs 表，内存里的 playQueueIds 全部悬空：
   * 不重建的话播放条会变空、并且下一次「兜底填全库」会把专辑队列顶掉。
   */
  public remapQueueAfterSync(): void {
    const appState = this.getAppState();
    if (appState.playQueueUris.length === 0) {
      return;
    }
    const before = appState.playQueueIds.length;
    const kept = PlayQueueUtil.remapIds(appState);
    this.musicIndex = appState.selectIndex;
    Logger.info(TAG, `remapQueueAfterSync: ${before} -> ${kept}`);
  }

  /**
   * Restores the queue index and position from a stored snapshot (called at
   * startup after the DB loads). Playback does not auto-start; the next play
   * request seeks to the stored position. Fills the queue from the DB when
   * the UI bootstrapped before the library finished loading.
   */
  public restorePlaybackSession(snapshot: PlaybackProgressSnapshot): void {
    if (!snapshot.hasSession()) {
      Logger.info(TAG, 'restore: no stored session');
      return;
    }
    const appState = this.getAppState();
    appState.playContextKind = snapshot.contextKind;
    appState.playContextId = snapshot.contextId;
    appState.playContextTitle = snapshot.contextTitle;
    appState.playQueueUris = [...snapshot.queueUris];
    appState.selectIndex = snapshot.selectIndex < 0 ? 0 : snapshot.selectIndex;
    // URI → 当前 RDB 里的 id（同步会重建 songs 表，id 每次都不一样）。
    let kept: number = PlayQueueUtil.remapIds(appState);
    if (kept === 0) {
      // 队列里的歌一首都不剩（换账号 / 清过资料库）：退回资料库全量，避免空队列。
      Logger.info(TAG, 'restore: queue empty after remap, fall back to library');
      appState.playQueueUris = [];
      appState.playQueueIds = MusicDbApi.getInstance().getSongList().map((dto: SongApiDto) => dto.id);
      appState.selectIndex = 0;
      kept = appState.playQueueIds.length;
      // 老版本只存了数字 id（同步后会失效），队列退化时至少把「上次那首」定位回来。
      if (snapshot.songUri !== '') {
        for (let i = 0; i < appState.playQueueIds.length; i++) {
          const item: SongApiDto | undefined =
            MusicDbApi.getInstance().getSongById(appState.playQueueIds[i]);
          if (item !== undefined && item.src === snapshot.songUri) {
            appState.selectIndex = i;
            break;
          }
        }
      }
    }
    const found: number = appState.selectIndex;
    this.musicIndex = found;
    const dto: SongApiDto | undefined = MusicDbApi.getInstance().getSongById(appState.playQueueIds[found]);
    if (dto !== undefined && dto.duration > 0) {
      // 恢复时长：否则播放条的进度圈会按 total=1 画成整圆，看起来像没有进度条。
      appState.progressMax = dto.duration;
      appState.totalTime = PlaybackProgressStore.formatMs(dto.duration);
    }
    // 不自动出声：用户按播放才继续；下一次 loadAsset 会 seek 到这个位置。
    this.pendingResumeMs = snapshot.positionMs > 0 ? snapshot.positionMs : -1;
    if (snapshot.positionMs > 0) {
      appState.progress = snapshot.positionMs;
      appState.currentTime = PlaybackProgressStore.formatMs(snapshot.positionMs);
    }
    Logger.info(TAG,
      `restored session: queue=${kept} index=${found} pos=${snapshot.positionMs} kind=${snapshot.contextKind}`);
  }

  /** Starts or refreshes continuous background audio task (required after some track-switch paths). */
  private ensureBackgroundAudioTask(): void {
    BackgroundUtil.startContinuousTask(this.abilityContext);
  }

  /** Called when the app goes to background while playing; keeps continuous task if needed. */
  public onApplicationBackground(): void {
    this.persistProgress(this.songItem.src, this.getCurrentTime());
    if (this.getAppState().isPlay) {
      this.ensureBackgroundAudioTask();
    }
  }

  /** Resolves SongItem at queue index via MusicAppState. */
  private getSongItemAtQueueIndex(index: number): SongItem | undefined {
    return this.getAppState().resolveSongAtQueueIndex(index);
  }

  /**
   * prepare 失败后的自愈：Apple 音源多半是缓存文件坏了（历史版本并发写留下的
   * 半截文件）。把这首的缓存作废，用户再点一次就会重新下载 —— 否则它会因为
   * 「缓存命中」而永远播不出来。
   */
  private onPrepareFailed(): void {
    const src: string = this.songItem.src;
    this.isPrepared = false;
    if (!src.startsWith('apple:')) {
      return;
    }
    const songId: string = src.substring('apple:'.length);
    Logger.warn(TAG, `prepare 失败，作废缓存并提示重试: ${songId}`);
    AppleCache.invalidate(songId).then(() => {
      AppleUi.toast('这首歌的缓存有问题，已清除，再点一次即可', 4500);
    });
  }

  /**
   * 预取队列里的下一首（Apple Music 音源）。
   *
   * 当前曲目开始加载时就在后台把下一首「下载 + 解密」进缓存，切歌时直接命中
   * 本地文件，避免每次切歌都等 5~10 秒。不阻塞播放，失败只记日志。
   * 随机播放模式不预取（下一首不确定，预取会浪费流量）。
   */
  private preloadNextTrack(): void {
    if (this.playMode === MusicPlayMode.RANDOM) {
      return;
    }
    const len = this.getQueueLength();
    const next = this.musicIndex + 1;
    if (len === 0 || next >= len) {
      return;
    }
    const nextId: number = this.getAppState().playQueueIds[next];
    const song: SongApiDto | undefined = MusicDbApi.getInstance().getSongById(nextId);
    if (song === undefined) {
      return;
    }
    const src: string = song.src;
    if (!src.startsWith('apple:')) {
      return;
    }
    const songId: string = src.substring('apple:'.length);
    // 资料库曲目与歌单曲目都走同一套「webPlayback 里换回 catalog id」的逻辑，
    // 所以这里统一按 true 请求。
    Logger.info(TAG, `preloadNextTrack: ${songId}`);
    AppleCache.preload(songId, true);
  }

  /** Current play queue length from MusicAppState. */
  private getQueueLength(): number {
    return this.getAppState().getQueueLength();
  }

  /** Clamps MusicAppState.selectIndex to a valid queue index (0 if empty or out of range). */
  private getValidSelectIndex(): number {
    const len = this.getQueueLength();
    const idx = this.getAppState().selectIndex;
    if (len === 0) {
      return 0;
    }
    if (idx < 0 || idx >= len) {
      return 0;
    }
    return idx;
  }

  /**
   * 处理「播放器还没建好时」挂起的两个装载请求。
   *
   * 两路都要消费掉：按队列下标（loadAsset）与按播放源（loadAssetBySrc）。
   * 旧实现只处理了前者，`pendingLoadBySrc` 写进去之后**再没人读** ——
   * 冷启动那一瞬间点「按源播放」会被静默丢掉。
   */
  private applyPendingLoadRequest(): void {
    if (this.pendingLoadIndex >= 0) {
      const pendingIndex: number = this.pendingLoadIndex;
      const pendingLoadOnly: boolean = this.pendingLoadOnly;
      this.pendingLoadIndex = -1;
      this.pendingLoadOnly = false;
      void this.loadAsset(pendingIndex, pendingLoadOnly);
    }
    const pendingSrc: SongItem | undefined = this.pendingLoadBySrc;
    if (pendingSrc !== undefined) {
      this.pendingLoadBySrc = undefined;
      this.switchTrack(pendingSrc, false).catch((err: Error) => {
        Logger.error(TAG, `pending load by src failed ${err.message}`);
      });
    }
  }

  // ───────────────────────── 看门狗（兜底自愈） ─────────────────────────
  //
  // 播放链是「AVPlayer 状态回调 + 若干异步步骤（建实例 / 下载解密 / 设 fdSrc）」
  // 串起来的，任何一环静默断掉，用户看到的表现都一样：
  // **这首歌之后怎么点都没反应，直到重启 App**（进程内状态坏了）。
  // 与其逐个去堵（历史上堵过三次，每次换一种断法），不如加一层确定性兜底：
  // 每秒核对一次「意图 vs 实际」，不一致就重建一次装载链。
  //
  // 成本：一个 1s 定时器 + 几次字段读取，可忽略；仅在异常时才真正干活。

  /** 看门狗定时器句柄（0 = 未启动）。 */
  private watchdogId: number = 0;
  /** 是否正在换轨（switchTrack 期间为 true）。 */
  private switching: boolean = false;
  /** 进入 completed 的时刻（0 = 当前不在 completed）。 */
  private completedAt: number = 0;
  /** 「想播但未就绪」的起始时刻（0 = 状态正常）。 */
  private notReadySince: number = 0;
  /** 连续自愈次数：超过上限就停手，别无限重试。 */
  private healCount: number = 0;
  /** completed 之后多久还没换轨就强制推进（毫秒）。 */
  private static readonly ADVANCE_GRACE_MS: number = 2500;
  /** 想播却一直没就绪多久后自愈（毫秒）。 */
  private static readonly NOT_READY_GRACE_MS: number = 6000;
  /** 连续自愈上限。 */
  private static readonly MAX_HEAL: number = 3;

  private startWatchdog(): void {
    if (this.watchdogId !== 0) {
      return;
    }
    this.watchdogId = setInterval(() => {
      this.watchdogTick();
    }, 1000);
  }

  /** 每秒一次的健康检查（只做判断，真正干活是异步的）。 */
  private watchdogTick(): void {
    if (this.switching) {
      return;
    }
    const now: number = Date.now();
    // ① 播完了却没换轨：completed 里的 setTimeout 可能被丢（后台冻结 / JS 忙）
    //    或者换轨链在别处断了。这里补一刀，最多 2.5s 就推进。
    if (this.state === AudioPlayerState.COMPLETED) {
      if (this.completedAt === 0) {
        this.completedAt = now;
        return;
      }
      if (now - this.completedAt > MediaService.ADVANCE_GRACE_MS) {
        this.completedAt = 0;
        Logger.warn(TAG, 'watchdog: completed 后仍未换轨，强制推进');
        this.playNextAuto(false);
      }
      return;
    }
    this.completedAt = 0;
    // ② 用户想播（isPlay）却一直没就绪：装载链中途断了，重建当前曲目。
    const appState = this.getAppState();
    if (!appState.isPlay || this.isPrepared || this.explicitLoad) {
      this.notReadySince = 0;
      return;
    }
    if (this.notReadySince === 0) {
      this.notReadySince = now;
      return;
    }
    if (now - this.notReadySince < MediaService.NOT_READY_GRACE_MS) {
      return;
    }
    if (this.healCount >= MediaService.MAX_HEAL) {
      Logger.error(TAG, 'watchdog: 连续自愈失败，停止重试（保持停止状态，等用户再点）');
      this.notReadySince = 0;
      this.healCount = 0;
      this.updateIsPlay(false);
      return;
    }
    this.healCount++;
    this.notReadySince = now;
    Logger.warn(TAG, `watchdog: 想播但未就绪，重建当前曲目（第 ${this.healCount} 次）`
      + ` idx=${this.musicIndex} state=${this.state}`);
    this.prepareRetry = 0;
    this.loadAsset(this.musicIndex).catch((err: Error) => {
      Logger.error(TAG, `watchdog reload failed ${err.message}`);
    });
  }

  /** Creates service, builds SongItemBuilder, and starts async AVPlayer creation. */
  public constructor() {
    this.songItemBuilder = new SongItemBuilder();
    this.initAudioPlayer();
    this.startWatchdog();
  }

          /** Global singleton stored on AppRuntime.mediaServiceRef. */
  public static getInstance(): MediaService {
    const rt = getAppRuntime();
    if (!rt.mediaServiceRef) {
      rt.mediaServiceRef = new MediaService();
    }
    return rt.mediaServiceRef as MediaService;
  }

  /** Creates AVPlayer, registers callbacks, creates AVSession, and drains pending load. */
  private initAudioPlayer(): void {
    media.createAVPlayer().then(async avPlayer => {
      if (avPlayer !== null) {
        this.avPlayer = avPlayer;
        this.bindPlayer(avPlayer);
        this.createSession();
        this.applyPendingLoadRequest();
      }
    }) .catch((error: BusinessError) => {
      Logger.error(TAG, 'this avPlayer: ', `catch error happened,error code is ${error.code}`);
    });
  }

  /**
   * 主动把 AVPlayer 推进到 prepared 状态。
   *
   * 实测（真机 HarmonyOS 6.1.1 / API 24）：切换曲目后 `prepare()` 的 Promise
   * 会 resolve，但 `stateChange('prepared')` 事件**不一定派发**，此时
   * `avPlayer.duration` 仍是 -1、`play()` 也无效 —— 用户看到的就是「点了歌
   * 一直没反应」（首曲因为是全新实例，事件正常，所以第一首总能播）。
   *
   * 这里不再依赖事件：每 200ms 读一次 `avPlayer.state`，处于 initialized
   * 就再补一次 prepare()，直到真正 prepared 再走 {@link onPrepared}；
   * 超时则走 {@link onPrepareFailed}（会提示并作废缓存），不会静默卡死。
   */
  private waitPrepared(attempt: number): void {
    if (this.isPrepared) {
      return;
    }
    const player = this.avPlayer;
    if (player === undefined) {
      return;
    }
    let st: string = '';
    let dur: number = -1;
    try {
      st = player.state;
      dur = player.duration;
    } catch (err) {
      return;
    }
    if (st === 'prepared' || st === 'playing' || st === 'paused' || st === 'completed') {
      this.onPrepared();
      return;
    }
    if (st === 'error' || st === 'released') {
      this.onPrepareFailed();
      return;
    }
    if (attempt >= 75) {
      if (this.prepareRetry < 2) {
        // 自愈：整条链路重来一遍（重建实例 + 重新装载），不打扰用户。
        this.prepareRetry++;
        this.reloadCurrent();
        return;
      }
      // 仍然不行：明确报错，别让用户干等。
      this.onPrepareFailed();
      return;
    }
    // 注意：这里**不能**再调一次 prepare()。prepare() 是异步的，200ms 一次的
    // 重复调用会把上一次正在进行的 prepare 反复打断，结果是永远停在 initialized。
    // 只负责观察状态；驱动 prepare 的是 stateCall('initialized') 那一次调用。
    setTimeout(() => {
      this.waitPrepared(attempt + 1);
    }, 200);
  }

  /** prepared 轮询的自愈重试次数（每次用户点播归零）。 */
  private prepareRetry: number = 0;
  /** 标记 loadAsset 是由自愈重试触发的（不要把 retry 计数清零）。 */
  private pendingReload: boolean = false;

  /** 重新装载当前曲目（prepared 超时后的自愈重试用）。 */
  private reloadCurrent(): void {
    const idx: number = this.musicIndex;
    this.pendingReload = true;
    this.loadAsset(idx).catch((err: Error) => {
      Logger.error(TAG, `reloadCurrent failed ${JSON.stringify(err)}`);
    });
  }

  /** 开始一次「主动推进到 prepared」的轮询（在新音源 fdSrc 设置之后调用）。 */
  private startPrepareWatch(): void {
    this.waitPrepared(0);
  }

  /**
   * 新建一个 AVPlayer 实例并绑定事件（换轨时用）。
   *
   * 为什么换轨要换实例、而不是 `reset()` 复用：实测在同一实例上走
   * `stop() → reset() → 设 fdSrc → prepare()` 之后，AVPlayer 虽然回到
   * initialized、`prepare()` 的 Promise 也会 resolve，但**不再派发
   * `stateChange('prepared')`**，`duration` 仍是 -1、`play()` 无效 ——
   * 表现就是「第一首能播，之后点任何一首都一直没反应」。
   * 新实例能拿到干净的状态机（首曲能播正是因为那时实例是新建的）。
   *
   * 注意顺序：**先建新实例、后释放旧实例**（反过来实测新实例会永远停在
   * initialized），并且释放**不 await**（在旧实例的回调栈里 await release
   * 会卡住整条装载链）。
   *
   * AVSession 与播放器实例无关，不需要重建。
   *
   * @returns 新实例；创建失败返回 undefined。
   */
  private async createPlayer(): Promise<media.AVPlayer | undefined> {
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      if (!p) {
        return undefined;
      }
      this.bindPlayer(p);
      // 播放器自身音量固定 1.0：响度完全交给**系统媒体音量**，应用侧不再衰减。
      // （用户 2026-10-19：「播放页的音量始终与系统音量一致，不要单独调节」。）
      this.applySystemVolumeLevel(p);
      return p;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `createAVPlayer failed ${e.code} ${e.message}`);
      return undefined;
    }
  }

  /**
   * 把播放器自身音量钉在 1.0（跟随系统音量）。
   *
   * AVPlayer 的 `setVolume` 是**应用级**衰减，与系统音量是两层乘法：
   * 之前音量行直接改它，于是侧键把系统音量推到最大时 App 还额外乘了
   * 一个系数（如 0.4）—— 用户听到的就是「这个 App 比别的 App 小声」。
   * 现在应用侧不再缩放，音量滑块改成镜像系统音量（见 SystemVolume）。
   */
  private applySystemVolumeLevel(player: media.AVPlayer): void {
    try {
      player.setVolume(1);
    } catch (err) {
      Logger.warn(TAG, `reset player volume failed: ${(err as BusinessError).message ?? ''}`);
    }
  }

  /** 页面进入播放页时调用：撤销历史遗留的应用级衰减，重新跟随系统音量。 */
  public followSystemVolume(): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player !== undefined) {
      this.applySystemVolumeLevel(player);
    }
    this.getAppState().volume = 1;
  }

  /** 释放一个（不再是当前的）播放器实例：不抛异常、不阻塞调用方。 */
  private async safeRelease(player: media.AVPlayer): Promise<void> {
    // 先摘监听：释放过程中它还会吐 stopped/released 事件。
    try {
      player.off('stateChange');
    } catch (err) {
      // ignore
    }
    try {
      await player.release();
    } catch (err) {
      const e = err as Error;
      Logger.warn(TAG, `release player failed ${e.message ?? ''}`);
    }
  }

  /**
   * 订阅播放器事件，并给每个回调加上**实例身份守卫**。
   *
   * 守卫是这套状态机的关键：换轨会不断新建/释放实例，而旧实例在释放过程中
   * 还会吐出 stopped / idle / released 等事件。旧实现里回调一律操作
   * `this.avPlayer`（= 新实例），于是「旧实例的 idle」会把新实例的音源清掉、
   * 把 `isPrepared` 置错 —— 用户看到的就是「切歌后不播、只能重启」。
   * 现在只要 `this.avPlayer !== player`，该事件一律丢弃。
   */
  private bindPlayer(player: media.AVPlayer): void {
    player.on('seekDone', (t: number) => {
      if (this.avPlayer === player) {
        this.seekCall(t);
      }
    });
    player.on('error', (err: BusinessError) => {
      if (this.avPlayer === player) {
        this.errorCall(err);
      }
    });
    player.on('audioInterrupt', (info: audio.InterruptEvent) => {
      if (this.avPlayer === player) {
        this.audioInterruptCall(info);
      }
    });
    player.on('timeUpdate', (t: number) => {
      if (this.avPlayer === player) {
        this.updateTimeCall(t);
      }
    });
    player.on('stateChange', (s: string) => {
      if (this.avPlayer === player) {
        this.stateCall(s);
      }
    });
    player.on('volumeChange', (v: number) => {
      if (this.avPlayer === player) {
        this.volumeChangeCall(v);
      }
    });
  }

  /** Creates and activates AVSession, sets launch want agent, and registers controller listeners. */
  private async createSession(): Promise<void> {
    if (!this.abilityContext) {
      return;
    }
    try {
      this.session = await avSession.createAVSession(this.abilityContext, 'SESSION_NAME', 'audio');
      Logger.info(TAG, `session create done : sessionId : ${this.session.sessionId}`);
      this.session.activate();
    } catch (error) {
      Logger.error(TAG, `${error.code} + ${error.message}`);
    }
    this.setAVMetadata();
    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.abilityContext.abilityInfo.bundleName,
          abilityName: this.abilityContext.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
      if (this.session) {
        this.session.setLaunchAbility(agent);
      }
    })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `getWantAgent failed, code: ${JSON.stringify(err.code)}, ` +
        `message: ${JSON.stringify(err.message)}`);
      });
    this.registerSessionControlListeners();
  }

  /** Subscribe to AVSession controller commands (play / pause / next / previous). */
  private async registerSessionControlListeners(): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      this.session.on('play', this.playCall);
      this.session.on('pause', this.pauseCall);
      this.session.on('playNext', this.playNextCall);
      this.session.on('playPrevious', this.playPreviousCall);
    } catch (error) {
      Logger.error(TAG, `${error.code} + ${error.message}`);
    }
  }

  /** Unsubscribe AVSession controller command listeners. */
  private async unregisterSessionControlListeners(): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      this.session.off('play');
      this.session.off('pause');
      this.session.off('playNext');
      this.session.off('playPrevious');
    } catch (error) {
      Logger.error(TAG, `${error.code} + ${error.message}`);
    }
  }

  /** Updates AVSession metadata (title, artist, duration, optional cover) for the current track. */
  private async setAVMetadata(): Promise<void> {
    const id = this.musicIndex;
    try {
      if (!this.abilityContext) {
        return;
      }
      const ctx = this.abilityContext;
      const metaSong = this.getSongItemAtQueueIndex(this.musicIndex);
      if (!metaSong) {
        return;
      }
      let mediaImage: PixelMap | undefined = undefined;
      try {
        try {
          // Prefer the sandbox cover cache of the scanned library song.
          // createImageSource officially accepts the cached file:// URI
          // (uri overload, API 11+).
          // Apple 的封面是 https 链接：先下到本地缓存再解码。锁屏 / 控制中心
          // 只吃 PixelMap，直接拿 URL 一定失败（之前就是这样丢的封面）。
          const coverLocal: string = await AppleArtworkCache.ensure(metaSong.coverPath);
          if (coverLocal !== '') {
            Logger.info(TAG, 'setAVMetadata coverPath = ' + coverLocal);
            // fd decode: sandbox URIs (file://<bundle>/...) cannot go through
            // createImageSource's uri overload; decode bounded at 512px for
            // the lock screen / control center limits.
            mediaImage = await MediaTools.decodeCoverPixelMap(coverLocal, 512);
            if (mediaImage !== undefined) {
              Logger.info(TAG, 'getPixelMapFromCoverPath success');
            }
          }
        } catch (error) {
          Logger.warn(TAG, `setAVMetadata cover path failed: ${JSON.stringify(error)}`);
        }
        try {
          if (mediaImage === undefined) {
            mediaImage = await MediaTools.getPixelMapFromResource(ctx,
              metaSong.label as resourceManager.Resource);
            Logger.info(TAG, 'getPixelMapFromResource success');
          }
        } catch (error) {
          const be = error as BusinessError;
          if (be && be.code !== undefined && be.message !== undefined) {
            Logger.warn(TAG, `setAVMetadata cover fallback, code=${be.code}, message=${be.message}`);
          } else {
            Logger.warn(TAG, `setAVMetadata cover fallback, ${(error as Error)?.message ?? JSON.stringify(error)}`);
          }
        }
        const song = metaSong;
        const metadata: avSession.AVMetadata = {
          assetId: `${id}`,
          title: StringResourceUtil.resolve(ctx, song.title),
          artist: StringResourceUtil.resolve(ctx, song.singer),
          duration: this.getDuration()
        };
        if (mediaImage !== undefined) {
          metadata.mediaImage = mediaImage;
        }
        if (this.session) {
          try {
            await this.session.setAVMetadata(metadata);
            Logger.info(TAG, 'SetAVMetadata successfully');
          } catch (err) {
            const be = err as BusinessError;
            Logger.error(TAG, `SetAVMetadata failed, code=${be.code}, message=${be.message}`);
          }
        }
        // Keep the live view (灵动岛) in sync with the current track.
        await LiveViewController.getInstance().showSong(ctx,
          StringResourceUtil.resolve(ctx, song.title),
          StringResourceUtil.resolve(ctx, song.singer),
          AppleArtworkCache.getCachedPath(song.coverPath));
      } finally {
        if (mediaImage !== undefined) {
          try {
            mediaImage.release();
          } catch (error) {
            const err = error as BusinessError;
            Logger.warn(TAG, `mediaImage.release failed, code=${err?.code}, message=${err?.message}`);
          }
        }
      }
    } catch (error) {
      const be = error as BusinessError;
      Logger.error(TAG, `SetAVMetadata failed, code=${be?.code}, message=${be?.message}`);
    }
  }

  /**
   * Load media asset for the given queue index (prepare or switch track).
   *
   * @param musicIndex Index in the play queue.
   * @param loadOnly When true, only load without starting playback.
   */
  /**
   * 按播放源播放（A 方案）：用于不在 songs 表里的曲目（收藏专辑临时曲目等）。
   *
   * @param src 播放源，形如 apple:<曲目id>
   * @param title 标题（AVSession 元数据，可空）
   * @param artist 艺人（可空）
   * @param coverPath 封面（可空）
   * @param startPositionMs 起播位置（-1 = 从头）
   */
  public async loadAssetBySrc(src: string, title: string, artist: string, coverPath: string,
                              startPositionMs: number): Promise<void> {
    if (src === '') {
      return;
    }
    Logger.info(TAG, `loadAssetBySrc src=${src}`);
    this.queueFinished = false;
    if (startPositionMs > 0) {
      this.pendingResumeMs = startPositionMs;
    }
    // 由播放源构造一个临时 SongItem（不在 songs 表里）。
    // src 形如 apple:<曲目id>，与资料库 Apple 歌曲同一约定，
    // SongItemBuilder 会走既有的下载 + 解密 + 容器处理链路。
    const item = new SongItem();
    item.id = -1;
    item.title = title;
    item.singer = artist;
    item.src = src;
    item.coverPath = coverPath;
    this.ensureBackgroundAudioTask();
    this.saveSessionSnapshot();
    if (!this.avPlayer) {
      // 播放器尚未创建：与 loadAsset 一样先记下待播项（首帧后由 initAudioPlayer 应用）。
      this.pendingLoadBySrc = item;
      return;
    }
    await this.switchTrack(item, false);
  }

  public async loadAsset(musicIndex: number, loadOnly?: boolean, startPositionMs?: number): Promise<void> {
    this.queueFinished = false;
    // Always assign: positive = resume position (consumed by onPrepared after prepare),
    // otherwise -1 = start from the beginning.
    // Previously it was only assigned for positive values, so tapping a new song
    // kept the stale position of the previous song (user-reported bug).
    this.pendingResumeMs = (startPositionMs !== undefined && startPositionMs > 0)
      ? startPositionMs : -1;
    if (loadOnly !== true) {
      // 用户主动点播时归零自愈计数（reloadCurrent 内部会带上当前 retry 继续算）
      if (this.pendingReload !== true) {
        this.prepareRetry = 0;
        // 同时给看门狗的额度重置：上一次失败的惩罚不该算到用户这次操作头上
        this.healCount = 0;
        this.notReadySince = 0;
      }
      this.pendingReload = false;
    }
    const len = this.getQueueLength();
    if (len === 0) {
      Logger.error(TAG, 'play queue is empty when loadAsset');
      return;
    }
    if (musicIndex < 0 || musicIndex >= len) {
      Logger.error(TAG, `current musicIndex ${musicIndex}`);
      return;
    }
    let queueSong: SongItem | undefined = this.getSongItemAtQueueIndex(musicIndex);
    if (queueSong === undefined) {
      // 资料库同步会重建 songs 表（id 全部重排），内存队列里的 id 可能已经悬空。
      // 先按 uri 把队列和新表对一次账，再解析一次 —— 历史上这里直接 return，
      // 用户看到的就是「播完第一首之后怎么点都不播，只能重启 App」。
      Logger.warn('MEDIA-HEAL resolve miss, remap queue then retry index=' + musicIndex);
      this.remapQueueAfterSync();
      queueSong = this.getSongItemAtQueueIndex(musicIndex);
    }
    if (queueSong === undefined) {
      Logger.error(TAG, `resolve song failed at queue index ${musicIndex} (after remap)`);
      this.updateIsPlay(false);
      AppleUi.toast('队列里的这首歌已经不在资料库里了，请重新选择', 4000);
      return;
    }
    this.ensureBackgroundAudioTask();
    this.updateMusicIndex(musicIndex);
    // Persist the active queue so a restart restores the same album/session.
    this.saveSessionSnapshot();
    if (!this.avPlayer) {
      // Defer play until initAudioPlayer creates AVPlayer; loadAsset is applied then.
      this.pendingLoadIndex = musicIndex;
      this.pendingLoadOnly = loadOnly === true;
      return;
    }
    await this.switchTrack(queueSong, loadOnly === true);
  }

  /**
   * **唯一换轨入口**：建新实例 → 装源 → 释放旧实例（异步、不阻塞）。
   *
   * 旧实现把这条链摊在 `loadAsset` / `loadAssetBySrc` 两处各写一遍，
   * 且中间还夹着 `stop()` 与「旧实例 stopped→idle 自动重载」，于是存在两条
   * 装载链同时跑（一条来自 idle 回调、一条来自调用方）——
   * 它们会互相清掉 fdSrc / 互相重置 `isPrepared`，真机上的表现就是
   * 「第一首播完，第二首永远不播，只能重启 App」。
   *
   * 现在的规矩：
   *  ① 期间置 `explicitLoad`，旧实例残留的 idle 事件一律让路（不再抢着装载）；
   *  ② `loadToken` 只让最新一次装载生效，晚到的旧链会被丢弃；
   *  ③ 旧实例**不 stop、不 reset**，直接异步释放 —— 少一次状态迁移就少一类竞态；
   *  ④ 新的 fdSrc 只设到新实例上（回调有实例身份守卫）。
   *
   * @param queueSong 目标曲目（已解析成 SongItem）。
   * @param loadOnly true = 只装载不自动播放。
   */
  private async switchTrack(queueSong: SongItem, loadOnly: boolean): Promise<void> {
    const token: number = ++this.loadToken;
    this.explicitLoad = true;
    this.switching = true;
    this.isPrepared = false;
    this.isNeedPlay = !loadOnly;
    this.pendingPlayAfterSeek = false;
    const old: media.AVPlayer | undefined = this.avPlayer;
    try {
      if (old !== undefined && this.isFirst) {
        // 首曲：构造 MediaService 时建的那个实例还是干净的 idle，直接复用。
        Logger.info(TAG, 'switchTrack: reuse idle player for the first track');
      } else {
        // 先建新实例（**不提前丢掉旧的**：创建失败时旧实例还在，不至于整机哑火）。
        const fresh: media.AVPlayer | undefined = await this.createPlayer();
        if (token !== this.loadToken) {
          // 期间又来了新的换轨请求：本次结果作废。
          if (fresh !== undefined) {
            void this.safeRelease(fresh);
          }
          return;
        }
        if (fresh === undefined) {
          Logger.error(TAG, 'switchTrack: createAVPlayer failed, keep current player');
          this.updateIsPlay(false);
          return;
        }
        if (old !== undefined) {
          // 旧曲目的进度先落一次（用 playheadMs()，此时 isPrepared 已清，不能走 getCurrentTime()），
          // 再把旧实例摘下来异步释放。
          const pos: number = Math.max(0, this.playheadMs());
          this.persistProgress(this.songItem.src, pos);
        }
        this.avPlayer = fresh;
        if (old !== undefined) {
          void this.safeRelease(old);
        }
      }
      this.isFirst = false;
      this.state = AudioPlayerState.IDLE;
      await this.applySongSource(queueSong, loadOnly);
    } finally {
      // 只有仍是最新一次装载时才解除「显式装载」标记，
      // 否则会把并发那条链的 idle 让路保护提前关掉。
      if (token === this.loadToken) {
        this.explicitLoad = false;
        this.switching = false;
      }
    }
  }

  /**
   * Builds the song item and assigns its fdSrc to AVPlayer. Shared by the
   * first-load and warm-process paths.
   * @param queueSong Song resolved at the target queue index.
   * @param loadOnly When true, do not start playback after prepare.
   */
  private async applySongSource(queueSong: SongItem, loadOnly?: boolean): Promise<void> {
    this.songItem = await this.songItemBuilder.build(queueSong);
    // Apple 音源解析失败（下载/解密失败、缓存文件坏了）：SongItemBuilder 已经
    // 弹过提示并作废了缓存。这里必须显式收手 —— 否则 fdSrc 既不会被更新，
    // prepare() 也只会把错误写进 hilog，用户看到的就是「点了完全没反应」。
    // 用户再点一次即可（损坏缓存已清掉，会重新下载）。
    const appleError: string = this.songItemBuilder.getAppleError();
    if (appleError.length > 0) {
      Logger.error(TAG, `applySongSource: apple 源不可用，本首不播放 => ${appleError}`);
      this.isNeedPlay = false;
      this.updateIsPlay(false);
      return;
    }
    this.notifyWidgetState();
    // 当前曲目已就绪：顺手把下一首在后台预取进缓存
    this.preloadNextTrack();
    if (loadOnly) {
      this.isNeedPlay = false;
    }
    // The now-current track starts at 0 — except when this very load is the
    // restart resume, in which case the stored position is kept.
    const startPos = this.pendingResumeMs > 0 ? this.pendingResumeMs : 0;
    this.persistProgress(queueSong.src, startPos);
    if (this.songItemBuilder.isLocalFileSource() && this.avPlayer) {
      const localFd = this.songItemBuilder.getLocalFileDescriptor();
      if (localFd !== undefined) {
        this.avPlayer.fdSrc = localFd;
        Logger.info(TAG, 'loadAsset avPlayer.fdSrc(local):' + this.avPlayer.fdSrc);
        this.startPrepareWatch();
      }
    } else {
      let url = this.songItemBuilder.getRealUrl();
      if (this.avPlayer && url) {
        let avFileDescriptor: media.AVFileDescriptor = { fd: url.fd, offset: url.offset, length: url.length };
        this.avPlayer.fdSrc = avFileDescriptor;
        Logger.info(TAG, 'loadAsset avPlayer.fdSrc:' + this.avPlayer.fdSrc);
      }
    }
  }

  /**
   * Whether the player has not yet applied the first fdSrc on this AVPlayer instance.
   *
   * @returns True until first asset load completes.
   */
  public getFirst() {
    return this.isFirst;
  }

  /**
   * Set music play mode (order, shuffle, repeat, etc.).
   *
   * @param playMode Target play mode.
   */
  public setPlayMode(playMode: MusicPlayMode) {
    this.playMode = playMode;
    Logger.info(TAG, 'setPlayMode mode: ' + this.playMode);
  }

  /**
   * Get music play mode.
   *
   * @returns playMode.
   */
  public getPlayMode() {
    return this.playMode;
  }

  /**
   * Handles a widget call event without opening the app. Keeps all playback
   * decision logic inside MediaService so the widget never touches UI.
   */
  public handleWidgetCall(method: string): void {
    const appState = this.getAppState();
    if (method === 'playPause') {
      if (appState.isPlay) {
        this.pause();
      } else {
        // App may be cold-started by the card click: queue/DB are not ready yet.
        this.widgetPlayPending = true;
        this.playFromWidget();
      }
    } else if (method === 'next') {
      this.playNextAuto(true);
    } else if (method === 'prev') {
      this.playPrevious();
    }
    this.notifyWidgetState();
  }

  /** Fills the play queue from the in-memory library when it is still empty. */
  private ensurePlayQueue(): void {
    const appState = this.getAppState();
    if (appState.playQueueIds.length > 0) {
      return;
    }
    const allIds: number[] = MusicDbApi.getInstance().getSongList().map((dto: SongApiDto) => dto.id);
    if (allIds.length > 0) {
      appState.playQueueIds = allIds;
      appState.selectIndex = 0;
      Logger.info(TAG, `ensurePlayQueue: filled default queue, size=${allIds.length}`);
    }
  }

  /**
   * Starts playback requested from the widget. When the library/queue is not
   * ready yet, keeps widgetPlayPending so onLibraryReady can retry once.
   */
  private playFromWidget(): void {
    this.ensurePlayQueue();
    if (this.getQueueLength() === 0) {
      Logger.info(TAG, 'playFromWidget: queue empty, keep pending widget play');
      return;
    }
    this.widgetPlayPending = false;
    this.play();
  }

  /**
   * Called by EntryAbility after DB init and progress restore. Fills the
   * default queue if needed and retries a widget play that was requested
   * while the app process was still cold-starting.
   */
  public onLibraryReady(): void {
    this.ensurePlayQueue();
    if (this.widgetPlayPending && this.getQueueLength() > 0) {
      this.widgetPlayPending = false;
      Logger.info(TAG, 'onLibraryReady: retry deferred widget play');
      this.play();
    }
  }

  /** Builds the widget snapshot from the current song and UI state. */
  public getCurrentWidgetSnapshot(): WidgetStateSnapshot {
    const snapshot = new WidgetStateSnapshot();
    if (this.abilityContext !== undefined) {
      snapshot.title = StringResourceUtil.resolve(this.abilityContext, this.songItem.title);
      snapshot.artist = StringResourceUtil.resolve(this.abilityContext, this.songItem.singer);
    }
    // 桌面卡片要能 openSync 到图片：URL 换成已缓存的本地路径（未缓存则为空，
    // 卡片回退到占位图，绝不再拿 https 去 openSync）。
    snapshot.coverPath = AppleArtworkCache.getCachedPath(this.songItem.coverPath);
    snapshot.isPlaying = this.getAppState().isPlay;
    return snapshot;
  }

  /** Saves widget state and refreshes every installed widget. */
  public notifyWidgetState(): void {
    if (this.abilityContext === undefined) {
      return;
    }
    const snapshot = this.getCurrentWidgetSnapshot();
    WidgetStateStore.save(this.abilityContext, snapshot);
    WidgetUpdater.refreshAll(this.abilityContext);
  }

  /** Updates MusicAppState.isPlay and AVSession playback state snapshot. */
  private updateIsPlay(isPlay: boolean) {
    this.getAppState().isPlay = isPlay;
    this.setPlayState({
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: {
        elapsedTime: this.getCurrentTime(),
        updateTime: new Date().getTime()
      }
    });
    if (this.abilityContext) {
      LiveViewController.getInstance().updatePlayState(this.abilityContext, isPlay);
    }
    this.notifyWidgetState();
  }

  /**
   * Seeks the current track to the given position in milliseconds.
   *
   * @param ms Target position in ms, clamped to [0, duration].
   */
  /**
   * 设置**应用级**音量（0~1，内部会钳制）。
   *
   * ⚠️ 手机播放页**不再使用**它：那里的音量行镜像系统媒体音量（见 SystemVolume），
   * 应用侧保持 1.0，否则系统音量与应用音量会叠成两层，App 会比别的 App 小声。
   * 现在只有手表形态的码表/弧形滑块还在用它做本地音量。
   */
  public setVolume(v: number): void {
    const vol: number = v < 0 ? 0 : (v > 1 ? 1 : v);
    try {
      if (this.avPlayer) {
        this.avPlayer.setVolume(vol);
      }
    } catch (err) {
      Logger.warn(TAG, `setVolume failed: ${(err as BusinessError).message}`);
    }
    this.getAppState().volume = vol;
  }

  public seek(ms: number) {
    if (this.isPrepared && this.state != AudioPlayerState.ERROR && this.avPlayer) {
      let seekMode = this.getCurrentTime() < ms ? 0 : 1;
      let realTime = (ms <= 0 ? 0 : (ms >= this.getDuration() ? this.getDuration() : ms));
      this.isCurrent = false;
      this.avPlayer.seek(realTime, seekMode);
      // **自愈**：isCurrent 只有 seekDone 回调会重新打开。那个回调在换歌 /
      // 播放器状态切换的瞬间偶发丢失，一旦丢掉，state.progress 就**永久冻结**——
      // 表现为歌词不高亮/不显示、进度条停住，直到用户再 seek 一次才恢复
      // （正是反馈的 bug）。这里 1.2s 后强制打开，宁可多放行一帧旧位置，
      // 也不能让进度从此不动。
      if (this.isCurrentRecoverTimer !== 0) {
        clearTimeout(this.isCurrentRecoverTimer);
      }
      this.isCurrentRecoverTimer = setTimeout(() => {
        this.isCurrentRecoverTimer = 0;
        this.isCurrent = true;
      }, 1200);
    }
  }

  /**
   * 真实播放头（毫秒）；播放器未就绪时返回 -1。
   *
   * 给歌词这类「需要毫秒级、且绝不能漂移」的 UI 用：`avPlayer.currentTime` 就是
   * 播放头本体，直接读它比「拿 timeUpdate 做锚点再插值」准得多 ——
   * 后者一旦有一拍没对上（缓冲/解密/状态切换），误差会一直累积下去，
   * 歌词就会「前半段不亮、后半段才跟上」（见 LyricPlayhead 的注释）。
   *
   * 它只是一次属性读取，没有异步、没有额外开销，100ms 心跳里调用完全安全。
   *
   * @returns 播放位置（毫秒）；不可用时 -1。
   */
  public playheadMs(): number {
    const player = this.avPlayer;
    if (!player) {
      return -1;
    }
    // 读一个**已释放**实例的 currentTime 会抛异常；这个函数在换轨链和 100ms
    // 歌词心跳里都被调用，一旦抛出去会顺着调用栈把整条装载链打断（换轨中途
    // 抛错 = 这首歌永远不播）。属性读取一律兜住。
    try {
      const t: number = player.currentTime;
      if (!Number.isFinite(t) || t < 0) {
        return -1;
      }
      return t;
    } catch (err) {
      return -1;
    }
  }

  /** Current playback position in ms from AVPlayer, or 0 if not prepared. */
  private getCurrentTime() {
    if (this.isPrepared && this.avPlayer) {
      try {
        return this.avPlayer.currentTime;
      } catch (err) {
        return 0;
      }
    }
    return 0;
  }

  /** Total duration in ms from AVPlayer, or 0 if not prepared. */
  private getDuration() {
    if (this.isPrepared && this.avPlayer) {
      try {
        return this.avPlayer.duration;
      } catch (err) {
        return 0;
      }
    }
    return 0;
  }

  /** Runs prepare(); used when play() is requested before prepared. */
  private start(seekMs?: number) {
    Logger.info(TAG, 'AVPlayer play() isPrepared:' + this.isPrepared + ', state:' + this.state + '，seek:' + seekMs);
    if (this.avPlayer) {
      this.avPlayer.prepare().then(() => {
      }).catch((error: BusinessError) => {
        Logger.error(TAG, `start error ${JSON.stringify(error)}`);
        this.state = AudioPlayerState.ERROR;
        this.updateIsPlay(false);
        this.isPrepared = false;
      });
    }
  }

  /**
   * Starts or resumes playback; triggers prepare if the player is not prepared yet.
   */
  public async play() {
    Logger.info(TAG, 'AVPlayer play() isPrepared:' + this.isPrepared + ', state:' + this.state);
    this.ensureBackgroundAudioTask();
    if (!this.isPrepared) {
      // Player was reset (e.g. the queue played through and stopped):
      // reload the current track instead of preparing an empty player.
      this.loadAsset(this.getValidSelectIndex()).catch((err: Error) => {
        Logger.error(TAG, `play() reload failed ${err.message}`);
      });
    } else if (this.avPlayer) {
      try {
        this.avPlayer.play().then(() => {
          Logger.info(TAG, 'progressTime play() current time:' + this.getCurrentTime());
          this.seek(this.getCurrentTime());
          this.updateIsPlay(true);
          this.state = AudioPlayerState.PLAY;
        });
      } catch (error) {
        Logger.error(TAG, `${error.code} + ${error.message}`);
      }
    }
  }

  /**
   * Pauses playback when currently in PLAY state.
   */
  public pause() {
    Logger.info(TAG, 'AVPlayer pause() isPrepared:' + this.isPrepared + ', state:' + this.state);
    this.persistProgress(this.songItem.src, this.getCurrentTime());
    if (this.isPrepared && this.state === AudioPlayerState.PLAY && this.avPlayer) {
      this.avPlayer.pause().then(() => {
        this.state = AudioPlayerState.PAUSE;
        this.updateIsPlay(false);
        if (this.abilityContext) {
          BackgroundUtil.stopContinuousTask(this.abilityContext);
        }
      }).catch((err: BusinessError) => {
        Logger.error(TAG, 'Failed to pause,error message is :' + err.message);
      })
    }
  }

  /**
   * Advances playback according to play mode (order, random, single-cycle).
   *
   * @param isFromControl True when invoked from user/system control (vs track completion).
   */
  public playNextAuto(isFromControl: boolean) {
    Logger.info(TAG, 'playNextAuto mode:' + this.playMode);
    if (isFromControl) {
      // 用户主动切歌：给看门狗重新计数（上一次失败的额度不该继续惩罚用户操作）
      this.healCount = 0;
      this.notReadySince = 0;
    }
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        if (isFromControl) {
          this.playNext();
        } else if (this.avPlayer) {
          try {
            this.avPlayer.play();
          } catch (error) {
            Logger.error(TAG, `${error.code} + ${error.message}`);
          }
        }
        break;
      case MusicPlayMode.ORDER:
        this.playNext();
        break;
      case MusicPlayMode.RANDOM:
        this.playRandom();
        break;
      default:
        break;
    }
  }

  /** Loads the next queue index in linear order; stops at the queue end
   * (a whole album plays through and then stops — no wrap to other songs). */
  private playNext() {
    const len = this.getQueueLength();
    if (len === 0) {
      return;
    }
    Logger.info(TAG, 'playNext Index:' + this.musicIndex + ', length-1:' + (len - 1));
    if (this.musicIndex === len - 1) {
      // Queue finished: stop playback, reset the player so the next play
      // request reloads the track, and rewind the progress display.
      Logger.info(TAG, 'playNext: queue finished, stopping');
      this.queueFinished = true;
      const appState = this.getAppState();
      void this.reset();
      this.state = AudioPlayerState.STOP;
      this.updateIsPlay(false);
      appState.progress = 0;
      appState.currentTime = '00:00';
      appState.progressMax = 0;
      if (this.abilityContext) {
        BackgroundUtil.stopContinuousTask(this.abilityContext);
      }
      void LiveViewController.getInstance().hide();
      // 整张专辑 / 歌单播完：清掉「继续播放」进度（用户定的规则）。
      this.clearContextProgress();
      return;
    }
    this.loadAsset(this.musicIndex + 1).catch((err: Error) => {
      Logger.error(TAG, `playNext load failed ${err.message}`);
    });
  }

  /**
   * Goes to the previous track for order / single-cycle, or random pick in random mode.
   */
  public playPrevious() {
    const len = this.getQueueLength();
    if (len === 0) {
      return;
    }
    switch (this.playMode) {
      case MusicPlayMode.RANDOM:
        this.playRandom();
        break;
      case MusicPlayMode.ORDER:
      case MusicPlayMode.SINGLE_CYCLE:
        if (this.musicIndex === 0) {
          this.updateMusicIndex(len - 1);
        } else {
          this.updateMusicIndex(this.musicIndex - 1);
        }
        Logger.info(TAG, 'setLastIndex:' + this.musicIndex);
        this.loadAsset(this.musicIndex).catch((err: Error) => {
          Logger.error(TAG, `playPrevious load failed ${err.message}`);
        });
        break;
      default:
        break;
    }
  }

  /** Picks a random queue index different from the current one (when length > 1). */
  private playRandom() {
    const len = this.getQueueLength();
    if (len <= 1) {
      if (len === 1) {
        this.loadAsset(0);
      }
      return;
    }
    // Uniform on {0..len-1} \ {musicIndex}; avoids recursion and stack overflow on repeated collisions.
    const k: number = Math.floor(Math.random() * (len - 1));
    const num: number = k < this.musicIndex ? k : k + 1;
    this.updateMusicIndex(num);
    this.loadAsset(num).catch((err: Error) => {
      Logger.error(TAG, `playRandom load failed ${err.message}`);
    });
    Logger.info(TAG, 'play Random:' + this.musicIndex);
  }

  /**
   * Stops AVPlayer and clears playing state when prepared.
   */
  public async stop() {
    Logger.info(TAG, 'stop()');
    this.persistProgress(this.songItem.src, this.getCurrentTime());
    if (this.isPrepared && this.avPlayer) {
      try {
        await this.avPlayer.stop();
        this.updateIsPlay(false);
        this.state = AudioPlayerState.PAUSE;
        if (this.abilityContext) {
          BackgroundUtil.stopContinuousTask(this.abilityContext);
        }
      } catch (error) {
        Logger.error(TAG, `${error.code} + ${error.message}`);
      }
    }
  }

  /** Resets AVPlayer and releases SongItemBuilder resources. */
  private async reset() {
    Logger.info(TAG, 'reset()');
    await this.songItemBuilder.release();
    if (this.avPlayer) {
      try {
        await this.avPlayer.reset();
      } catch (error) {
        Logger.error(TAG, `${error.code} + ${error.message}`);
      }
    }
    this.isPrepared = false;
  }

  /**
   * Releases AVPlayer and AVSession; intended for ability teardown (best-effort sync calls).
   */
  public async release() {
    if (this.avPlayer && this.session && this.abilityContext) {
      try {
        this.updateIsPlay(false);
        this.stop();
        this.reset();
        this.avPlayer.release().catch((err: BusinessError) => {
          Logger.error(TAG, `Failed to release avplayer. Code: ${err.code}, message: ${err.message}`);
        });
        this.state = AudioPlayerState.IDLE;
        BackgroundUtil.stopContinuousTask(this.abilityContext);
        LiveViewController.getInstance().hide();
        this.unregisterSessionControlListeners();
        this.session.destroy((err: BusinessError) => {
          if (err) {
            Logger.error(TAG, `Failed to destroy session. Code: ${err.code}, message: ${err.message}`);
          } else {
            Logger.info(TAG, `Destroy : SUCCESS `);
          }
        });
      } catch (error) {
        Logger.error(TAG, `${error.code} + ${error.message}`);
      }
    }
  }

  /** Writes selectIndex to MusicAppState and refreshes AVSession metadata when index changes. */
  private updateMusicIndex(musicIndex: number) {
    Logger.info(TAG, 'updateMusicIndex ===> ' + musicIndex);
    this.getAppState().selectIndex = musicIndex;
    if (this.musicIndex !== musicIndex) {
      this.musicIndex = musicIndex;
    }
    Logger.info(TAG, 'this.session !== undefined ===> ' + (this.session != undefined));
    if (this.session !== undefined) {
      this.setAVMetadata();
    }
  }

  /** Pushes playback state (play/pause and position) to AVSession. */
  private async setPlayState(playbackState: avSession.AVPlaybackState) {
    if (this.session) {
      this.session.setAVPlaybackState(playbackState, (err: BusinessError) => {
        if (err) {
          Logger.info(TAG, `SetAVPlaybackState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'SetAVPlaybackState successfully');
        }
      });
    }
  }
}

