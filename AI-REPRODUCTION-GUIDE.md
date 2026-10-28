# AI 复现手册（AI-REPRODUCTION-GUIDE）

**读者**：没有任何历史记忆的 AI 助手（或人），拿到一台 NVIDIA DRIVE Thor / DriveOS 车机域控板 + Dell D6000（DisplayLink `17e9:6006`）坞 + 显示器，要把坞屏点亮并装上可自愈的桌面。

**总原则**：
1. **第 0 步必须做基线记录**——跳过它，后面所有"成功/失败"都无法判定。
2. **每一步按【判据】验收，且判据必须核对时间戳属于本轮**——旧日志是最容易的假绿（文件非空 ≠ 本轮产生）。
3. 屏幕亮没亮的最终判定 = **人眼看屏**。内核日志、xrandr、EDID 全绿都**不**等于屏亮（本仓历史教训，两次误判）。
4. 路径占位：`<BOARD-IP>`=板子 IP；`/brand_data`=板上可写持久分区的**占位写法**（`ls /` 找形如 `<厂商>_data` 的大分区，下同）。**所有脚本把 `/brand_data` 写死为占位符**——你的分区名不同时，先 `sed -i 's|/brand_data|/你的分区|g'` 替换仓库内脚本再上传。
5. SSH 会话里启动长驻进程一律 `nohup setsid ... >/dev/null 2>&1 &`——裸 `&` 在 SSH 断开时会被 SIGHUP 杀掉，造成"时好时坏"假象。

---

## A0. 基线记录（只读，5 分钟，不可跳）

```bash
ssh nvidia@<BOARD-IP> '
  uname -a
  lsmod | grep -c evdi || true                  # 期望 0（装前）；非 0 说明栈已在 → A1 第 1 格
  ls /var/lib/displaylink 2>/dev/null || echo "no-driver-dir"
  systemctl is-active displaylink-driver 2>/dev/null || echo no-driver
  lsusb | grep -i 17e9                          # 坞在不在（显示器必须已插坞！）
  df -h /
  ls /
  sudo -n true && echo SUDO-OK                  # 免密 sudo 验证（后续全部 sudo -n 依赖它）
'
```

**判据**：SSH 通；`SUDO-OK` 出现；`lsusb` 见 `17e9:` 开头的坞；`ls /` 里认出了持久分区名。
**失败排查**：lsusb 无 17e9 → 换 USB 口/换线/确认坞上电（显示器必须插在坞上）；`sudo -n true` 失败 → 先解决免密 sudo（DriveOS 板 `nvidia` 账号通常已配 NOPASSWD；没有则配好再继续）。

**基线留档**：输出存**两份**——本机工作目录 `baseline-$(date +%F-%H%M).txt`（对照用）+ 板上 `/tmp/baseline.txt`（下轮会话可直接查）。`/tmp` 断电即失，别只存板上。

---

## A1. 判环境：你有哪条路（只读）

| 你的情况 | 走哪条 |
|---|---|
| 板上已有 `/var/lib/displaylink/DisplayLinkManager` + `evdi.ko` | 跳到 **A4**（栈已在，缺的是 X 会话层） |
| 板上无驱动 | 走 **A2**（拿到驱动件 → 文件级落位） |
| 只想把坞接到 x86 Linux 机器先验证坞+显示器+线是好的 | docs/01 路线 A（强烈建议先做，排除硬件嫌疑） |

**判据**：明确知道自己处于哪一格，写进你的工作笔记。

⛔ **驱动来源硬约束（先读再动手）**：`evdi.ko` 是**内核模块**，必须匹配本板 `uname -r`（vermagic 一致），x86 机器上的或别的内核版本的**装不上**（insmod 报 `Invalid module format`，硬失败）。合法来源只有三种，见 docs/01「路线 B 的驱动件来源」。这是全流程第一道墙，过不去就先解决它，别往后走。

---

## A2. 拿驱动件 + 暂存到板上 /tmp

**驱动件来源（四选一，按顺序试）**：
1. **本仓 Release 资产 `dl-driver-stack.tgz`**——板上生产驱动整包（DLM 6.4.0-22 / evdi 1.15.1 / vermagic `6.1.119-rt45-prod-rt-tegra aarch64`）。你的板 `uname -r` 与之一致就直接用（A2 判据里的 vermagic 校验必做）；
2. 板子厂商 BSP/驱动仓库里有现成 `evdi.ko`（同内核编译）→ 次优；
3. 另一块**同内核版本**（`uname -r` 相同）的板上已装好 → 整目录拷（`/var/lib/displaylink/` 全部 + `/etc/udev/rules.d/99-displaylink.rules` + 三个 unit）；
4. 从 Synaptics 官方 `.run` 包解出用户态件（DLM/spkg/libevdi/x 工具），`evdi.ko` 单独对板内核编译（需要板内核头文件与编译环境，DriveOS 板上通常不可行，交叉编译超出本仓范围）。

