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
 * 设置抽屉（左侧滑出）。
 *
 * 面板本体、开合动画与手势在 pages/Index.ets 里；这里只负责内容与行为。
 * 视觉遵循用户要求：官方半透明沉浸光感材质（backgroundBlurStyle + HDS 光感）
 * + 内部按钮的官方 spring 回弹。
 */
import { AppStorageV2, curves, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AiTransConfig, AppStorageKeys, AppearanceController, AppearanceMode, AppleApi, AppleArtworkCache, AppleAuthState, AppleCache, CacheStats, LibrarySignal, Logger, MusicDatabase, MusicDbApi, WindowUtil } from 'musicbasic';
import { AppleLibrarySync, SyncResult } from 'musicbasic';

import { MediaService } from 'player';

const TAG = 'SettingsDrawer';
/** 设置项持久化文件。 */
const PREF_NAME = 'app_settings';
const KEY_KEEP_SCREEN_ON = 'keep_screen_on';
const KEY_LAST_SYNC = 'last_sync_at';

/** 设置项的可观察状态（跨页面共享）。 */
@ObservedV2
export class AppSettingsState {
  @Trace public keepScreenOn: boolean = true;
  @Trace public lastSyncAt: number = 0;
  @Trace public syncing: boolean = false;
  @Trace public note: string = '';

  private static instance: AppSettingsState | undefined = undefined;

  public static getInstance(): AppSettingsState {
    if (AppSettingsState.instance === undefined) {
      AppSettingsState.instance = new AppSettingsState();
    }
    return AppSettingsState.instance;
  }

  /** 读取持久化的开关。 */
  public async init(context: common.Context): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      this.keepScreenOn = pref.getSync(KEY_KEEP_SCREEN_ON, true) as boolean;
      this.lastSyncAt = pref.getSync(KEY_LAST_SYNC, 0) as number;
    } catch (err) {
      Logger.warn(TAG, `settings init failed: ${(err as Error).message}`);
    }
  }

  /** 应用常亮开关并持久化。 */
  public async setKeepScreenOn(context: common.Context, on: boolean): Promise<void> {
    this.keepScreenOn = on;
    WindowUtil.getInstance().setKeepScreenOn(on);
    await this.persist(context);
  }

  /** 记录同步时间。 */
  public async markSynced(context: common.Context): Promise<void> {
    this.lastSyncAt = new Date().getTime();
    await this.persist(context);
  }

  private async persist(context: common.Context): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      await pref.put(KEY_KEEP_SCREEN_ON, this.keepScreenOn);
      await pref.put(KEY_LAST_SYNC, this.lastSyncAt);
      await pref.flush();
    } catch (err) {
      Logger.warn(TAG, `settings persist failed: ${(err as Error).message}`);
    }
  }
}

