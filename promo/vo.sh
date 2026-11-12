#!/bin/zsh
# 生成旁白：每句一个文件，out/vo/NN.wav（24kHz 单声道）。
S=~/.claude/skills/tts/scripts/tts.py
STYLE="warm, friendly and confident narrator of a product film, natural brisk conversational pace, light and lively, a smile in the voice, never slow or drawn out"
VOICE=${VOICE:-Charon}
cd "$(dirname "$0")"
mkdir -p out/vo
i=0
while IFS= read -r line; do
  i=$((i+1)); n=$(printf %02d $i)
  [ -s out/vo/$n.wav ] && continue
  for try in 1 2 3; do
    $S "$line" --voice $VOICE --style "$STYLE" -o out/vo/$n.wav >/dev/null 2>out/vo/$n.log && break
    sleep 2
  done
done < vo.txt
