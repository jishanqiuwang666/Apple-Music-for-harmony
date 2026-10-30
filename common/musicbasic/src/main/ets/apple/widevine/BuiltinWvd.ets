/*
 * 内置 WVD 的唯一出口。
 *
 * 真正的字符串在未跟踪的 `WvdLocal.ets` 里（仓库跟踪的是空模板 WvdLocal.example.ets），
 * 详见那个文件的说明。这样仓库与分发包都不携带任何 DRM 凭据。
 */
export { LOCAL_WVD_BASE64 as BUILTIN_WVD_BASE64 } from './WvdLocal';
