# thor-displaylink-dock

**DisplayLink USB dock display on NVIDIA DRIVE Thor (DriveOS) — complete field-tested playbook.**

Make a DisplayLink USB-C dock (Dell D6000, `17e9:6006`) drive a real desktop on an NVIDIA DRIVE Thor drive-unit board whose rootfs is **read-only, has no apt, and has no native display path** — including surviving dirty power cycles.

| Field-tested result (all measured on the target board) | Value |
|---|---|
| Dock display | 1920x1080@60, stable, full desktop |
| Desktop stack | openbox + XFCE (panel/desktop/settings/notifyd), USB keyboard & mouse via dock |
| Crash recovery | kill any desktop component → systemd re-launches in ≤5 s |
| Reboot safety | all units enabled; auto-start verified |
| Dirty-power-cycle self-healing | v1.2 idempotent restore script, end-to-end drill passed (units deleted → restored → active) |
| Portable rootfs rebuild | reproducible build, 8736 files / ~52 MB, EXIT=0 replay |

中文对照见下方 [中文摘要](#中文摘要)。

## Why this is hard (and why most attempts end in a black screen)

DisplayLink over USB needs a **four-layer chain**, and embedded boards usually break layer 3 or 4:

```
X client renders → Xorg composites onto evdi card1 → DisplayLinkManager (DLM)
reads frames from evdi → pushes over USB → dock → monitor
```

The kernel side (evdi probe, EDID, mode set) can look **perfect** while the screen stays black, because:

1. **No X session opened evdi card1** → DLM never registers a painter, never sets a mode.
2. **No continuously-redrawing client** → DLM has no frames to push → dock drops signal.
3. **DLM pushes frames event-driven, not at 60 Hz** → a one-shot root-window fill gives you one frame, then the monitor times out ("flashes once, then black").

All three must hold simultaneously. Details and the diagnostic ladder: [docs/02-light-up-three-layer-root-cause.md](docs/02-light-up-three-layer-root-cause.md).

## Repository map

```
AI-REPRODUCTION-GUIDE.md      ← start here if you are an AI agent / want a check-listed reproduction
docs/
  01-driver-install-on-linux.md          evdi + DLM install on x86 Linux (Debian example) & board-side layout
  02-light-up-three-layer-root-cause.md  the three-layer root cause + verification ladder
  03-portable-xfce-desktop.md            portable XFCE rootfs on a read-only rootfs board (no apt)
  04-dirty-power-cycle-selfhealing.md    why units vanish after dirty power cuts + idempotent restore
  05-protocol-recording-and-debug.md     LD_PRELOAD libusb recording, cross-machine diff, debugging story
scripts/
  build-portable-rootfs.sh    build the portable XFCE rootfs from Ubuntu noble arm64 debs
  deploy.sh                   one-shot deploy to the board (unpack, fix dbus paths, caches, systemd units)
  apply_displaylink.sh        idempotent driver/config restore (run at boot, survives overlay loss)
  evdi-desktop-session.sh     reference session script (deploy.sh generates the real one)
  evdi-display-client.sh      minimal "full-screen clock" client (fallback / teaching step)
configs/
  xorg-evdi.conf              minimal Xorg config driving evdi card1 on :1
  xorg-evdi.service           systemd unit for the dedicated Xorg :1
  evdi-desktop.service        reference copy of the desktop session unit (deploy.sh generates the real one)
  evdi-display-client.service systemd unit for the minimal clock client (A5)
  displaylink-driver.service  DLM unit (with the board's libusb preload workaround)
  99-displaylink.rules        upstream DisplayLink udev rules (unchanged)
```

**Release assets** (v1.0.0, sha256 in the release notes):

| Asset | What it is |
|---|---|
| `desktop-rootfs.tgz` (~52 MB) | prebuilt portable XFCE rootfs — skip the build step entirely |
| `dl-driver-stack.tgz` (~7 MB) | board driver stack as deployed: DLM 6.4.0-22 + evdi 1.15.1 (`libevdi.so.1.15.1`) + `evdi.ko` (vermagic `6.1.119-rt45-prod-rt-tegra aarch64`) + 4 dock firmware `.spkg` + udev rules + unit. Usable as-is only on boards whose `uname -r` matches — always `modinfo`-check vermagic first (docs/01) |
| (reference) official Synaptics package | `DisplayLink USB Graphics Software for Ubuntu` 6.3 — download page `https://www.synaptics.com/products/displaylink-usb-graphics-software-ubuntu-63`, file `displaylink-driver-6.3.0-48.run` inside the EXE zip (sha256 `7269856c…ce098`, see docs/01) |

DisplayLink binaries are © Synaptics and included here only for reproduction convenience alongside the official source link; prefer the official download for anything other than this exact board-kernel scenario.

## Three routes

| Route | What you get | Read |
|---|---|---|
| A. Minimal (blue full-screen clock) | proof the whole chain works | docs/02 + scripts/evdi-display-client.sh |
| B. Full XFCE desktop | panel, desktop icons, file manager, terminal, keyboard & mouse | docs/03 + AI-REPRODUCTION-GUIDE.md |
| C. Debugging someone else's broken setup | layered triage + USB protocol recording | docs/05 |

## Environments this was verified on

| Component | Board side | x86 side |
|---|---|---|
| Platform | NVIDIA DRIVE Thor (DriveOS), kernel 6.1.119-rt45 (real-time, vendor build) | Debian 13, kernel 6.12 |
| DLM | 6.4.0-22 (DisplayLinkManager) | 6.3.0-48 installer verified |
| evdi | 1.15.1 | 1.14.14 via DKMS |
| Dock | Dell D6000, USB ID 17e9:6006 | same |
| Desktop | openbox + XFCE from Ubuntu noble (arm64) arm64 debs, glibc 2.39 | — |

## Naming note / 代称说明

- `/brand_data` is a **placeholder** for the board's writable persistent data partition (a large ext4 partition, name pattern `<vendor>_data`). Scripts **hard-code** `/brand_data` as that placeholder (including `scripts/apply_displaylink.sh` and the session script). If your partition name differs, sed-replace it across the repo before deploying — example in [AI-REPRODUCTION-GUIDE.md](AI-REPRODUCTION-GUIDE.md) §A7. Find your partition with `ls /` / `df -h`.
- Board hostname/IP in examples (`192.168.1.105`) is a plain LAN address; replace with your board's.
- `nvidia` is the stock account name on NVIDIA DRIVE boards (as shipped), not a personal name.

## License

MIT — see [LICENSE](LICENSE).
