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
import { fileIo } from '@kit.CoreFileKit';

/**
 * Apple Music 链路诊断日志（跨模块可写）。
 *
 * 真机上 hilog 的 domain 不便从 hdc 侧过滤，因此把关键节点写成沙盒文件
 * {@code filesDir/apple_diag.log}，电脑侧用 `hdc file recv` 直接读。
 * 只做追加，不做轮转；正式使用时可忽略其存在。
 */
export class AppleDiag {
  private static path: string = '';

  /** 在 Ability onCreate 里调用一次。 */
  static init(context: common.Context): void {
    AppleDiag.path = context.filesDir + '/apple_diag.log';
  }

  /** 追加一行（自动带时间戳）。 */
  static log(line: string): void {
    if (AppleDiag.path.length === 0) {
      return;
    }
    try {
      const f = fileIo.openSync(AppleDiag.path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      try {
        const t: Date = new Date();
        const stamp: string = `${t.getHours()}:${t.getMinutes()}:${t.getSeconds()}`;
        fileIo.writeSync(f.fd, '[' + stamp + '] ' + line + '\n');
      } finally {
        fileIo.closeSync(f);
      }
    } catch (err) {
      // 诊断日志失败不影响主流程
    }
  }

  /** 清空日志（新一轮验证前调用）。 */
  static reset(): void {
    if (AppleDiag.path.length === 0) {
      return;
    }
    try {
      const f = fileIo.openSync(AppleDiag.path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.closeSync(f);
    } catch (err) {
      // 忽略
    }
  }
}
