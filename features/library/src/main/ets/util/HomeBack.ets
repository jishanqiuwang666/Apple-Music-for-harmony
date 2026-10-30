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

import { AppStorageV2, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppStorageKeys, MusicAppState } from 'musicbasic';

/**
 * 板块**首页**的返回处理。
 *
 * 背景（用户 2026-09-13 复现的 bug）：四个板块首页（艺人 / 专辑 / 歌单 / 搜索）
 * 本身就是各自 Navigation 栈里压着的第一页。系统返回键会把这一页也弹掉 —— 栈变空
 * 之后没人再把它压回来（Shell 只在 aboutToAppear 里压一次），页面就只剩底色，
 * 深色模式下看起来就是「黑屏，只能重启 App」。
 *
 * 正确行为：
 * 1. 设置抽屉开着 → 先关抽屉（返回键的常规语义）；
 * 2. 否则回到桌面（moveAbilityToBackground）—— 音乐继续后台播放，
 *    这是音乐类 App 在顶层的标准返回行为；
 * 3. 任何情况下都**消费**掉返回事件，绝不让首页被弹掉。
 */
export class HomeBack {
  /**
   * 统一的首页返回处理。
   *
   * @param ctx 当前页面的 UIContext（用于取 UIAbilityContext）
   * @returns 始终 true（返回事件已被消费，首页不会被弹出）
   */
  public static handle(ctx: UIContext): boolean {
    const appState: MusicAppState = AppStorageV2.connect(MusicAppState, AppStorageKeys.MUSIC_APP_STATE,
      () => new MusicAppState())!;
    if (appState.drawerOpen) {
      // 抽屉由 Index 侧监听这个标记来播放收起动画，这里只负责翻标记 + 消费事件
      appState.drawerOpen = false;
      return true;
    }
    const host = ctx.getHostContext() as common.UIAbilityContext;
    if (host !== undefined) {
      try {
        // 返回 Promise：挂个 catch，避免未处理的拒绝刷日志。
        host.moveAbilityToBackground().catch(() => {
        });
      } catch (e) {
        // 拿不到 ability 上下文或接口不可用就静默忽略：至少不会黑屏
      }
    }
    return true;
  }
}
