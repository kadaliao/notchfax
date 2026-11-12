#!/bin/zsh
# 混音合成：画面 + 旁白 + 配乐（旁白出现时自动压低）+ 引擎音效 → out/Notchfax-promo.mp4
cd "$(dirname "$0")"
LEN=69.5
# 每句旁白的入点（秒），与 Sources/film/main.swift 里的镜头时间表对应
STARTS=(0.9 5.2 9.0 12.6 18.0 24.5 35.1 41.6 50.0 57.8 62.6)
# 后半几句偏抒情、念得慢，略微提速
TEMPO=(1 1 1 1.03 1 1.03 1.08 1.05 1.04 1.07 1.07)
inputs=(); chain=""; mixin=""
for i in {1..11}; do
  n=$(printf %02d $i); ms=$(printf %.0f $((STARTS[i] * 1000)))
  inputs+=(-i out/vo/$n.wav)
  chain+="[$((i+2)):a]aresample=48000,atempo=${TEMPO[i]},adelay=${ms}:all=1[v$i];"; mixin+="[v$i]"
done
ffmpeg -y -loglevel error -i out/video.mp4 -i out/music.wav -i out/sfx.wav $inputs -filter_complex "
${chain}${mixin}amix=inputs=11:normalize=0,highpass=f=70,acompressor=threshold=-20dB:ratio=3:attack=8:release=160:makeup=2,volume=1.9,apad,asplit=2[vo][key];
[1:a]volume=1.15[m];[m][key]sidechaincompress=threshold=0.03:ratio=3.5:attack=80:release=600[music];
[2:a]aresample=48000,highpass=f=90,volume=1.1,pan=stereo|c0=c0|c1=c0[sfx];
[vo]pan=stereo|c0=c0|c1=c0[vos];
[vos][music][sfx]amix=inputs=3:normalize=0,alimiter=limit=0.9,afade=t=out:st=$((LEN-2.2)):d=2.2,loudnorm=I=-15:TP=-1.5:LRA=11[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 256k -ar 48000 -t $LEN -movflags +faststart out/Notchfax-promo.mp4 && echo out/Notchfax-promo.mp4
