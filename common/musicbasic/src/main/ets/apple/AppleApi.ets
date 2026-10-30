/**
 * Apple Music API 客户端
 *
 * 认证（不需要 Apple Developer 账号）：
 *   - developerToken：从 music.apple.com 首页 index.js 里正则抓 JWT
 *   - userToken   ：用户在应用内 Web 登录后，从 cookie 取 media-user-token
 *
 * 所有请求都带 Authorization: Bearer <devToken> + Cookie: media-user-token=<userToken>
 */
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../util/Logger';
import {
  AppleConst, AppleSong, AppleAlbum, AppleArtist, ApplePlaylist,
  AppleAsset, WebPlaybackInfo, PlayAssetInfo, AppleSearchResult, AlbumFavState, ArtistFavState, SongFavState
} from './AppleModels';

import { ArtistAliasTable } from './ArtistAliasTable';

const TAG: string = 'AppleApi';
const PREF_NAME: string = 'apple_music_auth';
const KEY_DEV: string = 'developer_token';
const KEY_USER: string = 'media_user_token';
const KEY_STORE: string = 'storefront';
/** 已登录的 Apple ID（仅用于界面展示，不含任何凭据）。 */
const KEY_ACCOUNT: string = 'apple_id';

/** 分页返回 */
export class PageResult<T> {
  items: T[] = [];
  total: number = 0;
  next: string = '';
}

export class AppleApi {
  private static devToken: string = '';
  private static userToken: string = '';
  private static storefront: string = 'cn';
  /** 当前登录的 Apple ID（展示用）。 */
  private static accountId: string = '';
  private static prefs: preferences.Preferences | null = null;

  // ─────────────────────────── 认证 ───────────────────────────

  /** 是否已具备调用条件 */
  static isAuthorized(): boolean {
    return AppleApi.userToken.length > 50;
  }

  static getStorefront(): string {
    return AppleApi.storefront;
  }

  /** 已登录的 Apple ID（未登录时为空串）。 */
  static getAccountId(): string {
    return AppleApi.accountId;
  }

  /** 记住登录用的 Apple ID（仅展示，不保存密码）。 */
  static async persistAccountId(accountId: string): Promise<void> {
    AppleApi.accountId = accountId;
    if (AppleApi.prefs !== null) {
      await AppleApi.prefs.put(KEY_ACCOUNT, accountId);
      await AppleApi.prefs.flush();
    }
  }

  static hasDeveloperToken(): boolean {
    return AppleApi.devToken.length > 50;
  }

  /**
   * 直接注入 user token（供端到端自检使用；正常流程请用 Web 登录 + persist）
   */
  static injectToken(userToken: string): void {
    AppleApi.userToken = userToken;
  }

  /** 从本地偏好恢复登录态 */
  static async restore(context: common.Context): Promise<boolean> {
    try {
      AppleApi.prefs = await preferences.getPreferences(context, PREF_NAME);
      AppleApi.devToken = (await AppleApi.prefs.get(KEY_DEV, '')) as string;
      AppleApi.userToken = (await AppleApi.prefs.get(KEY_USER, '')) as string;
      AppleApi.storefront = (await AppleApi.prefs.get(KEY_STORE, 'cn')) as string;
      AppleApi.accountId = (await AppleApi.prefs.get(KEY_ACCOUNT, '')) as string;
      Logger.info(TAG, `restore: dev=${AppleApi.devToken.length} user=${AppleApi.userToken.length} sf=${AppleApi.storefront}`);
      return AppleApi.isAuthorized();
    } catch (e) {
      Logger.error(TAG, 'restore failed ' + JSON.stringify(e));
      return false;
    }
  }

  /** 持久化 token */
  static async persist(userToken: string): Promise<void> {
    AppleApi.userToken = userToken;
    if (AppleApi.prefs !== null) {
      await AppleApi.prefs.put(KEY_DEV, AppleApi.devToken);
      await AppleApi.prefs.put(KEY_USER, AppleApi.userToken);
      await AppleApi.prefs.put(KEY_STORE, AppleApi.storefront);
      await AppleApi.prefs.flush();
    }
  }

  /**
   * 退出登录：清空本机保存的账号凭据（user token / Apple ID / 商店地区）
   * 并清掉 Web 引擎里的登录 Cookie，回到「首次打开」的干净状态。
   *
   * 注意：developer token 是 Apple 公开首页里的公共凭据（与账号无关），保留，
   * 避免下次登录时再下载 3MB+ 的 index.js。
   */
  static async logout(): Promise<void> {
    AppleApi.userToken = '';
    AppleApi.accountId = '';
    AppleApi.storefront = 'cn';
    if (AppleApi.prefs !== null) {
      await AppleApi.prefs.put(KEY_USER, '');
      await AppleApi.prefs.put(KEY_ACCOUNT, '');
      await AppleApi.prefs.put(KEY_STORE, 'cn');
      await AppleApi.prefs.flush();
    }
    await AppleApi.clearLoginCookies();
  }

  /**
   * 清掉 Web 引擎里 Apple 域下的登录 Cookie。
   *
   * 换账号登录时必须清：否则 ArkWeb 里还留着上一个账号的会话，
   * 新账号的 media-user-token 不会下发（Apple 直接复用旧会话）。
   */
  static async clearLoginCookies(): Promise<void> {
    try {
      await webview.WebCookieManager.clearAllCookies();
      Logger.info(TAG, 'login cookies cleared');
    } catch (err) {
      Logger.warn(TAG, 'clear cookies failed ' + JSON.stringify(err));
    }
  }

