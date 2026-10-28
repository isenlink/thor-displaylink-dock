# 01 · DisplayLink 驱动安装（Linux）与板上驱动布局

## DisplayLink 驱动的两部分（都必须有）

- **evdi**：内核模块，虚拟显示接口（`/dev/dri/cardN`）。ext-Linux 上经 DKMS 对运行内核编译；DriveOS 板上是预编译的 `evdi.ko`（必须与本板 `uname -r` 匹配）。
- **DisplayLinkManager（DLM）**：用户态守护，从 evdi 读帧、推 USB 图形。闭源，只随官方 `.run` 包分发。

坞本身：Dell D6000 = USB ID `17e9:6006`，还带一颗 RTL8153 USB 网卡（坞上网口）。

> ⛔ **坞必须真接了显示器才有画面**——没接显示器就调试驱动是白费。

## 路线 A：常规 Linux（Debian/Ubuntu，x86 验证机实测）

适用：先在 x86 机器上验证"坞+显示器+线"是好的，或给常规 Linux 主机装驱动。

### 1. 前置（DKMS 要对着运行中的内核编译 evdi）

```bash
sudo apt-get install -y dkms linux-headers-$(uname -r)
```

### 2. 下载官方 .run 安装包

官方下载页（synaptics.com）是 **JS 渲染**——直接 `curl` 页面 URL 拿到的是 HTML 不是文件。**真实文件 URL 嵌在页面 HTML 里**：

```bash
curl -sL <下载页URL> | grep -oE '/sites/default/files/exe_files/[^"]+\.(zip|run)'
```

实例（6.3 版，实测可用）：

```
下载页：https://www.synaptics.com/products/displaylink-usb-graphics-software-ubuntu-63
文件：  https://www.synaptics.com/sites/default/files/exe_files/2026-06/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.3-EXE.zip
```

（19,846,292 字节 zip，sha256 `7269856c7527060c513215ce1b5a36fef074d8e89cab89bcab13df342acce098`，解压得 `displaylink-driver-6.3.0-48.run`，Makeself 2.5.0 自解压格式。新版请到 synaptics.com 的 DisplayLink Ubuntu 软件页按同法挖直链。）

### 3. 非交互安装：`--accept` + `yes |`

```bash
yes | sudo ./displaylink-driver-6.3.0-48.run --accept
```

**⛔ 坑：`-y` 不是合法参数**——带 `-y` 会打印 help 然后退出，**看起来像装完了其实什么都没装**（rc=0 但 evdi/DLM 都没落地）。正确组合 = `--accept`（接受许可）+ `yes |`（喂 apt 的 `Continue? [Y/n]`）。

### 4. 装完必须验证（别只看退出码）

```bash
lsmod | grep evdi                          # evdi 模块已加载
systemctl status displaylink-driver        # 服务 active
```

### 5. APT 仓库只有 evdi，没有完整驱动

Synaptics APT 仓（`https://www.synaptics.com/sites/default/files/Ubuntu`，dists/stable/main）只有 `evdi` 包；`displaylink-driver`（含 DLM + libevdi + 固件 .spkg）只在 `.run` 独立安装包里。只装 APT 的 evdi 是不够的。

### 6. 内核兼容

6.3 驱动支持到内核 6.16（6.12 实测 OK），evdi 1.14.14。

## 路线 B：DriveOS 板（rootfs 只读、无 apt、无网）

板上无法跑 .run 安装器，采用**文件级落位**：把驱动件直接放到 `/var/lib/displaylink/`（这是 DLM systemd unit 的硬编码工作目录）。

### 驱动件来源（先解决这个，再动手——`evdi.ko` 是内核模块，必须匹配板内核）

⛔ **硬约束**：`evdi.ko` 的 vermagic 必须与板上 `uname -r` 一致，否则 insmod 报 `Invalid module format`，硬失败。x86 机器上的 `.ko`、别的内核版本的 `.ko` 都装不上。

