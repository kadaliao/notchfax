#!/bin/zsh
# 9:16 竖版（视频号）：时间线和横版完全一样，直接套用横版混好的声音。
# 先跑 ./mix.sh 出横版，再 .build/debug/film --vertical 出竖版画面。
cd "$(dirname "$0")"
ffmpeg -y -loglevel error -i out/v-video-9x16.mp4 -i out/Notchfax-promo.mp4 \
  -map 0:v -map 1:a -c copy -t 69.5 -movflags +faststart out/Notchfax-promo-9x16.mp4 && echo out/Notchfax-promo-9x16.mp4
