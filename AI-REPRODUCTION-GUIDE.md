# AI 复现手册（AI-REPRODUCTION-GUIDE）

**读者**：没有任何历史记忆的 AI 助手（或人），拿到一台 NVIDIA DRIVE Thor / DriveOS 车机域控板 + Dell D6000（DisplayLink `17e9:6006`）坞 + 显示器，要把坞屏点亮并装上可自愈的桌面。

**总原则**：
1. **第 0 步必须做基线记录**——跳过它，后面所有"成功/失败"都无法判定。
2. **每一步按【判据】验收，且判据必须核对时间戳属于本轮**——旧日志是最容易的假绿（文件非空 ≠ 本轮产生）。
3. 屏幕亮没亮的最终判定 = **人眼看屏**。内核日志、xrandr、EDID 全绿都**不**等于屏亮（本仓历史教训，两次误判）。
4. 路径占位：`<BOARD-IP>`=板子 IP；`/brand_data`=板上可写持久分区（`ls /` 找形如 `<厂商>_data` 的大分区，下同）；`$ROOTFS`=桌面 rootfs 落点（本文用 `/brand_data/displaylink/desktop-rootfs`）。

---

## A0. 基线记录（只读，5 分钟，不可跳）

```bash
ssh nvidia@<BOARD-IP> '
  uname -a
  lsmod | grep -c evdi || true                 # 期望 0（装前）
  ls /usr/lib/modules/$(uname -r) 2>/dev/null | head -3
  ls /var/lib/displaylink 2>/dev/null          # 期望不存在（裸板）
  systemctl is-active displaylink-driver 2>/dev/null || echo no-driver
  lsusb | grep -i 17e9                         # 坞在不在（显示器必须已插坞！）
  df -h /                                      # 只读？空间多少？
  ls /                                         # 找持久分区名
'
```

**判据**：命令全部 rc=0（grep -c 为 0 也算完成）；拿到持久分区名；`lsusb` 见 `17e9:` 开头的坞。
**失败排查**：lsusb 无 17e9 → 换 USB 口/换线/确认坞上电；`df -h /` 显示根分区可写且 >2G 可用 → 你可能不在 DriveOS 板上，本文 03/04 章可跳过部分加固步骤。

**把 A0 输出原样存到 `/tmp/baseline-$(date +%s).txt`**——这是后面所有对照的锚。

---

## A1. 判环境：你有哪条路（只读）

| 你的情况 | 走哪条 |
|---|---|
| 板上已有 `/var/lib/displaylink/DisplayLinkManager` + `evdi.ko` | 跳到 **A4**（栈已在，缺的是 X 会话层） |
| 板上无驱动，但板能上外网/有驱动仓库 | 按 docs/01 在板上装驱动 → A4 |
| 板上无驱动且无法安装（只读 rootfs、无网） | 需要从另一台已装好的机器**拷驱动目录**（见 A2），或走厂商通道 |
| 只想把坞接到 x86 Linux 机器先验证坞+显示器是好的 | docs/01（强烈建议先做，排除硬件嫌疑） |

**判据**：明确知道自己处于哪一格，写进你自己的工作笔记。

---

## A2.（仅当板上缺驱动）驱动件从哪来、放到哪

板上驱动件清单（与 x86 安装包同源，见 docs/01）：`evdi.ko`（**必须对本板内核编译**或取同内核版本产物）、`DisplayLinkManager`、`libevdi.so`、`libusb-1.0.so.0.6.0`、`ella/firefly/navarro/ridge-dock-release.spkg`（固件包，DLM 运行需要）、`udev.sh`、`xclock/xrandr/xset/xsetroot`（DLM 自带小工具）、`libXft.so.2`、`99-displaylink.rules`、`LICENSE`、`MANIFEST.sha256`。

落位（本仓已验证的布局）：

```bash
ssh nvidia@<BOARD-IP> 'sudo -n mkdir -p /var/lib/displaylink /var/lib/xorg-evdi'
# scp 上述文件到板 /tmp 后：
ssh nvidia@<BOARD-IP> 'sudo -n cp -a /tmp/dl-driver/* /var/lib/displaylink/ && sudo -n cp -a /tmp/dl-driver/99-displaylink.rules /etc/udev/rules.d/'
```

