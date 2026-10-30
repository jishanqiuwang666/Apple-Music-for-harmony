#!/usr/bin/env bash
# 把一段手机录屏（mp4/mov）压成 README 里能内嵌播放的 GIF。
#
# 用法（全部参数都是 ASCII，安全）：
#   bash tools/apple-music/make-demo-gif.sh IN.mp4 OUT.gif [START] [DUR] [WIDTH] [FPS] [SPEED]
#     START  从第几秒开始裁（默认 0）
#     DUR    取多长（默认 6）
#     WIDTH  输出宽度 px（默认 480；GIF 体积与 WIDTH^2 成正比）
#     FPS    帧率（默认 20；逐字填充类动效低于 15 会看出跳跃）
#     SPEED  播放速度倍数（默认 1；0.6 = 慢放，便于看清逐字）
#
# 输出体积目标：< 8MB（GitHub README 内嵌图超过 10MB 会明显卡，且大图不预加载）
set -euo pipefail

IN=${1:?input video required}
OUT=${2:?output gif required}
START=${3:-0}
DUR=${4:-6}
WIDTH=${5:-480}
FPS=${6:-20}
SPEED=${7:-1}

command -v ffmpeg >/dev/null || { echo "ffmpeg not found"; exit 1; }

# 两遍法：先生成专用调色板，再按调色板 dither，暗色 UI 上的文字边缘才不会糊成光晕。
PAL=$(mktemp -t demo-pal).png
trap 'rm -f "$PAL"' EXIT

FILTER_BASE="setpts=(PTS-STARTPTS)/${SPEED},fps=${FPS},scale=${WIDTH}:-1:flags=lanczos"

ffmpeg -hide_banner -loglevel error -y -ss "$START" -t "$DUR" -i "$IN" \
  -vf "${FILTER_BASE},palettegen=max_colors=192:stats_mode=diff" "$PAL"

ffmpeg -hide_banner -loglevel error -y -ss "$START" -t "$DUR" -i "$IN" -i "$PAL" \
  -lavfi "${FILTER_BASE} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 "$OUT"

SIZE=$(stat -f%z "$OUT")
echo "OK $OUT  $((SIZE/1024)) KB  (${WIDTH}px ${FPS}fps ${DUR}s x${SPEED})"
if [ "$SIZE" -gt 9500000 ]; then
  echo "WARN > 9.5MB：请调小 WIDTH / DUR，或减少 FPS"
fi