详见 docs/01「路线 B 的驱动件来源」对照表。

**暂存块（一次传齐，后续步骤都从 /tmp 拿）**——在本机仓库根目录执行：

```bash
BOARD=nvidia@<BOARD-IP>
scp configs/displaylink-driver.service configs/xorg-evdi.service \
    configs/evdi-display-client.service configs/xorg-evdi.conf \
    scripts/evdi-display-client.sh scripts/apply_displaylink.sh $BOARD:/tmp/
# 驱动目录（来源 2 时）：
scp -r <驱动目录>/* $BOARD:/tmp/dl-driver/
```

落位（本仓已验证的布局）：

```bash
ssh $BOARD 'sudo -n mkdir -p /var/lib/displaylink /var/lib/xorg-evdi'
ssh $BOARD 'sudo -n cp -a /tmp/dl-driver/* /var/lib/displaylink/ && sudo -n cp -a /tmp/dl-driver/99-displaylink.rules /etc/udev/rules.d/'
```

**判据（按文件名清单，不数总数）**：`sudo -n ls /var/lib/displaylink` 至少含 `DisplayLinkManager`、`evdi.ko`、`libevdi.so.*`、至少一个 `*-dock-release.spkg`、`udev.sh`；**evdi.ko 硬校验**：`sudo -n modinfo /var/lib/displaylink/evdi.ko | grep vermagic` 输出含你板的 `uname -r` 值——不含就是装不上的废件，回 A2 换来源。
**假绿警告**：文件存在 ≠ 版本对。vermagic 校验是唯一可靠判据。

## A3. 驱动服务三件

```bash
ssh $BOARD 'sudo -n cp /tmp/displaylink-driver.service /etc/systemd/system/
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now displaylink-driver.service'
```

**判据**：`systemctl is-active displaylink-driver` = active；`pgrep -f DisplayLinkManager` 有 PID（⛔ 不要 `pgrep -x`：进程名超 15 字符，-x 必失败）；`sudo -n dmesg | grep -i evdi | tail` 见本轮时间戳的 evdi 探测行；`ls -l /dev/dri/` 出现**新的** card 节点（对照 A0 基线：基线里有几个 card、现在多了哪个——那个是 evdi，**记下它的编号**，A4 要用）。
**失败排查**：inactive → `journalctl -u displaylink-driver -n 30`（无输出≠没跑，DriveOS 部分 unit 日志进内存 buffer）；DLM 起了又退 → vermagic 不符（回 A2）或 spkg 固件缺失。

---

## A4. X 会话层（三层根因的第 1、2 层）——本仓最核心的一步

裸板到"屏上出现画面"的最小路径（蓝色全屏时钟）：

```bash
# ① 确认 evdi 卡号（A3 已记录；这里复核）
ssh $BOARD 'ls -l /dev/dri/'
# ② 最小 Xorg 配置——若 evdi 不是 card1，先 sed 改 configs/xorg-evdi.conf 里的 kmsdev
ssh $BOARD 'sudo -n cp /tmp/xorg-evdi.conf /var/lib/xorg-evdi/xorg-evdi.conf'
# ③ 手动起 Xorg :1 验证（nohup 防 SIGHUP）
ssh $BOARD 'sudo -n nohup /usr/bin/Xorg :1 -config /var/lib/xorg-evdi/xorg-evdi.conf -logfile /var/lib/xorg-evdi/Xorg.1.log >/dev/null 2>&1 & sleep 8; tail -5 /var/lib/xorg-evdi/Xorg.1.log'
# ④ 全屏时钟客户端（xclock 依赖同目录 libXft.so.2）
ssh $BOARD 'sudo -n nohup bash /tmp/evdi-display-client.sh >/dev/null 2>&1 & sleep 5'
```

**判据（逐条，缺一不可；时间戳必须属于本轮）**：
1. `Xorg.1.log` 有 `Screens setup complete` 且无 `(EE)` 致命行；
2. `sudo -n dmesg | tail` 出现 `evdi ... Edid property set` → `power state: on` → `Notifying mode changed: 1920x1080@60`（或你显示器真实 mode）；
3. `DISPLAY=:1 /var/lib/displaylink/xrandr` 显示 connected + 1920x1080（xrandr 用 DLM 目录下自带副本，别用系统里不存在的）；
4. **人眼看屏：全屏蓝底、中间走时数字**。前三条全绿但屏黑 = 还是没成，回 docs/02 排查矩阵。

