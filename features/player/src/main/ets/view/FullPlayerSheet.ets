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

import { PlayerSheetProgress } from '../model/PlayerSheetProgress';
import { PhonePlaybackPage } from './PhonePlaybackPage';

/**
 * 手机形态的全屏播放页外壳。
 *
 * 这一层必须独立成组件：跟手时 progress 每帧都在变，只有这个轻组件会重建，
 * 宿主壳层（Index 挂着整个 HdsTabs）不受影响（见 PlayerSheetProgress 的注释）。
 *
 * 位移/封面变形都下沉到 {@link PhonePlaybackPage} 内部了 —— 封面不能放在会
 * translate 的容器里，否则整页上移后它就再也回不到播放条那一点了。
 */
@ComponentV2
export struct FullPlayerSheet {
  /** 升起进度容器（引用不变，内部 @Trace 变化只重建本组件）。 */
  @Param progress: PlayerSheetProgress = new PlayerSheetProgress();
  /** 屏幕高度（vp）。 */
  @Param screenHeightVp: number = 800;
  /** 屏幕宽度（vp）。 */
  @Param screenWidthVp: number = 420;
  /** 播放条封面的中心 x（vp，窗口坐标）；-1 = 没测到，交给页面兜底。 */
  @Param miniCoverCx: number = -1;
  /** 播放条封面的中心 y（vp，窗口坐标）；-1 = 没测到。 */
  @Param miniCoverCy: number = -1;
  /** 播放条封面边长（vp）。 */
  @Param miniCoverSize: number = 48;
  /** 播放条胶囊左边缘 x（vp）：播放页背景从这个位置长出来。 */
  @Param barLeftVp: number = 0;
  /** 播放条胶囊顶边 y（vp）。 */
  @Param barTopVp: number = 0;
  /** 播放条胶囊宽度（vp）。 */
  @Param barWidthVp: number = 60;
  /** 页面内手势请求收起（true = 收起，false = 弹回展开）。 */
  @Event requestClose: (commit: boolean) => void = (): void => {};
  /** 系统返回请求（递增）：歌词页时由播放页自己把歌词收回去。 */
  @Param backRequest: number = 0;
  /** 歌词页显隐上报（外壳据此判断返回键该收哪一层）。 */
  @Event onLyricPageChanged: (isLyric: boolean) => void = (isLyric: boolean): void => {};

  build() {
    Stack() {
      PhonePlaybackPage({
        sheet: this.progress,
        miniCoverCx: this.miniCoverCx,
        miniCoverCy: this.miniCoverCy,
        miniCoverSize: this.miniCoverSize,
        barLeftVp: this.barLeftVp,
        barTopVp: this.barTopVp,
        barWidthVp: this.barWidthVp,
        screenHeightVp: this.screenHeightVp,
        screenWidthVp: this.screenWidthVp,
        backRequest: this.backRequest,
        onLyricPageChanged: (isLyric: boolean): void => {
          this.onLyricPageChanged(isLyric);
        },
        requestClose: (commit: boolean): void => {
          this.requestClose(commit);
        }
      })
    }
    .width('100%')
    .height('100%')
    // 还完全藏在屏幕下方时不能吃事件：那块区域正好压在系统手势条上。
    .hitTestBehavior(this.progress.value > 0.02 ? HitTestMode.Default : HitTestMode.None)
    // 必须盖过 HdsTabs(1) / 搜索浮层(11) / 遮罩(20) / 设置面板(21)。
    .zIndex(30)
  }
}
