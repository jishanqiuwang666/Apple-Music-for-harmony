# 播放中断：队列 id 失效 + 看门狗自愈（2026-10-18）

## 用户反馈

> 现在还是有播放 bug，在专辑播放完第一首歌曲之后，后续的歌曲就播放不了了，
> 手动点击也没用，必须退出应用后再点击。

关键信息：**整条链路失效、点击无反应、重启 App 才恢复** —— 这是「进程内状态坏了」，
不是某首歌的数据问题。

## 根因（数据面 + 代码面两处）

### 1. 内存队列存的是「自增 id」，而 songs 表每次同步都会被重建

`MusicDatabase.syncAppleSongs`（≈836 行）：

```
DELETE FROM songs WHERE folder = 'apple'   // 全删
批量 insert（AUTOINCREMENT）               // id 全部重排
```

于是任何一次资料库同步（启动后那轮、或用户手动同步）都会让 **songs 表所有 Apple 曲目的 id 变化**。
而内存里的播放队列 `MusicAppState.playQueueIds` 是同步前抓的快照：

- 正在播的那一首已经装进 AVPlayer → 不受影响，**所以「第一首能播」**；
- 第一首播完 → `playNext()` → `loadAsset(1)` → `resolveSongAtQueueIndex(1)` →
  `getSongById(旧id)` 查不到 → **`loadAsset` 直接 `return`**（只写一行 error 日志）→ 什么都不播；
- 用户点列表 = 同一套 resolve → **同样静默失败**，看起来就是「点了没反应」；
- 重启 App：队列从新表重建，id 有效 → 恢复正常。

这解释了为什么「必须退出应用后再点击」。

### 2. 静默失败：resolve 失败就 return，没有第二道防线

`loadAsset` 里 resolve 失败只打日志；`play()` 依赖 `isPrepared`，而这一首从没 prepared 过，
UI 的播放/暂停按钮表现为「完全没反应」。看门狗缺失导致一旦断链就永久断链。

## 修复（4 处）

| 位置 | 改动 |
|---|---|
| `common/musicbasic/src/main/ets/model/MusicAppState.ets` | `resolveSongAtQueueIndex`：按 id 查不到时，用**稳定的 `playQueueUris[index]`** 反查 `getSongByUri`，命中就把 `playQueueIds[index]` **就地修好**再返回。一处兜底覆盖所有入口（自动切歌 / 点列表 / 小组件 / 播放历史）。 |
| `features/player/src/main/ets/model/MediaService.ets` | `loadAsset`：resolve 仍失败时先 `remapQueueAfterSync()`（按 uri 全队列对账）再解析一次；还是失败才提示「这首歌已不在资料库里」。 |
| 同上 | **看门狗**：构造函数启动 1s 定时器，每秒核对「意图 vs 实际」：① 进了 `completed` 2.5s 还没换轨 → 强制 `playNextAuto`；② `isPlay=true` 但 6s 都没 prepared（装载链中途断了）→ 重建当前曲目。连续自愈上限 3 次，之后就停手并收回 `isPlay`，避免无限重试；用户任何主动操作（点播/切歌/真正就绪）都会把额度重置。 |
| 同上 | 健壮性细节：`playheadMs/getCurrentTime/getDuration` 的 AVPlayer 属性读取加 try/catch（读已释放实例会抛，抛出去会把整条装载链打断）；`playNext/playPrevious/playRandom/play()` 里的 `loadAsset` 全部挂 catch，不再产生未处理的 Promise 拒绝。 |

## 验证（真机回归）

自检脚本：程序化播整张专辑 → 把内存队列的 id **全部注入成非法值**（`[0,0,0,…]`，等价于同步后 id 悬空）
→ 同一拍立刻切下一首（不给任何顺带修复留时间）。

```
TEMP-PLAYBUG badIdsAdvance ids=0,0,0
TEMP-PLAYBUG badIdsAdvance load resolved
AVPlayer prepared succeeded.
TEMP-PLAYBUG t1 idx=1/12 prepared=true isPlay=true playhead=192 ids0=0 id1=75506
```

`ids0` 仍是 0（没动过的索引保持原样），`id1` 已被修成真实 id —— 印证是「按 uri 就地修复」
这一层救回来的；第 2 首正常装载、正常出声。auto-next（completed → 下一首）在 id 悬空时同样正常。

清理自检代码后出正式包，装真机验证：启动正常、`restored session: queue=12 index=1 pos=34538 kind=album`
（队列与断点续播也完好）。

## 复用经验（写进全局记忆）

1. **「内存列表里存自增主键」+「源头表会被 DELETE 重插」= 定时炸弹**：同步/重建只影响后续解析，
   当前正在用的那条看不出问题，表现成「用了几个之后突然全体失效、重启就好」。
   对策：内存里同时保存**稳定自然键**（这里是 `apple:<songId>` 的 uri），解析失败时按自然键兜一次，
   并顺手把派生 id 修回去。
2. **任何「解析不到就 return」的分支都必须有第二道防线**（重映射 / 重试 / 提示），
   否则用户看到的是「点了完全没反应」，而日志里只有一行 error。
3. **播放器这类多段异步链，加一层 1s 看门狗核对「意图 vs 实际」比逐段堵漏可靠**：
   历史上这条链断过三次（实例回调串台、prepared 事件丢失、id 悬空），每次断法都不同，
   但用户感知完全一样。看门狗把「未知断法」统一收敛成「最多 6s 自愈」。
