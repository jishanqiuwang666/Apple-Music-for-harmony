/*
 * Widevine L3 设备凭证（WVD）的**本地**配置（仓库里的版本是空模板）。
 *
 * 为什么单独一个文件：WVD 是第三方（Google/设备厂商）的专有凭据，不能随仓库分发。
 *   - 仓库跟踪 WvdLocal.example.ets（空串）；
 *   - 本机自用：复制成 WvdLocal.ets（已 gitignore）并填入自己的 WVD base64，
 *     构建出来的包才能解密播放；
 *   - 别人克隆仓库：build.sh 会自动复制模板（空），编译通过但不能播放受 DRM 保护的音频。
 */
export const LOCAL_WVD_BASE64: string = '';
