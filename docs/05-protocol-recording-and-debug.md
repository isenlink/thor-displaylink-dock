# 05 · USB 协议录制（LD_PRELOAD 垫片法）与完整排障案例

## 第一部分：排障案例复盘（从"驱动层全好、屏全黑"到定案）

背景：板侧驱动栈逐环检查**全部正常**，但坞屏黑。整个过程踩了两个方向的弯路，最后发现根因不在检查过的任何一层。写成案例是为了让读者**跳过弯路**。

### 故障形态（起点）

| 检查项 | 结果 | 当时判断 |
|---|---|---|
| displaylink-driver 服务 | active，DLM 47 线程无死锁 | 驱动层好 |
| DLM ↔ USB | 握着坞的 usbfs 设备（接口 0/1） | USB 枚举好 |
| evdi | card1 在；Xorg :1 持 card1 且每秒刷帧 | X 层好 |
| 内核 EDID | 256B 非空（真显示器 EDID） | 坞↔显示器链路好 |
| connector | **disconnected** + evdi 每秒刷 `Painter is not connected` | ← 异常点 |
| DLM USB read_bytes | **恒 0**（write 缓涨 = 重试循环） | ← 异常点 |

### 弯路一：怀疑 USB 传输层（方向不对）

DLM"连 read 都不收却上报了 EDID"的矛盾形态，引导我们怀疑 libusb 传输层兼容性。计划并搭建了**协议录制对比**（见第二部分）：录制 x86 成功机器与板的 USB 握手轨迹，diff 定位卡点。这个基础设施本身有效，但本案没用上——因为：

### 弯路二/真相：根因在 X 会话层

板上的"Xorg :1 持 card1 每秒刷帧"是**残留的中间态客户端**（一个走时时钟）提供的，它只证明"曾有帧流过 evdi"，不证明 DLM 注册了 painter。真正缺的是 docs/02 说的**第 1 层完整形态**（专用 Xorg + 持续重绘客户端 + 全屏内容三者齐备）。

**用专用 Xorg 配置重启 :1 后**：`Edid property set` → `power state: on` → `mode changed 1920x1080@60` → `Connected with (DisplayLinkMana)`，全链贯通，屏亮。

**教训提炼**：
1. "每一层都检查过"≠"每一层都检查对了"。X 会话层的检查要打到 **painter 注册 / mode set** 这一层，而不是"Xorg 进程在跑"。
2. 协议录制是对的工程方法，但**先分层排障、再上重武器**——本案用 5 分钟的"重启 Xorg 配置"验证就命中，协议 diff 是给"分层排障穷尽后"的。
3. USB 授权翻转（docs/02 末尾）是坞侧卡态（反复重握手、HDMI 闪、屏黑）的快速解锁手段，实测有效。

## 第二部分：USB 协议录制方法（LD_PRELOAD 垫片）

用途：当分层排障穷尽仍黑屏时，录制**成功机器**与**失败机器**的 DLM↔坞 USB 交互轨迹（CTRL/SUBMIT/EVENT + hex），diff 定位第一个分歧点。

### 垫片

一个预编译的 `libusb-tee.so`（x64 / aarch64 两个版本），LD_PRELOAD 挂到 DLM 进程，拦截 libusb 调用写入日志。只挂 libusb 层，**不碰 DLM 母本**。

（垫片构建方法超出本仓范围：用 LD_PRELOAD 包装 `libusb_control_transfer` / `libusb_submit_transfer` / `libusb_handle_events` 系列符号，逐调用写时间戳+端点+hex。你也可以用 usbmon/`cat /sys/kernel/debug/usb/usbmon` 做内核侧录制，无需垫片。）

### 挂垫片（systemd drop-in，不改原 unit）

```bash
sudo mkdir -p /etc/systemd/system/displaylink-driver.service.d
printf '[Service]\nEnvironment=LD_PRELOAD=/path/to/libusb-tee.so\nEnvironment=USBTEE_LOG=/tmp/usbtee.log\n' \
  | sudo tee /etc/systemd/system/displaylink-driver.service.d/20-tee.conf
sudo systemctl daemon-reload && sudo systemctl restart displaylink-driver
```

### 录制纪律（顺序不可乱）

1. **先无垫片点亮成功并稳定**（基线：evdi `power state: on` 不翻 off）——垫片对比的前提是有成功轨迹。
2. 挂垫片重启服务，等 60s 录制。
3. **摘垫片重启服务，验证显示仍亮**——防垫片本身改变行为。
4. 日志传回对比机，diff。

### diff 前提：版本对齐

两台机器 DLM/evdi 版本必须一致（本案 x86 6.4.0-22 / 板 6.4.0-22 对齐后才有可比性），内核版本记入报告（evdi 是 DKMS 按各自内核编的，行为可能因内核而异）。

### 别在这上面浪费时间

- DLM 官方日志是混淆/加密的（base64 乱码），**解密不值得**——`dmesg` 侧 evdi `[I]` 级信息足够。
- 垫片录制 60s 就够，轨迹分歧点在握手前几秒。

## 排障阶梯总表（从快到慢，按序执行）

| 步 | 动作 | 判据 | 见 |
|---|---|---|---|
| 1 | 坞上真有显示器？线好？ | 换线/换显示器/坞插 x86 机验证 | docs/01 |
| 2 | X 会话层完整形态 | 专用 Xorg + 全屏持续客户端 → 屏亮 | docs/02 |
| 3 | USB 授权翻转 | connector 翻 connected、屏亮 | docs/02 |
| 4 | 服务/驱动状态核验 | `journalctl`/dmesg/ldd 逐环 | docs/01 |
| 5 | 协议录制 diff | 首个分歧调用点 | 本文第二部分 |
