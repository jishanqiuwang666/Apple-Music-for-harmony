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
 * 全屏播放页「升起进度」的可观察容器（0 = 还在屏幕下方，1 = 完全铺满）。
 *
 * 为什么是一个类而不是一个 number：
 * 跟手拖动时这个值**每帧都在变**。如果把它做成 Index 的 @Local，每帧都会让
 * Index 重建 —— 而 Index 的 build 里挂着整个 HdsTabs 壳层（5 个 tab 页 +
 * 流光 + 抽屉），60fps 下必然掉帧。
 * 做成 @ObservedV2 对象后，父组件（Index）持有引用不变、自身不重建，
 * 只有真正读 `value` 的那一个轻组件（FullPlayerSheet）会跟着刷新。
 * 这是 ArkUI 状态管理 V2 里做「高频跟手动画」的标准做法。
 */
@ObservedV2
export class PlayerSheetProgress {
  /** 升起进度，0..1。 */
  @Trace public value: number = 0;
  /**
   * 播放条上那枚封面**是否可见**（默认可见）。
   *
   * 播放条封面与播放页封面是**同一枚封面**，任何时刻屏幕上只允许存在一份：
   *  - 拉起播放页时，播放条那颗先让位（opacity 0，尺寸不变、命中不变），
   *    由播放页那颗从同一个原位接着长大 —— 观感才是「封面跟着页面一起长出来」，
   *    而不是「页面从封面那里长出来、原来那颗待在原地不动」；
   *  - 收起时反过来：播放条那颗一直藏着，直到播放页那颗**落回原位**（进度≈0）
   *    才换回来，于是不会出现「播放条那颗 + 落回来那颗」叠在一起。
   *
   * 为什么是一个布尔而不是每帧的数值：这个值被播放条（{@link Player}）在 build 里读，
   * 而播放条住在 HDS 悬浮胶囊里 —— 每帧写一个数字会让它每帧重建；
   * 布尔只在整个动画的头尾各翻一次，播放条最多重绘两次。
   * 写入方是播放页（它本来就每帧读进度，见 PhonePlaybackPage 的 @Monitor）。
   */
  @Trace public barCoverVisible: boolean = true;
}
