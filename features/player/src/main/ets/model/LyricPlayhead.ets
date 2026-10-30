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

import { MediaService } from './MediaService';

/**
 * 歌词播放头：给逐词高亮提供**毫秒级、且不会漂移**的播放位置。
 *
 * ## 为什么要单独做一层（这是「前半段不高亮」bug 的根因）
 *
 * 旧实现只有一条时间来源：`MusicAppState.progress`（AVPlayer 的 `timeUpdate` 回调），
 * 然后用「锚点 + 墙钟插值」补到毫秒级。它有两个致命前提：
 *
 *  ① `timeUpdate` 必须**持续**送来新值 —— 实际上 `MediaService` 在 seek 之后会把
 *     `isCurrent` 置 false 冻结进度（等 `seekDone`），那个回调偶发丢失时进度会
 *     冻住一段时间；歌的开头正好是各种 seek/恢复最密集的地方。
 *  ② 「锚点 + 墙钟」只在播放位置与墙钟**严格同步**时成立 —— 一旦有一拍没对上
 *     （缓冲、解密、状态切换），插值就会跑到真实播放头前面去，而且**误差不会自己
 *     收敛**：实测出现过领先 15 秒。
 *
 * 而歌词的时间轴是**绝对时间轴**（每行 `begin` 都是相对整首歌的毫秒数），
 * 位置错 3 秒就足以让「当前行」落在别的行上。歌的开头句子间隔只有 2~3 秒，
 * 于是表现成「前半段完全不亮 / 停在前一行」，后半程句子间隔大就看不出来。
 *
 * ## 现在的做法
 *
 * **主源**：直接读 AVPlayer 的 `currentTime`（`MediaService.playheadMs()`）。
 * 它就是播放头本体，没有插值、没有滞后，误差 = 0；
 * 如果底层属性更新粒度较粗（相邻两次读到同一个值），才用墙钟做**有上限**的插值。
 *
 * **备源**：播放器未就绪时（`currentTime < 0`）才退回 `state.progress` 锚点。
 *
 * 所以：只要音乐在播，歌词位置永远与播放头一致，不存在「越播越偏」。
 */
export class LyricPlayhead {
  /** 最近一次读到的**真实**播放头（毫秒）；-1 表示还没读到过。 */
  private realMs: number = -1;
  /** 上次 realMs 发生变化时的墙钟时刻（毫秒）。 */
  private realAt: number = 0;
  /** 备源锚点（`state.progress`，毫秒）。 */
  private fallbackMs: number = -1;
  /** 备源锚点的墙钟时刻。 */
  private fallbackAt: number = 0;
  /**
   * 墙钟插值的上限（毫秒）。
   *
   * 正常情况下 `currentTime` 每 66ms 心跳都会给出新值，插值最多补 66ms。
   *
   * **2026-10-30 收紧到 400ms**：原来给了 2.5s，断断续续暂停/缓冲时
   * 「播放头不更新 + 墙钟继续跑」会把位置虚推到最多 2.5 秒之后 —— 足够跨过一行，
   * 于是画面自己换行、再被真实播放头拉回来，看起来就是「乱跳」。
   * 400ms 小于最短句子间隔，跨不过一行，最坏只是同一行内略微超前。
   */
  private static readonly MAX_EXTRAPOLATE_MS: number = 400;

  /**
   * 喂一个备源锚点（`MusicAppState.progress` 变化时调用）。
   *
   * 只在播放器还没就绪（例如刚 loadAsset、正在解密）时用得上；
   * 平时主源完全覆盖，喂不喂都不影响结果。
   */
  public anchor(progressMs: number): void {
    if (!Number.isFinite(progressMs)) {
      return;
    }
    if (progressMs !== this.fallbackMs) {
      this.fallbackMs = progressMs;
      this.fallbackAt = Date.now();
    }
  }

  /** 切歌 / seek / 重新进入歌词页时清掉采样，避免拿上一首的位置。 */
  public reset(): void {
    this.realMs = -1;
    this.realAt = 0;
    this.fallbackMs = -1;
    this.fallbackAt = 0;
  }

  /**
   * 当前播放位置（毫秒，绝对时间轴）。
   *
   * @param playing 是否正在播放（暂停时不做外推，停在最后一次采样处）。
   * @param durationMs 总时长，用来夹住结果（0 表示未知）。
   */
  public now(playing: boolean, durationMs: number): number {
    const nowWall: number = Date.now();
    const real: number = LyricPlayhead.readPlayhead();
    let pos: number;

    if (real >= 0) {
      if (real !== this.realMs) {
        // 采样值变了：这是最准的位置，直接用它锚定（下一次真值到达时再拉回来）
        this.realMs = real;
        this.realAt = nowWall;
        pos = real;
      } else if (!playing) {
        // 暂停：停在最后一次采样处，不做外推。
        // **同时把锚点时间刷成"现在"** —— 否则暂停 30 秒后恢复播放的第一拍，
        // since 会是 30 秒，被 clamp 成 400ms 的外推 → 位置瞬间前跳 400ms，
        // 足够跨过一个字：高光会先跳到这个字的末尾、下一拍再被真值拉回中间。
        // （用户实测到的「恢复播放时高光跳一下再回来」就是这一条。）
        this.realAt = nowWall;
        pos = this.realMs;
      } else {
        // 底层属性更新粒度较粗（或这一拍没刷新）：两次采样之间用墙钟补齐，
        // 但**有上限** —— 采样一旦长时间不更新也不会跑飞几十秒。
        const since: number = nowWall - this.realAt;
        pos = this.realMs + (since < LyricPlayhead.MAX_EXTRAPOLATE_MS ? since : LyricPlayhead.MAX_EXTRAPOLATE_MS);
      }
    } else if (this.fallbackMs >= 0) {
      // 播放器未就绪：退回 state.progress 锚点（暂停时不动）
      const since: number = nowWall - this.fallbackAt;
      pos = this.fallbackMs + (playing && since > 0 ? since : 0);
    } else {
      pos = 0;
    }

    if (durationMs > 0 && pos > durationMs) {
      pos = durationMs;
    }
    return pos >= 0 ? pos : 0;
  }

  /** 读 AVPlayer 的真实播放位置；未就绪返回 -1。 */
  private static readPlayhead(): number {
    try {
      return MediaService.getInstance().playheadMs();
    } catch (err) {
      return -1;
    }
  }
}
