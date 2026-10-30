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

import { UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { rpc } from '@kit.IPCKit';
import { getAppRuntime, LibrarySignal, Logger, MusicDatabase, AppleCache, AppleApi, AppleAuthState, AppleDiag, AppleLibrarySync, SyncResult, MusicTransferService, PlaybackProgressStore, WindowUtil, BackHandler } from 'musicbasic';
import { MediaService } from 'player';

import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { AppearanceController } from 'musicbasic';

/** Return value for widget call events; minimal IPC parcelable. */
class WidgetCallResult implements rpc.Parcelable {
  private code: number = 0;

  constructor(code: number) {
    this.code = code;
  }

  marshalling(messageSequence: rpc.MessageSequence): boolean {
    messageSequence.writeInt(this.code);
    return true;
  }

  unmarshalling(messageSequence: rpc.MessageSequence): boolean {
    this.code = messageSequence.readInt();
    return true;
  }
}

/** Main UIAbility for the default phone product: wires app runtime, window util, and media singleton. */
export default class EntryAbility extends UIAbility {
  /** Persists UIAbility context on app runtime for global access. */
  /** 把 Apple 同步结果写到沙盒，便于电脑侧拉取诊断 */
  /** 把 Apple 同步结果写到沙盒（追加），便于电脑侧拉取诊断 */
  /**
   * 拉取资料库曲目，失败时重试一次。
   *
   * 原因：手机网络偶发 HTTP/2 断流（hilog 可见 `CURLcode result 92`），
   * 一旦这次失败，整轮启动同步就白跑 —— 曲风（艺人页音乐板块）也会是空的。
   * 8 秒后重试一次，绝大多数瞬时错误都能自愈。
   *
   * @returns 同步结果（第二次仍失败则返回第二次的结果）
   */
  private static async syncSongsWithRetry(): Promise<SyncResult> {
    const first: SyncResult = await AppleLibrarySync.syncSongs();
    if (first.ok) {
      return first;
    }
    Logger.warn('EntryAbility: 资料库同步失败，8 秒后重试一次：' + first.message);
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 8000);
    });
    const second: SyncResult = await AppleLibrarySync.syncSongs();
    Logger.info(`EntryAbility: 资料库同步重试 ok=${second.ok} songs=${second.songs}`);
    return second;
  }

  static writeAppleLog(line: string): void {
    try {
      const f = fileIo.openSync(getAppRuntime().context!.filesDir + '/apple_sync.log',
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      try {
        fileIo.writeSync(f.fd, '[' + new Date().toTimeString().substring(0, 8) + '] ' + line + '\n');
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      // 忽略
    }
  }

  onCreate() {
    getAppRuntime().context = this.context;
    Logger.info('EntryAbility: Ability onCreate');
    AppleDiag.init(this.context);
    AppleDiag.reset();
    AppleDiag.log('==== 新一轮启动 ====');
    try {
      fileIo.unlinkSync(this.context.filesDir + '/apple_sync.log');
    } catch (e) {
      // 日志不存在则忽略
    }
    this.registerWidgetCallHandlers();
    // Load the music library DB in the background; UI reads its in-memory mirror.
    MusicDatabase.getInstance().init(this.context).then(() => {
      Logger.info('EntryAbility: music library loaded');
      // 音源已切换为 Apple Music：清掉历史「导入外部音乐」留下的本地歌曲
      // 及其沙盒副本（本地导入功能已从代码中移除，此后不会再产生）。
      this.purgeImportedSongs().then(() => {
        Logger.info('EntryAbility: imported songs purged');
        this.restorePlaybackProgress();
      }).catch((error: Error) => {
        Logger.error(`EntryAbility: purge imported songs failed ${JSON.stringify(error)}`);
      });
    }).catch((error: Error) => {
      Logger.error(`EntryAbility: music library init failed ${JSON.stringify(error)}`);
    });
    // Apply the persisted appearance mode (follow system / light / dark).
    AppearanceController.getInstance().init(this.context).then(() => {
      Logger.info('EntryAbility: appearance applied');
    }).catch((error: Error) => {
      Logger.error(`EntryAbility: appearance init failed ${JSON.stringify(error)}`);
    });
    // Sender side of the phone→watch transfer channel.
    MusicTransferService.getInstance().init(this.context, true).then(() => {
      Logger.info('EntryAbility: transfer channel ready');
    }).catch((error: Error) => {
      Logger.error(`EntryAbility: transfer init failed ${JSON.stringify(error)}`);
    });
    // ── Apple Music 音源初始化：缓存目录 + 登录态恢复 + 资料库同步 ──
    AppleCache.init(this.context).then(() => {
      Logger.info('EntryAbility: apple cache ready');
      return AppleApi.restore(this.context);
    }).then((authorized: boolean) => {
      Logger.info(`EntryAbility: apple restored=${authorized}`);
      // 登录态写进全局状态：三个板块据此决定「登录」还是「同步」
      AppleAuthState.getInstance().refreshFromApi();
      if (!authorized) {
        // 未登录：不发起任何网络请求，由用户点「登录 Apple Music」走 ArkWeb 登录页
        return Promise.resolve(undefined);
      }
      // 启动同步延后 25 秒（2026-09 真机时间线实测后的优化）：
      //   启动后 4~16 秒是我们自己排的三批 tab 预建，头 1~2 秒是首屏渲染；
      //   再叠一次「全库同步（2724 首写库）+ 重建聚合 + 通知 4 个板块刷新」，
      //   用户体感就是「打开卡一两秒、切主页面掉帧」。同步不紧急 → 顺延到首屏稳定后。
      //   外壳左上的手动同步按钮不受影响，随时可点。
      return new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 25000);
      })
        // ensureDeveloperToken：只在没有 token 或 24 小时内过期时才去抓
        // （抓一次要下载 music.apple.com 的 index.js，3MB+）
        .then(() => AppleApi.ensureDeveloperToken())
        .then(() => AppleApi.getAccountInfo())
        .then(() => {
          Logger.info('EntryAbility: apple account ok, storefront=' + AppleApi.getStorefront());
          AppleAuthState.getInstance().refreshFromApi();
          // 歌单元数据（1 个请求，写的是 apple_playlists 表）与歌曲同步互不依赖 ⇒ 并发跑
          const playlistTask: Promise<SyncResult> = AppleLibrarySync.syncPlaylists();
          EntryAbility.syncSongsWithRetry().then((r: SyncResult) => {
            Logger.info(`EntryAbility: apple sync ok=${r.ok} songs=${r.songs} msg=${r.message}`);
            EntryAbility.writeAppleLog('sync ok=' + r.ok + ' songs=' + r.songs + ' msg=' + r.message);
          }).catch(() => {
          });
          return playlistTask;
        })
        .then((p: SyncResult) => {
          Logger.info(`EntryAbility: apple playlists ok=${p.ok} count=${p.songs} msg=${p.message}`);
          EntryAbility.writeAppleLog('sync ok=' + p.ok + ' playlists=' + p.songs + ' msg=' + p.message);
          // 歌单曲目一次性拉全 → 三个板块是「资料库 + 歌单」并集
          return AppleLibrarySync.syncAllPlaylistTracks();
        })
        .then((t: SyncResult) => {
          Logger.info(`EntryAbility: apple playlist tracks ok=${t.ok} count=${t.songs} msg=${t.message}`);
          EntryAbility.writeAppleLog('playlist tracks ok=' + t.ok + ' count=' + t.songs + ' msg=' + t.message);
          // 资料库同步重建了 songs 表（id 全部改变）：把内存队列的 id 镜像重建，
          // 否则播放条会变空、并且「兜底填全库」会把恢复的专辑队列顶掉。
          MediaService.getInstance().remapQueueAfterSync();
          // 同步完成：通知四个板块刷新（启动时页面可能已经建好并在等数据）
          LibrarySignal.notifyChanged();
          // TEMP-PROBE 已撤除。
          // 结论：/v1/me/library/artists 的返回会随账号索引变化，之前那批
          // 「只有艺人条目」的空壳艺人（椎名林檎/Utada/The Beatles/Stevie Wonder/
          // D'Angelo）现在已经不在该接口里，自动化补齐失去判定依据。
          // 改为「搜索曲库 → 加入资料库」这条更可靠的路径（见搜索页实现）。
          // TEMP-AUTOFILL 已撤除：假阳性过滤不完善（资料库里同一艺人有中英两种
          // 名字），曾误把已在库的古典厂牌专辑重复加入资料库。改为用户手动触发，
          // 并且触发前必须二次确认。
        });
    }).catch((error: Error) => {
      Logger.error(`EntryAbility: apple init failed ${JSON.stringify(error)}`);
      EntryAbility.writeAppleLog('ERROR ' + JSON.stringify(error));
    });

    // Distributed data sync is user-granted; request it at launch.
    const atManager = abilityAccessCtrl.createAtManager();
    const permissions: Array<Permissions> = ['ohos.permission.DISTRIBUTED_DATASYNC'];
    atManager.requestPermissionsFromUser(this.context, permissions).then((result) => {
      Logger.info(`EntryAbility: distributed permission granted=${result.authResults[0] === 0}`);
    }).catch((error: Error) => {
      Logger.error(`EntryAbility: permission request failed ${JSON.stringify(error)}`);
    });

  }

  /**
   * Restores the last session's song and position from Preferences (no
   * auto-play; the next play request seeks to the stored position).
   * Afterwards notifies MediaService that the library is ready so a widget
   * play request issued while the app was cold-starting can be retried.
   */
  private async restorePlaybackProgress(): Promise<void> {
    const store = PlaybackProgressStore.getInstance();
    try {
      await store.init(this.context);
      // TEMP-DIAG：会话快照落盘情况（排查「跨进程恢复失效」）
      try {
        const dir = this.context.preferencesDir;
        const names: string[] = fileIo.listFileSync(dir);
        let info = '';
        for (let i = 0; i < names.length; i++) {
          let size = -1;
          try {
            size = fileIo.statSync(`${dir}/${names[i]}`).size;
          } catch (e) {
            size = -2;
          }
          info += `${names[i]}=${size} `;
        }

      } catch (e) {
        Logger.warn(`EntryAbility: prefs dir dump failed`);
      }
      const probe = store.load();

      const snapshot = store.load();
      if (snapshot.hasSession()) {
        MediaService.getInstance().restorePlaybackSession(snapshot);
      } else {
        Logger.info('EntryAbility: no stored playback session');
      }
    } catch (error) {
      Logger.error(`EntryAbility: progress store init failed ${JSON.stringify(error)}`);
    }
    MediaService.getInstance().onLibraryReady();
  }

  /**
   * 一次性清理：删除所有「导入外部音乐」时代遗留的本地歌曲行（folder 非
   * 'apple'）以及它们在沙盒里的音频/封面副本。本地导入功能与扫描器已从
   * 工程中删除，因此该操作之后不会再有任何行可删（幂等）。
   */
  private async purgeImportedSongs(): Promise<void> {
    const removed = await MusicDatabase.getInstance().purgeImportedSongs();
    const files = EntryAbility.removeSandboxMusicDir();
    if (removed > 0 || files > 0) {
      Logger.info(`EntryAbility: purged imported songs rows=${removed} files=${files}`);
      LibrarySignal.notifyChanged();
    } else {
      Logger.info('EntryAbility: nothing to purge (Apple-only library)');
    }
  }

  /** 递归删除沙盒里的本地音乐与封面缓存目录，返回删除的文件数。 */
  private static removeSandboxMusicDir(): number {
    const context = getAppRuntime().context;
    if (context === undefined) {
      return 0;
    }
    let count = 0;
    const dirs: string[] = [`${context.filesDir}/music`, `${context.filesDir}/covers`];
    for (let i = 0; i < dirs.length; i++) {
      count += EntryAbility.removeTree(dirs[i]);
    }
    return count;
  }

  /** 递归删除目录（文件 + 子目录），返回删除的文件数。 */
  private static removeTree(dir: string): number {
    let children: string[] = [];
    try {
      children = fileIo.listFileSync(dir);
    } catch (err) {
      return 0; // 目录不存在，无需清理
    }
    let count = 0;
    for (let i = 0; i < children.length; i++) {
      const path = `${dir}/${children[i]}`;
      try {
        if (fileIo.statSync(path).isDirectory()) {
          count += EntryAbility.removeTree(path);
        } else {
          fileIo.unlinkSync(path);
          count++;
        }
      } catch (err) {
        Logger.warn(`EntryAbility: remove ${path} failed ${JSON.stringify(err)}`);
      }
    }
    try {
      fileIo.rmdirSync(dir);
    } catch (err) {
      // 目录非空或已被占用：留待下次启动继续清理
    }
    return count;
  }

  /** Registers widget call methods so cards can control playback in background. */
  private registerWidgetCallHandlers(): void {
    try {
      this.callee.on('playPause', (data: rpc.MessageSequence): WidgetCallResult => {
        MediaService.getInstance().handleWidgetCall('playPause');
        return new WidgetCallResult(0);
      });
      this.callee.on('next', (data: rpc.MessageSequence): WidgetCallResult => {
        MediaService.getInstance().handleWidgetCall('next');
        return new WidgetCallResult(0);
      });
      this.callee.on('prev', (data: rpc.MessageSequence): WidgetCallResult => {
        MediaService.getInstance().handleWidgetCall('prev');
        return new WidgetCallResult(0);
      });
    } catch (err) {
      Logger.error(`EntryAbility: widget call handlers register failed ${JSON.stringify(err)}`);
    }
  }

  /** Ability lifecycle teardown hook. */
  onDestroy() {
    Logger.info('EntryAbility: Ability onDestroy');
  }

  /** Loads main page, captures UIContext, initializes window helper and MediaService singleton. */
  onWindowStageCreate(windowStage: window.WindowStage) {
    // Main window is created, set main page for this ability
    Logger.info('EntryAbility: Ability onWindowStageCreate');

    // Layout over the whole screen (incl. nav-bar area) so the HDS floating
    // bar can sit closer to the bottom instead of the system-safe-area inset.
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true);
      // Hide the status bar: only then does the HDS content area start at
      // the true screen top, letting content scroll under the punch-hole
      // camera area. The nav indicator stays for gesture navigation.
      win.setWindowSystemBarEnable(['navigation']);
      // 屏幕常亮：调试/长时间播放时不让系统熄屏，避免进程被挂起后
      // 远程调不起来（也很符合"音乐播放器正在放歌"这个场景）。
      win.setWindowKeepScreenOn(true);
      Logger.info('EntryAbility: keep screen on enabled');
    } catch (error) {
      Logger.error(`window full-screen config error ${JSON.stringify(error)}`);
    }

    windowStage.loadContent('pages/Index', (err) => {
      try {
        getAppRuntime().uiContext = windowStage.getMainWindowSync().getUIContext();
      } catch (error) {
        Logger.error(`getMainWindowSync error ${JSON.stringify(error)}`);
      }
      if (err.code) {
        Logger.error(`Failed to load the content. Cause: ${JSON.stringify(err) ?? ''}`);
        return;
      }
      Logger.info('Succeeded in loading the content.');
      try {
        MediaService.getInstance();
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(`Failed to get media service instance. Code: ${err.code}, message: ${err.message}`);
      }
      try {
        const windowUtil = WindowUtil.getInstance();
        windowUtil.setWindowStage(windowStage);
        windowUtil.setUIContext();
        windowUtil.updateWindowInfo();
      } catch (err) {
        let error = err as BusinessError;
        Logger.error(`WindowUtil init error ${error.code} ${error.message}`);
      }
    });
  }

  /** Called when the main window stage is destroyed. */
  async onWindowStageDestroy(): Promise<void> {
    // Main window is destroyed, release UI related resources
    Logger.info('EntryAbility: Ability onWindowStageDestroy');
    try {
      await MediaService.getInstance().release();
    } catch (error) {
      Logger.error(`MediaService release error. Code: ${error.code}, message: ${error.message}`);
    }
  }

  /** App brought to foreground. */
  onForeground() {
    // Ability has brought to foreground
    Logger.info('EntryAbility: Ability onForeground');
  }

  /** App moved to background; notifies media layer for background-task policy. */
  onBackground() {
    // Ability has back to background
    Logger.info('EntryAbility: Ability onBackground');
    MediaService.getInstance().onApplicationBackground();
  }

  /** Reserved for warm-start / new Want delivery (no-op for this sample). */
  onNewWant(): void {

  }

  /**
   * 系统返回 / 侧滑返回（UIAbility 级）。
   *
   * **方法名是 `onBackPressed`（带 d）**，不是页面组件的 `onBackPress` —— 之前
   * 写成 `onBackPress` 导致这一层从未被回调，用户侧滑时直接回到了桌面。
   *
   * 语义（官方文档）：不重写时系统默认把 UIAbility 置于后台（不是销毁）。
   * 这里保持该默认行为，只在「播放页开着」时额外把播放页收起来。
   */
  onBackPressed(): boolean {
    const handled: boolean = BackHandler.handle();
    Logger.info('EntryAbility: onBackPressed handled=' + handled);
    // 返回 true = 这次返回已被处理（系统不会再把 Ability 置于后台/销毁）。
    // 播放页没开时 handled=false，但保持 true 才能维持「返回只回桌面」的默认观感。
    return true;
  }
}
