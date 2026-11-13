#!/bin/zsh
# README 里的演示动画：从宣传片画面（out/video.mp4，无声）截几段，压成循环播放的动画 WebP，
# 放进 ../docs/media/。先用 .build/debug/film 渲染出 out/video.mp4。
#
#   ./readme-media.sh            全部重做
#   ./readme-media.sh memories   只做一段
#
# 时间点对应 Sources/film/main.swift 里的镜头表；改了片子要回来对一遍。
set -euo pipefail
cd "$(dirname "$0")"
SRC=out/video.mp4
DEST=../docs/media
FPS=15
mkdir -p "$DEST"
[ -f "$SRC" ] || { echo "缺 $SRC：先渲染宣传片" >&2; exit 1; }

# 名字  宽度  片段（起点:时长，可以多段，按顺序硬切拼起来）
typeset -A WIDTH CUTS
WIDTH[overview]=960;  CUTS[overview]="9.3:2.6 15.2:3.2 29.4:3.4 44.0:2.8 51.6:3.6"
WIDTH[memories]=720;  CUTS[memories]="13.2:7.8"
WIDTH[photobooth]=720; CUTS[photobooth]="24.8:8.6"
WIDTH[fax]=720;       CUTS[fax]="36.0:5.0 42.0:6.6"
WIDTH[receipt]=720;   CUTS[receipt]="50.0:6.4"

names=("$@")
(( $#names )) || names=(overview memories photobooth fax receipt)
for name in $names; do
  work=$(mktemp -d)
  i=0
  for cut in ${(s: :)CUTS[$name]}; do
    start=${cut%%:*}; length=${cut##*:}
    ffmpeg -v error -ss $start -t $length -i $SRC \
      -vf "fps=$FPS,scale=${WIDTH[$name]}:-2:flags=lanczos" "$work/$(printf %02d $i)-%04d.png"
    i=$((i + 1))
  done
  frames=($work/*.png)
  # 有损压缩、每帧 1000/FPS 毫秒、无限循环；-mixed 让静止的地方自动用无损块
  img2webp -loop 0 -d $((1000 / FPS)) -mixed -q 72 -m 6 $frames -o "$DEST/$name.webp" >/dev/null
  rm -rf "$work"
  printf '%-12s %s\n' $name "$(du -h "$DEST/$name.webp" | cut -f1)"
done
