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

import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'AppearanceController';
const PREF_NAME = 'appearance_store';
const PREF_KEY = 'appearance_mode';

/** User-facing appearance modes. */
export enum AppearanceMode {
  /** Follow the system color mode. */
  SYSTEM = 0,
  /** Force light mode. */
  LIGHT = 1,
  /** Force dark mode. */
  DARK = 2
}

/**
 * Persists and applies the appearance mode (follow system / light / dark).
 * Applies via {@link common.UIAbilityContext.setColorMode}; resources under
 * resources/dark adapt automatically.
 */
export class AppearanceController {
  private static instance: AppearanceController | undefined = undefined;
  private context: common.UIAbilityContext | undefined;
  private mode: AppearanceMode = AppearanceMode.SYSTEM;

  private constructor() {
  }

  /** @returns The shared appearance controller. */
  public static getInstance(): AppearanceController {
    if (AppearanceController.instance === undefined) {
      AppearanceController.instance = new AppearanceController();
    }
    return AppearanceController.instance;
  }

  /**
   * Reads the persisted mode (default: follow system) and applies it.
   * @param context UIAbility context for preferences and setColorMode.
   */
  public async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      const saved = await pref.get(PREF_KEY, AppearanceMode.SYSTEM) as number;
      this.mode = saved === AppearanceMode.LIGHT || saved === AppearanceMode.DARK ? saved : AppearanceMode.SYSTEM;
    } catch (err) {
      Logger.warn(TAG, `init read failed: ${JSON.stringify(err)}`);
      this.mode = AppearanceMode.SYSTEM;
    }
    this.applyMode();
  }

  /** @returns The current appearance mode. */
  public currentMode(): AppearanceMode {
    return this.mode;
  }

  /** @returns The display label of a mode. */
  public static labelOf(mode: AppearanceMode): string {
    if (mode === AppearanceMode.LIGHT) {
      return '亮色模式';
    }
    if (mode === AppearanceMode.DARK) {
      return '暗色模式';
    }
    return '跟随系统';
  }

  /**
   * 直接设置外观模式（设置抽屉里的三选一），持久化并立即生效。
   * @param mode 目标模式。
   */
  public async setMode(mode: AppearanceMode): Promise<AppearanceMode> {
    this.mode = mode;
    this.applyMode();
    await this.persist();
    return this.mode;
  }

  /**
   * Cycles system → light → dark → system, persists, and applies immediately.
   * @returns The newly selected mode.
   */
  public async cycle(): Promise<AppearanceMode> {
    this.mode = this.mode === AppearanceMode.SYSTEM ? AppearanceMode.LIGHT :
      (this.mode === AppearanceMode.LIGHT ? AppearanceMode.DARK : AppearanceMode.SYSTEM);
    this.applyMode();
    await this.persist();
    return this.mode;
  }

  /** Applies the current mode to the application context. */
  private applyMode(): void {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    const colorMode = this.mode === AppearanceMode.LIGHT ?
      ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
      (this.mode === AppearanceMode.DARK ?
        ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    context.setColorMode(colorMode);
  }

  /** Persists the current mode. */
  private async persist(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      await pref.put(PREF_KEY, this.mode);
      await pref.flush();
    } catch (err) {
      Logger.warn(TAG, `persist failed: ${JSON.stringify(err)}`);
    }
  }
}
