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
 * Apple Music 登录页 —— 未登录时打开 App 见到的第一个页面。
 *
 * 流程（2026-10-31 改版）：
 *  intro  ：一屏说明「接下来会发生什么」，点「确定」
 *  web    ：拉起 Apple Music 官方登录页（内嵌 Web），用户自己填 Apple ID / 密码 /
 *           验证码；右下角「我已登录」只是兜底按钮，正常情况下自动检测
 *  syncing：检测到登录（轮询 cookie）→ **在本页把资料库同步完**，进度条实时显示
 *           页数/曲目数 → 同步结束自动进入主界面
 *
 * 为什么改：以前检测到登录就立刻关页、资料库交给外壳后台拉，用户看到的是
 * 「登录成功了，但界面是空的，要等十几秒才出内容」。现在把同步摆在登录页上
 * 带进度跑完，用户看到的是「输完账号密码 → 进度条 → 资料库就位」。
 *
 * 为什么不做自动填充：Apple 的登录表单在自己的域里、DOM 由 JS 动态渲染，
 * 注入脚本填不进去（真机验证失败），因此回到「用户手动登录 + 自动收尾」。
 */
import { webview } from '@kit.ArkWeb';

import {
  AppleApi,
  AppleAuthState,
  AppleConst,
  AppleDiag,
  AppleLibrarySync,
  getWindowInfoState,
  LibrarySignal,
  Logger,
  SyncResult,
  WindowInfo
} from 'musicbasic';

const TAG: string = 'AppleLoginView';
/** 轮询 media-user-token 的间隔（毫秒）。 */
const POLL_INTERVAL_MS: number = 1500;
/** 登录页地址（中文区，未登录时会自动跳到 Apple 登录表单）。 */
const LOGIN_URL: string = `${AppleConst.HOME}/cn/login`;

/**
 * 全屏 Apple Music 登录页。由产品壳层挂在最上层，
 * 显隐由 {@link AppleAuthState.loginVisible} 驱动。
 */
@ComponentV2
export struct AppleLoginView {
  /** 全局登录态（visible / busy / statusText）。 */
  @Local authState: AppleAuthState = AppleAuthState.getInstance();
  /** 'intro' = 说明页；'web' = Apple 官方登录页。 */
  @Local stage: string = 'intro';
  /** 提示 / 错误文案。 */
  @Local message: string = '';
  /** 正在检查登录状态（按钮转圈）。 */
  @Local checking: boolean = false;
  /** 同步进度（0-100）。 */
  @Local syncPercent: number = 0;
  /** 同步阶段文案（正在读取资料库… / 正在同步歌单…）。 */
  @Local syncNote: string = '';
  /** 同步失败（显示重试）。 */
  @Local syncFailed: boolean = false;
  /** 窗口尺寸 / 安全区（@Trace，窗口测量完成后会自动刷新本页）。 */
  @Local windowInfo: WindowInfo = getWindowInfoState();
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 轮询定时器 id（-1 表示未启动）。 */
  private pollTimer: number = -1;
  /** 是否已进入收尾流程（防重入）。 */
  private finishing: boolean = false;

  aboutToAppear(): void {
    AppleDiag.log('AppleLoginView.aboutToAppear');
    this.authState.refreshFromApi();
    AppleDiag.log(`login inset: statusBar=${this.windowInfo.statusBarTopVp} ` +
      `cutout=${this.topInsetVp()} winH=${this.windowInfo.windowSize.height}`);
  }