  /**
   * 本地解析已缓存 developer token 的 `exp`（JWT 第二段 base64url）。
   *
   * 为什么要：抓 token 要下载 music.apple.com 的 index.js —— **3MB+**，
   * 每次冷启动都抓一次等于白烧流量与电量。token 有效期通常半年，
   * 本地看一眼 exp 就够判断要不要重抓了。
   *
   * @returns 过期时间戳（毫秒）；解析不出来返回 0
   */
  private static devTokenExpMs(): number {
    try {
      const parts: string[] = AppleApi.devToken.split('.');
      if (parts.length < 2) {
        return 0;
      }
      let b64: string = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4 !== 0) {
        b64 += '=';
      }
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(b64);
      let json: string = '';
      for (let i = 0; i < bytes.length; i++) {
        json += String.fromCharCode(bytes[i]);
      }
      const m: RegExpMatchArray | null = json.match(/"exp"\s*:\s*(\d+)/);
      if (m === null) {
        return 0;
      }
      return Number(m[1]) * 1000;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 仅在「没有 token」或「24 小时内即将过期」时重新抓取。
   *
   * @returns 当前可用的 developer token
   */
  static async ensureDeveloperToken(): Promise<string> {
    const exp: number = AppleApi.devTokenExpMs();
    const now: number = new Date().getTime();
    if (AppleApi.hasDeveloperToken() && exp > now + 24 * 60 * 60 * 1000) {
      Logger.info(TAG, `developer token 仍在有效期（${Math.round((exp - now) / 3600000)} 小时后过期），跳过抓取`);
      return AppleApi.devToken;
    }
    return AppleApi.refreshDeveloperToken();
  }

  /** 抓 developer token（首页 → index.js → JWT） */
  static async refreshDeveloperToken(): Promise<string> {
    const home: string = await AppleApi.rawGet(AppleConst.HOME + '/us/browse', false);
    const mIdx: RegExpMatchArray | null = home.match(/\/assets\/index[~-][^/"]+\.js/);
    if (mIdx === null) {
      throw new Error('首页未找到 index.js（Apple 可能改了结构）');
    }
    const js: string = await AppleApi.rawGet(AppleConst.HOME + mIdx[0], false);
    const mTok: RegExpMatchArray | null =
      js.match(/"(eyJ[A-Za-z0-9\-_]+\.eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+)"/);
    if (mTok === null) {
      throw new Error('index.js 中未找到 developer token');
    }
    AppleApi.devToken = mTok[1];
    if (AppleApi.prefs !== null) {
      await AppleApi.prefs.put(KEY_DEV, AppleApi.devToken);
      await AppleApi.prefs.flush();
    }
    Logger.info(TAG, 'developer token refreshed, len=' + AppleApi.devToken.length);
    return AppleApi.devToken;
  }

  /**
   * 从 Web 组件当前 cookie 中取 media-user-token。
   *
   * ArkWeb 的 cookie 域可能是 `.music.apple.com` 也可能是 `.apple.com`
   * （取决于 Apple 当时下发的 Set-Cookie Domain），两种域对
   * `music.apple.com` 的请求都命中，所以这里把几个查询 URL 都试一遍。
   */
  static async fetchUserTokenFromCookie(): Promise<string> {
    const urls: string[] = [
      AppleConst.HOME + '/us/browse',
      AppleConst.HOME + '/cn/browse',
      AppleConst.AMP + '/'
    ];
    for (let i = 0; i < urls.length; i++) {
      try {
        const cookie: string = await webview.WebCookieManager.fetchCookie(urls[i]);
        const m: RegExpMatchArray | null = cookie.match(/media-user-token=([^;]+)/);
        if (m !== null && m.length >= 2 && m[1].length >= 50) {
          Logger.info(TAG, `cookie 命中 ${urls[i]}，token 长度=${m[1].length}`);
          return m[1];
        }
      } catch (e) {
        Logger.warn(TAG, `fetchCookie ${urls[i]} 失败 ${JSON.stringify(e)}`);
      }
    }
    return '';
  }

  /** 确保 token 就绪（必要时刷新 developer token） */
  static async ensureReady(): Promise<void> {
    if (!AppleApi.hasDeveloperToken()) {
      await AppleApi.refreshDeveloperToken();
    }
  }

  // ─────────────────────────── HTTP ───────────────────────────

  private static headers(withAuth: boolean): Record<string, string> {
    const h: Record<string, string> = {
      'Origin': AppleConst.HOME,
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    };
    if (withAuth) {
      h['Authorization'] = 'Bearer ' + AppleApi.devToken;
      h['Cookie'] = 'media-user-token=' + AppleApi.userToken;
    }
    return h;
  }

  /** 不带鉴权的裸 GET（抓 token 用） */
  private static async rawGet(url: string, withAuth: boolean): Promise<string> {
    const req = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 25000,
        expectDataType: http.HttpDataType.STRING,
        header: AppleApi.headers(withAuth)
      };
      const resp: http.HttpResponse = await req.request(url, options);
      if (resp.responseCode !== 200) {
        throw new Error('HTTP ' + resp.responseCode + ' @ ' + url);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  private static async requestJson(url: string, method: http.RequestMethod, body: string): Promise<string> {
    await AppleApi.ensureReady();
    const req = http.createHttp();
    try {
      const h: Record<string, string> = AppleApi.headers(true);
      h['Content-Type'] = 'application/json';
      const options: http.HttpRequestOptions = {
        method: method,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        header: h,
        extraData: body
      };
      const resp: http.HttpResponse = await req.request(url, options);
      if (resp.responseCode !== 200) {
        throw new Error('HTTP ' + resp.responseCode + ' @ ' + url + ' body=' + (resp.result as string).substring(0, 200));
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  /** GET 一个 amp-api 接口 */
  private static async ampGet(path: string): Promise<string> {
    return AppleApi.requestJson(AppleConst.AMP + path, http.RequestMethod.GET, '');
  }

  /**
   * GET 一个 amp-api 接口；非 200（典型是 404「该曲目没有歌词」）返回空串而不是抛错。
   *
   * 歌词是**可选**资源，404 是正常结果，不能让它冒泡成一次播放/界面异常。
   */
  static async ampGetOptional(path: string): Promise<string> {
    try {
      return await AppleApi.requestJson(AppleConst.AMP + path, http.RequestMethod.GET, '');
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.info(TAG, `ampGetOptional miss: ${e?.message ?? ''} @ ${path}`);
      return '';
    }
  }

  // ─────────────────────────── 账号 ───────────────────────────

  /** 账号信息（校验订阅） */
  static async getAccountInfo(): Promise<string> {
    const txt: string = await AppleApi.ampGet('/v1/me/account?meta=subscription');
    const obj: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const meta: Record<string, Object> = obj['meta'] as Record<string, Object>;
    if (meta !== undefined) {
      const sub: Record<string, Object> = meta['subscription'] as Record<string, Object>;
      if (sub !== undefined) {
        const sf: string | undefined = sub['storefront'] as string;
        if (sf !== undefined && sf.length > 0) {
          AppleApi.storefront = sf;
          if (AppleApi.prefs !== null) {
            await AppleApi.prefs.put(KEY_STORE, sf);
            await AppleApi.prefs.flush();
          }
        }
      }
    }
    return txt;
  }

  // ─────────────────────────── 资料库 ───────────────────────────

  /** 资料库歌曲（分页） */
  static async getLibrarySongs(limit: number, offset: number): Promise<PageResult<AppleSong>> {
    // 性能：以前带 `extend=artistUrl&include=albums,artists`，会给每首歌附带完整的
    // 专辑/艺人关系对象（pickSongs 根本不读它们）⇒ 响应体成倍膨胀。
    // 全量同步 2888 首是带宽瓶颈（实测并发翻倍也快不了多少），砍掉没用的字段最有效。
    const path: string = `/v1/me/library/songs?limit=${limit}&offset=${offset}&l=en-US`;
    const txt: string = await AppleApi.ampGet(path);
    // NOTE: do NOT filter by attributes.playParams here.
    // Library song payloads often omit playParams for perfectly playable tracks;
    // filtering dropped real songs (album track counts shrank, artists vanished).
    return AppleApi.parseSongs(txt, true);
  }

  /** 资料库专辑 */
  static async getLibraryAlbums(limit: number, offset: number): Promise<PageResult<AppleAlbum>> {
    const path: string = `/v1/me/library/albums?limit=${limit}&offset=${offset}&l=en-US`;
    const txt: string = await AppleApi.ampGet(path);
    return AppleApi.parseAlbums(txt, true);
  }

  /**
   * 专辑曲目：优先资料库专辑，未入库专辑回退 Apple 目录。
   * 未入库专辑用它的曲目组「临时队列」（不写 songs 表，不污染「全部歌曲」）。
   */
  static async getAlbumTracks(libraryId: string, catalogId: string, limit: number): Promise<AppleSong[]> {
    const paths: string[] = [];
    if (libraryId !== '') {
      paths.push(`/v1/me/library/albums/${libraryId}/tracks?limit=${limit}&offset=0&l=en-US`);
    }
    if (catalogId !== '') {
      paths.push(`/v1/catalog/${AppleApi.storefront}/albums/${catalogId}/tracks?limit=${limit}&offset=0&l=en-US`);
    }
    for (let i = 0; i < paths.length; i++) {
      try {
        const txt: string = await AppleApi.ampGet(paths[i]);
        // 只保留在当前店面「可播放」的曲目：
        //   Apple 的曲目条目里，可播放的带 attributes.playParams；不可用/仅预听的没有。
        //   官方 App 也是把这些不可用曲目直接隐藏（例：某专辑 8 个曲目位，cn 店面只显示 4 首）。
        let usable: string = txt;
        try {
          const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
          const data: Object[] | undefined = root['data'] as Object[];
          if (data !== undefined) {
            const kept: Object[] = [];
            for (let k = 0; k < data.length; k++) {
              const it: Record<string, Object> = data[k] as Record<string, Object>;
              const attrs: Record<string, Object> | undefined = it['attributes'] as Record<string, Object>;
              if (attrs !== undefined && attrs['playParams'] !== undefined) {
                kept.push(it);
              }
            }
            root['data'] = kept;
            usable = JSON.stringify(root);
            // 诊断：看清 Apple 到底给了多少条、其中多少条可播、名字分别是什么
            let brief: string = '';
            for (let m = 0; m < data.length && m < 10; m++) {
              const it2: Record<string, Object> = data[m] as Record<string, Object>;
              const a2: Record<string, Object> | undefined = it2['attributes'] as Record<string, Object>;
              const nm: string = a2 === undefined ? '?' : String(a2['name'] ?? '?');
              const hasPp: string = (a2 !== undefined && a2['playParams'] !== undefined) ? 'P' : '-';
              brief += `[${hasPp}]${nm}; `;
            }
            Logger.info('AppleApi', `ALBTRK path=${paths[i]} raw=${data.length} kept=${kept.length} :: ${brief}`);
          }
        } catch (e) {
        }
        const page: PageResult<AppleSong> = AppleApi.parseSongs(usable, libraryId !== '' && i === 0);
        if (page.items.length > 0) {
          return page.items;
        }
      } catch (e) {
        continue;
      }
    }
    return [];
  }

  /**
   * 把专辑加入资料库（**写操作，仅用户点击「加号」时调用**）。
   * 返回 true = 接口 200；失败不抛异常。
   */
  static async addAlbumToLibrary(catalogId: string): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    try {
      const url: string = AppleConst.AMP + `/v1/me/library?ids[albums]=${catalogId}&l=en-US`;
      await AppleApi.requestJson(url, http.RequestMethod.POST, '');
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 资料库专辑（带收藏标记）：请求带 `extend=inFavorites`，
   * Apple 才会在 attributes 里返回 inFavorites。
   *
   * 不带 `l` 参数：让 Apple 按商店语言返回本地化名称（如「方大同」），
   * 与资料库曲目里的 artistName 口径一致，页面才能把收藏专辑对回本地专辑。
   */
  static async getLibraryAlbumsFav(limit: number, offset: number): Promise<PageResult<AppleAlbum>> {
    const path: string = `/v1/me/library/albums?limit=${limit}&offset=${offset}&extend=inFavorites`;
    const txt: string = await AppleApi.ampGet(path);
    return AppleApi.parseAlbums(txt, true);
  }

  /**
   * Apple Music 里「收藏（⭐）的专辑」。
   *
   * 收藏状态只能通过资料库资源上的 inFavorites 属性读到（ratings 接口在本账号不可用），
   * 所以这里按 100 张/页扫描资料库专辑并过滤。Apple 没有「一次列出全部收藏」的接口。
   *
   * @param maxPages 最多扫描多少页（100 张/页），防止异常账号拉爆流量
   */
  static async getFavoriteAlbums(maxPages: number): Promise<AppleAlbum[]> {
    const out: AppleAlbum[] = [];
    let offset: number = 0;
    for (let p = 0; p < maxPages; p++) {
      const page: PageResult<AppleAlbum> = await AppleApi.getLibraryAlbumsFav(100, offset);
      let hit: number = 0;
      for (let i = 0; i < page.items.length; i++) {
        if (page.items[i].inFavorites) {
          out.push(page.items[i]);
          hit++;
        }
      }
      Logger.info(TAG, `收藏专辑 第${p + 1}页 items=${page.items.length} fav=${hit} 累计=${out.length}`);
      if (page.items.length < 100) {
        break;
      }
      offset += page.items.length;
    }
    return out;
  }

  /**
   * 读某位艺人的收藏状态（⭐）+ 资料库/目录 id。
   *
   * 扫描资料库艺人列表（按名字匹配，通常 1 页就够），请求带
   * `include=catalog&extend=inFavorites` ⇒ 一次拿到资料库 id、目录 id 与收藏标记。
   * 找不到时 found=false（页面据此不显示心形）。
   *
   * @param artistName 艺人名（与资料库曲目里的 artistName 同口径）
   */
  static async getArtistFavState(artistName: string): Promise<ArtistFavState> {
    const out = new ArtistFavState();
    const want: string = artistName.trim();
    if (want === '') {
      return out;
    }
    let offset: number = 0;
    for (let p = 0; p < 3; p++) {
      const path: string =
        `/v1/me/library/artists?limit=100&offset=${offset}&include=catalog&extend=inFavorites`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      if (data === undefined || data.length === 0) {
        return out;
      }
      for (let i = 0; i < data.length; i++) {
        const it: Record<string, Object> = data[i] as Record<string, Object>;
        const attrs: Record<string, Object> | undefined =
          it['attributes'] as Record<string, Object> | undefined;
        if (attrs === undefined) {
          continue;
        }
        const nm: string = (attrs['name'] as string) ?? '';
        if (nm !== want) {
          continue;
        }
        out.found = true;
        out.libraryId = String(it['id'] ?? '');
        out.inFavorites = (attrs['inFavorites'] as boolean) ?? false;
        const pp: Record<string, Object> | undefined =
          attrs['playParams'] as Record<string, Object> | undefined;
        if (pp !== undefined) {
          out.catalogId = String(pp['catalogId'] ?? '');
        }
        const rels: Record<string, Object> | undefined =
          it['relationships'] as Record<string, Object> | undefined;
        if (rels !== undefined) {
          const cat: Record<string, Object> | undefined = rels['catalog'] as Record<string, Object> | undefined;
          if (cat !== undefined) {
            const cd: Object[] | undefined = cat['data'] as Object[] | undefined;
            if (cd !== undefined && cd.length > 0) {
              out.catalogId = String((cd[0] as Record<string, Object>)['id'] ?? out.catalogId);
            }
          }
        }
        return out;
      }
      if (data.length < 100) {
        break;
      }
      offset += data.length;
    }
    return out;
  }

  /**
   * 按名字在 Apple 目录里找艺人的目录 id（用于「不在资料库里的艺人」也要能收藏）。
   * 命中顺序与歌单/专辑一致：完全同名优先，其次包含关系。
   */
  static async searchArtistIdByName(artistName: string): Promise<string> {
    const want: string = artistName.trim();
    if (want === '') {
      return '';
    }
    try {
      const res: AppleSearchResult = await AppleApi.search(want, 10);
      const artists: AppleArtist[] = res.artists;
      for (let i = 0; i < artists.length; i++) {
        if (artists[i].name.trim() === want) {
          return artists[i].id;
        }
      }
      if (artists.length > 0) {
        return artists[0].id;
      }
    } catch (e) {
      Logger.warn(TAG, '目录搜艺人失败：' + ((e as Error).message ?? ''));
    }
    return '';
  }

  /** 读目录艺人的收藏状态（不在资料库里的艺人用）。 */
  static async getCatalogArtistInFavorites(catalogId: string): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    try {
      const txt: string = await AppleApi.ampGet(
        `/v1/catalog/${AppleApi.storefront}/artists/${catalogId}?extend=inFavorites`);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      if (data === undefined || data.length === 0) {
        return false;
      }
      const attrs: Record<string, Object> | undefined =
        (data[0] as Record<string, Object>)['attributes'] as Record<string, Object> | undefined;
      if (attrs === undefined) {
        return false;
      }
      return (attrs['inFavorites'] as boolean) ?? false;
    } catch (e) {
      return false;
    }
  }

  /**
   * 收藏 / 取消收藏一位艺人（写进 Apple Music）。
   *
   * 真机实测（2026-09-26）：
   *   - 收藏：POST   /v1/me/favorites?ids[artists]={目录艺人id}  body {} → 202
   *   - 取消：DELETE 同一 URL                                     → 204
   *   两者都在约 6 秒后体现在 `inFavorites` 上（与专辑不同：专辑必须走 ratings）。
   *
   * @param catalogId 目录艺人 id
   * @param fav true = 收藏，false = 取消收藏
   */
  static async setArtistFavorite(catalogId: string, fav: boolean): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    const url: string = `${AppleConst.AMP}/v1/me/favorites?ids%5Bartists%5D=${catalogId}`;
    try {
      const code: number = fav
        ? await AppleApi.rawWrite(http.RequestMethod.POST, url, '{}')
        : await AppleApi.rawWrite(http.RequestMethod.DELETE, url, '{}');
      Logger.info(TAG, `艺人收藏写入 fav=${fav} catalog=${catalogId} -> ${code}`);
      return code === 200 || code === 202 || code === 204;
    } catch (e) {
      Logger.warn(TAG, '艺人收藏写入失败：' + ((e as Error).message ?? ''));
      return false;
    }
  }

  /**
   * Apple Music 里「收藏（⭐）的艺人」姓名。
   *
   * 资料库艺人资源同样支持 `extend=inFavorites`；这里只取姓名，
   * 页面再按姓名去本地艺人表换成带封面的卡片（Apple 不返回艺人封面）。
   *
   * @param maxPages 最多扫描多少页（100 位/页）
   */
  static async getFavoriteArtistNames(maxPages: number): Promise<string[]> {
    const out: string[] = [];
    let offset: number = 0;
    for (let p = 0; p < maxPages; p++) {
      const path: string =
        `/v1/me/library/artists?limit=100&offset=${offset}&extend=inFavorites`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      let hit: number = 0;
      if (data !== undefined) {
        for (let i = 0; i < data.length; i++) {
          const attrs: Record<string, Object> | undefined =
            (data[i] as Record<string, Object>)['attributes'] as Record<string, Object> | undefined;
          if (attrs === undefined) {
            continue;
          }
          const fav: boolean = (attrs['inFavorites'] as boolean) ?? false;
          const nm: string = (attrs['name'] as string) ?? '';
          if (fav && nm !== '') {
            out.push(nm);
            hit++;
          }
        }
      }
      const n: number = data === undefined ? 0 : data.length;
      Logger.info(TAG, `收藏艺人 第${p + 1}页 items=${n} fav=${hit} 累计=${out.length}`);
      if (n < 100) {
        break;
      }
      offset += n;
    }
    return out;
  }

  // ─────────────────────────── 收藏（Apple Music ⭐） ───────────────────────────

  /**
   * 读资料库专辑的收藏状态 —— 一次请求同时拿到**目录 id** 与 inFavorites。
   * `include=catalog` 给出 relationships.catalog（目录 id），
   * `extend=inFavorites` 才让 Apple 返回收藏标记。
   *
   * @param libAlbumId 资料库专辑 id（形如 l.xxxx）
   */
  static async getLibraryAlbumFavState(libAlbumId: string): Promise<AlbumFavState> {
    const out = new AlbumFavState();
    if (libAlbumId === '') {
      return out;
    }
    const txt: string = await AppleApi.ampGet(
      `/v1/me/library/albums/${libAlbumId}?include=catalog&extend=inFavorites`);
    try {
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      if (data === undefined || data.length === 0) {
        return out;
      }
      const item: Record<string, Object> = data[0] as Record<string, Object>;
      const attrs: Record<string, Object> | undefined =
        item['attributes'] as Record<string, Object> | undefined;
      if (attrs !== undefined) {
        out.inFavorites = (attrs['inFavorites'] as boolean) ?? false;
        const pp: Record<string, Object> | undefined =
          attrs['playParams'] as Record<string, Object> | undefined;
        if (pp !== undefined) {
          out.catalogId = String(pp['catalogId'] ?? '');
        }
      }
      const rels: Record<string, Object> | undefined =
        item['relationships'] as Record<string, Object> | undefined;
      if (rels !== undefined) {
        const cat: Record<string, Object> | undefined =
          rels['catalog'] as Record<string, Object> | undefined;
        if (cat !== undefined) {
          const cd: Object[] | undefined = cat['data'] as Object[] | undefined;
          if (cd !== undefined && cd.length > 0) {
            out.catalogId = String((cd[0] as Record<string, Object>)['id'] ?? out.catalogId);
          }
        }
      }
    } catch (e) {
      Logger.warn(TAG, '解析资料库专辑收藏状态失败');
    }
    return out;
  }

  /**
   * 读目录专辑的收藏状态（专辑还没进资料库时用）。
   * 与资料库侧同源：真机实测 PUT/DELETE ratings 后约 6 秒两侧都会更新。
   */
  static async getCatalogAlbumInFavorites(catalogId: string): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    const txt: string = await AppleApi.ampGet(
      `/v1/catalog/${AppleApi.storefront}/albums/${catalogId}?extend=inFavorites`);
    try {
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      if (data === undefined || data.length === 0) {
        return false;
      }
      const attrs: Record<string, Object> | undefined =
        (data[0] as Record<string, Object>)['attributes'] as Record<string, Object> | undefined;
      if (attrs === undefined) {
        return false;
      }
      return (attrs['inFavorites'] as boolean) ?? false;
    } catch (e) {
      return false;
    }
  }

  /**
   * 收藏 / 取消收藏一张专辑（写进 Apple Music 自己的资料库）。
   *
   * 真机实测（2026-09-26）：
   *   - 收藏：PUT  /v1/me/ratings/albums/{目录id}  body {"attributes":{"value":1},"type":"ratings"} → 200
   *   - 取消：DELETE /v1/me/ratings/albums/{目录id}                                     → 204
   *   两者都要用**目录 id**（不是 l.xxx），且 inFavorites 约 6 秒后才传播完成；
   *   官方 `POST /v1/me/favorites`（202）虽然被接受，但实测不改 inFavorites，故不用。
   *
   * @param catalogId 目录专辑 id
   * @param fav true = 收藏，false = 取消收藏
   * @returns 是否写入成功
   */
  static async setAlbumFavorite(catalogId: string, fav: boolean): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    const url: string = `${AppleConst.AMP}/v1/me/ratings/albums/${catalogId}`;
    try {
      const code: number = fav
        ? await AppleApi.rawWrite(http.RequestMethod.PUT, url,
          '{"attributes":{"value":1},"type":"ratings"}')
        : await AppleApi.rawWrite(http.RequestMethod.DELETE, url, '{}');
      const ok: boolean = fav ? (code === 200 || code === 204) : (code === 200 || code === 204);
      Logger.info(TAG, `收藏写入 fav=${fav} catalog=${catalogId} -> ${code}`);
      return ok;
    } catch (e) {
      Logger.warn(TAG, '收藏写入失败：' + ((e as Error).message ?? ''));
      return false;
    }
  }

  /**
   * 读某首资料库歌曲的收藏状态 + 目录 id。
   *
   * 与专辑同源：`include=catalog` 给出目录 id，`extend=inFavorites` 才返回收藏标记。
   * 资料库歌曲 id 形如 `i.xxxx`，**不能**直接用于收藏写入。
   *
   * @param libSongId 资料库歌曲 id（i.xxxx）
   */
  static async getLibrarySongFavState(libSongId: string): Promise<SongFavState> {
    const out = new SongFavState();
    if (libSongId === '') {
      return out;
    }
    const txt: string = await AppleApi.ampGet(
      `/v1/me/library/songs/${libSongId}?include=catalog&extend=inFavorites`);
    try {
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[] | undefined;
      if (data === undefined || data.length === 0) {
        return out;
      }
      const item: Record<string, Object> = data[0] as Record<string, Object>;
      const attrs: Record<string, Object> | undefined =
        item['attributes'] as Record<string, Object> | undefined;
      if (attrs !== undefined) {
        out.inFavorites = (attrs['inFavorites'] as boolean) ?? false;
      }
      const rel: Record<string, Object> | undefined =
        item['relationships'] as Record<string, Object> | undefined;
      const cat: Record<string, Object> | undefined =
        rel !== undefined ? (rel['catalog'] as Record<string, Object> | undefined) : undefined;
      const catData: Object[] | undefined =
        cat !== undefined ? (cat['data'] as Object[] | undefined) : undefined;
      if (catData !== undefined && catData.length > 0) {
        out.catalogId = ((catData[0] as Record<string, Object>)['id'] as string) ?? '';
      }
    } catch (e) {
      Logger.warn(TAG, '读歌曲收藏状态失败：' + ((e as Error).message ?? ''));
    }
    return out;
  }

  /**
   * 收藏 / 取消收藏一首歌。
   *
   * 先按专辑那套走 `PUT/DELETE /v1/me/ratings/songs/{目录id}`；
   * 若该端点对这种资源不生效（艺人就属于这种情况），自动回退到
   * `POST/DELETE /v1/me/favorites?ids[songs]={目录id}`（与艺人收藏同一套）。
   * 两者都是最终一致：约 6 秒后才在 inFavorites 上体现，所以 UI 必须乐观更新。
   *
   * @param catalogId 目录歌曲 id
   * @param fav true = 收藏，false = 取消收藏
   */
  static async setSongFavorite(catalogId: string, fav: boolean): Promise<boolean> {
    if (catalogId === '') {
      return false;
    }
    const ratingsUrl: string = `${AppleConst.AMP}/v1/me/ratings/songs/${catalogId}`;
    try {
      const code: number = fav
        ? await AppleApi.rawWrite(http.RequestMethod.PUT, ratingsUrl,
          '{"attributes":{"value":1},"type":"ratings"}')
        : await AppleApi.rawWrite(http.RequestMethod.DELETE, ratingsUrl, '{}');
      if (code === 200 || code === 202 || code === 204) {
        Logger.info(TAG, `歌曲收藏 ratings fav=${fav} catalog=${catalogId} -> ${code}`);
        return true;
      }
      Logger.warn(TAG, `歌曲收藏 ratings 不可用(${code})，回退 favorites`);
    } catch (e) {
      Logger.warn(TAG, '歌曲收藏 ratings 异常，回退 favorites：' + ((e as Error).message ?? ''));
    }
    const favUrl: string = `${AppleConst.AMP}/v1/me/favorites?ids[songs]=${catalogId}`;
    try {
      const code2: number = fav
        ? await AppleApi.rawWrite(http.RequestMethod.POST, favUrl, '{}')
        : await AppleApi.rawWrite(http.RequestMethod.DELETE, favUrl, '{}');
      Logger.info(TAG, `歌曲收藏 favorites fav=${fav} catalog=${catalogId} -> ${code2}`);
      return code2 === 200 || code2 === 202 || code2 === 204;
    } catch (e) {
      Logger.warn(TAG, '歌曲收藏 favorites 失败：' + ((e as Error).message ?? ''));
      return false;
    }
  }

  /** 写请求（收藏/取消等），返回 HTTP 状态码。注意：body 不能传空串，否则本地报 Parameter error。 */
  private static async rawWrite(method: http.RequestMethod, url: string, body: string): Promise<number> {
    await AppleApi.ensureReady();
    const req = http.createHttp();
    try {
      const h: Record<string, string> = AppleApi.headers(true);
      h['Content-Type'] = 'application/json';
      const options: http.HttpRequestOptions = {
        method: method,
        connectTimeout: 15000,
        readTimeout: 25000,
        expectDataType: http.HttpDataType.STRING,
        header: h,
        extraData: body
      };
      const resp: http.HttpResponse = await req.request(url, options);
      return resp.responseCode;
    } finally {
      req.destroy();
    }
  }


  /** 资料库歌单 */
  static async getLibraryPlaylists(limit: number, offset: number): Promise<PageResult<ApplePlaylist>> {
    const path: string = `/v1/me/library/playlists?limit=${limit}&offset=${offset}&l=en-US`;
    const txt: string = await AppleApi.ampGet(path);
    return AppleApi.parsePlaylists(txt);
  }

  /** 歌单内的歌曲 */
  static async getPlaylistTracks(playlistId: string, limit: number, offset: number): Promise<PageResult<AppleSong>> {
    const path: string = `/v1/me/library/playlists/${playlistId}/tracks?limit=${limit}&offset=${offset}&l=en-US`;
    const txt: string = await AppleApi.ampGet(path);
    return AppleApi.parseSongs(txt, true);
  }

  // ─────────────────────────── 目录 / 搜索 ───────────────────────────

  /**
   * 当前商店对应的语言标签。
   *
   * 这个值直接影响搜索能否命中：写死 `l=en-US` 时，Apple 只在英文名/别名里
   * 匹配，搜「方大同」（Apple 目录里的规范名是 Khalil Fong）就搜不到本人，
   * 只会返回一堆名字里含这几个字的相关艺人。所以按商店语言来。
   */
  static langTag(): string {
    const sf: string = AppleApi.storefront;
    if (sf === 'cn' || sf === 'zh') {
      return 'zh-Hans-CN';
    }
    if (sf === 'jp') {
      return 'ja-JP';
    }
    if (sf === 'kr') {
      return 'ko-KR';
    }
    if (sf === 'tw' || sf === 'hk') {
      return 'zh-Hant-TW';
    }
    return 'en-US';
  }

  /** 单次搜索（指定语言）。 */
  private static async searchOnce(term: string, limit: number, lang: string): Promise<AppleSearchResult> {
    const enc: string = encodeURIComponent(term);
    const path: string = `/v1/catalog/${AppleApi.storefront}/search?term=${enc}` +
      `&types=songs,albums,artists,playlists&limit=${limit}&l=${lang}`;
    const txt: string = await AppleApi.ampGet(path);
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const results: Record<string, Object> = (root['results'] as Record<string, Object>) ?? {};
    const out = new AppleSearchResult();
    // 目录搜索的响应形状是 { results: { songs: { data: [...] }, ... } }：
    // 每个类型外面还包了一层对象（含 href/next/data），必须先把 data 那一层取出来。
    // 以前直接按数组读，所有类型永远解析成空 —— search() 一直没被调用过所以没暴露。
    out.songs = AppleApi.pickSongs(AppleApi.searchSection(results, 'songs'), 'data', false);
    out.albums = AppleApi.pickAlbums(AppleApi.searchSection(results, 'albums'), 'data', false);
    out.artists = AppleApi.pickArtists(AppleApi.searchSection(results, 'artists'), 'data');
    out.playlists = AppleApi.pickPlaylists(AppleApi.searchSection(results, 'playlists'), 'data');
    return out;
  }

  /**
   * 搜索（歌曲/专辑/艺人/歌单）：**按商店语言 + 英文各搜一次后合并**，
   * 所以中文名（方大同）和英文名（Khalil Fong）都能命中。
   */
  static async search(term: string, limit: number): Promise<AppleSearchResult> {
    const lang: string = AppleApi.langTag();
    const merged = new AppleSearchResult();
    const seenArtist: Set<string> = new Set();
    const seenAlbum: Set<string> = new Set();
    const seenSong: Set<string> = new Set();
    const langs: string[] = lang === 'en-US' ? ['en-US'] : [lang, 'en-US'];
    for (let i = 0; i < langs.length; i++) {
      try {
        const part: AppleSearchResult = await AppleApi.searchOnce(term, limit, langs[i]);
        for (let k = 0; k < part.artists.length; k++) {
          const a = part.artists[k];
          if (!seenArtist.has(a.id)) {
            seenArtist.add(a.id);
            merged.artists.push(a);
          }
        }
        for (let k = 0; k < part.albums.length; k++) {
          const a = part.albums[k];
          if (!seenAlbum.has(a.id)) {
            seenAlbum.add(a.id);
            merged.albums.push(a);
          }
        }
        for (let k = 0; k < part.songs.length; k++) {
          const a = part.songs[k];
          if (!seenSong.has(a.id)) {
            seenSong.add(a.id);
            merged.songs.push(a);
          }
        }
        if (i === 0 && merged.artists.length > 0 && merged.albums.length >= 5) {
          break;
        }
      } catch (e) {
        Logger.warn(TAG, `search with lang=${langs[i]} failed: ${(e as Error).message ?? ''}`);
      }
    }
    // 对照表兜底：Apple 公开搜索只索引规范名（方大同 → Khalil Fong），
    // 命中对照表时把规范名也搜一次，并把这些结果**放在最前面**。
    const alias: string = ArtistAliasTable.lookup(term);
    if (alias !== '' && alias.toLowerCase() !== term.toLowerCase()) {
      try {
        const mapped: AppleSearchResult = await AppleApi.searchOnce(alias, limit, 'en-US');
        const frontArtists: AppleArtist[] = [];
        for (let i = 0; i < mapped.artists.length; i++) {
          if (!seenArtist.has(mapped.artists[i].id)) {
            seenArtist.add(mapped.artists[i].id);
            frontArtists.push(mapped.artists[i]);
          }
        }
        const frontAlbums: AppleAlbum[] = [];
        for (let i = 0; i < mapped.albums.length; i++) {
          if (!seenAlbum.has(mapped.albums[i].id)) {
            seenAlbum.add(mapped.albums[i].id);
            frontAlbums.push(mapped.albums[i]);
          }
        }
        const frontSongs: AppleSong[] = [];
        for (let i = 0; i < mapped.songs.length; i++) {
          if (!seenSong.has(mapped.songs[i].id)) {
            seenSong.add(mapped.songs[i].id);
            frontSongs.push(mapped.songs[i]);
          }
        }
        merged.artists = frontArtists.concat(merged.artists);
        merged.albums = frontAlbums.concat(merged.albums);
        merged.songs = frontSongs.concat(merged.songs);
        Logger.info(TAG, `alias search: ${term} -> ${alias} (artists=${frontArtists.length})`);
      } catch (e) {
        Logger.warn(TAG, `alias search failed ${alias}: ${(e as Error).message ?? ''}`);
      }
    }
    merged.playlists = [];
    return merged;
  }

  /** 目录搜索响应里取出某个类型的容器对象（含 data 数组）。 */
  private static searchSection(results: Record<string, Object>, key: string): Record<string, Object> {
    return (results[key] as Record<string, Object>) ?? {};
  }

  /** 只搜专辑（独立请求）。专辑索引比艺人索引宽，艺人搜不到时用它兜底。 */
  static async searchAlbumsOnly(term: string, limit: number): Promise<AppleAlbum[]> {
    if (term === '') {
      return [];
    }
    const enc: string = encodeURIComponent(term);
    const path: string = `/v1/catalog/${AppleApi.storefront}/search?term=${enc}` +
      `&types=albums&limit=${limit}&l=${AppleApi.langTag()}`;
    try {
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const results: Record<string, Object> = (root['results'] as Record<string, Object>) ?? {};
      return AppleApi.pickAlbums(AppleApi.searchSection(results, 'albums'), 'data', false);
    } catch (e) {
      Logger.warn(TAG, `searchAlbumsOnly failed ${term}: ${(e as Error).message ?? ''}`);
      return [];
    }
  }

  /**
   * 资料库搜索（只取艺人）。命中「你自己库里的元数据」，所以中文名能匹配
   * （那是 Apple 返回给你的本地化名字），而目录搜索接口索引的是规范名。
   */
  static async librarySearchArtists(term: string): Promise<AppleArtist[]> {
    if (term === '') {
      return [];
    }
    const enc: string = encodeURIComponent(term);
    const path: string = `/v1/me/library/search?term=${enc}` +
      `&types=library-artists&limit=25&l=en-US`;
    try {
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const results: Record<string, Object> = (root['results'] as Record<string, Object>) ?? {};
      const section: Record<string, Object> =
        (results['library-artists'] as Record<string, Object>) ?? {};
      const data: Object[] | undefined = section['data'] as Object[];
      const out: AppleArtist[] = [];
      if (data === undefined) {
        return out;
      }
      for (let i = 0; i < data.length; i++) {
        const it: Record<string, Object> = data[i] as Record<string, Object>;
        const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
        const a = new AppleArtist();
        a.id = (it['id'] as string) ?? '';
        a.name = (attrs['name'] as string) ?? '';
        if (a.id !== '' && a.name !== '') {
          out.push(a);
        }
      }
      Logger.info(TAG, `library artist search ${term}: ${out.length}`);
      return out;
    } catch (e) {
      Logger.warn(TAG, `librarySearchArtists failed ${term}: ${(e as Error).message ?? ''}`);
      return [];
    }
  }

  /** 目录艺人详情（补名字与头像；目录搜索结果里没有时用）。 */
  static async getCatalogArtist(artistId: string): Promise<AppleArtist | null> {
    if (artistId === '') {
      return null;
    }
    try {
      const path: string = `/v1/catalog/${AppleApi.storefront}/artists/${artistId}?l=${AppleApi.langTag()}`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return null;
      }
      const it: Record<string, Object> = data[0] as Record<string, Object>;
      const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
      const a = new AppleArtist();
      a.id = (it['id'] as string) ?? '';
      a.name = (attrs['name'] as string) ?? '';
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      const artUrl: string = (art['url'] as string) ?? '';
      a.artworkUrl = AppleApi.bigArtwork(artUrl);
      return a.name !== '' ? a : null;
    } catch (e) {
      Logger.warn(TAG, `getCatalogArtist failed ${artistId}: ${(e as Error).message ?? ''}`);
      return null;
    }
  }


  /**
   * 只搜艺人（独立请求，limit 更大）。
   * 混在 types=songs,albums,artists 里搜时，艺人结果容易被歌曲/专辑挤掉，
   * 出现「搜名字搜不到这位艺人」的情况。
   */
  static async searchArtistsOnly(term: string, limit: number): Promise<AppleArtist[]> {
    if (term === '') {
      return [];
    }
    const enc: string = encodeURIComponent(term);
    const path: string = `/v1/catalog/${AppleApi.storefront}/search?term=${enc}` +
      `&types=artists&limit=${limit}&l=${AppleApi.langTag()}`;
    try {
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const results: Record<string, Object> = (root['results'] as Record<string, Object>) ?? {};
      return AppleApi.pickArtists(AppleApi.searchSection(results, 'artists'), 'data');
    } catch (e) {
      Logger.warn(TAG, `searchArtistsOnly failed ${term}: ${(e as Error).message ?? ''}`);
      return [];
    }
  }

  /**
   * 某位曲库艺人的专辑列表（分页，用于「全部加入资料库」）。
   * @param artistId 曲库艺人 id。
   * @param limit 单页条数（Apple 上限 100）。
   * @param offset 偏移。
   */
  static async getCatalogArtistAlbums(artistId: string, limit: number, offset: number): Promise<AppleAlbum[]> {
    const path: string = `/v1/catalog/${AppleApi.storefront}/artists/${artistId}/albums` +
      `?limit=${limit}&offset=${offset}&l=en-US`;
    const txt: string = await AppleApi.ampGet(path);
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    return AppleApi.pickAlbums(root, 'data', false);
  }

  // ─────────────── 资料库写入：补齐曲库版本 ───────────────

  /**
   * 目录歌曲所属的专辑 id（搜索页点歌时用来取整张专辑当队列）。
   * @param songId 目录歌曲 id。
   */
  static async getCatalogSongAlbumId(songId: string): Promise<string> {
    if (songId === '') {
      return '';
    }
    const path: string = `/v1/catalog/${AppleApi.storefront}/songs/${songId}?include=albums&l=en-US`;
    try {
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return '';
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const rel: Record<string, Object> = (first['relationships'] as Record<string, Object>) ?? {};
      const albums: Record<string, Object> = (rel['albums'] as Record<string, Object>) ?? {};
      const list: Object[] | undefined = albums['data'] as Object[];
      if (list === undefined || list.length === 0) {
        return '';
      }
      const a: Record<string, Object> = list[0] as Record<string, Object>;
      return (a['id'] as string) ?? '';
    } catch (e) {
      Logger.warn(TAG, `getCatalogSongAlbumId failed ${songId}: ${(e as Error).message ?? ''}`);
      return '';
    }
  }

  /**
   * 目录专辑的曲目（搜索页点某首歌时，队列取它所在的专辑）。
   * @param albumId 目录专辑 id。
   */
  static async getCatalogAlbumTracks(albumId: string): Promise<AppleSong[]> {
    if (albumId === '') {
      return [];
    }
    // 注意：Apple 的 albums/{id}?include=tracks **不允许带 limit**
    // （带 upstream 会返回 400 "Limit may not be supplied on this request"，
    // 表现为专辑详情页曲目为空）。
    const path: string = `/v1/catalog/${AppleApi.storefront}/albums/${albumId}` +
      `?include=tracks&l=en-US`;
    try {
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return [];
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const rel: Record<string, Object> =
        (first['relationships'] as Record<string, Object>) ?? {};
      const tracks: Record<string, Object> = (rel['tracks'] as Record<string, Object>) ?? {};
      return AppleApi.pickSongs(tracks, 'data', false);
    } catch (e) {
      Logger.warn(TAG, `getCatalogAlbumTracks failed ${albumId}: ${(e as Error).message ?? ''}`);
      return [];
    }
  }

  /**
   * 云资料库歌曲 id（i.xxxx）→ 曲库 catalogId。
   * 本地歌曲的 URI 就是云资料库 id，从这里能精确换到曲库身份，不需要按名字猜。
   */
  static async librarySongCatalogId(libraryId: string): Promise<string> {
    if (libraryId === '') {
      return '';
    }
    try {
      const txt: string = await AppleApi.ampGet(`/v1/me/library/songs/${libraryId}?l=en-US`);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return '';
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const attrs: Record<string, Object> = (first['attributes'] as Record<string, Object>) ?? {};
      const pp: Record<string, Object> = (attrs['playParams'] as Record<string, Object>) ?? {};
      const cid: string | undefined = pp['catalogId'] as string;
      return cid !== undefined ? cid : '';
    } catch (e) {
      Logger.warn(TAG, `librarySongCatalogId failed ${libraryId}: ${(e as Error).message ?? ''}`);
      return '';
    }
  }

  /** 目录歌曲 id（数字）→ 其主艺人（目录艺人 id）。 */
  static async getCatalogSongArtistId(catalogSongId: string): Promise<string> {
    if (catalogSongId === '') {
      return '';
    }
    try {
      const path: string = `/v1/catalog/${AppleApi.storefront}/songs/${catalogSongId}` +
        `?include=artists&l=en-US`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return '';
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const rel: Record<string, Object> = (first['relationships'] as Record<string, Object>) ?? {};
      const artists: Record<string, Object> = (rel['artists'] as Record<string, Object>) ?? {};
      const list: Object[] | undefined = artists['data'] as Object[];
      if (list === undefined || list.length === 0) {
        return '';
      }
      const a: Record<string, Object> = list[0] as Record<string, Object>;
      return (a['id'] as string) ?? '';
    } catch (e) {
      Logger.warn(TAG, `getCatalogSongArtistId failed ${catalogSongId}: ${(e as Error).message ?? ''}`);
      return '';
    }
  }

  /**
   * 批量：目录歌曲 id → 这首歌的主艺人（含官方头像）。
   *
   * 用途：资料库歌曲里有 `playParams.catalogId`，但**资料库接口不返回艺人头像**；
   * 一次请求最多 100 个目录歌曲 id，返回的 relationships.artists 就带
   * `attributes.artwork`（Apple Music 官方艺人图），所以整库只要二三十次请求，
   * 且随每次资料库同步自动更新。
   *
   * @param songIds 目录歌曲 id 列表（建议 ≤100）
   * @returns 目录歌曲 id → 主艺人
   */
  static async catalogArtistsForSongs(songIds: string[]): Promise<Map<string, AppleArtist>> {
    const out: Map<string, AppleArtist> = new Map();
    if (songIds.length === 0) {
      return out;
    }
    try {
      const ids: string = songIds.join(',');
      const path: string = `/v1/catalog/${AppleApi.storefront}/songs?ids=${ids}` +
        `&include=artists&l=${AppleApi.langTag()}`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined) {
        return out;
      }
      for (let i = 0; i < data.length; i++) {
        const it: Record<string, Object> = data[i] as Record<string, Object>;
        const id: string = (it['id'] as string) ?? '';
        if (id === '') {
          continue;
        }
        const rel: Record<string, Object> = (it['relationships'] as Record<string, Object>) ?? {};
        const arts: Record<string, Object> = (rel['artists'] as Record<string, Object>) ?? {};
        const list: Object[] | undefined = arts['data'] as Object[];
        if (list === undefined || list.length === 0) {
          continue;
        }
        const a: Record<string, Object> = list[0] as Record<string, Object>;
        const attrs: Record<string, Object> = (a['attributes'] as Record<string, Object>) ?? {};
        const artist = new AppleArtist();
        artist.id = (a['id'] as string) ?? '';
        artist.name = (attrs['name'] as string) ?? '';
        const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
        artist.artworkUrl = AppleApi.bigArtwork((art['url'] as string) ?? '');
        out.set(id, artist);
      }
    } catch (e) {
      Logger.warn(TAG, `catalogArtistsForSongs failed: ${(e as Error).message ?? ''}`);
    }
    return out;
  }

  /** 目录专辑 id → 其主艺人（目录艺人 id）。 */
  static async getCatalogAlbumArtistId(albumId: string): Promise<string> {
    const artist: AppleArtist | null = await AppleApi.catalogAlbumArtist(albumId);
    return artist !== null ? artist.id : '';
  }

  /**
   * 一次请求同时拿到专辑**主艺人**的 id / 名称 / 头像。
   *
   * 原来的实现只取 id，调用方为了头像还得再发一次艺人请求 —— 长按封面进艺人
   * 主页要等两个来回，用户会觉得「按了没反应」。搜索页长按改用这个版本。
   */
  static async catalogAlbumArtist(albumId: string): Promise<AppleArtist | null> {
    if (albumId === '') {
      return null;
    }
    try {
      const path: string = `/v1/catalog/${AppleApi.storefront}/albums/${albumId}` +
        `?include=artists&l=${AppleApi.langTag()}`;
      const txt: string = await AppleApi.ampGet(path);
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] | undefined = root['data'] as Object[];
      if (data === undefined || data.length === 0) {
        return null;
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const rel: Record<string, Object> = (first['relationships'] as Record<string, Object>) ?? {};
      const artists: Record<string, Object> = (rel['artists'] as Record<string, Object>) ?? {};
      const list: Object[] | undefined = artists['data'] as Object[];
      if (list === undefined || list.length === 0) {
        return null;
      }
      const a: Record<string, Object> = list[0] as Record<string, Object>;
      const attrs: Record<string, Object> = (a['attributes'] as Record<string, Object>) ?? {};
      const out = new AppleArtist();
      out.id = (a['id'] as string) ?? '';
      out.name = (attrs['name'] as string) ?? '';
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      out.artworkUrl = AppleApi.bigArtwork((art['url'] as string) ?? '');
      if (out.id === '') {
        return null;
      }
      return out;
    } catch (e) {
      Logger.warn(TAG, `catalogAlbumArtist failed ${albumId}: ${(e as Error).message ?? ''}`);
      return null;
    }
  }

  /**
   * 把某张「曲库专辑」加入用户的 Apple Music 资料库。
   *
   * 用途：本地导入过的歌在 iCloud 里是「上传版本」，Apple 的网页接口看不到、
   * 也放不了；把同一张专辑的曲库版本加进资料库，这些艺人就能正常显示与播放。
   * 官方接口：POST /v1/me/library?ids[albums]=<catalogAlbumId>（幂等）。
   *
   * @param albumId 曲库专辑 id（数字形式，来自搜索/目录接口）。
   * @returns 是否成功。
   */
  static async addCatalogAlbumToLibrary(albumId: string): Promise<boolean> {
    if (albumId === '') {
      return false;
    }
    const enc: string = encodeURIComponent(albumId);
    // 方括号百分号编码（ids%5Balbums%5D）；不用通用 requestJson 的原因：
    // 1) POST 空 body 会被鸿蒙 http 判成「Parameter error」，请求根本发不出去；
    // 2) 官方该接口成功返回 204 No Content，通用「非 200 即失败」会误判。
    // 不要带 l 参数：storefront 代码（cn）不是合法的语言标签，Apple 会直接
    // 返回 400 Invalid Parameter Value / Invalid language tag 'cn'（实测）。
    // 该接口也不需要语言标签。
    // 只用 amp-api 主机：api.music.apple.com 用网页版 token 会 403
    // （Authentication required for request），是必然失败的一次多余重试。
    const urls: string[] = [
      `${AppleConst.AMP}/v1/me/library?ids%5Balbums%5D=${enc}`
    ];
    for (let i = 0; i < urls.length; i++) {
      const result: string = await AppleApi.postLibraryAdd(urls[i], albumId);
      if (result === 'ok') {
        return true;
      }
      Logger.warn(TAG, `add album attempt ${i} failed: ${result}`);
    }
    Logger.warn(TAG, `add album failed ${albumId}: all attempts failed`);
    return false;
  }

  /**
   * 资料库写入专用 POST。
   * @returns 'ok' 或错误描述（含响应码与响应体，便于定位）。
   */
  private static async postLibraryAdd(url: string, albumId: string): Promise<string> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = AppleApi.headers(true);
      header['Content-Type'] = 'application/json';
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        connectTimeout: 15000,
        readTimeout: 20000,
        extraData: '{}'
      };
      const resp: http.HttpResponse = await req.request(url, options);
      const code: number = resp.responseCode;
      // 2xx 全算成功。特别注意 202：Apple 对「加入资料库」是**异步受理**，
      // 返回 202 Accepted（实测），只认 200/201/204 会把它误判成失败。
      if (code >= 200 && code < 300) {
        Logger.info(TAG, `album added to library (${code}): ${albumId}`);
        // 注意：这里**不能**每张都等 —— 202 是异步受理，但逐个等 2.5 秒会让
        // 100 张专辑变成 4 分钟（用户实测「卡在正在读取」）。等待放到批量末尾一次。
        return 'ok';
      }
      const body: string = typeof resp.result === 'string' ? resp.result as string : 'binary';
      return `HTTP ${code} body=${body.substring(0, 220)}`;
    } catch (e) {
      const be = e as BusinessError;
      const msg: string = be !== undefined && be.message !== undefined ? be.message : JSON.stringify(e);
      const code: number = be !== undefined && be.code !== undefined ? be.code : -1;
      return `exception code=${code} msg=${msg}`;
    } finally {
      req.destroy();
    }
  }

  // ─────────────── 诊断用：资料库侧原始接口 ───────────────

  /**
   * 资料库搜索（含「上传的歌曲」这类只能在客户端看到的条目）。
   * @returns 原始 JSON 文本（诊断用，不做解析）。
   */
  static async rawLibrarySearch(term: string): Promise<string> {
    const enc: string = encodeURIComponent(term);
    const path: string = `/v1/me/library/search?term=${enc}` +
      `&types=library-songs,library-albums,library-artists&limit=10&l=en-US`;
    return AppleApi.ampGet(path);
  }

  /** 资料库艺人清单原始 JSON（诊断用）。 */
  static async rawLibraryArtists(limit: number, offset: number): Promise<string> {
    const path: string = `/v1/me/library/artists?limit=${limit}&offset=${offset}&l=en-US`;
    return AppleApi.ampGet(path);
  }

  /**
   * 资料库里已存在的曲库专辑 id 集合（用于「补齐」时去重）。
   *
   * 资料库专辑响应里带 playParams.catalogId —— 用它与待加入的曲库专辑 id 比对，
   * 已经在库里的直接跳过。这比按艺人名判断可靠得多：同一位艺人在资料库里可能
   * 是中文名（阿尔多·奇科里尼）而目录里是英文名（Aldo Ciccolini），按名字判重
   * 会把整批古典专辑重复加入。
   */
  static async libraryAlbumCatalogIds(): Promise<Set<string>> {
    const ids: Set<string> = new Set();
    let offset = 0;
    let guard = 0;
    while (guard < 6) {
      const path: string = `/v1/me/library/albums?limit=100&offset=${offset}&include=tracks&l=en-US`;
      let raw: string = '';
      try {
        raw = await AppleApi.ampGet(path);
      } catch (e) {
        break;
      }
      const re = new RegExp('"catalogId":"([0-9]+)"', 'g');
      let m: RegExpExecArray | null = re.exec(raw);
      let items = 0;
      while (m !== null) {
        ids.add(m[1]);
        m = re.exec(raw);
      }
      const itemRe = new RegExp('"type":"library-albums"', 'g');
      let im: RegExpExecArray | null = itemRe.exec(raw);
      while (im !== null) {
        items++;
        im = itemRe.exec(raw);
      }
      offset += items;
      if (items < 100) {
        break;
      }
      guard++;
    }
    Logger.info(TAG, `library album catalogIds=${ids.size}`);
    return ids;
  }

  /** 资料库专辑清单原始 JSON（诊断用）。 */
  static async rawLibraryAlbums(limit: number, offset: number): Promise<string> {
    const path: string = `/v1/me/library/albums?limit=${limit}&offset=${offset}&l=en-US`;
    return AppleApi.ampGet(path);
  }

  /** 某个资料库专辑的曲目（诊断用）。 */
  static async rawLibraryAlbumTracks(albumId: string): Promise<string> {
    const path: string = `/v1/me/library/albums/${albumId}/tracks?limit=50&l=en-US`;
    return AppleApi.ampGet(path);
  }

  /** 资料库歌曲原始 JSON（诊断用：看单条记录里有哪些字段/标记）。 */
  static async rawLibrarySongs(limit: number, offset: number): Promise<string> {
    const path: string = `/v1/me/library/songs?limit=${limit}&offset=${offset}&l=en-US`;
    return AppleApi.ampGet(path);
  }

  /** 目录歌曲详情（用于补全元数据） */
  static async getCatalogSong(songId: string): Promise<AppleSong | null> {
    const path: string = `/v1/catalog/${AppleApi.storefront}/songs/${songId}?l=en-US&include=albums,artists`;
    const txt: string = await AppleApi.ampGet(path);
    const page: PageResult<AppleSong> = AppleApi.parseSongs(txt, false);
    return page.items.length > 0 ? page.items[0] : null;
  }

  // ─────────────────────────── 播放资源 ───────────────────────────

  /** webPlayback：拿到该歌的资产列表（含音频子清单 URL） */
  static async getWebPlayback(songId: string, isLibrary: boolean): Promise<WebPlaybackInfo> {
    const body: string = isLibrary
      ? `{"universalLibraryId":"${songId}","language":"en-US"}`
      : `{"salableAdamId":"${songId}","language":"en-US"}`;
    const txt: string = await AppleApi.requestJson(AppleConst.WEBPLAYBACK, http.RequestMethod.POST, body);
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const list: Object[] = (root['songList'] as Object[]) ?? [];
    const info = new WebPlaybackInfo();
    info.songId = songId;
    if (list.length > 0) {
      const first: Record<string, Object> = list[0] as Record<string, Object>;
      const sid: string | undefined = first['songId'] as string;
      if (sid !== undefined) {
        info.songId = sid;
      }
      const assets: Object[] = (first['assets'] as Object[]) ?? [];
      for (let i = 0; i < assets.length; i++) {
        const a: Record<string, Object> = assets[i] as Record<string, Object>;
        const asset = new AppleAsset();
        asset.flavor = (a['flavor'] as string) ?? '';
        asset.url = (a['URL'] as string) ?? '';
        info.assets.push(asset);
      }
    }
    return info;
  }

  /** /v1/play/assets：拿 HLS + license 服务器地址 */
  static async getPlayAssets(songId: string): Promise<PlayAssetInfo> {
    const path: string = `/v1/play/assets?id=${songId}&kind=song&includeLicenseUrls=true` +
      `&hlsEncryption=CBC&hlsProfile=enhancedHls`;
    const txt: string = await AppleApi.ampGet(path);
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const results: Record<string, Object> = (root['results'] as Record<string, Object>) ?? {};
    const arr: Object[] = (results['assets'] as Object[]) ?? [];
    const info = new PlayAssetInfo();
    if (arr.length > 0) {
      const a: Record<string, Object> = arr[0] as Record<string, Object>;
      info.hlsUrl = (a['url'] as string) ?? '';
      info.keyServerUrl = (a['keyServerUrl'] as string) ?? '';
      info.widevineCertUrl = (a['widevineKeyCertificateUrl'] as string) ?? '';
      info.fairPlayCertUrl = (a['fairPlayKeyCertificateUrl'] as string) ?? '';
    }
    return info;
  }

  /** 下载任意 URL 为字节（HLS 清单 / 分片） */
  static async downloadBytes(url: string): Promise<Uint8Array> {
    return AppleApi.downloadRange(url, -1, -1);
  }

  /**
   * 带 Range 的下载。
   *
   * @param url 目标地址
   * @param start 起始字节（含）；传 -1 表示整段下载（不带 Range 头）
   * @param end 结束字节（含）；传 -1 表示到文件末尾
   */
  static async downloadRange(url: string, start: number, end: number): Promise<Uint8Array> {
    await AppleApi.ensureReady();
    const req = http.createHttp();
    try {
      const h: Record<string, string> = AppleApi.headers(true);
      if (start >= 0) {
        h['Range'] = end >= 0 ? `bytes=${start}-${end}` : `bytes=${start}-`;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: h
      };
      const resp: http.HttpResponse = await req.request(url, options);
      // 带 Range 时服务端返回 206 Partial Content；少数场景会回 200（整段）
      if (resp.responseCode !== 200 && resp.responseCode !== 206) {
        throw new Error('HTTP ' + resp.responseCode + ' @ ' + url);
      }
      return new Uint8Array(resp.result as ArrayBuffer);
    } finally {
      req.destroy();
    }
  }

  /** 下载文本（m3u8） */
  static async downloadText(url: string): Promise<string> {
    const bytes: Uint8Array = await AppleApi.downloadBytes(url);
    let s: string = '';
    for (let i = 0; i < bytes.length; i++) {
      s += String.fromCharCode(bytes[i]);
    }
    return s;
  }

  /** license 请求用的 headers（与开源实现对齐：小写名 + 不带 UA） */
  static licenseHeaders(): Record<string, string> {
    const h: Record<string, string> = {
      'authorization': 'Bearer ' + AppleApi.devToken,
      'origin': 'https://music.apple.com',
      'cookie': 'media-user-token=' + AppleApi.userToken,
      'content-type': 'application/json'
    };
    return h;
  }

  /** 换 license（challenge 为 base64） */
  static async getLicense(challengeB64: string, uri: string, adamId: string, isLibrary: boolean): Promise<string> {
    const body: string = '{"challenge":"' + challengeB64 + '"' +
      ',"key-system":"com.widevine.alpha"' +
      ',"uri":"' + uri + '"' +
      ',"adamId":"' + adamId + '"' +
      ',"isLibrary":' + (isLibrary ? 'true' : 'false') +
      ',"user-initiated":true}';
    Logger.info(TAG, 'license body len=' + body.length + ' head=' + body.substring(0, 48));
    const req = http.createHttp();
    let txt: string = '';
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        header: AppleApi.licenseHeaders(),
        extraData: body
      };
      const resp: http.HttpResponse = await req.request(AppleConst.LICENSE, options);
      txt = resp.result as string;
      Logger.info(TAG, 'license http=' + resp.responseCode + ' resp=' + txt.substring(0, 200));
    } finally {
      req.destroy();
    }
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const lic: string | undefined = root['license'] as string;
    if (lic === undefined || lic.length === 0) {
      throw new Error('license 响应异常: ' + txt.substring(0, 200));
    }
    return lic;
  }

  // ─────────────────────────── JSON → 模型 ───────────────────────────

  private static parseSongs(txt: string, isLibrary: boolean): PageResult<AppleSong> {
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const page = new PageResult<AppleSong>();
    page.items = AppleApi.pickSongs(root, 'data', isLibrary);
    // meta.total = Apple 侧的真实总数。以前这里恒写 0，导致分页是否漏数据
    // 无从判断（资料库少了整批艺人时看不出来）。
    const meta: Record<string, Object> | undefined = root['meta'] as Record<string, Object>;
    if (meta !== undefined) {
      const total: number | undefined = meta['total'] as number;
      page.total = (total === undefined || total === null) ? 0 : total;
    }
    const next: string | undefined = root['next'] as string;
    page.next = (next === undefined) ? '' : next;
    return page;
  }

  private static pickSongs(root: Record<string, Object>, key: string, isLibrary: boolean): AppleSong[] {
    const out: AppleSong[] = [];
    const data: Object[] | undefined = root[key] as Object[];
    if (data === undefined) {
      return out;
    }
    for (let i = 0; i < data.length; i++) {
      const it: Record<string, Object> = data[i] as Record<string, Object>;
      const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
      const s = new AppleSong();
      s.id = (it['id'] as string) ?? '';
      s.name = (attrs['name'] as string) ?? '';
      s.artistName = (attrs['artistName'] as string) ?? '';
      s.albumName = (attrs['albumName'] as string) ?? '';
      s.trackNumber = (attrs['trackNumber'] as number) ?? 0;
      s.discNumber = (attrs['discNumber'] as number) ?? 0;
      s.isLibrary = isLibrary;
      const dur: number = (attrs['durationInMillis'] as number) ?? 0;
      s.durationMs = dur;
      const rd: string = (attrs['releaseDate'] as string) ?? '';
      if (rd.length >= 4) {
        s.year = parseInt(rd.substring(0, 4), 10);
        if (isNaN(s.year)) {
          s.year = 0;
        }
      }
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      const artUrl: string = (art['url'] as string) ?? '';
      s.artworkUrl = AppleApi.bigArtwork(artUrl);
      // 曲风（资料库/歌单接口自带）：艺人页「音乐板块」分类用，多值用 | 连接
      const genres: Object[] | undefined = attrs['genreNames'] as Object[];
      if (genres !== undefined && genres.length > 0) {
        const parts: string[] = [];
        for (let gi = 0; gi < genres.length; gi++) {
          const g: string = genres[gi] as string;
          if (g !== undefined && g.length > 0) {
            parts.push(g);
          }
        }
        s.genre = parts.join('|');
      }
      const traits: Object[] | undefined = attrs['audioTraits'] as Object[];
      if (traits !== undefined) {
        for (let k = 0; k < traits.length; k++) {
          s.audioTraits.push(traits[k] as string);
        }
      }
      const rel: Record<string, Object> | undefined = attrs['playParams'] as Record<string, Object>;
      if (rel !== undefined) {
        const cid: string | undefined = rel['catalogId'] as string;
        if (cid !== undefined) {
          s.catalogId = cid;
        }
        if (cid !== undefined && !isLibrary) {
          s.id = cid;
        }
      }
      out.push(s);
    }
    return out;
  }

  private static parseAlbums(txt: string, isLibrary: boolean): PageResult<AppleAlbum> {
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const page = new PageResult<AppleAlbum>();
    page.items = AppleApi.pickAlbums(root, 'data', isLibrary);
    return page;
  }

  private static pickAlbums(root: Record<string, Object>, key: string, isLibrary: boolean): AppleAlbum[] {
    const out: AppleAlbum[] = [];
    const data: Object[] | undefined = root[key] as Object[];
    if (data === undefined) {
      return out;
    }
    for (let i = 0; i < data.length; i++) {
      const it: Record<string, Object> = data[i] as Record<string, Object>;
      const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
      const a = new AppleAlbum();
      a.id = (it['id'] as string) ?? '';
      a.name = (attrs['name'] as string) ?? '';
      a.artistName = (attrs['artistName'] as string) ?? '';
      a.isLibrary = isLibrary;
      a.trackCount = (attrs['trackCount'] as number) ?? 0;
      a.isSingle = (attrs['isSingle'] as boolean) ?? false;
      // 只有带 extend=inFavorites 的请求才会返回该属性
      a.inFavorites = (attrs['inFavorites'] as boolean) ?? false;
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      a.artworkUrl = AppleApi.bigArtwork((art['url'] as string) ?? '');
      const rd: string = (attrs['releaseDate'] as string) ?? '';
      if (rd.length >= 4) {
        const y: number = parseInt(rd.substring(0, 4), 10);
        a.year = isNaN(y) ? 0 : y;
      }
      out.push(a);
    }
    return out;
  }

  private static parsePlaylists(txt: string): PageResult<ApplePlaylist> {
    const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
    const page = new PageResult<ApplePlaylist>();
    page.items = AppleApi.pickPlaylists(root, 'data');
    return page;
  }

  private static pickPlaylists(root: Record<string, Object>, key: string): ApplePlaylist[] {
    const out: ApplePlaylist[] = [];
    const data: Object[] | undefined = root[key] as Object[];
    if (data === undefined) {
      return out;
    }
    for (let i = 0; i < data.length; i++) {
      const it: Record<string, Object> = data[i] as Record<string, Object>;
      const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
      const p = new ApplePlaylist();
      p.id = (it['id'] as string) ?? '';
      p.name = (attrs['name'] as string) ?? '';
      const desc: Record<string, Object> | undefined = attrs['description'] as Record<string, Object>;
      if (desc !== undefined) {
        p.description = (desc['standard'] as string) ?? '';
      }
      p.trackCount = (attrs['trackCount'] as number) ?? 0;
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      p.artworkUrl = AppleApi.bigArtwork((art['url'] as string) ?? '');
      out.push(p);
    }
    return out;
  }

  private static pickArtists(root: Record<string, Object>, key: string): AppleArtist[] {
    const out: AppleArtist[] = [];
    const data: Object[] | undefined = root[key] as Object[];
    if (data === undefined) {
      return out;
    }
    for (let i = 0; i < data.length; i++) {
      const it: Record<string, Object> = data[i] as Record<string, Object>;
      const attrs: Record<string, Object> = (it['attributes'] as Record<string, Object>) ?? {};
      const a = new AppleArtist();
      a.id = (it['id'] as string) ?? '';
      a.name = (attrs['name'] as string) ?? '';
      const art: Record<string, Object> = (attrs['artwork'] as Record<string, Object>) ?? {};
      a.artworkUrl = AppleApi.bigArtwork((art['url'] as string) ?? '');
      out.push(a);
    }
    return out;
  }

  /** Apple 的封面 URL 模板替换成 600x600 */
  static bigArtwork(url: string): string {
    return AppleApi.artworkAt(url, 600);
  }

  /**
   * 按显示尺寸取封面：Apple 的封面是模板 URL（`{w}/{h}/{f}` 占位），
   * 列表里 52vp 的小图没必要下 600×600 再解码（解码内存差 4 倍以上），
   * 这里按调用方给的边长生成对应尺寸；不是模板 URL（本地路径等）时原样返回。
   *
   * @param url 封面 URL（可能含 {w}/{h}/{f} 占位）
   * @param size 目标边长（像素）
   */
  static artworkAt(url: string, size: number): string {
    if (url.length === 0) {
      return '';
    }
    const n: number = size > 0 ? Math.round(size) : 600;
    return url.replace('{w}', String(n)).replace('{h}', String(n)).replace('{f}', 'jpg');
  }
}
