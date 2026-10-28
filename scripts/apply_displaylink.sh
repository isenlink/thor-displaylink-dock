#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  apply_displaylink.sh — DRIVE Thor (DriveOS) DisplayLink/evdi driver idempotent restore v1.2
#
#  母本(master copy): /brand_data/persist/displaylink/master/
#  落位(targets):     /var/lib/displaylink/ + /var/lib/xorg-evdi/xorg-evdi.conf
#                     /etc/systemd/system/{displaylink-driver,xorg-evdi,evdi-desktop}.service
#                     (+enable 软链) + /etc/udev/rules.d/99-displaylink.rules
#
#  调用方: 板上开机钩子链（rw_overlay / do_write_patch 类）或 systemd oneshot，见 docs/04
#  v1.1:  ①缺哪个补哪个(永不覆盖活体,免 Text file busy)
#         ②补 systemctl enable(脏断电后 wants 软链也会丢)
#  v1.2:  ③桌面 unit(xorg-evdi/evdi-desktop)纳入保护清单
#         ——脏断电实测: 两桌面 unit 在 overlay 被吞, 母本未含 → 桌面不自启
#  设计:  fail-open / 幂等 / 不重启已跑服务
#  版本:  v1.2-20261028 (field-tested)
# ═══════════════════════════════════════════════════════════════════════
M=/brand_data/persist/displaylink/master
LOGTAG="[apply_displaylink]"

# 活体健康判定: 核心件齐 + 三服务已 enable = 无需动作
if [ -f /var/lib/displaylink/evdi.ko ] \
   && [ -f /var/lib/displaylink/DisplayLinkManager ] \
   && [ -f /etc/systemd/system/displaylink-driver.service ] \
   && [ -f /etc/systemd/system/xorg-evdi.service ] \
   && [ -f /etc/systemd/system/evdi-desktop.service ] \
   && [ -f /etc/udev/rules.d/99-displaylink.rules ] \
   && [ -f /var/lib/xorg-evdi/xorg-evdi.conf ] \
   && systemctl is-enabled displaylink-driver.service >/dev/null 2>&1 \
   && systemctl is-enabled xorg-evdi.service >/dev/null 2>&1 \
   && systemctl is-enabled evdi-desktop.service >/dev/null 2>&1; then
  echo "$LOGTAG $(date '+%F %T') healthy, skip"
  exit 0
fi

echo "$LOGTAG $(date '+%F %T') 检测到缺失, 开始逐件拷回"
[ -d /var/lib/displaylink ] || mkdir -p /var/lib/displaylink
[ -d /var/lib/xorg-evdi ] || mkdir -p /var/lib/xorg-evdi
[ -d /etc/systemd/system ] || mkdir -p /etc/systemd/system
[ -d /etc/udev/rules.d ] || mkdir -p /etc/udev/rules.d

# ① 驱动目录: 逐件"缺才拷"(不碰在跑二进制)
for f in "$M"/var/lib/displaylink/*; do
  b=$(basename "$f")
  if [ ! -e "/var/lib/displaylink/$b" ]; then
    cp -a "$f" /var/lib/displaylink/ 2>&1 | sed "s/^/$LOGTAG cp $b: /"
    echo "$LOGTAG + 拷回 $b"
  fi
done

# ② 其余件: 缺才拷(含 v1.2 新增的两个桌面 unit)
[ -f /var/lib/xorg-evdi/xorg-evdi.conf ] || cp -a "$M/var/lib/xorg-evdi/xorg-evdi.conf" /var/lib/xorg-evdi/
[ -f /etc/systemd/system/displaylink-driver.service ] || cp -a "$M/etc/systemd/system/displaylink-driver.service" /etc/systemd/system/
[ -f /etc/systemd/system/xorg-evdi.service ] || cp -a "$M/etc/systemd/system/xorg-evdi.service" /etc/systemd/system/
[ -f /etc/systemd/system/evdi-desktop.service ] || cp -a "$M/etc/systemd/system/evdi-desktop.service" /etc/systemd/system/
[ -f /etc/udev/rules.d/99-displaylink.rules ] || cp -a "$M/etc/udev/rules.d/99-displaylink.rules" /etc/udev/rules.d/

# ③ 配置重载 + enable(wants 软链丢了也能重建,幂等)
[ -d /run/systemd/system ] && systemctl daemon-reload 2>/dev/null
systemctl enable displaylink-driver.service >/dev/null 2>&1
systemctl enable xorg-evdi.service >/dev/null 2>&1
systemctl enable evdi-desktop.service >/dev/null 2>&1
udevadm control --reload 2>/dev/null

# ④ 自验
FAIL=0
for f in /var/lib/displaylink/evdi.ko \
         /var/lib/displaylink/DisplayLinkManager \
         /etc/systemd/system/displaylink-driver.service \
         /etc/systemd/system/xorg-evdi.service \
         /etc/systemd/system/evdi-desktop.service \
         /etc/udev/rules.d/99-displaylink.rules \
         /var/lib/xorg-evdi/xorg-evdi.conf; do
  [ -f "$f" ] || { echo "$LOGTAG ✗ 缺 $f"; FAIL=1; }
done
for s in displaylink-driver.service xorg-evdi.service evdi-desktop.service; do
  systemctl is-enabled "$s" >/dev/null 2>&1 || { echo "$LOGTAG ✗ $s 未 enable"; FAIL=1; }
done
[ "$FAIL" = "0" ] && echo "$LOGTAG ✓ $(date '+%F %T') 拷回完成,七件+三服务enable 全在位" \
                  || echo "$LOGTAG ✗ $(date '+%F %T') 不完整,待下轮重试"
exit 0
