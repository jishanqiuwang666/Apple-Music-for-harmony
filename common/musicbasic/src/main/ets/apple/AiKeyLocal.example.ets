/*
 * AI 翻译 key 的**本地**配置（仓库里的版本是空模板）。
 *
 * 为什么单独一个文件：key 是账号级凭据，不能进仓库。
 *   - 仓库里跟踪的是 AiKeyLocal.example.ets（LOCAL_AI_KEY 为空串）；
 *   - 本机自用：把本文件复制成 AiKeyLocal.ets（已在 .gitignore 里），填上自己的 key，
 *     构建出来的包就自带 key，装完即用；
 *   - 别人克隆仓库：build.sh 会自动把模板复制成 AiKeyLocal.ets，编译通过但没有 key，
 *     需要在「设置 → AI 翻译」里自己填。
 */
export const LOCAL_AI_KEY: string = '';
