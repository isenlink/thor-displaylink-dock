# 03 · 便携 XFCE 桌面 rootfs（只读 rootfs / 无 apt 的板上跑标准桌面）

板上约束：DriveOS rootfs **只读**、无 apt、根分区只剩几百 MB。解法：从 Ubuntu noble (arm64) 官方仓拉 deb、解包合并成一个**自包含便携 rootfs**（不安装、不写系统分区），会话进程的环境变量全部指向便携目录。

前置核对：板上 glibc 与所选 Ubuntu suite 同版本时二进制可直接跑（实测板 2.39 = noble 同版）。glibc 更老的板要换更老的 suite，否则跑起来报 `GLIBC_2.x not found`。

## 构建机侧：`scripts/build-portable-rootfs.sh`

一条命令：拉 noble arm64 索引（main/universe ±updates）→ python3 依赖闭包 → 下载（重试+持久 pool）→ `dpkg-deb -x` 合并 → 打包 `desktop-rootfs.tgz`。

**可选输入 `board-installed.txt`**：放在构建目录（脚本工作目录）时，脚本把它当"板上已有的包"清单（空白分隔的包名；生成法：板上 `dpkg -l | awk '/^ii/{print $2}' > board-installed.txt`），闭包计算会排除这些包以减重。**没有此文件构建照常进行**——只是不减重，产物更自包含（推荐直接不带它跑）。

种子包：openbox、xfdesktop**4**、xfce4-panel、xfsettingsd、xfconf、xfce4-notifyd、thunar、xfce4-terminal、xterm、xfce4-screenshooter、xfce4-appfinder、xfce4-whiskermenu-plugin、obconf、menu。

实测重放：8736 文件 / ~52MB / EXIT=0。

**构建脚本里的坑（都在脚本里有对应处理，读懂再改）**：
1. **包名带版本号陷阱**：noble 里没有 `xfdesktop` 这个种子名（真名 `xfdesktop4`），闭包计算对不存在的种子名**静默跳过** → rootfs 缺二进制。部署后必须 `ls` 验关键二进制（thunar 同理带 `-data` 子包）。
2. **Ubuntu ports 索引 URL**：`dists/noble/<suite>/<comp>/binary-arm64/Packages.gz`（是 `binary-arm64`；裸 `arm64` 404）。
3. **下载重试 + 持久 pool**：瞬时网络失败几个包就整场挂；工作目录用持久 `.build-work/pool` 复用已下载包（"mktemp + trap EXIT 清理"的写法会在断言失败时把 pool 一并删光——正是为此被否决，脚本才改用持久目录）。
4. **tar -T 列表坑**：`dpkg-deb -c` 输出含目录行，喂给 `tar -T` 会把目录当参数递归展开（实测 56174 文件/55MB 假象）→ 文件清单用 `os.path.isfile` 过滤后再打包。

## 板上部署：`scripts/deploy.sh`

```bash
scp desktop-rootfs.tgz nvidia@<BOARD-IP>:/tmp/
ssh nvidia@<BOARD-IP> 'sudo bash -s' < scripts/deploy.sh /brand_data/displaylink/desktop-rootfs
```

deploy.sh 五步：解包 → 修 dbus service 绝对路径 → 生成板上缓存 → 安放会话脚本（模板+占位符替换）→ 建 `evdi-desktop.service` 并 enable。

**部署层的坑（复现失败头几名全在这）**：

5. **dbus service 绝对路径（头号坑）**：deb 里 `org.xfce.Xfconf.service` / `org.xfce.Thunar*.service` / `ca.desrt.dconf.service` 写死 `Exec=/usr/...`，便携 rootfs 不在 /usr → dbus 激活失败 → xfconfd/Thunar 全瘫 → 桌面组件连锁不起。修法：`sed -i "s|Exec=/usr/|Exec=<ROOTFS>/usr/|g"` 所有 `usr/share/dbus-1/services/*.service`。
6. **gdk-pixbuf loaders.cache**：`query-loaders` 默认扫系统路径为空，必须 `GDK_PIXBUF_MODULE_DIR` 指到便携 loaders 目录再生成。
7. **fontconfig**：板上已有字体（如 dejavu）时，fonts.conf 叠加引用即可；`fc-cache -f` 指向便携 etc/fonts。
8. **glib schemas**：便携包不带编译器，用板上原生 `glib-compile-schemas`（没有就跳过，XFCE 主件不强依赖）。
9. **会话脚本 heredoc 双坑**：无引号 heredoc 会展开 `$R/$B` 运行时变量，加引号又丢占位替换 → 用 `__ROOTFS__` 占位符 + `sed` 两头兼顾（deploy.sh 已内置）。

## 会话脚本（`scripts/evdi-desktop-session.sh` 为参考版，deploy.sh 生成真实版）

组件拉起顺序（dbus-run-session 内，间隔 sleep）：

```
xfconfd（配置守护，libexec 路径）→ xfsettingsd → xfdesktop → openbox → xfce4-panel → xfce4-notifyd
```

- **xfdesktop 是帧流保活的关键**——它持续重绘 root 窗口，满足 docs/02 第 2/3 层要求。
- **直接拉起而非依赖 dbus 激活**：dbus service 路径坑多（坑5），直接拉最稳。
- xfconfd / xfce4-notifyd 在 `lib/aarch64-linux-gnu/` 下（libexec），不在 bin。

**为什么是 openbox 不是 xfwm4**：xfwm4 在极简 DriveOS 上 exit 1 "Missing defaults file"——defaults 文件在、XDG 路径对、无段错误，**硬伤无解**。openbox 验收法：`timeout 8 openbox` 退出码 124 = 存活 = 可用。openbox 缺 5 个库要从 deb 补进 rootfs：`libobt.so.2`、`libpangoxft-1.0.so.0`、`libXft.so.2`、`libImlib2.so.1`、`librsvg-2.so.2`（板上全无，新增不覆盖系统库）。

## 键盘鼠标（"插了没反应"诊断序）

- Xorg 靠 **udev 自动发现** USB 键鼠（evdev 自动加载，Xorg.1.log 见 "Configuring as keyboard/mouse" 即驱动 OK）——xorg.conf **不用写** InputClass。
- 屏上没指针 = `XCURSOR_THEME=Adwaita` 没设（rootfs `usr/share/icons/Adwaita/cursors` 有全套）。
- 键盘没反应 = 没有焦点窗口（桌面是 root 窗口）→ 开一个 xterm/Thunar 即可打字。
- 两点都不是驱动问题。

## 验收

```bash
systemctl is-active evdi-desktop          # active
ps aux | grep -E 'xfconfd|xfsettingsd|xfdesktop|openbox|xfce4-panel|xfce4-notifyd' | grep -v grep   # 6 组件齐
```

- 屏上：顶栏 + 桌面图标整屏亮（人眼终判）。
- 坞 USB 键盘开终端能打字。
- kill 任一组件 → 5 秒内 systemd 拉起（Restart=on-failure）。

**假绿警告**：deploy.sh 打印"部署完成"≠桌面在跑。必须 ps 核对 + 肉眼看屏。

## 已知边界

- xfwm4 未解（疑缺某 X 扩展，需 xdpyinfo 查扩展后回攻）。
- xfce4-settings 是元包无独立二进制。
- 音频未配（板载声卡另案）。
- 单屏 1920x1080@60；多屏需改 xorg-evdi.conf 加 Screen 段。
- 板上没有的调试工具（别指望）：strace、xinput、xset、xdotool、xwininfo、apt。诊断靠 Xorg 日志 + ldd + 手动前台跑进程看 stderr。