**判据**：`sudo -n ls /var/lib/displaylink | wc -l` ≥ 13；`sudo -n sha256sum -c /var/lib/displaylink/MANIFEST.sha256` 全过（若源带清单）。
**假绿警告**：`evdi.ko` 必须匹配本板内核（`uname -r`）——版本不符时 `insmod` 报 `Invalid module format`，这是硬失败不是警告。

## A3. 驱动服务三件

```bash
# ① DLM 服务（本仓 configs/displaylink-driver.service，含板上 libusb preload 兼容层）
ssh nvidia@<BOARD-IP> 'sudo -n cp /tmp/displaylink-driver.service /etc/systemd/system/'
# ② udev 规则（configs/99-displaylink.rules，上游原样）
# ③ enable + 起
ssh nvidia@<BOARD-IP> 'sudo -n systemctl daemon-reload && sudo -n systemctl enable --now displaylink-driver.service'
```

**判据**：`systemctl is-active displaylink-driver` = active；`pgrep -f DisplayLinkManager` 有 PID（**不要** `pgrep -x`——进程名超 15 字符，-x 必失败）；`dmesg | grep evdi` 见 `evdi: Probe...` 或 `evdi: Initial tile...` 类探测行，且时间戳是刚才。
**失败排查**：inactive → `journalctl -u displaylink-driver -n 30`（无输出≠没跑，DriveOS 部分 unit 日志进内存 buffer）；DLM 起了但几秒退出 → 多半 evdi.ko 内核版本不符或 spkg 固件缺失。

---

## A4. X 会话层（三层根因的第 1、2 层）——本仓最核心的一步

裸板到"屏上出现画面"的最小路径（蓝色全屏时钟）：

```bash
# ① 最小 Xorg 配置（configs/xorg-evdi.conf 原样）
ssh nvidia@<BOARD-IP> 'sudo -n cp /tmp/xorg-evdi.conf /var/lib/xorg-evdi/xorg-evdi.conf'
# ② 手动起 Xorg :1 验证（先不建服务）
ssh nvidia@<BOARD-IP> 'sudo -n /usr/bin/Xorg :1 -config /var/lib/xorg-evdi/xorg-evdi.conf -logfile /var/lib/xorg-evdi/Xorg.1.log & sleep 8; tail -5 /var/lib/xorg-evdi/Xorg.1.log'
# ③ 全屏时钟客户端（configs/evdi-display-client.sh，DLM 自带 xclock 依赖同目录 libXft.so.2）
ssh nvidia@<BOARD-IP> 'sudo -n bash /tmp/evdi-display-client.sh & sleep 5'
```

**判据（逐条，缺一不可）**：
1. `Xorg.1.log` 有 `Screens setup complete` 且无 `(EE)` 致命行；
2. `dmesg | tail` 出现 `evdi ... Notifying display power state: on` 和 `Notifying mode changed: 1920x1080@60`（或你显示器的真实 mode），时间戳为本轮；
3. `xrandr`（`DISPLAY=:1`，DLM 目录下自带）显示 connected + 1920x1080；
4. **人眼看屏：全屏蓝底、中间走时数字**。前三条全绿但屏黑 = 还是没成，回到 docs/02 排查矩阵。

**失败排查表**：

| 症状 | 根因层 | 处置 |
|---|---|---|
| evdi 卡 connected、modes 空、edid_len=0 | 无 X 会话开 card1 | 本文 A4-② |
| 屏"闪一下就黑" | 客户端只画了一帧（如 `xsetroot -solid` 一次性填色） | 换持续重绘客户端（xclock `-update 1`），**xsetroot 在此配置下不落 framebuffer，弃用** |
| 全黑但角落一小块有时钟 | 时钟窗口不是全屏 geometry | `-geometry 1920x1080+0+0` 全屏 |
| 屏亮但只有一小块蓝、其余黑 | 同上（root 背景不落 fb） | 全屏窗口方案 |
| xclock 秒退 | 缺 libXft.so.2 | `LD_LIBRARY_PATH=/var/lib/displaylink` 必须设 |
| mode changed 有了、屏还是黑 | 坞显示通道 | docs/05 的 USB 授权翻转 + 协议录制 |

## A5. 服务持久化（重启安全）

把 A4 的手动验证固化为两个 unit（本仓 configs/ 原样）：

```bash
ssh nvidia@<BOARD-IP> '
  sudo -n cp /tmp/xorg-evdi.service /etc/systemd/system/
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now xorg-evdi.service
  sleep 8
  systemctl is-active xorg-evdi && sudo -n bash /tmp/evdi-display-client.sh &
'
```

