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

import { hdsEffect } from '@kit.UIDesignKit';

/**
 * 全 App 那**一层**流光背景的调度台。
 *
 * 背景从「每个板块页面各一层」改成「App 根层一层」之后（2026-09-13），
 * 页面对流的控制就只剩下「什么时候让位给交互」：
 *
 * - 滚动列表时暂停：全屏 UV shader 每帧都要合成，手机发热降频时列表滑动会卡；
 *   手指一停 220ms 再自动恢复，视觉上几乎察觉不到，但把滑动那几帧的渲染预算
 *   全让给了列表。
 * （切 tab 的暂停/恢复由 Index 自己控制，因为那还要配合 tab 动画时长。）
 */
export class FlowLightRegistry {
  private static controller: hdsEffect.ShaderEffectController | undefined = undefined;
  /** 停止滚动后恢复的定时器 id（-1 = 没有待恢复任务）。 */
  private static resumeTimer: number = -1;

  /**
   * 交给它 App 层唯一那层流光的控制器（Index 在 aboutToAppear 调用一次）。
   *
   * @param controller 流光控制器
   */
  public static attach(controller: hdsEffect.ShaderEffectController): void {
    FlowLightRegistry.controller = controller;
  }

  /**
   * 列表滚动中调用（放 onDidScroll 里）：暂停流光，并在最后一次滚动后 220ms 恢复。
   * 高频调用是安全的：只重置定时器，不重复 pause。
   */
  public static beginScroll(): void {
    const controller = FlowLightRegistry.controller;
    if (controller === undefined) {
      return;
    }
    if (FlowLightRegistry.resumeTimer === -1) {
      controller.pause();
    } else {
      clearTimeout(FlowLightRegistry.resumeTimer);
    }
    FlowLightRegistry.resumeTimer = setTimeout(() => {
      FlowLightRegistry.resumeTimer = -1;
      controller.resume();
    }, 220);
  }
}