  /**
   * 顶部要让开多少（vp）：挖孔摄像头 / 状态栏。
   *
   * 注意两点：
   *  1. 应用是全屏 + 隐藏状态栏，此时 statusBarTopVp 会变成 0，只有
   *     TYPE_CUTOUT 的 topRect 还留着摄像头的高度 → 两个取大的那个；
   *  2. 窗口测量是异步的，登录页可能比它先建出来 → 用 @Trace 的 WindowInfo
   *     让这个值测量完成后自动刷新（写死成常量会在首帧算成 0 后再也不变）。
   */
  private topInsetVp(): number {
    let top: number = this.windowInfo.statusBarTopVp;
    const area = this.windowInfo.avoidCutout;
    if (area !== undefined) {
      try {
        const cutoutVp: number = this.getUIContext().px2vp(area.topRect.height);
        if (cutoutVp > top) {
          top = cutoutVp;
        }
      } catch (err) {
        // 拿不到就只用状态栏高度
      }
    }
    return top > 0 ? top + 6 : 0;
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  // ───────────────────── 流程 ─────────────────────

  /** 用户点「确定」：打开 Apple 官方登录页并开始轮询登录状态。 */
  private openWebLogin(): void {
    this.stage = 'web';
    this.message = '';
    AppleDiag.log('login: 打开 Apple 登录页 ' + LOGIN_URL);
    this.startPolling();
  }

  private startPolling(): void {
    if (this.pollTimer !== -1) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.checkLogin(false);
    }, POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 用户点右下角「我已登录」。 */
  private async onUserConfirmed(): Promise<void> {
    if (this.checking || this.finishing) {
      return;
    }
    this.checking = true;
    await this.checkLogin(true);
    this.checking = false;
  }

  /**
   * 读一次 cookie：拿到 media-user-token 就收尾。
   *
   * @param notifyFail 是否提示「还没检测到登录」
   */
  private async checkLogin(notifyFail: boolean): Promise<void> {
    if (this.finishing) {
      return;
    }
    try {
      // 先把 Web 引擎内存里的 cookie 落盘，否则刚登录完可能读不到
      await webview.WebCookieManager.saveCookieAsync();
    } catch (err) {
      Logger.warn(TAG, `saveCookie 失败 ${JSON.stringify(err)}`);
    }
    try {
      const token: string = await AppleApi.fetchUserTokenFromCookie();
      if (token.length >= 50) {
        await this.completeLogin(token);
        return;
      }
    } catch (err) {
      Logger.warn(TAG, `读取 cookie 失败 ${JSON.stringify(err)}`);
    }
    if (notifyFail) {
      this.toast('还没有检测到登录状态，请先在页面里完成登录');
    }
  }

  /**
   * 登录成功收尾：落盘 token → 进入「同步中」阶段 → 同步完自动关页。
   *
   * 以前是「拿到 token 马上关页、资料库交给外壳后台拉」，用户会对着空界面等
   * 十几秒；现在把同步摆在登录页上带进度跑完（见 syncLibrary）。
   */
  private async completeLogin(token: string): Promise<void> {
    if (this.finishing) {
      return;
    }
    this.finishing = true;
    this.stopPolling();
    AppleDiag.log('login: 检测到 media-user-token，开始同步资料库');
    try {
      await AppleApi.persist(token);
    } catch (err) {
      Logger.error(TAG, `persist 失败 ${JSON.stringify(err)}`);
    }
    this.authState.refreshFromApi();
    this.stage = 'syncing';
    this.syncFailed = false;
    this.syncPercent = 0;
    this.syncNote = '正在连接 Apple Music…';
    await this.syncLibrary();
  }

  /**
   * 登录后的首次资料库同步（带进度，跑完自动进入主界面）。
   *
   * 顺序：开发者 token → 账号信息 → 资料库歌曲（分页并发，进度回调给真实百分比）
   * → 歌单 → 通知各板块刷新。
   */
  private async syncLibrary(): Promise<void> {
    try {
      await AppleApi.ensureDeveloperToken();
      await AppleApi.getAccountInfo();
      this.syncNote = '正在读取资料库…';
      const songs: SyncResult = await AppleLibrarySync.syncSongs((p: number, note: string) => {
        this.syncPercent = p;
        if (note.length > 0) {
          this.syncNote = note;
        }
      });
      this.syncPercent = 96;
      this.syncNote = '正在同步歌单…';
      await AppleLibrarySync.syncPlaylists();
      LibrarySignal.notifyChanged();
      this.authState.loginSynced = true;
      this.syncPercent = 100;
      this.syncNote = `同步完成 · ${songs.songs} 首`;
      Logger.info(TAG, `登录后同步完成 songs=${songs.songs}`);
      // 让「同步完成」在屏幕上停一下再关页
      setTimeout(() => {
        this.authState.closeLogin();
      }, 340);
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      Logger.warn(TAG, '登录后同步失败：' + msg);
      this.syncFailed = true;
      this.syncNote = msg.length > 0 ? ('同步失败：' + msg) : '同步失败，请检查网络';
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (err) {
      Logger.warn(TAG, `toast failed ${JSON.stringify(err)}`);
    }
  }

  // ───────────────────── UI ─────────────────────

  /** 顶部栏：关闭 / 返回说明页 + 刷新。 */
  @Builder
  private TopBar() {
    Row() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(this.stage === 'web' ? $r('sys.symbol.chevron_left') : $r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([$r('app.color.library_text_primary')])
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.stopPolling();
        if (this.stage === 'web') {
          this.stage = 'intro';
          return;
        }
        this.authState.closeLogin();
      })

      Text(this.stage === 'web' ? '登录 Apple Music' : '欢迎使用')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.library_text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.stage === 'web') {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(20)
            .fontColor([$r('app.color.library_text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          try {
            this.controller.refresh();
          } catch (err) {
            Logger.warn(TAG, `refresh failed ${JSON.stringify(err)}`);
          }
        })
      } else {
        Row()
          .width(40)
          .height(40)
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
  }

  /**
   * 同步页：登录成功后的进度。
   *
   * 只在这一刻出现（首次登录 / 重新登录），进度来自 syncSongs 的真实分页回调，
   * 所以用户看到的是「第几页、多少首」而不是一根假装在动的进度条。
   */
  @Builder
  private SyncingPage() {
    Column({ space: 18 }) {
      Blank()
      SymbolGlyph($r('sys.symbol.icloud_fill'))
        .fontSize(56)
        .fontColor([$r('app.color.library_accent')])
      Text(this.syncFailed ? '资料库同步没有完成' : '正在同步你的资料库')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.library_text_primary'))
      Text(this.syncNote)
        .fontSize(13)
        .fontColor($r('app.color.library_text_secondary'))
        .width('86%')
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (!this.syncFailed) {
        Column({ space: 8 }) {
          Progress({ value: this.syncPercent, total: 100, type: ProgressType.Linear })
            .width('72%')
            .height(6)
            .color($r('app.color.library_accent'))
          Text(`${Math.round(this.syncPercent)}%`)
            .fontSize(12)
            .fontColor($r('app.color.library_text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else {
        Row({ space: 12 }) {
          Button('重试')
            .fontSize(15)
            .fontColor(Color.White)
            .height(40)
            .padding({ left: 22, right: 22 })
            .backgroundColor($r('app.color.library_accent'))
            .onClick(() => {
              this.syncFailed = false;
              this.syncPercent = 0;
              this.syncNote = '正在连接 Apple Music…';
              this.syncLibrary();
            })
          Button('稍后再同步')
            .fontSize(15)
            .fontColor($r('app.color.library_text_primary'))
            .height(40)
            .padding({ left: 18, right: 18 })
            .backgroundColor($r('app.color.library_card_bg'))
            .onClick(() => {
              this.authState.closeLogin();
            })
        }
      }

      Text('资料库同步在后台完成，期间耗多少流量取决于资料库大小')
        .fontSize(12)
        .fontColor($r('app.color.library_text_secondary'))
        .width('80%')
        .textAlign(TextAlign.Center)
      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
  }

  /** 说明页：告诉用户接下来要做什么。 */
  @Builder
  private IntroPage() {
    Column({ space: 16 }) {
      Column({ space: 8 }) {
        Text('登录 Apple Music')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.library_text_primary'))
          .width('100%')
        Text('登录后，你的资料库、歌单和艺人头像会自动同步到这个应用里')
          .fontSize(14)
          .fontColor($r('app.color.library_text_secondary'))
          .width('100%')
      }
      .padding({ top: 12, bottom: 8 })

      Column({ space: 14 }) {
        this.StepRow('1', '点下面的「确定」，打开 Apple Music 官方登录页')
        this.StepRow('2', '在页面里填写你的 Apple ID 和密码完成登录')
        this.StepRow('3', '如果 Apple 要求验证码，填它发到你设备上的 6 位码')
        this.StepRow('4', '登录完成后什么都不用点：应用会自动开始同步资料库，同步完自动进入主界面')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 14 })
      .backgroundColor($r('app.color.library_card_bg'))
      .borderRadius(16)

      Text('账号和密码只提交给 Apple 官方页面，本应用不会读取、也不会保存你的密码')
        .fontSize(12)
        .fontColor($r('app.color.library_text_secondary'))
        .width('100%')

      Blank()

      Button({ type: ButtonType.Capsule }) {
        Text('确定')
          .fontSize(17)
          .fontColor(Color.White)
      }
      .width('100%')
      .height(50)
      .backgroundColor($r('app.color.library_accent'))
      .onClick(() => {
        this.openWebLogin();
      })

      Text('还没准备好？也可以先关掉这一页，之后在设置里随时登录')
        .fontSize(12)
        .fontColor($r('app.color.library_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 说明页里的一行步骤。 */
  @Builder
  private StepRow(no: string, text: string) {
    Row({ space: 12 }) {
      Text(no)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor($r('app.color.library_accent'))
      Text(text)
        .fontSize(14)
        .fontColor($r('app.color.library_text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 底部操作条：提示 + 「我已登录」。 */
  @Builder
  private BottomBar() {
    Row({ space: 12 }) {
      Text('在上方页面里完成登录后，点右边按钮进入主界面')
        .fontSize(12)
        .fontColor($r('app.color.library_text_secondary'))
        .layoutWeight(1)
        .maxLines(2)
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 6 }) {
          if (this.checking) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Color.White)
          }
          Text(this.checking ? '检查中…' : '我已登录')
            .fontSize(15)
            .fontColor(Color.White)
        }
      }
      .height(40)
      .padding({ left: 18, right: 18 })
      .backgroundColor($r('app.color.library_accent'))
      .enabled(!this.checking)
      .opacity(this.checking ? 0.6 : 1)
      .onClick(() => {
        this.onUserConfirmed();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 14 })
    .backgroundColor($r('app.color.library_card_bg'))
  }

  build() {
    Column() {
      this.TopBar()
      if (this.stage === 'syncing') {
        this.SyncingPage()
      } else if (this.stage === 'web') {
        Web({ src: LOGIN_URL, controller: this.controller })
          // Apple 登录表单依赖 DOM Storage + JS + Cookie。
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .fileAccess(false)
          .onlineImageAccess(true)
          .imageAccess(true)
          .horizontalScrollBarAccess(false)
          .verticalScrollBarAccess(true)
          .darkMode(WebDarkMode.Auto)
          .layoutWeight(1)
          .width('100%')
          .onPageEnd(() => {
            AppleDiag.log('Web onPageEnd url=' + this.controller.getUrl());
            // 页面每次加载完立刻查一次，减少用户等待
            this.checkLogin(false);
          })
          .onErrorReceive((event) => {
            if (event) {
              AppleDiag.log('Web onErrorReceive code=' + event.error.getErrorCode());
              this.message = '网页加载失败，请检查网络后重试';
            }
          })
        this.BottomBar()
      } else {
        this.IntroPage()
      }
    }
    .width('100%')
    .height('100%')
    // 应用是全屏布局（状态栏隐藏），顶部要避开挖孔摄像头（见 topInsetVp 注释）。
    .padding({ top: this.topInsetVp() })
    .backgroundColor($r('app.color.library_bg'))
  }
}
