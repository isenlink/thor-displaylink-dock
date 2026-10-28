#!/bin/bash
# ============================================================================
# build-portable-rootfs.sh
# 从 Ubuntu noble (arm64) 官方仓构建一个【自包含便携 XFCE 桌面 rootfs】
# 用途：在无法 apt 安装、根分区只读的嵌入式板（如 NVIDIA DRIVE Thor/DriveOS）
#       上跑一个标准桌面。所有文件解包到一个目录，不写系统分区。
#
# 用法：
#   ./build-portable-rootfs.sh [输出目录]
#   默认输出到 ./desktop-rootfs
#
# 产物：
#   <输出目录>/usr/...   完整桌面文件树（openbox + XFCE 面板/桌面/文件管理/通知/截图）
#   <输出目录>/etc/...   系统级配置（xdg/xfce4、fonts、dbus）
#   <输出目录>/home/     可写的用户主目录（运行时 HOME 指向这里）
#   desktop-rootfs.tgz  打包好的便携包（可 scp 到板）
#
# 依赖（构建机）：curl, dpkg-deb, gzip, python3
# ============================================================================
set -euo pipefail

OUT="${1:-./desktop-rootfs}"
MIRROR="http://ports.ubuntu.com/ubuntu-ports"
SUITE="noble"
ARCH="arm64"
# 持久工作目录（pool 复用：重跑时已下载的包不重下）
WORK="$(pwd)/.build-work"
mkdir -p "$WORK"

echo "==> 输出目录: $OUT"
mkdir -p "$OUT"

# ----------------------------------------------------------------------------
# ① 拉取 Ubuntu noble arm64 官方包索引（main + universe + updates）
# ----------------------------------------------------------------------------
echo "==> ① 拉取包索引"
cd "$WORK"
for s in main universe; do
  for u in "" "-updates"; do
    f="Packages-${s}${u}.gz"
    [ -f "$f" ] || curl -sfL "$MIRROR/dists/$SUITE${u}/$s/binary-$ARCH/Packages.gz" -o "$f"
  done
done

# ----------------------------------------------------------------------------
# ② 计算依赖闭包 + 下载 + 解包（python3 做依赖解析）
# ----------------------------------------------------------------------------
echo "==> ② 计算依赖闭包并下载"
python3 - "$WORK" "$OUT" <<'PYEOF'
import gzip, re, os, sys, subprocess, concurrent.futures
work, out = sys.argv[1], sys.argv[2]
os.chdir(work)

pkgs = {}
def ver_bigger(a, b):
    sa = re.split(r"[.\-~+]", a); sb = re.split(r"[.\-~+]", b)
    for x, y in zip(sa, sb):
        xn = re.match(r"(\d+)", x); yn = re.match(r"(\d+)", y)
        xa = int(xn.group(1)) if xn else 0; ya = int(yn.group(1)) if yn else 0
        if xa != ya: return xa > ya
    return len(sa) > len(sb)

def process(b):
    n = b["Package"]; v = b.get("Version", ""); cur = pkgs.get(n)
    if cur is None or ver_bigger(v, cur["version"]):
        pkgs[n] = {"version": v, "filename": b.get("Filename", ""),
                   "size": int(b.get("Size", "0")),
                   "deps": b.get("Depends", ""), "pre": b.get("Pre-Depends", "")}

def parse(path):
    with gzip.open(path, "rt", errors="replace") as f:
        block = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if block.get("Package"): process(block)
                block = {}; continue
            if line.startswith(" ") and block:
                k = list(block)[-1]; block[k] += "\n" + line
            elif ":" in line:
                k, v = line.split(":", 1); block[k] = v.strip()
        if block.get("Package"): process(block)

for s in ["main", "universe"]:
    for u in ["", "updates"]:
        p = f"Packages-{s}{u}.gz"
        if os.path.exists(p): parse(p)

print(f"    索引包总数: {len(pkgs)}")

# 板上已有的包（避免重复带核心库）—— 从 board-installed.txt 读，没有就空
board = set()
if os.path.exists("board-installed.txt"):
    board = set(open("board-installed.txt").read().split())

# 这些是系统基础包，板子自带，不重复带
EXCLUDE = {"libc6","libgcc-s1","libstdc++6","dpkg","perl-base","perl-modules-5.38",
           "libperl5.38t64","gcc-14-base","python3.12-minimal","python3-minimal",
           "libpython3.12-stdlib","libpython3.12-minimal","cpp-13-aarch64-linux-gnu",
           "cpp-13","cpp","libisl23","libmpc3","libmpfr6","default-dbus-session-bus"}
EXCLUDE |= board

def dep_names(ds):
    out = []
    if not ds: return out
    for g in ds.split(","):
        g = g.strip(); alts = [a.strip() for a in g.split("|")]; picked = None
        for a in alts:
            n = re.split(r"[ (]", a)[0].split(":")[0]
            if n in pkgs: picked = n; break
        if picked is None and alts: picked = re.split(r"[ (]", alts[0])[0].split(":")[0]
        if picked: out.append(picked)
    return out