**失败排查表**：

| 症状 | 根因层 | 处置 |
|---|---|---|
| evdi 卡 connected、modes 空、edid_len=0 | 无 X 会话开 evdi 卡 | 本文 A4-③（核对 kmsdev 卡号） |
| 屏"闪一下就黑" | 客户端只画了一帧 | 换持续重绘客户端（xclock `-update 1`）；**xsetroot 在此配置下不落 framebuffer，弃用** |
| 全黑但角落一小块有时钟 | 时钟窗口非全屏 | `-geometry 1920x1080+0+0` |
| xclock 秒退 | 缺 libXft.so.2 | `LD_LIBRARY_PATH=/var/lib/displaylink` 必须设 |
| mode changed 有了、屏还黑 | 坞显示通道 | docs/05：USB 授权翻转 → 协议录制 |

## A5. 服务持久化（重启安全）

A4 的手动进程**先清掉**（否则服务拉起的第二个 Xorg 抢 :1 失败、Restart 疯狂重试）：

```bash
ssh $BOARD 'sudo -n pkill -f xclock; pgrep -x Xorg | xargs -r sudo -n kill; sleep 2
  sudo -n mkdir -p /brand_data/displaylink
  sudo -n install -m755 /tmp/evdi-display-client.sh /brand_data/displaylink/evdi-display-client.sh
  sudo -n cp /tmp/xorg-evdi.service /tmp/evdi-display-client.service /etc/systemd/system/
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now xorg-evdi.service evdi-display-client.service'
```

（脚本必须落持久位——unit 的 ExecStart 指向 `/brand_data/displaylink/`，留在 /tmp 的话重启后服务会起不来。）

**判据**：两服务 `is-active` = active；屏上时钟仍在；`sudo -n reboot`（**先确认板 load 正常，见 docs/04 reboot 陷阱**）后两分钟内屏自动恢复时钟（两个 unit 都 enabled，开机自启链完整）。
**已知怪相（勿"修复"）**：板上 `xorg-evdi.service` 的 `After=/Wants= displaylink.service` 引用了一个**不存在**的 unit（真名 `displaylink-driver.service`）。systemd 对不存在的引用静默忽略，实测无害——别改名、别删行，保持与 production 一致。

## A6. 完整桌面（XFCE 便携 rootfs）——可选升级

前置：板上能跑 `dbus-run-session`（`ssh $BOARD 'command -v dbus-run-session'`；没有 → 把 `dbus` 相关包加进 `scripts/build-portable-rootfs.sh` 的 SEEDS 重新构建，或板厂商包补）。

```bash
# 构建机：构建（或直接用 Release 里的现成 tgz）
./scripts/build-portable-rootfs.sh
scp desktop-rootfs.tgz $BOARD:/tmp/
# deploy 从构建机经 stdin 管道执行（deploy.sh 不需要上板）：
ssh $BOARD 'sudo bash -s' < scripts/deploy.sh /brand_data/displaylink/desktop-rootfs
# deploy 只 enable 不 start，补 start：
ssh $BOARD 'sudo -n systemctl start evdi-desktop.service'
# 退位时钟客户端（A5 装的 unit，这时才存在、才能 disable）：
ssh $BOARD 'sudo -n systemctl disable --now evdi-display-client.service'
```

**判据**：`systemctl is-active evdi-desktop` = active；板上 6 组件进程齐（xfconfd/xfsettingsd/xfdesktop/openbox/xfce4-panel/xfce4-notifyd）；**屏上出现顶栏+桌面**；坞 USB 键盘开一个终端能打字。
**假绿警告**：deploy.sh 输出"部署完成"≠桌面在跑——必须 ps 核对 6 组件 + 肉眼看屏。

## A7. 脏断电自愈（前置：已完成 A6）

**① 母本要一次填全**（apply 脚本按"七件+三服务 enable"验收，母本缺件=恢复必报不完整）：

```bash
ssh $BOARD '
  M=/brand_data/persist/displaylink/master
  sudo -n mkdir -p $M/var/lib/displaylink $M/var/lib/xorg-evdi $M/etc/systemd/system $M/etc/udev/rules.d
  sudo -n cp -a /var/lib/displaylink/. $M/var/lib/displaylink/
  sudo -n cp -a /var/lib/xorg-evdi/xorg-evdi.conf $M/var/lib/xorg-evdi/
  sudo -n cp -a /etc/systemd/system/{displaylink-driver,xorg-evdi,evdi-desktop}.service $M/etc/systemd/system/
  sudo -n cp -a /etc/udev/rules.d/99-displaylink.rules $M/etc/udev/rules.d/
  sudo -n cp /tmp/apply_displaylink.sh /brand_data/persist/displaylink/
  sudo -n sed -i "s|/brand_data|/你的真实分区|g" /brand_data/persist/displaylink/apply_displaylink.sh  # 分区名不同才需要
'
```

