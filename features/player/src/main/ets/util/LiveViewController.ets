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

import { liveViewManager } from '@kit.LiveViewKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppleArtworkCache, Logger } from 'musicbasic';
import { MediaTools } from './MediaTools';

const TAG = 'LiveViewController';
/** Fixed live-view id used for the now-playing capsule. */
const LIVE_VIEW_ID = 9001;
/** Brand accent used for underline and capsule background. */
const ACCENT_COLOR = '#FF0A59F7';

/**
 * Now-playing live view ("灵动岛"): a floating capsule plus expanded card
 * that follows playback state. Created on first play, updated on track
 * change / pause / resume, and stopped when playback stops.
 */
export class LiveViewController {
  private static instance: LiveViewController | undefined = undefined;
  private context: common.UIAbilityContext | undefined;
  /** Last built live-view payload; reused for updateLiveView. */
  private view: liveViewManager.LiveView | undefined;
  /** Cover pixel map cached from the sandbox cover path. */
  private coverPixmap: image.PixelMap | undefined;
  /** Whether startLiveView has been called successfully. */
  private started: boolean = false;

  private constructor() {
  }

  /** @returns Shared live-view controller. */
  public static getInstance(): LiveViewController {
    if (LiveViewController.instance === undefined) {
      LiveViewController.instance = new LiveViewController();
    }
    return LiveViewController.instance;
  }

  /**
   * Shows or updates the now-playing live view for the given song.
   * @param context Host UIAbility context.
   * @param title Track title.
   * @param artist Track artist.
   * @param coverPath Sandbox cover JPEG path (empty if none).
   */
  public async showSong(context: common.UIAbilityContext, title: string, artist: string, coverPath: string):
  Promise<void> {
    this.context = context;
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        return;
      }
      const view = await this.buildLiveView(title, artist, coverPath);
      if (view === undefined) {
        return;
      }
      this.view = view;
      if (this.started) {
        await liveViewManager.updateLiveView(this.view);
      } else {
        await liveViewManager.startLiveView(this.view);
        this.started = true;
      }
    } catch (err) {
      const be = err as BusinessError;
      Logger.warn(TAG, `showSong failed, code=${be.code}, message=${be.message}`);
    }
  }

  /**
   * Updates the capsule status to reflect play/pause state.
   * @param context Host UIAbility context (first call).
   * @param isPlay True when audio is playing.
   */
  public async updatePlayState(context: common.UIAbilityContext, isPlay: boolean): Promise<void> {
    if (!this.started || this.view === undefined) {
      return;
    }
    this.context = context;
    const capsule = this.view.liveViewData.capsule;
    if (capsule !== undefined && capsule.type === liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT) {
      (capsule as liveViewManager.TextCapsule).title = isPlay ? '正在播放' : '已暂停';
    }
    try {
      await liveViewManager.updateLiveView(this.view);
    } catch (err) {
      const be = err as BusinessError;
      Logger.warn(TAG, `updatePlayState failed, code=${be.code}, message=${be.message}`);
    }
  }

  /** Ends the live view (called when playback stops or app exits). */
  public async hide(): Promise<void> {
    if (!this.started || this.view === undefined) {
      return;
    }
    try {
      await liveViewManager.stopLiveView(this.view);
      this.started = false;
      this.view = undefined;
      this.releaseCover();
    } catch (err) {
      const be = err as BusinessError;
      Logger.warn(TAG, `hide failed, code=${be.code}, message=${be.message}`);
    }
  }

  /** Builds the PICK_UP (emphasis-text) live view payload with a text capsule. */
  private async buildLiveView(title: string, artist: string, coverPath: string):
  Promise<liveViewManager.LiveView | undefined> {
    const context = this.context;
    if (context === undefined) {
      return undefined;
    }
    this.releaseCover();
    this.coverPixmap = await this.loadCover(coverPath);
    const clickAction = await this.buildClickAction();
    // Capsule icon and descPic are runtime-mandatory: fall back to the bundled
    // note icon when no cover art exists (undefined values fail validation).
    const art: image.PixelMap | string = this.coverPixmap !== undefined ? this.coverPixmap : 'live_icon.png';
    return {
      id: LIVE_VIEW_ID,
      event: 'PICK_UP',
      isMute: false,
      liveViewData: {
        primary: {
          title: '正在播放',
          content: [
            { text: title }
          ],
          keepTime: 0,
          clickAction: clickAction,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PICKUP,
            title: title,
            content: artist,
            underlineColor: ACCENT_COLOR,
            descPic: art
          }
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          backgroundColor: ACCENT_COLOR,
          icon: art,
          title: '正在播放',
          content: title
        }
      }
    };
  }

  /** Builds a want agent that brings the app to the foreground. */
  private async buildClickAction(): Promise<WantAgent | undefined> {
    const context = this.context;
    if (context === undefined) {
      return undefined;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      const be = err as BusinessError;
      Logger.warn(TAG, `buildClickAction failed, code=${be.code}, message=${be.message}`);
      return undefined;
    }
  }

  /** Loads a pixel map from the sandbox cover URI, or undefined on failure. */
  private async loadCover(coverPath: string): Promise<image.PixelMap | undefined> {
    if (coverPath === '') {
      return undefined;
    }
    // 传进来的可能是 Apple 的 https 封面：实况窗同样只吃 PixelMap/本地文件。
    const local: string = await AppleArtworkCache.ensure(coverPath);
    if (local === '') {
      return undefined;
    }
    // The scanner caches covers as file:// URIs; createImageSource officially
    // accepts the URI (uri overload, API 11+). The old fileIo.accessSync
    // pre-check always failed on the URI and silently dropped every cover.
    Logger.info(TAG, 'loadCover coverPath = ' + coverPath);
    // fd decode: sandbox URIs (file://<bundle>/...) cannot go through
    // createImageSource's uri overload; 256px is plenty for the capsule.
    return await MediaTools.decodeCoverPixelMap(local, 256);
  }

  /** Releases the cached cover pixel map. */
  private releaseCover(): void {
    if (this.coverPixmap !== undefined) {
      try {
        this.coverPixmap.release();
      } catch (err) {
        Logger.warn(TAG, `releaseCover failed: ${JSON.stringify(err)}`);
      }
      this.coverPixmap = undefined;
    }
  }
}
