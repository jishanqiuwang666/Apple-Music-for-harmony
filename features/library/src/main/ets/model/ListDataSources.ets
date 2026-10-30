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

import { AlbumApiDto, SongApiDto } from 'musicbasic';

/**
 * Lazy list data source for song rows: feeds LazyForEach so only visible
 * rows are created (official long-list optimization — ForEach builds every
 * node eagerly and wastes memory/measure time on large libraries).
 */
export class SongListDataSource implements IDataSource {
  private rows: SongApiDto[] = [];
  private listeners: DataChangeListener[] = [];

  /** Replaces the row set and notifies lazy listeners (full reload). */
  public setRows(rows: SongApiDto[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): SongApiDto {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(): void {
    this.listeners = [];
  }
}

/**
 * Lazy list data source for album grid rows (same rationale as above).
 */
/**
 * 专辑「行」数据源：每行 2 张专辑，供 List 使用。
 *
 * 为什么不用 Grid：专辑页原来是 `Scroll > Column > Grid`，Grid 拿不到确定视口高度，
 * 虚拟化失效 —— 327 张卡片全部实例化（实测首建 1~2 秒、参与切页时掉帧）。
 * 改成 List + 每行两张卡后，List 会按可视区惰性创建，节点数只剩可视的十来张。
 */
export class AlbumRowDataSource implements IDataSource {
  private rows: AlbumApiDto[][] = [];
  private listeners: DataChangeListener[] = [];

  /** 替换全部行（整体刷新）。 */
  public setRows(rows: AlbumApiDto[][]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): AlbumApiDto[] {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}

export class AlbumListDataSource implements IDataSource {
  private rows: AlbumApiDto[] = [];
  private listeners: DataChangeListener[] = [];

  /** Replaces the row set and notifies lazy listeners (full reload). */
  public setRows(rows: AlbumApiDto[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): AlbumApiDto {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(): void {
    this.listeners = [];
  }
}