**② 开机触发（按板上实际机制二选一）**：
- **探测板上有无开机钩子链**：`ssh $BOARD 'ls /etc/systemd/system/ | grep -i restore; grep -rln apply /etc/rc.local /etc/systemd/system/*.service 2>/dev/null; ls /brand_data/.rw_overlay_scripts/ 2>/dev/null'`——有形如"开机重建 /etc"的钩子脚本 → 其末尾追加一行 `bash /brand_data/persist/displaylink/apply_displaylink.sh`；
- **没有钩子链 → systemd oneshot**（完整 unit 见 docs/04；注意该 unit 自己也在 /etc、也会被吞——把 `displaylink-restore.service` 也放进母本 `$M/etc/systemd/system/` 并在 apply 脚本的恢复清单里加一行，形成自举闭环）。

**③ 端到端演练（必做；语义要说清——apply 脚本只负责"文件+enable"恢复，不负责 start 服务）**：

```bash
# 模拟脏断电
ssh $BOARD 'sudo -n systemctl stop xorg-evdi evdi-desktop
  sudo -n rm /etc/systemd/system/xorg-evdi.service /etc/systemd/system/evdi-desktop.service
  sudo -n rm -f /etc/systemd/system/multi-user.target.wants/{xorg-evdi,evdi-desktop}.service
  systemctl is-enabled xorg-evdi'        # 期望 not-found（=模拟成功）
# 恢复
ssh $BOARD 'sudo -n bash /brand_data/persist/displaylink/apply_displaylink.sh'
# 验收两段
ssh $BOARD 'systemctl is-enabled xorg-evdi evdi-desktop displaylink-driver'   # 三连 enabled（apply 职责）
ssh $BOARD 'sudo -n systemctl restart xorg-evdi evdi-desktop
  systemctl is-active xorg-evdi evdi-desktop'                                  # active（重启拉起验证）
```

最后**人眼看屏**：画面回来。全过 = 自愈链闭环。（下次真实脏断电后，开机钩子跑 apply → 文件回来 + unit enabled → systemd 按依赖自动 start，链条成立。）
**历史教训**：v1.1 只查"母本在不在"（恒在）→ 假阴性 healthy；v1.2 查**落位件+enable 状态**，本仓 scripts/apply_displaylink.sh 已是 v1.2。

## A8. 终验清单（全部满足才算复现成功）

- [ ] `systemctl is-active displaylink-driver xorg-evdi evdi-desktop` 三连 active（走了 A6）
- [ ] 6 组件进程齐（ps 核对）
- [ ] 屏上：全屏桌面（或 A5 路线的全屏时钟），1920x1080
- [ ] 坞 USB 键盘鼠标可用（开终端打字验证）
- [ ] **会话级**自愈：`sudo -n systemctl restart evdi-desktop` 或 kill 会话主进程（dbus-run-session/bash 包装）→ ≤5s 拉起。注意粒度：systemd 监督的是**会话脚本**这个整体；单独 kill 桌面组件（如 openbox）**不会**被自动拉起（组件级监督不在本仓范围）——别按"杀任一组件"验收，那是判据写错了
- [ ] `sudo -n reboot` → 桌面自动恢复
- [ ] 模拟脏断电 → apply 拉回文件+enable → restart 服务 active
- [ ] A0 基线对照：所有"新出现"的件都能指出来源步骤

## 附：本仓已验证环境与你环境的差异点

| 项 | 本仓验证值 | 你需要自查的 |
|---|---|---|
| 内核 | 6.1.119-rt45（DriveOS 实时_vendor 构建） | `uname -r`；evdi.ko vermagic 必须匹配（A2 硬校验） |
| 板载 glibc | 2.39（与 Ubuntu noble 同版，rootfs 二进制直接跑） | `ldd --version`；低于 2.39 报 GLIBC 版本错，改用低版本 suite 构建 |
| 显示器 | 27 寸 1080p | 分辨率不同时 xclock geometry 跟着改 |
| 坞 | D6000（17e9:6006） | 其他 DisplayLink 坞 ID 不同，udev 规则通用（按 17e9/* 匹配） |
| Xorg 路径 | /usr/bin/Xorg | `which Xorg` |
| 分区名 | /brand_data 占位 | `ls /`；不同则 sed 全仓替换（A7-① 有示例） |
