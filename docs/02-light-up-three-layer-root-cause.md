# 02 · 点亮的三层根因（缺一不可）与验证阶梯

这是全仓最核心的一篇。**内核侧全绿 + 屏幕全黑**是这类项目最经典的假象，根因几乎都在 X 会话层。

## DisplayLink 出画面的完整链路

```
X 客户端渲染 → Xorg 合成到 evdi card1 → DLM 从 evdi 读帧 → 推 USB → 坞 → 显示器
```

四层各自独立，任何一层断 = 黑屏。嵌入式板（DriveOS/Jetson/极简 Linux）最常见的断点是第 2、3 层。

## 三层根因（板侧实测定案）

### 第 1 层：必须有 X 会话打开 evdi card1

DLM 只有在检测到**有 X server 打开了 evdi 设备**后才注册 painter、设置 mode。

缺这个时的特征（诊断信号）：
- evdi connector 停在 `connected`，但 `modes` 空、`edid_len=0`
- dmesg 反复刷 `Painter is not connected`
- DLM 日志暴涨（每秒几十 KB 重试循环）

### 第 2 层：必须有客户端持续重绘

DLM 要有帧可推。**裸 Xorg（无窗口管理器/合成器/任何 X 客户端）= 无持续渲染 = 坞丢信号黑屏**。

### 第 3 层：DLM 推帧是事件驱动，不是 60Hz 持续推

framebuffer 有变化才推帧。三个实测案例：

| 操作 | 实际效果 | 屏幕表现 |
|---|---|---|
| 全黑背景 + 只有 xclock 每秒走时 | 每秒只推时钟那一小块 | "蓝底白字中间一小块、周围黑" |
| `xsetroot -solid <color>` 一次性纯色 | 只推一帧，视频流停 | "闪一下就黑"（显示器超时无信号） |
| 对照：gnome-shell(mutter) 持续 60Hz 合成整屏 | 整屏帧流不断 | 全屏稳定亮 |

> **xsetroot 的 root 背景在此最小 Xorg 配置下不落 framebuffer**——本仓已弃用它，改用全屏窗口（xclock `-geometry 1920x1080+0+0` 或完整桌面）。

一句话总结：**X 会话开 evdi card1（painter 注册）+ 持续重绘客户端（帧流不断）+ 全屏内容（整屏有变化）**，三者齐才全屏稳定亮。

## 最小点亮路径（无桌面环境，5 分钟验证全链）

```bash
# ① 专用 Xorg（configs/xorg-evdi.conf：kmsdev=/dev/dri/card1，只驱动 evdi）
sudo -n /usr/bin/Xorg :1 -config /var/lib/xorg-evdi/xorg-evdi.conf -logfile /var/lib/xorg-evdi/Xorg.1.log &

# ② 全屏时钟客户端（scripts/evdi-display-client.sh）
DISPLAY=:1 LD_LIBRARY_PATH=/var/lib/displaylink \
  /var/lib/displaylink/xclock -digital -update 1 -geometry 1920x1080+0+0 -bg steelblue -fg white &
```

成功判据（**逐条核对，时间戳必须属于本轮**）：
1. `Xorg.1.log`：`Screens setup complete`，无 `(EE)`；
2. dmesg：`evdi ... Edid property set` → `power state: on` → `Notifying mode changed: 1920x1080@60`；
3. `DISPLAY=:1 /var/lib/displaylink/xrandr`：`DVI-I-1 connected primary 1920x1080+0+0`；
4. **人眼看屏**：全屏蓝底、中间走时。

前三条全绿但屏黑 → 回到本页三层根因逐层排查（最常见：客户端挂了/没全屏/只画了一帧）。

## 判活纪律（本仓两次误判换来的教训）

- **evdi 内核日志只证明虚拟 DRM 侧配置，不证明屏亮**。`power state: on` / `mode changed` 出现过 ≠ 屏上现在有画面。
- **DLM 是否在推帧：用 /proc/stat 两次采样差值测瞬时 CPU**（时钟活着 ≈ 每 3 秒 1 jiffies 的增量）。`ps -o pcpu` 是进程生命周期均值，长时间运行后恒显 0.0%，**不能**用来判帧。
- `pgrep -x DisplayLinkManager` 必失败（进程名 >15 字符）→ 用 `pgrep -f`。
- `pkill -f "Xorg :1"` 会匹配到你自己的 SSH 命令行 → 自杀。用 `pgrep -x Xorg` 拿 PID 再 kill。
- **最终判定以人眼看屏为准**。一切日志判据都只是旁证。

## 坞侧最后一招：USB 授权翻转（等效拔插坞线）

当 connector `disconnected` 且各层看着都好时，翻转 USB 端口授权（8 秒，不动驱动配置）：

```bash
# <USBPATH> 形如 2-3（坞所在端口，lsusb -t 或 dmesg 里找）
echo 0 > /sys/bus/usb/devices/<USBPATH>/authorized
sleep 5
echo 1 > /sys/bus/usb/devices/<USBPATH>/authorized
```

实测：翻转后 connector=connected 持续稳定、`Edid property set` 出现、xrandr 恢复 1920x1080。这在"坞显示芯片反复重握手但 evdi→坞像素流没跟上"的卡态（HDMI 口闪、屏黑）上有效。

仍不行 → USB 协议层录制对比，见 [05-protocol-recording-and-debug.md](05-protocol-recording-and-debug.md)。
