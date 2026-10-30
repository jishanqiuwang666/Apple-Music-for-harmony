/**
 * AI 歌词翻译的凭据配置（用户可在「设置 → AI 翻译」里填自己的 key）。
 *
 * **开源仓库里不带任何凭据**：`DEFAULT_KEY` 默认为空串，装完要翻译就得自己填一个
 * （设置 → AI 翻译）。想本地开箱即用可以把 key 填进 `DEFAULT_KEY`，但别提交 ——
 * 提交前请确认那里是空串，否则等于把自己的 key 公开。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../util/Logger';
import { LOCAL_AI_KEY } from './AiKeyLocal';

const TAG: string = 'AiTransConfig';
const PREF_NAME: string = 'musichome_ai';
const KEY_API: string = 'translate_api_key';

export class AiTransConfig {
  /**
   * 默认 key：**来自未跟踪的本地文件** `AiKeyLocal.ets`（仓库里是空模板）。
   *
   * 这样同一个仓库能出两种包：
   *   - 本机自用（AiKeyLocal.ets 有 key）→ 装完即用；
   *   - 开源/分发包（模板的空 key）→ 包里不含任何凭据。
   */
  public static readonly DEFAULT_KEY: string = LOCAL_AI_KEY;

  private static prefs: preferences.Preferences | null = null;
  private static custom: string = '';

  /** App 启动时调一次，把用户自定义的 key 读回内存。 */
  public static async init(context: common.Context): Promise<void> {
    if (AiTransConfig.prefs !== null) {
      return;
    }
    try {
      AiTransConfig.prefs = await preferences.getPreferences(context, PREF_NAME);
      AiTransConfig.custom = (await AiTransConfig.prefs.get(KEY_API, '')) as string;
      Logger.info(TAG, `init: 自定义 key=${AiTransConfig.custom.length} 字符`);
    } catch (err) {
      const e: Error = err as Error;
      Logger.warn(TAG, 'init failed: ' + e.message);
    }
  }

  /** 当前生效的 key（自定义优先，否则默认；都没有时返回空串 = 未配置）。 */
  public static apiKey(): string {
    return AiTransConfig.custom.length > 8 ? AiTransConfig.custom : AiTransConfig.DEFAULT_KEY;
  }

  /** 是否已经配置了可用的 key（设置面板与翻译器据此判断「能不能翻译」）。 */
  public static hasKey(): boolean {
    return AiTransConfig.apiKey().length > 8;
  }

  /** 是否已使用自定义 key（设置面板据此显示状态）。 */
  public static hasCustom(): boolean {
    return AiTransConfig.custom.length > 8;
  }

  /** 已保存的自定义 key（脱敏展示用；没有时返回空串）。 */
  public static maskedKey(): string {
    if (!AiTransConfig.hasCustom()) {
      return '';
    }
    const k: string = AiTransConfig.custom;
    if (k.length <= 12) {
      return k.substring(0, 4) + '****';
    }
    return k.substring(0, 6) + '…' + k.substring(k.length - 4);
  }

  /**
   * 保存自定义 key（传空串 = 恢复出厂默认）。
   *
   * @returns 是否保存成功
   */
  public static async save(context: common.Context, key: string): Promise<boolean> {
    const trimmed: string = key.trim();
    if (trimmed.length > 0 && trimmed.length < 16) {
      return false;
    }
    try {
      if (AiTransConfig.prefs === null) {
        AiTransConfig.prefs = await preferences.getPreferences(context, PREF_NAME);
      }
      AiTransConfig.custom = trimmed;
      await AiTransConfig.prefs.put(KEY_API, trimmed);
      await AiTransConfig.prefs.flush();
      Logger.info(TAG, `save: ${trimmed.length} 字符`);
      return true;
    } catch (err) {
      const e: Error = err as Error;
      Logger.warn(TAG, 'save failed: ' + e.message);
      return false;
    }
  }
}
