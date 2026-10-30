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

import { CatalogAlbumOffer } from 'musicbasic';

/**
 * 一位艺人的 Apple 目录作品（按页面上的三个分块存）。
 *
 * 只缓存**目录列表本身**：「这张作品在不在资料库」由 `workInLibrary()` 每次
 * 现算（一次内存查表），所以入库后标记会立刻变，不会被缓存冻住。
 */
export class CachedArtistWorks {
  public albumWorks: CatalogAlbumOffer[] = [];
  public epWorks: CatalogAlbumOffer[] = [];
  public singleWorks: CatalogAlbumOffer[] = [];
}

/**
 * 艺人作品缓存（App 生命周期内有效）。
 *
 * 为什么需要它：艺人详情页每次打开都会向 Apple 目录要一次「这位艺人的全部作品」，
 * 网络慢的时候整个页面要等好几秒（用户反馈「每次进艺人都要重新加载」）。
 * 同一次运行里再进同一位艺人完全没有必要再问一次 —— 目录作品几小时内不会变。
 *
 * 三条纪律（不要破坏）：
 *  ① 只在**成功拿到结果**后写缓存；失败不写，下次还可以重试；
 *  ② 命中缓存时**一个请求都不发**，页面立刻渲染（也不显示加载动画）；
 *  ③ 缓存是内存级（进程内），重启 App 自动失效 —— 相当于「每次冷启动首进会更新一次」。
 *
 * 所有艺人入口（收藏的艺人、艺人列表、搜索里的艺人）都走同一个
 * `ArtistDetailPage`，所以在这一层做缓存即可全覆盖。
 */
export class ArtistWorksCache {
  /** 艺人名 → 目录作品。 */
  private static works: Map<string, CachedArtistWorks> = new Map();
  /**
   * 艺人名 → 上次「收藏 → 自动补齐全部作品」的时间戳（毫秒）。
   *
   * 补齐会跑「全部作品入库 + 整库同步」，非常重；以前每次进收藏艺人的主页
   * 都会跑一遍。这里做会话级节流：同一次运行内每位艺人只跑一次。
   */
  private static fillAt: Map<string, number> = new Map();

  /**
   * @param name 艺人名
   * @returns 命中的缓存；没进过返回 undefined
   */
  public static get(name: string): CachedArtistWorks | undefined {
    return ArtistWorksCache.works.get(name);
  }

  /** 写入缓存（只在拿到结果后调用）。 */
  public static put(name: string, works: CachedArtistWorks): void {
    if (name === '') {
      return;
    }
    ArtistWorksCache.works.set(name, works);
  }

  /** @returns 是否已经缓存过这位艺人的作品。 */
  public static has(name: string): boolean {
    return name !== '' && ArtistWorksCache.works.has(name);
  }

  /**
   * @param name 艺人名
   * @param ttlMs 节流窗口（毫秒）
   * @returns 是否在窗口内已经自动补齐过
   */
  public static filledRecently(name: string, ttlMs: number): boolean {
    const at: number = ArtistWorksCache.fillAt.get(name) ?? 0;
    if (at <= 0) {
      return false;
    }
    return (Date.now() - at) < ttlMs;
  }

  /** 记一次「自动补齐全部作品」完成。 */
  public static markFilled(name: string): void {
    if (name !== '') {
      ArtistWorksCache.fillAt.set(name, Date.now());
    }
  }

  /** 清空（资料库重新同步 / 排障用）。 */
  public static clear(): void {
    ArtistWorksCache.works.clear();
    ArtistWorksCache.fillAt.clear();
  }
}
