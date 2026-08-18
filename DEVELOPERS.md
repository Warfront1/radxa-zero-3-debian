# Building the image

Build a dd-able Debian arm64 SD card image for the Radxa Zero 3E (RK3566) with mainline U-Boot.

For flashing and using a prebuilt image, see [README.md](README.md).

## Prerequisites

- arm64 host (Apple Silicon Mac, arm64 Linux, or arm64 cloud instance) &mdash; this build runs natively, no cross-compilation
- Docker (no `--privileged`, no host binfmt setup, no extra capabilities)

Both the Debian ISO and the bootloader are auto-fetched and sha256-verified at build time:

| Input | Source | Pinned version |
|---|---|---|
| Debian arm64 DVD ISO | [cdimage.debian.org](https://cdimage.debian.org/debian-cd/13.6.0/arm64/iso-dvd/) | `13.6.0` |
| `u-boot-rockchip.bin` | [radxa-zero-3-boot-firmware](https://github.com/Warfront1/radxa-zero-3-boot-firmware) releases | `v2026.07` |

The ISO is downloaded only if not mounted at `/input/iso`. The bootloader is always downloaded from the pinned release.

Override at build time with `-e DEBIAN_VERSION=... -e DEBIAN_ISO_SHA256=...` or `-e FIRMWARE_RELEASE=... -e FIRMWARE_SHA256=...`.

## Build the image

```sh
docker build -t radxa-zero-3-debian .

docker run --rm \
    -v "$PWD/out:/output" \
    radxa-zero-3-debian
```

Optional mounts (avoid re-downloading the ~3.7 GB ISO each build):
- `-v "$PWD/resources/debian-13.6.0-arm64-DVD-1.iso:/input/iso:ro"`
- `-v "$PWD/resources/board.dtb:/input/board.dtb:ro"` as a DTB fallback.

## Serial debug

- Adapter: 3.3V USB-to-TTL (recommend CP2102N-based, e.g. DSD TECH SH-U09BL)
- Wiring: TX&rarr;RX, RX&rarr;TX, GND&rarr;GND, VCC disconnected (board is self-powered)
- Baud: 1,500,000 8N1
- Command: `picocom -b 1500000 /dev/ttyUSB0` (exit: Ctrl-A Ctrl-X)
- Note: U-Boot output is serial-only. HDMI shows nothing until the kernel's DRM driver probes.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No serial output at all | UART wiring/baud/pins wrong | Check TX&harr;RX crossing, 1500000 baud, UART2 pins (0xfe660000) |
| DDR banner then silence | SPL can't load FIT | Re-flash bootloader; verify card integrity |
| SPL prints "failed to find FIT config" | ADC board-id misread (unverified fallback) | Requires serial to diagnose further |
| U-Boot banner but "Device not found" | extlinux.conf not found | Verify ext4, `/boot/extlinux/extlinux.conf` path |
| Kernel hangs at "Waiting for root device" | Wrong PARTUUID | Verify PARTUUID matches GPT |
| Kernel panics "unable to mount root fs" | Missing or mismatched initrd | Verify `/boot/initrd.img` exists and matches kernel |
| HDMI black but serial shows login | DRM didn't probe or no getty on tty1 | Check `getty@tty1.service` symlink; install `linux-firmware` |