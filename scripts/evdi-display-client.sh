#!/bin/bash
# 全屏 xclock 窗口 = 整屏底色 + 中间走时；-update 1 每秒重绘保持 DLM 视频流。
# （xsetroot 的 root 背景在此最小 Xorg 配置下不落 framebuffer，弃用——只推一帧，屏"闪一下就黑"）
export DISPLAY=:1
export LD_LIBRARY_PATH=/var/lib/displaylink
exec /var/lib/displaylink/xclock -digital -update 1 -geometry 1920x1080+0+0 -bg steelblue -fg white
