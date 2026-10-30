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

/*
 * Barrel file for musicbasic (common HAR). All public exports are listed here.
 */

import { AppRuntimeStorage, getAppRuntime as getAppRuntimeFromModel } from './src/main/ets/model/AppRuntimeStorage';

// Constants (single Constants.ets file; class names unchanged)
export {
  AppStorageKeys,
  BreakpointConstants,
  GridConstants,
  PlaybackIntentLogEvent,
  PlaybackShellConstants,
  RouterUrlConstants,
  SdkConstants,
  SongConstants,
  StyleConstants,
  WatchNavRouteConstants
} from './src/main/ets/constants/Constants';

export { TabItem } from './src/main/ets/model/TabItem';

// Data and in-memory DB mocks
export { SongRow } from './src/main/ets/data/SongRow';
export { PlaylistRow } from './src/main/ets/data/PlaylistRow';
export { RecommendFeedKind, RecommendFeedRow } from './src/main/ets/data/RecommendFeedRow';
export { MusicMemoryStore } from './src/main/ets/db/MusicMemoryStore';
export { MusicDbApi } from './src/main/ets/util/MusicDbApi';

// Library RDB（Apple Music 音源，本地导入已移除）
export { MusicDatabase } from './src/main/ets/db/MusicDatabase';
export { MusicSongRow } from './src/main/ets/data/MusicSongRow';
export { ApplePlaylistRow } from './src/main/ets/data/ApplePlaylistRow';
export { ArtistRow } from './src/main/ets/data/ArtistRow';
export { AlbumRow } from './src/main/ets/data/AlbumRow';
export { ArtistApiDto, AlbumApiDto } from './src/main/ets/api/MusicApiDtos';
export { LibrarySignal } from './src/main/ets/model/LibrarySignal';
export { AppearanceController, AppearanceMode } from './src/main/ets/util/AppearanceController';
export { PlaybackProgressStore, PlaybackProgressSnapshot } from './src/main/ets/util/PlaybackProgressStore';
export { DeviceDiscovery } from './src/main/ets/transfer/DeviceDiscovery';
export {
  MusicTransferService,
  WATCH_LOCAL_FOLDER,
  LibraryMetaListener,
  TransferProgressListener,
  TransferDoneListener
} from './src/main/ets/transfer/MusicTransferService';
export {
  TransferRequest,
  TransferReady,
  TransferDone,
  MetaSong,
  LibraryMeta
} from './src/main/ets/transfer/TransferModels';

// API DTOs for MusicDbApi (separate from row types in data/*)
export {
  SongApiDto,
  HeroCardApiDto,
  RecommendCardApiDto,
  TabApiDto
} from './src/main/ets/api/MusicApiDtos';
export { SongDtoMapper } from './src/main/ets/api/SongDtoMapper';

// Model: bind getAppRuntime via export const so runtimes that skip re-exported functions still resolve.
export { AppRuntimeStorage };
export const getAppRuntime = getAppRuntimeFromModel;
export { MenuData } from './src/main/ets/model/MenuData';
export { SongItem } from './src/main/ets/model/SongData';
export { OptionItem } from './src/main/ets/model/OptionItem';
export { MusicAppState } from './src/main/ets/model/MusicAppState';
export { PlaybackIntentState } from './src/main/ets/model/PlaybackIntentState';
export { SongDataSource } from './src/main/ets/model/SongDataSource';
export { PlayQueueContext, PlaySourceKind, PlayContextKeys } from './src/main/ets/model/PlayQueueContext';
export { PlayQueueUtil } from './src/main/ets/model/PlayQueueUtil';
export { PlaybackResumeRow } from './src/main/ets/data/PlaybackResumeRow';

// util
export { BreakpointType, isWidthBreakpointLgOrXl } from './src/main/ets/util/BreakpointSystem';
export { Logger } from './src/main/ets/util/Logger';
export { GenreBuckets } from './src/main/ets/util/GenreBuckets';
export { StringResourceUtil } from './src/main/ets/util/StringResourceUtil';
export { ImmersiveType } from './src/main/ets/util/ImmersiveType';
export {
  WindowUtil,
  WindowInfo,
  WINDOW_INFO_STORAGE_KEY,
  getWindowInfoState
} from './src/main/ets/util/WindowUtil';
export { getStatusBarTopVpFromWindowUtil } from './src/main/ets/util/StatusBarInsetUtil';
export { BackHandler } from './src/main/ets/util/BackHandler';
export { ColorConversion } from './src/main/ets/util/ColorConversion';
export { SdkApiUtil } from './src/main/ets/util/SdkApiUtil';
export { WidgetStateStore, WidgetStateSnapshot } from './src/main/ets/util/WidgetStateStore';
export { WidgetUpdater } from './src/main/ets/util/WidgetUpdater';

export { MusicEmptyComponent } from './src/main/ets/components/MusicEmptyComponent';
export { MusicTextIcon } from './src/main/ets/components/MusicTextIcon';

// ─────────────── Apple Music 音源支撑 ───────────────
export { AppleApi, PageResult } from './src/main/ets/apple/AppleApi';
export {
  AppleSong,
  AppleAlbum,
  AppleArtist,
  ApplePlaylist,
  AppleAsset,
  WebPlaybackInfo,
  PlayAssetInfo,
  AppleSearchResult,
  AlbumFavState,
  ArtistFavState,
  SongFavState,
  AppleConst
} from './src/main/ets/apple/AppleModels';
export { AppleDownloader, DlStage, DownloadResult } from './src/main/ets/apple/AppleDownloader';
export { AppleAuthState } from './src/main/ets/apple/AppleAuthState';
export { AppleDiag } from './src/main/ets/apple/AppleDiag';
export { AppleUi } from './src/main/ets/apple/AppleUi';
export { AppleCache, CacheEntry, CacheStats } from './src/main/ets/apple/AppleCache';
export { AppleArtworkCache } from './src/main/ets/apple/AppleArtworkCache';
export { ArtistAliasTable } from './src/main/ets/apple/ArtistAliasTable';
export { CatalogFillService, ShellArtist, CatalogAlbumOffer } from './src/main/ets/apple/CatalogFillService';
export { HlsParser, HlsMediaInfo, HlsMasterInfo, HlsByteRange } from './src/main/ets/apple/HlsParser';
export { AppleLibrarySync, SyncResult, SyncProgress } from './src/main/ets/apple/AppleLibrarySync';
export { AppleLyrics, AppleLyric, LyricLine, LyricWord, TtmlParser } from './src/main/ets/apple/AppleLyrics';
export { AiLyricsTranslator } from './src/main/ets/apple/AiLyricsTranslator';
export { AiTransConfig } from './src/main/ets/apple/AiTransConfig';
export { WvdParser, WvdDevice } from './src/main/ets/apple/widevine/WvdParser';
export { WidevineCdm, ContentKey, ChallengeContext } from './src/main/ets/apple/widevine/WidevineCdm';
