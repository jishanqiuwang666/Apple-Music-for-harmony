/**
 * Apple Music 数据模型（对应 amp-api / webPlayback 的返回结构）
 *
 * 设计原则：只保留这个音乐 App 需要的字段，避免把整个 API 结构搬进来。
 */

/** 一首歌（目录或资料库） */
export class AppleSong {
  /** Apple Music 歌曲 ID（catalog id / library id） */
  id: string = '';
  /** 歌曲名 */
  name: string = '';
  /** 艺人名 */
  artistName: string = '';
  /** 专辑名 */
  albumName: string = '';
  /** 专辑 ID */
  albumId: string = '';
  /** 艺人 ID */
  artistId: string = '';
  /** 时长（毫秒） */
  durationMs: number = 0;
  /** 曲序 */
  trackNumber: number = 0;
  /** 碟号 */
  discNumber: number = 0;
  /** 发行年份（0 表示未知） */
  year: number = 0;
  /** 封面 URL（已按需要的尺寸替换） */
  artworkUrl: string = '';
  /** 是否来自资料库（true 表示 library song，播放要用 library id） */
  isLibrary: boolean = false;
  /** 音频特性（如 lossless / dolby-atmos / hi-res-lossless） */
  public audioTraits: string[] = [];
  /**
   * Apple 曲风（attributes.genreNames 用 `|` 连接，如 `J-Pop` / `Classical`）。
   * 艺人页的音乐板块分类用它（资料库接口自带，不需要额外请求）。
   */
  public genre: string = '';
  /**
   * 目录歌曲 id（playParams.catalogId）。资料库歌曲的 id 是 i.xxx，但拿它
   * 就能批量向目录请求「这首歌的主艺人」，从而给资料库艺人配官方头像。
   */
  public catalogId: string = '';
}

/** 专辑 */
export class AppleAlbum {
  id: string = '';
  name: string = '';
  artistName: string = '';
  artistId: string = '';
  artworkUrl: string = '';
  trackCount: number = 0;
  year: number = 0;
  isLibrary: boolean = false;
  /** Apple 标记：是否为单曲（用来分「专辑 / 单曲」两个板块）。 */
  isSingle: boolean = false;
  /**
   * Apple Music 里的「收藏」状态（⭐）。
   * 只有请求带 `extend=inFavorites` 时 Apple 才会返回该属性，否则恒为 false。
   */
  inFavorites: boolean = false;
}

/** 艺人（通常由歌曲聚合而来） */
export class AppleArtist {
  id: string = '';
  name: string = '';
  artworkUrl: string = '';
  albumCount: number = 0;
  songCount: number = 0;
}

/** 歌单 */
export class ApplePlaylist {
  id: string = '';
  name: string = '';
  description: string = '';
  artworkUrl: string = '';
  trackCount: number = 0;
  isLibrary: boolean = true;
}

/** webPlayback 返回的某个资产（audio asset） */
export class AppleAsset {
  /** 资产 flavor，如 "28:ctrp256" */
  flavor: string = '';
  /** 子清单 m3u8 URL */
  url: string = '';
}

/** webPlayback 结果 */
export class WebPlaybackInfo {
  songId: string = '';
  assets: AppleAsset[] = [];
}

/** get_assets（/v1/play/assets）结果 */
export class PlayAssetInfo {
  hlsUrl: string = '';
  keyServerUrl: string = '';
  widevineCertUrl: string = '';
  fairPlayCertUrl: string = '';
}

/** 搜索结果 */
export class AppleSearchResult {
  songs: AppleSong[] = [];
  albums: AppleAlbum[] = [];
  artists: AppleArtist[] = [];
  playlists: ApplePlaylist[] = [];
}

/** 专辑收藏状态（读 Apple Music 用）：目录 id + 是否已收藏（⭐）。 */
export class AlbumFavState {
  /** 目录专辑 id（收藏写入必须用它）。 */
  catalogId: string = '';
  /** Apple Music 里的收藏状态。 */
  inFavorites: boolean = false;
}

/** 歌曲收藏状态：资料库歌曲 id + 目录歌曲 id + 是否已收藏（⭐）。 */
export class SongFavState {
  /** 目录歌曲 id（收藏写入必须用它，不能用 i.xxxx）。 */
  catalogId: string = '';
  /** Apple Music 里的收藏状态。 */
  inFavorites: boolean = false;
}

/** 艺人收藏状态：资料库艺人 id + 目录艺人 id + 是否已收藏（⭐）。 */
export class ArtistFavState {
  /** 资料库艺人 id（r.xxxx；没找到时为空）。 */
  libraryId: string = '';
  /** 目录艺人 id（收藏写入必须用它）。 */
  catalogId: string = '';
  /** Apple Music 里的收藏状态。 */
  inFavorites: boolean = false;
  /** 是否在资料库里找到了这位艺人。 */
  found: boolean = false;
}

/** Apple Music 常量 */
export class AppleConst {
  static readonly HOME: string = 'https://music.apple.com';
  static readonly AMP: string = 'https://amp-api.music.apple.com';
  /** MusicKit 官方主机（资料库写入等接口）。 */
  static readonly API: string = 'https://api.music.apple.com';
  static readonly WEBPLAYBACK: string = 'https://play.itunes.apple.com/WebObjects/MZPlay.woa/wa/webPlayback';
  static readonly LICENSE: string = 'https://play.itunes.apple.com/WebObjects/MZPlay.woa/wa/acquireWebPlaybackLicense';
  /** Widevine system id */
  static readonly WIDEVINE_UUID: string = 'edef8ba9-79d6-4ace-a3c8-27dcd51d21ed';
  /** 默认音质：256kbps AAC（aac-web） */
  static readonly DEFAULT_FLAVOR: string = '28:ctrp256';
}