/** 左侧设置抽屉的内容面板。 */
@ComponentV2
export struct SettingsDrawer {
  /** 关闭请求（由壳层做回弹动画）。 */
  @Event onClose: () => void = () => {
  };
  /** 当前外观模式（镜像 AppearanceController，便于三选一高亮）。 */
  @Local mode: AppearanceMode = AppearanceMode.SYSTEM;
  /** 共享设置状态。 */
  @Local settings: AppSettingsState = AppSettingsState.getInstance();
  /** Apple 登录态。 */
  @Local authState: AppleAuthState =
    AppStorageV2.connect(AppleAuthState, AppStorageKeys.APPLE_AUTH_STATE, () => new AppleAuthState())!;
  /** 各段按钮的按压缩放（官方 spring 回弹）。 */
  @Local pressedKey: string = '';
  /** AI 翻译 key 输入框的草稿（不直接读配置，避免未保存就生效）。 */
  @Local aiKeyDraft: string = '';
  /** 是否已保存自定义 key（决定副标题文案）。 */
  @Local aiKeyCustom: boolean = false;
  /** 已保存 key 的脱敏展示。 */
  @Local aiKeyMasked: string = '';
  /** 「补齐曲库版本」是否正在跑（长任务，防重复点击）。 */
  aboutToAppear(): void {
    this.mode = AppearanceController.getInstance().currentMode();
    this.syncAiKeyState();
    this.authState.refreshFromApi();
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      this.settings.init(ctx).then(() => {
        WindowUtil.getInstance().setKeepScreenOn(this.settings.keepScreenOn);
      });
    }
  }

  /** 把已保存的 key 状态同步到界面（打开面板时调一次）。 */
  private syncAiKeyState(): void {
    this.aiKeyCustom = AiTransConfig.hasCustom();
    this.aiKeyMasked = AiTransConfig.maskedKey();
    this.aiKeyDraft = '';
  }

  /** 保存 AI 翻译 key（空串 = 恢复内置 key）。 */
  private async saveAiKey(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const ok: boolean = await AiTransConfig.save(ctx, this.aiKeyDraft);
    if (!ok) {
      promptAction.showToast({ message: 'Key 太短或保存失败', duration: 1800 });
      return;
    }
    this.syncAiKeyState();
    promptAction.showToast({
      message: AiTransConfig.hasCustom() ? '已保存，下一首歌生效' : '已清除，翻译功能已关闭',
      duration: 1800
    });
  }

  /** vp → 屏幕坐标（略：仅用于布局常量）。 */
  private panelPaddingTop(): number {
    return 56;
  }

  /** 切换外观模式。 */
  private async pickMode(target: AppearanceMode): Promise<void> {
    this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
      this.mode = target;
    });
    await AppearanceController.getInstance().setMode(target);
  }

  /** 立即同步资料库（歌曲 + 歌单 + 歌单曲目）。 */
  private async syncNow(): Promise<void> {
    if (this.settings.syncing) {
      return;
    }
    this.settings.syncing = true;
    this.settings.note = '正在同步资料库…';
    try {
      const songs: SyncResult = await AppleLibrarySync.syncSongs(undefined, true);
      const lists: SyncResult = await AppleLibrarySync.syncPlaylists();
      const tracks: SyncResult = await AppleLibrarySync.syncAllPlaylistTracks(true);
      this.settings.note = `同步完成：${songs.songs} 首歌曲 · ${lists.songs} 个歌单 · ${tracks.songs} 个可用`;
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        await this.settings.markSynced(ctx);
      }
      // songs 表被重建：队列的 id 镜像要重建，否则播放条会变空。
      MediaService.getInstance().remapQueueAfterSync();
      LibrarySignal.notifyChanged();
    } catch (err) {
      this.settings.note = '同步失败：' + ((err as Error).message ?? '');
    }
    this.settings.syncing = false;
  }

  /** 清理下载缓存（保留 pinned）。 */
  private async clearCache(): Promise<void> {
    const removed: number = await AppleCache.clearAll(true);
    const art: number = AppleArtworkCache.clear();
    this.settings.note = `已清理 ${removed} 首音频缓存、${art} 张封面`;
  }

  /** 退出 Apple Music 账号：清掉本机凭据与登录 Cookie，回到未登录状态。 */
  private async logout(): Promise<void> {
    await AppleApi.logout();
    this.authState.refreshFromApi();
    this.settings.note = '已退出 Apple Music，可以登录另一个账号了';
    // 先收起抽屉（抽屉 zIndex 高于登录页，不收会盖住登录页），再弹登录页
    this.onClose();
    this.authState.openLogin();
  }

  /** 清空本机资料库与缓存（换账号后避免两个账号的曲库混在一起）。 */
  private async clearLocalLibrary(): Promise<void> {
    await MusicDatabase.getInstance().clearAll();
    const removed: number = await AppleCache.clearAll(false);
    const art: number = AppleArtworkCache.clear();
    MediaService.getInstance().remapQueueAfterSync();
    LibrarySignal.notifyChanged();
    this.settings.note = `已清空本机资料库：${removed} 首音频缓存、${art} 张封面`;
  }

  /** 字节 → 人类可读。 */
  private fmtBytes(bytes: number): string {
    if (bytes <= 0) {
      return '0 MB';
    }
    const mb = bytes / 1024 / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 时间戳 → MM-DD HH:mm。 */
  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '尚未同步';
    }
    const d = new Date(ts);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  /** 分段标题。 */
  @Builder
  private SectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.library_text_secondary'))
      .width('100%')
      .padding({ left: 4, top: 18, bottom: 8 })
  }

  /** 外观模式三选一（用户要求：删掉文字，只留 3 个图标）。 */
  @Builder
  private ModeChip(target: AppearanceMode, icon: Resource, key: string) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.mode === target ? Color.White : $r('app.color.library_text_primary')])
    }
    .width(46)
    .height(46)
    .padding(0)
    .backgroundColor(this.mode === target ? $r('app.color.library_accent') : '#33000000')
    .scale({ x: this.pressedKey === key ? 0.94 : 1, y: this.pressedKey === key ? 0.94 : 1 })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
          this.pressedKey = key;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.getUIContext().animateTo({ curve: curves.springMotion() }, () => {
          this.pressedKey = '';
        });
      }
    })
    .onClick(() => {
      this.pickMode(target);
    })
  }

  /** 通用设置行（图标 + 标题 + 副标题 + 右侧操作）。 */
  @Builder
  private ActionRow(title: string, subtitle: string, actionText: string, key: string, enabled: boolean,
    action: () => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor($r('app.color.library_text_primary'))
          .width('100%')
        if (subtitle !== '') {
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.library_text_secondary'))
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (actionText !== '') {
        Button({ type: ButtonType.Capsule }) {
          Text(actionText)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .height(34)
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.library_accent'))
        .enabled(enabled)
        .opacity(enabled ? 1 : 0.45)
        .scale({ x: this.pressedKey === key ? 0.94 : 1, y: this.pressedKey === key ? 0.94 : 1 })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
              this.pressedKey = key;
            });
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.getUIContext().animateTo({ curve: curves.springMotion() }, () => {
              this.pressedKey = '';
            });
          }
        })
        .onClick(() => {
          action();
        })
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 10, bottom: 10 })
  }

  build() {
    Column() {
      // ── 标题栏 ──
      Row() {
        Text('设置')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.library_text_primary'))
        Blank()
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.library_text_primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor('#1A000000')
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 14, bottom: 6 })

      Scroll() {
        Column() {
          // ── 外观 ──
          this.SectionTitle('外观')
          Row({ space: 10 }) {
            this.ModeChip(AppearanceMode.SYSTEM, $r('sys.symbol.circle_lefthalf_inset_filled'), 'mode-system')
            this.ModeChip(AppearanceMode.LIGHT, $r('sys.symbol.sun_max'), 'mode-light')
            this.ModeChip(AppearanceMode.DARK, $r('sys.symbol.moon'), 'mode-dark')
          }
          .width('100%')

          // ── 账户 ──
          this.SectionTitle('Apple Music 账户')
          this.ActionRow(
            this.authState.authorized ? '已登录' : '未登录',
            this.authState.authorized
              ? (this.authState.accountId !== ''
                ? `${this.authState.accountId} · 商店地区 ${this.authState.storefront}`
                : `商店地区：${this.authState.storefront}`)
              : '登录后即可同步资料库、歌单与艺人头像',
            this.authState.authorized ? '切换账户' : '登录',
            'account-login',
            true,
            (): void => {
              this.authState.openLogin();
            })
          if (this.authState.authorized) {
            this.ActionRow('退出登录', '清除本机登录凭据，之后可登录另一个账号', '退出', 'account-logout', true,
              (): void => {
                this.logout();
              })
          }
          this.ActionRow('清空本机资料库', '删除本机已同步的歌曲、歌单与缓存（不影响 Apple 账号）', '清空',
            'library-clear', true,
            (): void => {
              this.clearLocalLibrary();
            })

          // ── 资料库 ──
          this.SectionTitle('资料库')
          this.ActionRow(
            `上次同步：${this.fmtTime(this.settings.lastSyncAt)}`,
            `${MusicDbApi.getInstance().getSongList().length} 首 · ` +
              `${MusicDbApi.getInstance().getApplePlaylists().length} 个歌单`,
            this.settings.syncing ? '同步中…' : '立即同步',
            'library-sync',
            !this.settings.syncing,
            (): void => {
              this.syncNow();
            })

          // ── 缓存与存储 ──
          this.SectionTitle('缓存与存储')
          this.ActionRow('已下载的音频', this.cacheSummary(), '清理缓存', 'cache-clear', true,
            (): void => {
              this.clearCache();
            })

          // ── 播放 ──
          this.SectionTitle('播放')
          Row() {
            Column({ space: 2 }) {
              Text('播放时保持屏幕常亮')
                .fontSize(16)
                .fontColor($r('app.color.library_text_primary'))
              Text(this.settings.keepScreenOn ? '暂停或停止播放后恢复系统息屏' : '跟随系统自动息屏')
                .fontSize(12)
                .fontColor($r('app.color.library_text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.settings.keepScreenOn })
              .selectedColor($r('app.color.library_accent'))
              .onChange((isOn: boolean) => {
                const ctx = this.getUIContext().getHostContext();
                if (ctx !== undefined) {
                  this.settings.setKeepScreenOn(ctx, isOn);
                }
              })
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 10, bottom: 10 })

          // ── AI 翻译 ──
          // 歌词译文平时用内置 key；想换成自己的 DeepSeek 账号就在这里填，
          // 保存后立刻生效（翻译结果不落盘，只在本机内存里缓存一次）。
          this.SectionTitle('AI 翻译')
          Row({ space: 8 }) {
            TextInput({ text: this.aiKeyDraft, placeholder: 'DeepSeek API Key（sk-…）' })
              .type(InputType.Password)
              .layoutWeight(1)
              .height(38)
              .fontSize(14)
              .borderRadius(10)
              .backgroundColor('#22000000')
              .onChange((value: string) => {
                this.aiKeyDraft = value;
              })
            Button({ type: ButtonType.Capsule }) {
              Text('保存')
                .fontSize(14)
                .fontColor(Color.White)
            }
            .height(34)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.library_accent'))
            .scale({ x: this.pressedKey === 'ai-key' ? 0.94 : 1, y: this.pressedKey === 'ai-key' ? 0.94 : 1 })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion() }, () => {
                  this.pressedKey = 'ai-key';
                });
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.getUIContext().animateTo({ curve: curves.springMotion() }, () => {
                  this.pressedKey = '';
                });
              }
            })
            .onClick(() => {
              this.saveAiKey();
            })
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 4, bottom: 4 })

          Text(this.aiKeyCustom
            ? `当前使用自定义 key（${this.aiKeyMasked}），留空保存可恢复内置 key`
            : '当前使用内置 key；歌曲没有官方译文时，点歌词页右上角「译」会调用 AI 翻译')
            .fontSize(12)
            .fontColor($r('app.color.library_text_secondary'))
            .width('100%')
            .padding({ left: 4, top: 2, bottom: 6 })

          // ── 提示 / 关于 ──
          if (this.settings.note !== '') {
            Text(this.settings.note)
              .fontSize(12)
              .fontColor($r('app.color.library_text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 14 })
          }
          Text('自用版 · Apple Music 音频在本机下载并解密后播放，不做任何分享')
            .fontSize(11)
            .fontColor($r('app.color.library_text_secondary'))
            .width('100%')
            .padding({ left: 4, top: 18, bottom: 24 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: this.panelPaddingTop() })
    .alignItems(HorizontalAlign.Start)
    // 官方半透明沉浸光感：毛玻璃 + UV 流光背景（与四个板块同款效果）
    // 半透明材质：比之前那档薄一点，能透出底下的页面色彩
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    // 官方毛玻璃 + 一层淡色薄层 = 半透明沉浸光感。
    // 注：面板不要再叠 UV 流光 shaderEffect —— 定宽容器上它会整片画成黑底，
    // 配合遮罩看起来就是「黑屏」（真机实测）。
    .backgroundColor('#26FFFFFF')
    // 用户要求：不要圆角，恢复原来的整高方角样式
    .border({ width: { right: 0.5 }, color: '#1A000000' })
  }

  /** 缓存摘要文案。 */
  private cacheSummary(): string {
    const stats: CacheStats = AppleCache.stats();
    const art: number = AppleArtworkCache.sizeBytes();
    return `${stats.count} 首 · ${this.fmtBytes(stats.bytes)}（上限 ${this.fmtBytes(stats.limitBytes)}）` +
      ` · 封面 ${this.fmtBytes(art)}`;
  }
}
