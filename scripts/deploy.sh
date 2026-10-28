#!/bin/bash
# ============================================================================
# deploy.sh — 把便携 XFCE rootfs 部署到目标板（NVIDIA DRIVE Thor / DriveOS）
#
# 用法（在构建机上，已 scp desktop-rootfs.tgz 到板 /tmp/）：
#   ssh nvidia@<板IP> 'sudo bash -s' < deploy.sh <板上的rootfs目标路径>
#   例: ssh nvidia@<BOARD-IP> 'sudo bash -s' < deploy.sh /brand_data/displaylink/desktop-rootfs
#
# 前置条件（板上）：
#   - Xorg 已在 :1 跑（evdi card1，见 xorg-evdi.conf 模板）
#   - DLM（DisplayLink 管理器）已注册 painter
#   - 有免密 sudo
#   - 目标路径可写（板上 /brand_data 等数据分区，根分区只读/空间不足）
#
# 本脚本做 5 件事：
#   1. 解包 rootfs 到目标路径
#   2. 修 dbus service 绝对路径（Exec=/usr/... → Exec=<ROOTFS>/usr/...）
#   3. 生成板上缓存（gdk-pixbuf loaders / fontconfig / glib schemas）
#   4. 安放会话脚本 evdi-desktop-session.sh
#   5. 建 systemd 服务 evdi-desktop.service（开机自启 + 失败自拉起）
# ============================================================================
set -euo pipefail

ROOTFS="${1:?用法: deploy.sh <板上rootfs目标路径>}"
TGZ="${2:-/tmp/desktop-rootfs.tgz}"
B="$ROOTFS/usr"

echo "==> ① 解包 rootfs 到 $ROOTFS"
mkdir -p "$ROOTFS"
tar xzf "$TGZ" -C "$ROOTFS" --strip-components=1 2>/dev/null || \
  tar xzf "$TGZ" -C "$(dirname "$ROOTFS")"

echo "==> ② 修 dbus service 绝对路径（关键坑！）"
# deb 里 dbus service 写死 Exec=/usr/bin/xxx，便携 rootfs 不在 /usr，
# 不修则 dbus 激活失败 → xfconfd/Thunar 起不来 → 桌面组件全瘫
find "$B/share/dbus-1" -name "*.service" 2>/dev/null | while read f; do
  sed -i "s|Exec=/usr/|Exec=$ROOTFS/usr/|g" "$f"
done
echo "    已替换: $(grep -rl "Exec=$ROOTFS" "$B/share/dbus-1" 2>/dev/null | wc -l) 个 service 文件"

echo "==> ③ 生成板上缓存"
# 3a. gdk-pixbuf loaders.cache（默认扫系统路径为空，必须显式指到便携 loaders 目录）
QL="$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders/query-loaders"
if [ -x "$QL" ]; then
  GDK_PIXBUF_MODULE_DIR="$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders" \
    "$QL" > "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || true
  echo "    gdk-pixbuf loaders: $(wc -l < "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || echo 0) 个 loader"
fi
# 3b. fontconfig 缓存（板上已有 dejavu 字体，fonts.conf 叠加引用）
if [ -x "$B/bin/fc-cache" ]; then
  "$B/bin/fc-cache" -f "$ROOTFS/etc/fonts" 2>/dev/null || true
  echo "    fontconfig 缓存 OK"
fi
# 3c. glib schemas（用板上原生 glib-compile-schemas，便携包不带）
SCHEMA_DIR="$B/share/glib-2.0/schemas"
if [ -d "$SCHEMA_DIR" ]; then
  SYS_GLIB="/usr/lib/aarch64-linux-gnu/glib-2.0/glib-compile-schemas"
  [ -x "$SYS_GLIB" ] && "$SYS_GLIB" "$SCHEMA_DIR" 2>/dev/null || true
  echo "    glib schemas OK"
fi

echo "==> ④ 安放会话脚本"
mkdir -p "$ROOTFS/home"
SESS_DIR="$(dirname "$ROOTFS")"
mkdir -p "$SESS_DIR"
# heredoc 用引号（保留 $R/$B/$HOME 等运行时变量），ROOTFS 用占位符 __ROOTFS__ 再 sed 替换
cat > "$SESS_DIR/evdi-desktop-session.sh" <<'SESS'
#!/bin/bash
# 完整桌面会话（openbox + XFCE 组件），所有可写路径指向 rootfs 内
export DISPLAY=:1
R=__ROOTFS__
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

exec dbus-run-session -- bash -c '
R=__ROOTFS__
B=$R/usr
$B/lib/aarch64-linux-gnu/xfce4/xfconf/xfconfd &   # 配置守护（必须在最前）
sleep 1
$B/bin/xfsettingsd &                               # X 设置同步
sleep 1
$B/bin/xfdesktop &                                 # 桌面（root 窗口，持续重绘保 DLM 视频流）
sleep 1
$B/bin/openbox &                                   # 窗口管理器（xfwm4 在此环境起不来，用 openbox）
sleep 2
$B/bin/xfce4-panel &                               # 顶栏
$B/lib/aarch64-linux-gnu/xfce4/notifyd/xfce4-notifyd &  # 通知
wait
'
SESS
sed -i "s|__ROOTFS__|$ROOTFS|g" "$SESS_DIR/evdi-desktop-session.sh"
chmod 755 "$SESS_DIR/evdi-desktop-session.sh"
echo "    会话脚本 OK: $SESS_DIR/evdi-desktop-session.sh"

echo "==> ⑤ 建 systemd 服务（开机自启 + 失败自拉起）"
cat > /etc/systemd/system/evdi-desktop.service <<SVC
[Unit]
Description=Dock display - portable XFCE desktop session on :1
After=xorg-evdi.service
Requires=xorg-evdi.service

[Service]
Type=simple
ExecStart=$SESS_DIR/evdi-desktop-session.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable evdi-desktop.service
echo "    evdi-desktop.service 已启用"

echo ""
echo "============================================================"
echo "部署完成。启动桌面："
echo "  systemctl start evdi-desktop.service"
echo "验收："
echo "  systemctl is-active evdi-desktop.service"
echo "  ps aux | grep -E 'openbox|xfce4-panel|xfdesktop' | grep -v grep"
echo "============================================================"