# 桌面组件种子（openbox 替代 xfwm4——xfwm4 在极简 DriveOS 上起不来）
# 注意：xfdesktop 的包名是 xfdesktop4（noble 里无 "xfdesktop"），thunar 同理带 -data
SEEDS = ["openbox","obconf","menu","xterm","thunar","thunar-data","xfdesktop4","xfdesktop4-data",
         "xfce4-panel","xfsettingsd","xfconf","xfce4-notifyd","xfce4-screenshooter",
         "xfce4-appfinder","xfce4-whiskermenu-plugin","xfce4-terminal"]
seen, queue = set(), list(SEEDS)
while queue:
    n = queue.pop()
    if n in seen or n not in pkgs: continue
    seen.add(n); queue.extend(dep_names(pkgs[n]["pre"])); queue.extend(dep_names(pkgs[n]["deps"]))

todo = {n: pkgs[n] for n in seen if n not in EXCLUDE and n in pkgs}
total = sum(v["size"] for v in todo.values())
print(f"    闭包 {len(seen)} 包, 需下载 {len(todo)} 个, {total/1048576:.1f} MB")

os.makedirs("pool", exist_ok=True)
def fetch(item):
    n, v = item
    url = "http://ports.ubuntu.com/ubuntu-ports/" + v["filename"]
    outp = "pool/" + os.path.basename(v["filename"])
    if os.path.exists(outp) and os.path.getsize(outp) == v["size"]: return n, True
    for attempt in range(3):  # 重试3次，防瞬时网络失败
        r = subprocess.run(["curl","-sfL","--connect-timeout","10","--max-time","300",
                            "--retry","2","--retry-delay","2","-o",outp,url], capture_output=True)
        if r.returncode == 0 and os.path.getsize(outp) == v["size"]: return n, True
    return n, False

fails = []
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    for n, ok in ex.map(fetch, sorted(todo.items())):
        if not ok: fails.append(n)
print(f"    下载: {len(todo)-len(fails)} 成功, 失败: {fails if fails else '无'}")
assert not fails, f"下载失败: {fails}"

# 解包合并到 rootfs
bad = []
for d in sorted(os.listdir("pool")):
    r = subprocess.run(["dpkg-deb","-x","pool/"+d,out], capture_output=True, text=True)
    if r.returncode != 0: bad.append(d)
print(f"    解包: {len(os.listdir('pool'))-len(bad)} 成功, 失败: {bad if bad else '无'}")
assert not bad
PYEOF

# ----------------------------------------------------------------------------
# ③ 修 dbus service 绝对路径坑
#    deb 里 dbus service 文件写死 Exec=/usr/bin/xxx，但便携 rootfs 不在 /usr，
#    必须改成指向实际 rootfs 路径，否则 dbus 激活失败（xfconfd/Thunar 起不来）。
# ----------------------------------------------------------------------------
echo "==> ③ 修 dbus service 绝对路径"
# 注意：部署时 rootfs 会在板上某路径，这里先用占位符，deploy 时再替换
# 实际上更稳妥：deploy 脚本里用 sed 替换。这里先标记。
find "$OUT/usr/share/dbus-1" -name "*.service" 2>/dev/null | while read f; do
  if grep -q "Exec=/usr/" "$f"; then
    echo "    待 deploy 时替换: $(basename $f)"
  fi
done

# ----------------------------------------------------------------------------
# ④ 生成缓存（gdk-pixbuf loaders / fontconfig / glib schemas）
#    这些缓存默认扫系统路径，便携 rootfs 必须显式指定目录生成。
# ----------------------------------------------------------------------------
echo "==> ④ 生成缓存"
B="$OUT/usr"
# gdk-pixbuf loaders.cache（需 GDK_PIXBUF_MODULE_DIR 指到便携 loaders）
if [ -x "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders/query-loaders" ]; then
  GDK_PIXBUF_MODULE_DIR="$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders" \
    "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders/query-loaders" \
    > "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || true
  echo "    gdk-pixbuf loaders.cache: $(wc -l < "$B/lib/aarch64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || echo 0) 行"
fi
# fontconfig 缓存
if [ -x "$B/bin/fc-cache" ]; then
  "$B/bin/fc-cache" -f "$OUT/etc/fonts" 2>/dev/null || true
  echo "    fontconfig 缓存已生成"
fi

# ----------------------------------------------------------------------------
# ⑤ 打包
# ----------------------------------------------------------------------------
echo "==> ⑤ 打包"
OUT_PARENT="$(dirname "$OUT")"
OUT_NAME="$(basename "$OUT")"
TGZ_PATH="${OUT%/}.tgz"
tar czf "$TGZ_PATH" -C "$OUT_PARENT" "$OUT_NAME"
echo ""
echo "============================================================"
echo "完成！"
echo "  rootfs 目录: $OUT"
echo "  便携包:      $TGZ_PATH ($(du -h "$TGZ_PATH" | cut -f1))"
echo "  文件数:      $(find "$OUT" -type f | wc -l)"
echo ""
echo "下一步：用 deploy.sh 部署到板（替换 dbus 路径 + 建 systemd 服务）"
echo "============================================================"
