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

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PREF_NAME = 'widget_state';
const KEY_TITLE = 'title';
const KEY_ARTIST = 'artist';
const KEY_COVER = 'cover';
const KEY_IS_PLAYING = 'isPlaying';

/** Snapshot of the playback state shown on the home-screen widget. */
export class WidgetStateSnapshot {
  public title: string = '';
  public artist: string = '';
  /** Cover art path/URI; empty falls back to a placeholder in the card. */
  public coverPath: string = '';
  public isPlaying: boolean = false;
}

/**
 * Persists the minimal widget state in Preferences. Both the UIAbility
 * process and the FormExtensionAbility process read/write the same file,
 * so a card can show the latest track without holding the app process.
 * Sync APIs are used because FormExtensionAbility callbacks are sync.
 */
export class WidgetStateStore {
  private static options(): preferences.Options {
    return { name: PREF_NAME };
  }

  public static save(context: common.Context, snapshot: WidgetStateSnapshot): void {
    const pref = preferences.getPreferencesSync(context, WidgetStateStore.options());
    pref.putSync(KEY_TITLE, snapshot.title);
    pref.putSync(KEY_ARTIST, snapshot.artist);
    pref.putSync(KEY_COVER, snapshot.coverPath);
    pref.putSync(KEY_IS_PLAYING, snapshot.isPlaying);
    pref.flushSync();
  }

  public static load(context: common.Context): WidgetStateSnapshot {
    const pref = preferences.getPreferencesSync(context, WidgetStateStore.options());
    const snapshot = new WidgetStateSnapshot();
    snapshot.title = pref.getSync(KEY_TITLE, '') as string;
    snapshot.artist = pref.getSync(KEY_ARTIST, '') as string;
    snapshot.coverPath = pref.getSync(KEY_COVER, '') as string;
    snapshot.isPlaying = pref.getSync(KEY_IS_PLAYING, false) as boolean;
    return snapshot;
  }
}
