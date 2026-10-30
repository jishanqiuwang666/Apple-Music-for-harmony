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

/**
 * Global library-change signal: bump {@link version} after any import so
 * library pages (artists / albums / songs) can refresh even when the host
 * page stays alive (e.g. after a share-import while the app is warm).
 */
@ObservedV2
export class LibrarySignal {
  /** Incremented on every library mutation. */
  @Trace public version: number = 0;

  /** @returns The shared signal instance. */
  public static getInstance(): LibrarySignal {
    return AppStorageV2.connect(LibrarySignal, AppStorageKeys.LIBRARY_SIGNAL, () => new LibrarySignal())!;
  }

  /** Notifies all library pages to refresh. */
  public static notifyChanged(): void {
    LibrarySignal.getInstance().version++;
  }
}
