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
 * 把系统返回（含侧滑返回）转给当前页面的处理者。
 *
 * 为什么要这一层：实测 `@Entry` 组件的 `onBackPress` 在 HDS 壳层下**不会被调用**
 * （编译产物里方法在，但侧滑返回直接退出了应用）。所以改成两层兜底：
 * 页面自己实现 `onBackPress`，同时把同一段逻辑注册到这里，
 * 由 `UIAbility.onBackPress` 再兜一次。
 *
 * 用法：
 * - 页面 aboutToAppear 时 `BackHandler.register(() => ...)`；
 * - `EntryAbility.onBackPress()` 里 `return BackHandler.handle()`。
 */
export class BackHandler {
  private static handler: (() => boolean) | undefined = undefined;

  /** 注册当前页面的返回处理者（返回 true 表示已消费）。 */
  public static register(handler: () => boolean): void {
    BackHandler.handler = handler;
  }

  /** 注销（页面销毁时调用，避免持有已卸载页面的引用）。 */
  public static unregister(): void {
    BackHandler.handler = undefined;
  }

  /**
   * 交给已注册的处理者；没有处理者或它不消费时返回 false
   * （false 会让系统继续默认行为 —— 退出应用）。
   */
  public static handle(): boolean {
    const h: (() => boolean) | undefined = BackHandler.handler;
    if (h === undefined) {
      return false;
    }
    try {
      return h();
    } catch (e) {
      return false;
    }
  }
}
