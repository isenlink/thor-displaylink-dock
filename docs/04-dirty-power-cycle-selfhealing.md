# 04 · 脏断电自愈：unit 为什么会丢、怎么自动拉回

## 背景：DriveOS 的 overlay 与脏断电

DriveOS 类板子的根分区是 overlayfs：**下层只读镜像 + 上层可写 overlay**。`/etc` 里的改动（新建 systemd unit 等）落在**上层 overlay**。

**脏断电（运行中直接断电/硬复位）时上层 overlay 会被吞掉**，`/etc` 回滚到出厂镜像态：

- `/etc/systemd/system/*.service` 里你新建的 unit **消失**（`systemctl is-enabled xxx` 回 `not-found`）
- wants 软链（enable 的产物）**消失**
- 而 `/brand_data` 这类**独立数据分区完好无损**——母本和脚本都在

（软重启 `reboot` 不吞 overlay；吞的是硬断电。板子若支持，重启前先看 load——见下"reboot 陷阱"。）

## 方案：持久层母本 + 幂等恢复脚本 + 开机触发

三件套（本仓 `scripts/apply_displaylink.sh` v1.2）：

```
/brand_data/persist/displaylink/master/     ← 母本（驱动目录 + 3 个 unit + udev 规则 + xorg 配置）
/brand_data/persist/displaylink/apply_displaylink.sh   ← 幂等恢复脚本
开机钩子（板上 rw_overlay 钩子链追加一行，或 systemd oneshot unit）
```

设计原则：
- **fail-open**：任何一步失败不阻塞开机（exit 0 收尾）。
- **幂等**：缺哪个补哪个，**永不覆盖活体**（在跑的二进制被 cp 会 Text file busy）；enable 软链丢了也能重建。
- **不重启已跑服务**：恢复动作不打断当前画面。

### v1.1 的假阴性教训（为什么 v1.2 查"落位"不查"母本"）

v1.1 的健康判定是"母本在不在"——母本在持久分区、永远在 → **永远报 healthy, skip**，但 /etc 侧 unit 其实已经丢了。假阴性。

v1.2 的健康判定改为：**核心件存在 + 三服务 is-enabled 全过**才算健康（`systemctl is-enabled` 返回 `not-found` = unit 丢了 = 触发恢复）。并做了端到端演练：模拟脏断电（删两 unit + 去 wants 软链）→ 跑 v1.2 → 自动拷回 + enable + 服务 active ✓。

### v1.2 的第二个教训：桌面 unit 也要进保护清单

保护清单从"驱动一件套"扩到"七件+三服务 enable"：驱动目录、xorg-evdi.conf、displaylink-driver/xorg-evdi/evdi-desktop 三个 unit、udev 规则。**漏掉桌面 unit 的后果**：驱动自愈成功但桌面不自启，屏黑——又一层假绿。

## 开机触发方式（二选一）

1. **板上已有开机钩子链**（rw_overlay / do_write_patch 类脚本，开机重建 /etc 的机制）：末尾追加一行 `bash /brand_data/persist/displaylink/apply_displaylink.sh`。
2. **systemd oneshot**（通用）：

```ini
# /etc/systemd/system/displaylink-restore.service
[Unit]
Description=Restore DisplayLink stack from persistent master
After=local-fs.target
Before=displaylink-driver.service

[Service]
Type=oneshot
ExecStart=/bin/bash /brand_data/persist/displaylink/apply_displaylink.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

注意：这个 unit 自己也在 /etc（也会被吞）——钩子链方案里它也要进母本恢复清单；oneshot 方案要求板上有一层不被吞的执行入口（如固件级 rcS / 持久化 init 注入），按你板子的实际恢复机制选择。

## reboot 陷阱（实测，先看这个再 reboot）

- **运行中内核 CPU 硬锁（RCU stall `0 ticks this GPU/CPU`）时 `sudo reboot` 静默失败**：网络断了、但内核还活着，reboot 挂在"等全 CPU 同步"一步走不完。
- **判"没重启"第一查 uptime 是否还在涨**（串口或 SSH；uptime 持续上涨 = 根本没重启）。
- 正常板 `sudo reboot` 后：expect 1-2 分钟网络恢复 + unit 自启 + 屏幕回来。
- **关机/断电纪律**：确保 poweroff 流程跑完再断电（poweroff 没跑完就拔电 = 一次脏断电，overlay 被吞）。重载板（大内存、慢存储）断电前多等 60-90 秒。

## 端到端验收（必做，不许只看脚本 exit 0）

```bash
# 1. 模拟脏断电
sudo -n rm /etc/systemd/system/xorg-evdi.service /etc/systemd/system/evdi-desktop.service
sudo -n rm -f /etc/systemd/system/multi-user.target.wants/{xorg-evdi,evdi-desktop}.service
systemctl is-enabled xorg-evdi        # 期望 not-found（= 模拟成功）

# 2. 跑恢复
sudo -n bash /brand_data/persist/displaylink/apply_displaylink.sh

# 3. 验收
systemctl is-enabled xorg-evdi evdi-desktop displaylink-driver   # 三连 enabled
systemctl is-active  xorg-evdi evdi-desktop                      # active
ls /var/lib/displaylink | wc -l                                   # 驱动件齐
```

最后人眼看屏：画面回来。全过 = 自愈链闭环。