**判据**：`systemctl is-active xorg-evdi` = active；屏上时钟仍在；`sudo -n reboot`（**先确认板子 load 正常，见 docs/04 的 reboot 陷阱**）后两分钟内屏自动恢复时钟。
**已知怪相（勿"修复"）**：板上 `xorg-evdi.service` 的 `After=/Wants= displaylink.service` 引用了一个**不存在**的 unit（真名是 `displaylink-driver.service`）。systemd 对不存在的引用静默忽略，实测无害——别改名、别删行，保持与 production 一致。

## A6. 完整桌面（XFCE 便携 rootfs）——可选升级

走 docs/03：构建机 `scripts/build-portable-rootfs.sh` → `scp` → 板上 `sudo bash scripts/deploy.sh /brand_data/displaylink/desktop-rootfs /tmp/desktop-rootfs.tgz` → disable 时钟客户端、enable `evdi-desktop.service`。

**判据**：`systemctl is-active evdi-desktop` = active；板上 6 组件进程齐（xfconfd/xfsettingsd/xfdesktop/openbox/xfce4-panel/xfce4-notifyd）；**屏上出现顶栏+桌面**；坞 USB 键盘开一个终端能打字。
**假绿警告**：deploy.sh 输出"部署完成"≠桌面在跑——必须 ps 核对 6 组件 + 肉眼看屏。

## A7. 脏断电自愈（DriveOS 板强烈建议）

```bash
ssh nvidia@<BOARD-IP> '
  sudo -n mkdir -p /brand_data/persist/displaylink/master
  sudo -n cp -a /var/lib/displaylink /brand_data/persist/displaylink/master/var-lib-displaylink   # 母本
  sudo -n cp /tmp/apply_displaylink.sh /brand_data/persist/displaylink/                            # 本仓 scripts/
  # 挂开机钩子（板上已有 rw_overlay 钩子链时追加一行；没有则用 systemd oneshot，见 docs/04）
'
```

**端到端验收（必须做，不许只看脚本 exit 0）**：模拟脏断电——`sudo -n rm /etc/systemd/system/xorg-evdi.service /etc/systemd/system/evdi-desktop.service && sudo -n rm -f /etc/systemd/system/multi-user.target.wants/{xorg-evdi,evdi-desktop}.service && systemctl is-enabled xorg-evdi`（应回 `not-found`）→ 跑 apply 脚本 → 判据：两 unit 恢复 + `is-enabled` = enabled + `is-active` = active + 屏上画面回来。**历史教训**：v1.1 只查"母本在不在"（恒在）就报 healthy——假阴性；v1.2 改为查**落位件+enable 状态**，本仓 scripts/apply_displaylink.sh 已是 v1.2。

## A8. 终验清单（全部满足才算复现成功）

- [ ] `systemctl is-active displaylink-driver xorg-evdi evdi-desktop` 三连 active（若走了 A6）
- [ ] 6 组件进程齐（ps 核对）
- [ ] 屏上：全屏桌面（或 A5 路线的全屏时钟），1920x1080
- [ ] 坞 USB 键盘鼠标可用（开终端打字验证）
- [ ] kill 任一组件 → ≤5s 自动拉起
- [ ] `sudo -n reboot` → 桌面自动恢复
- [ ] 模拟脏断电 → apply 脚本拉回全链
- [ ] A0 基线对照：所有"新出现"的件都能指出来源步骤

## 附：本仓已验证环境与你环境的差异点

| 项 | 本仓验证值 | 你需要自查的 |
|---|---|---|
| 内核 | 6.1.119-rt45（DriveOS 实时_vendor 构建） | `uname -r`；evdi.ko 必须匹配 |
| 板载 glibc | 2.39（与 Ubuntu noble 同版，rootfs 二进制直接跑） | `ldd --version`；低于 2.39 时 rootfs 内二进制会报 GLIBC 版本错，需改用低版本 suite 构建 |
| 显示器 | 27 寸 1080p | 分辨率不同时 xclock geometry 跟着改 |
| 坞 | D6000（17e9:6006） | 其他 DisplayLink 坞 ID 不同，udev 规则通用（按 17e9/* 匹配） |
| Xorg 路径 | /usr/bin/Xorg | `which Xorg` |
