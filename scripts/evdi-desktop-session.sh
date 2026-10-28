#!/bin/bash
# ============================================================================
# evdi-desktop-session.sh — 参考会话脚本（deploy.sh 会在部署时生成同款并替换路径）
# 这里给出板上生产版本的原样参考（路径以 /brand_data 为例）。
# 组件：xfconfd(配置) + xfsettingsd(X设置) + xfdesktop(桌面) + openbox(窗口管理)
#       + xfce4-panel(顶栏) + xfce4-notifyd(通知)；Thunar/terminal 按需手动开。
# 全部可写路径指到便携 rootfs 内，不写板子只读系统分区。
# ============================================================================
export DISPLAY=:1
R=/brand_data/displaylink/desktop-rootfs
B=$R/usr
export HOME=$R/home
export LD_LIBRARY_PATH=$B/lib/aarch64-linux-gnu
export GDK_PIXBUF_MODULE_FILE=$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache
export GDK_PIXBUF_MODULE_DIR=$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders
export FONTCONFIG_FILE=$R/etc/fonts/fonts.conf
export XDG_CACHE_HOME=$HOME/cache
export XDG_CONFIG_HOME=$HOME/.config
export XDG_DATA_HOME=$HOME/.local/share
export XDG_CONFIG_DIRS=$R/etc:/etc
export XDG_DATA_DIRS=$B/share:/usr/local/share:/usr/share
export XDG_RUNTIME_DIR=/tmp/xfce-runtime
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24
export PATH=$B/bin:$PATH
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

# dbus-run-session 内按序直接拉起（不依赖 dbus 激活——dbus service 路径坑多，直接拉最稳）
exec dbus-run-session -- bash -c '
R=/brand_data/displaylink/desktop-rootfs
B=$R/usr
$B/lib/aarch64-linux-gnu/xfce4/xfconf/xfconfd &        # 1) 配置守护（必须在最前）
sleep 1
$B/bin/xfsettingsd &                                    # 2) X 设置同步
sleep 1
$B/bin/xfdesktop &                                      # 3) 桌面（root 窗口，持续重绘保 DLM 视频流）
sleep 1
$B/bin/openbox &                                        # 4) 窗口管理器（xfwm4 在极简 DriveOS 上起不来）
sleep 2
$B/bin/xfce4-panel &                                    # 5) 顶栏
$B/lib/aarch64-linux-gnu/xfce4/notifyd/xfce4-notifyd &  # 6) 通知守护
wait
'