| 来源 | 拿什么 | 适用 |
|---|---|---|
| **本仓 Release 资产 `dl-driver-stack.tgz`** | 板上生产驱动目录整包（内核 `6.1.119-rt45-prod-rt-tegra` aarch64，DLM 6.4.0-22，evdi 1.15.1，含 4 个 spkg 固件） | 你的板内核 vermagic 与之相同 → 直接用（先 `modinfo` 校验再落位） |
| 板厂商 BSP/驱动仓库 | 同内核编译的 `evdi.ko` + 用户态件 | 有厂商通道时最优 |
| 另一块**同内核版本**的板 | `/var/lib/displaylink/` 整目录 + `/etc/udev/rules.d/99-displaylink.rules` + 三个 systemd unit | 有同内核姊妹板时 |
| Synaptics 官方 `.run` 包（docs/01 路线 A 下载） | 解出用户态件（DLM/spkg/libevdi/x 工具/udev 规则/unit），`evdi.ko` 单独对板内核编译 | 板内核头文件与编译环境可得时（DriveOS 板上通常不可行，交叉编译超出本仓范围） |

用户态件（DLM 等）不依赖内核版本，从任何官方 `.run` 包解出即可用；**只有 `evdi.ko` 是硬约束**。

### 板上驱动件清单（与 x86 安装包同源）

| 文件 | 作用 | 来源 |
|---|---|---|
| `DisplayLinkManager` | DLM 主程序 | .run 包 |
| `evdi.ko` | 内核模块 | **必须对本板内核编译**（或同版本内核产物） |
| `libevdi.so.1.x.x` | evdi 用户态库 | .run 包 |
| `libusb-1.0.so.0.6.0` | DLM 自带的 libusb（板上兼容层，见下） | .run 包 |
| `ella/firefly/navarro/ridge-dock-release.spkg` | 各代坞固件包，DLM 运行需要 | .run 包 |
| `udev.sh` | udev 事件处理脚本 | .run 包 |
| `xclock / xrandr / xset / xsetroot` | DLM 自带 X 小工具（诊断/最小客户端用） | .run 包 |
| `libXft.so.2` | xclock 的依赖 | .run 包 |
| `99-displaylink.rules` | udev 规则（按 `ENV{PRODUCT}=="17e9/*"` 匹配，各坞通用） | .run 包 |
| `displaylink-driver.service` | systemd unit | .run 包 |

### 板上 systemd unit 的兼容要点（本仓 configs/displaylink-driver.service 即板上生产版）

```ini
ExecStartPre=/bin/sh -c 'lsmod | grep -q evdi || insmod /var/lib/displaylink/evdi.ko initial_device_count=1'
Environment=LD_LIBRARY_PATH=/var/lib/displaylink
Environment=LD_PRELOAD=/var/lib/displaylink/libusb-1.0.so.0.6.0
ExecStart=/var/lib/displaylink/DisplayLinkManager
Restart=always
RestartSec=5
```

- `ExecStartPre`：兜底 insmod（开机时 DKMS 不可用，模块要手动进内核）。
- `LD_PRELOAD` 板上自带 libusb：DriveOS 的 xUSB 控制器 + 坞方带的老 libusb 有传输层兼容问题，preload 板内副本是实测出来的稳定形态。**x86 机器上不需要这行。**
- `initial_device_count=1`：一块坞一块虚拟屏。

### 验证

```bash
systemctl is-active displaylink-driver                 # active
pgrep -f DisplayLinkManager                            # 有 PID（⛔ 不要 pgrep -x：进程名 >15 字符，-x 必失败）
dmesg | grep -i evdi | tail                            # evdi probe 行，时间戳为本轮
ls /dev/dri/                                           # 应出现新的 card（evdi 的虚拟卡，通常是 card1）
```

装好驱动 ≠ 出画面。下一步是 X 会话层 → [02-light-up-three-layer-root-cause.md](02-light-up-three-layer-root-cause.md)。
