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

import { AppStorageV2, uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStorageKeys, AppleLyric, AppleLyrics, BreakpointType, getAppRuntime, Logger, StyleConstants } from 'musicbasic';
import { MusicAppState } from '../model/PlayerModels';
import { LrcEntry } from '../model/LrcEntry';
import { parseKrcLyric, parseLrcLyric } from '../util/LrcUtils';
import LrcView from './LrcView';
import { AppleLyricsView } from './AppleLyricsView';
import { LyricScrollEffect, LyricTopPosition } from '../constant/LyricConst';
import { ControlAreaComponent } from './ControlAreaComponent';
import { LyricFile } from '../constant/LyricConst';
import { PlayerConstants } from '../constant/PlayerConstants';
import { MediaService } from '../model/MediaService';

const TAG = 'LyricsComponent';

/** Lyric panel: Apple Music TTML first, then local LRC/KRC, then a placeholder. */
@ComponentV2
export struct LyricsComponent {
  /** Window breakpoint for responsive lyric layout. */
  @Env(SystemProperties.BREAK_POINT) breakpointEnv: uiObserver.WindowSizeLayoutBreakpointInfo;
  /** Shared playback state (track, progress). */
  @Local state: MusicAppState =
    AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE, () => new MusicAppState())!;
  /** When true, shows transport controls under lyrics (tablet / wide layouts). */
  @Param isShowControl: boolean = false;
  /** Tablet-style spacing flag passed to child layout. */
  @Param isTablet: boolean = false;
  /** Hides title/artist header above lyrics when embedded in split layouts. */
  @Param hideLyricsMetaHeader: boolean = false;
  /** When true, replaces the lyrics-bottom action row with the wide panel dual-icon variant. */
  @Param panelBottomBar: boolean = false;
  /** 屏幕高度（vp）：Apple 歌词的活跃行要钉在它的 25% 处。 */
  @Param screenHeightVp: number = 837;
  /** 歌词区顶边在屏幕里的 y（vp）：算渐隐与滚动偏移都要用。 */
  @Param lyricsAreaTopVp: number = 134;
  /** 歌词区底边在屏幕里的 y（vp）；0 = 一直排到屏幕最底（底部没有播控时）。 */
  @Param lyricsAreaBottomVp: number = 0;
  /**
   * 当前曲目封面（本地沙箱路径）。
   *
   * 只给 Apple 歌词页的「模糊运动背景」用：拿这张图做重度模糊 + 缓慢漂移，
   * 复刻官方歌词页那块会流动的封面色块。空串时退回纯色渐变。
   */
  @Param coverPath: string = '';
  /**
   * 歌词文字区的左右边距（vp）。
   *
   * 背景层要铺满整宽，所以边距不能再挂在宿主容器上 —— 由歌词组件内部施加给列表。
   * 官方歌词条墨迹从 ~33vp 开始（字侧还有一点视觉空隙）。
   */
  @Param edgePaddingVp: number = 33;
  /**
   * 歌词页是否在前台。
   *
   * 宿主按「歌词页显示进度」传进来：false 时 Apple 歌词页的心跳完全空转，
   * 封面页那段时间不再有任何逐字动画/滚动开销（省电、省渲染）。
   */
  @Param active: boolean = true;
  /** Visual scroll / gradient effect mode for LrcView. */
  @Local lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  /** Parsed lyric lines for the current track (local LRC/KRC fallback). */
  @Local mLrcEntryList: Array<LrcEntry> = [];
  /**
   * Apple Music 歌词（TTML）。
   * undefined = 还没拉 / 这首歌没有；有值就走 Apple 风格歌词页。
   */
  @Local appleLyric: AppleLyric | undefined = undefined;
  /** 正在拉 Apple 歌词（只在 Apple 音源上会为 true）。 */
  @Local appleLoading: boolean = false;
  /**
   * 是否显示译文行。
   *
   * 开关**不再放在歌词页底部右下角**（用户反馈那颗「译」位置别扭），
   * 已上移到播放页歌词头部右上角的玻璃圆钮；状态由宿主持有，这里只读。
   */
  @Param showTranslation: boolean = true;
  /** 宿主点「译」时的回调（宿主翻转状态后回传）。 */
  @Event onToggleTranslation: () => void = (): void => {};
  /** 「译」按钮的递增请求号：透传给歌词视图，由它发起 AI 翻译。 */
  @Param aiRequest: number = 0;
  /** 译文状态上报（0 无 / 1 官方 / 2 AI 就绪），透传给播放页。 */
  @Event onTransInfo: (state: number) => void = (state: number): void => {};
  /** 歌词拉取的重试计数与定时器（队列未装配好时需要重试，见 loadAppleLyric）。 */
  private lyricRetry: number = 0;
  private lyricRetryTimer: number = 0;
  /** 歌词拉取的序号：切歌很快时，旧请求回包不许覆盖新歌的歌词。 */
  private lyricSeq: number = 0;

  /** UIAbility context for raw lyric file access. */
  private get lyricAbilityContext(): common.UIAbilityContext | undefined {
    return getAppRuntime().context;
  }

  /** Triggers initial lyric load for the current song. */
  aboutToAppear(): void {
    this.reloadLyrics();
  }

  /** 卸载时把重试定时器收干净（否则切走页面后还在后台空转）。 */
  aboutToDisappear(): void {
    if (this.lyricRetryTimer !== 0) {
      clearTimeout(this.lyricRetryTimer);
      this.lyricRetryTimer = 0;
    }
  }

  /**
   * 切歌（或队列变了）时重新取歌词。
   *
   * 本地 LRC/KRC 与 Apple 歌词**在同一次通知里一起重载**：以前挂了两份
   * `@Monitor('state.selectIndex', 'state.playQueueIds')`，同一个事件把两条加载
   * 链都触发一遍，白白多走一次 rawfile 读取和一次网络请求。
   */
  @Monitor('state.selectIndex', 'state.playQueueIds')
  reloadLyrics(): void {
    this.lyricRetry = 0;
    this.loadLocalLyric();
    this.loadAppleLyric();
  }

  /** 读本地 LRC/KRC（Apple 音源基本没有，兜底用）。 */
  private loadLocalLyric(): void {
    this.mLrcEntryList = [];
    if (!this.lyricAbilityContext) {
      return;
    }
    const song = this.state.getCurrentSongItem();
    if (!song) {
      return;
    }
    const lyricPath = song.lyric;
    if (!lyricPath || lyricPath.length === 0) {
      return;
    }
    try {
      this.lyricAbilityContext.resourceManager.getRawFileContent(lyricPath)
        .then((value: Uint8Array) => {
          let textDecoder = util.TextDecoder.create(PlayerConstants.ENCODING, { ignoreBOM: true });
          let stringData = textDecoder.decodeToString(value, { stream: false });
          if (lyricPath.endsWith(LyricFile.krc)) {
            this.mLrcEntryList = parseKrcLyric(stringData);
          } else if (lyricPath.endsWith(LyricFile.lrc)) {
            this.mLrcEntryList = parseLrcLyric(stringData);
          }
        })
        .catch((error: BusinessError) => {
          Logger.error(TAG, `getRawFileContent failed, code: ${error.code}, message: ${error.message}`);
        });
    } catch (error) {
      Logger.error(TAG, `${error.code} + ${error.message}`);
    }
  }

  /**
   * 拉 Apple Music 歌词（只有 Apple 音源才有曲目 id）。
   *
   * 优先逐词（syllable-lyrics），404 时 AppleLyrics 内部会自动降级到逐行。
   * 拉不到就留 undefined，交给本地 LRC/KRC 或「暂无歌词」。
   *
   * **必须重试**：App 刚启动 / 刚切歌时，播放队列可能还没装配好，
   * `getCurrentSongItem()` 会返回 undefined —— 这时如果直接放弃，
   * 歌词就永远空白，直到下一次切歌（用户反馈「第一次进入歌曲后不显示」）。
   * 所以拿不到 id 就短间隔重试，直到拿到为止。
   */
  private loadAppleLyric(): void {
    const song = this.state.getCurrentSongItem();
    const songId: string = song !== undefined ? AppleLyrics.songIdFromSrc(song.src) : '';
    const seq: number = ++this.lyricSeq;
    this.appleLyric = undefined;
    if (songId.length === 0) {
      this.appleLoading = false;
      this.scheduleLyricRetry();
      return;
    }
    this.appleLoading = true;
    AppleLyrics.get(songId).then((lyric: AppleLyric | null) => {
      if (seq !== this.lyricSeq) {
        // 已经切到别的歌了，这次回包作废
        return;
      }
      this.appleLoading = false;
      if (lyric !== null && !lyric.isEmpty()) {
        this.appleLyric = lyric;
        Logger.info(TAG, `Apple 歌词就绪 ${songId}: ${lyric.lines.length} 行`);
      } else {
        Logger.info(TAG, `Apple 没有歌词 ${songId}`);
      }
    }).catch((err: Error) => {
      if (seq !== this.lyricSeq) {
        return;
      }
      this.appleLoading = false;
      Logger.warn(TAG, `Apple 歌词拉取失败: ${err.message}`);
      this.scheduleLyricRetry();
    });
  }

  /**
   * 拿不到曲目 id 时的短间隔重试（队列装配是异步的，第一拍经常是空的）。
   * 指数退避到 2s 封顶，最多 12 次；一旦拿到 id 或换歌就会走正常流程。
   */
  private scheduleLyricRetry(): void {
    if (this.lyricRetry >= 12) {
      return;
    }
    this.lyricRetry++;
    const delay: number = Math.min(2000, 250 * this.lyricRetry);
    if (this.lyricRetryTimer !== 0) {
      clearTimeout(this.lyricRetryTimer);
    }
    this.lyricRetryTimer = setTimeout(() => {
      this.lyricRetryTimer = 0;
      // 序号没变才值得再试：换过歌的话 loadAppleLyric 已经被 Monitor 重新调过了
      if (this.appleLyric === undefined && !this.appleLoading) {
        this.loadAppleLyric();
      }
    }, delay);
  }

  /** Column with lyric body, footer icons, and optional ControlAreaComponent. */
  build() {
    Column() {
      if (this.appleLyric !== undefined && this.appleLyric.lines.length > 0) {
        AppleLyricsView({
          lyric: this.appleLyric,
          fontSize: this.panelBottomBar ? 34 : 35,
          showTranslation: this.showTranslation,
          screenHeightVp: this.screenHeightVp,
          areaTopVp: this.lyricsAreaTopVp,
          areaBottomVp: this.lyricsAreaBottomVp,
          coverPath: this.coverPath,
          edgePaddingVp: this.edgePaddingVp,
          active: this.active,
          onSeek: (ms: number): void => {
            MediaService.getInstance().seek(ms);
          },
          aiRequest: this.aiRequest,
          onTransInfo: (state: number): void => {
            this.onTransInfo(state);
          }
        })
          .layoutWeight(1)
      } else if (this.mLrcEntryList.length > 0) {
        LrcView({
          lyricMilliSecondsTime: this.state.progress,
          mLrcEntryList: this.mLrcEntryList,
          lyricScrollEffect: this.lyricScrollEffect,
          lyricTopPosition: LyricTopPosition.Middle,
          mNormalTextSize: this.panelBottomBar ? 32 : 24,
          mCurrentTextSize: this.panelBottomBar ? 40 : 28
        })
          .layoutWeight(1)
      } else {
        Column() {
          Text(this.appleLoading ? '正在获取歌词…' : '此歌曲暂无歌词')
            .fontSize(16)
            .fontColor('#FFFFFF')
            .opacity(0.45)
        }
        .width(StyleConstants.FULL_WIDTH)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }

      if (this.panelBottomBar) {
        Row({ space: 48 }) {
          SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize(32)
            .fontWeight(FontWeight.Regular)
            .height(32)
            .fontColor(['#99ffffff'])
          SymbolGlyph($r('sys.symbol.dot_grid_1x2_circle'))
            .fontSize(32)
            .fontWeight(FontWeight.Regular)
            .height(32)
            .fontColor(['#99ffffff'])
        }
        .width(StyleConstants.FULL_WIDTH)
        .height($r('app.float.control_icon_height'))
        .justifyContent(FlexAlign.End)
      }

      if (this.isShowControl) {
        ControlAreaComponent()
          .margin({
            top: $r('app.float.control_lyric_margin'),
            bottom: $r('app.float.music_component_bottom')
          })
      }
    }
    .width(StyleConstants.FULL_WIDTH)
    .height('100%')
  }
}
