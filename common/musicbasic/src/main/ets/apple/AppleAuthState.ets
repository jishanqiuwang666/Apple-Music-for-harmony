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

import { AppStorageV2 } from '@kit.ArkUI';
import { AppStorageKeys } from '../constants/Constants';
import { AppleApi } from './AppleApi';
import { AppleDiag } from './AppleDiag';

/**
 * Apple Music 登录态（AppStorageV2 全局单例）。
 *
 * 登录页（ArkWeb 内嵌 music.apple.com）与三个板块通过这个状态通信：
 *  - {@link authorized}：是否已拿到可用的 media-user-token
 *  - {@link loginVisible}：全屏登录页是否显示（任一板块点「登录」时置 true）
 *  - {@link busy} / {@link statusText}：登录 + 首次资料库同步的进度文案
 */
@ObservedV2
export class AppleAuthState {
  /** 是否已具备调用 Apple Music API 的登录态。 */
  @Trace public authorized: boolean = false;
  /** 全屏登录页是否可见（由板块设置，产品壳层的 bindContentCover 监听）。 */
  @Trace public loginVisible: boolean = false;
  /** 登录 / 首次同步进行中（按钮转圈、拦截重复点击）。 */
  @Trace public busy: boolean = false;
  /** 进度文案（如「正在登录 Apple Music…」）。 */
  @Trace public statusText: string = '';
  /**
   * 登录页是否已经把「首次资料库同步」跑完。
   *
   * 登录流程现在是「登录页带着进度同步完再关页」，所以外壳不能再重复跑一遍
   * （见 Index.syncAfterLogin 的守卫）。
   */
  @Trace public loginSynced: boolean = false;
  /** 已登录账号的 storefront（'cn' / 'us' …），未登录为空串。 */
  @Trace public storefront: string = '';
  /** 已登录的 Apple ID（展示用，未登录为空串）。 */
  @Trace public accountId: string = '';
  /** 诊断用：本实例是第几个被创建出来的（正常应只有一个）。 */
  private static created: number = 0;
  private instanceNo: number = 0;

  constructor() {
    AppleAuthState.created++;
    this.instanceNo = AppleAuthState.created;
    AppleDiag.log('AppleAuthState 实例创建 #' + this.instanceNo);
  }

  /** @returns 全局共享的登录态单例。 */
  public static getInstance(): AppleAuthState {
    return AppStorageV2.connect(AppleAuthState, AppStorageKeys.APPLE_AUTH_STATE,
      () => new AppleAuthState())!;
  }

  /** 从 AppleApi 的持久化状态同步一次登录标记。 */
  public refreshFromApi(): void {
    this.authorized = AppleApi.isAuthorized();
    this.storefront = this.authorized ? AppleApi.getStorefront() : '';
    this.accountId = this.authorized ? AppleApi.getAccountId() : '';
  }

  /** 打开全屏登录页。 */
  public openLogin(): void {
    this.loginSynced = false;
    AppleDiag.log('AppleAuthState.openLogin() 调用，本实例序号=' + this.instanceNo);
    this.loginVisible = true;
  }

  /** 关闭全屏登录页并清空进度文案。 */
  public closeLogin(): void {
    this.loginVisible = false;
    this.busy = false;
    this.statusText = '';
  }
}
