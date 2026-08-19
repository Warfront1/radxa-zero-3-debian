#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned bootloader — auto-fetched and hash-verified from GitHub releases.
# Override at runtime with -e FIRMWARE_RELEASE=... / FIRMWARE_SHA256=...
# ---------------------------------------------------------------------------
FIRMWARE_REPO="Warfront1/radxa-zero-3-boot-firmware"
FIRMWARE_RELEASE="${FIRMWARE_RELEASE:-v2026.07}"
FIRMWARE_SHA256="${FIRMWARE_SHA256:-ed1b019e0ab5cc7385c3096813c87e5214a89dac1a670471680987063b510b68}"
FIRMWARE_BASE="https://github.com/${FIRMWARE_REPO}/releases/download/${FIRMWARE_RELEASE}"
UBOOT_BIN="/tmp/u-boot-rockchip.bin"

# ---------------------------------------------------------------------------
# Pinned Debian ISO — used if /input/iso is absent; sha256-verified either way.
# Override at runtime with -e DEBIAN_VERSION=... / DEBIAN_ISO_SHA256=...
# ---------------------------------------------------------------------------
DEBIAN_VERSION="${DEBIAN_VERSION:-13.6.0}"
DEBIAN_ISO_NAME="debian-${DEBIAN_VERSION}-arm64-DVD-1.iso"
DEBIAN_ISO_SHA256="${DEBIAN_ISO_SHA256:-0e170d9ff0c53f7b59c8d35793b8ce308ceffd519f8370b949995634e22f5b09}"
DEBIAN_CD_BASE="https://cdimage.debian.org/debian-cd/${DEBIAN_VERSION}/arm64/iso-dvd"
ISO_PATH="/input/iso"

# ---------------------------------------------------------------------------
# Cleanup trap — remove temp dirs on EXIT, even on failure
# ---------------------------------------------------------------------------
cleanup() {
    rm -f /tmp/rootfs.ext4 "$UBOOT_BIN"
    [ -n "${DOWNLOADED_ISO:-}" ] && rm -f "$DOWNLOADED_ISO"
    rm -rf /tmp/rootfs /tmp/iso
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Validate outputs and resolve the Debian ISO
# ---------------------------------------------------------------------------
echo "==> [1/14] Validating inputs..."

if [ ! -w /output ]; then
    echo "ERROR: /output is not writable" >&2
    exit 1
fi

# Resolve the ISO: use a mounted /input/iso if present, else download the pinned release.
if [ -s /input/iso ]; then
    echo "    Using mounted /input/iso"
    ISO_PATH="/input/iso"
else
    echo "    /input/iso not mounted — downloading ${DEBIAN_ISO_NAME} from cdimage.debian.org"
    DOWNLOADED_ISO="/tmp/${DEBIAN_ISO_NAME}"
    curl -fsSL "${DEBIAN_CD_BASE}/${DEBIAN_ISO_NAME}" -o "$DOWNLOADED_ISO"
    ISO_PATH="$DOWNLOADED_ISO"
fi

# Verify the ISO sha256 against the pinned constant (covers both sources).
echo "    Verifying ISO sha256..."
ISO_ACTUAL_SHA256="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
if [ "$ISO_ACTUAL_SHA256" != "$DEBIAN_ISO_SHA256" ]; then
    echo "ERROR: ISO sha256 mismatch" >&2
    echo "       expected: $DEBIAN_ISO_SHA256" >&2
    echo "       actual:   $ISO_ACTUAL_SHA256" >&2
    exit 1
fi
echo "    sha256 verified: $ISO_ACTUAL_SHA256"

# ---------------------------------------------------------------------------
# Step 2: Fetch and verify the bootloader (pinned release, sha256-checked)
# ---------------------------------------------------------------------------
echo "==> [2/14] Fetching bootloader from ${FIRMWARE_REPO}@${FIRMWARE_RELEASE}..."
curl -fsSL "${FIRMWARE_BASE}/u-boot-rockchip.bin" -o "$UBOOT_BIN"

ACTUAL_SHA256="$(sha256sum "$UBOOT_BIN" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$FIRMWARE_SHA256" ]; then
    echo "ERROR: bootloader sha256 mismatch" >&2
    echo "       expected: $FIRMWARE_SHA256" >&2
    echo "       actual:   $ACTUAL_SHA256" >&2
    exit 1
fi
echo "    sha256 verified: $ACTUAL_SHA256"

# ---------------------------------------------------------------------------
# Step 3: Extract ISO (no mount needed)
# ---------------------------------------------------------------------------
echo "==> [3/14] Extracting ISO with bsdtar..."
mkdir -p /tmp/iso
bsdtar xf "$ISO_PATH" -C /tmp/iso

if [ ! -d /tmp/iso/dists ]; then
    echo "ERROR: /tmp/iso/dists/ not found — ISO is not a valid Debian ISO" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Detect the Debian suite (do NOT hardcode)
# ---------------------------------------------------------------------------
echo "==> [4/14] Detecting Debian suite..."
SUITE=""
for d in /tmp/iso/dists/*/; do
    rel="${d}Release"
    [ -f "$rel" ] || continue
    s=$(awk '/^Suite:/ {print $2}' "$rel")
    c=$(awk '/^Codename:/ {print $2}' "$rel")
    if [ -n "$s" ] && [ -n "$c" ] && { [ "$s" = stable ] || [ "$s" = testing ]; }; then
        SUITE="$c"
        break
    fi
done
if [ -z "$SUITE" ]; then
    SUITE="$(ls /tmp/iso/dists/ | head -1)"
    echo "    WARNING: Release files unparseable, falling back to $SUITE" >&2
fi
if [ -z "$SUITE" ]; then
    echo "ERROR: Could not detect Debian suite from /tmp/iso/dists/" >&2
    exit 1
fi
echo "    Detected suite: $SUITE"

# ---------------------------------------------------------------------------
# Step 5: First-stage debootstrap (no chroot, no privileges)
# ---------------------------------------------------------------------------
echo "==> [5/14] First-stage debootstrap (arm64, foreign, minbase)..."
mkdir -p /tmp/rootfs
debootstrap --arch=arm64 --foreign --variant=minbase --no-check-gpg \
    "$SUITE" /tmp/rootfs file:///tmp/iso
# --no-check-gpg: DVD ISOs ship no Release.gpg/InRelease (trusted local media).
# --foreign: only does extraction. We chroot manually for the second stage
# because debootstrap's non-foreign mode tries to mount /proc internally
# (requires SYS_ADMIN, which is NOT a default Docker cap).

# ---------------------------------------------------------------------------
# Step 6: Create device nodes + prepare chroot
# ---------------------------------------------------------------------------
echo "==> [6/14] Creating device nodes and preparing chroot..."

mkdir -p /tmp/rootfs/dev/pts /tmp/rootfs/proc
# debootstrap --foreign may have already created some of these (e.g. /dev/null
# for extraction). Remove them first so mknod doesn't fail under set -e.
rm -f /tmp/rootfs/dev/null /tmp/rootfs/dev/zero \
      /tmp/rootfs/dev/urandom /tmp/rootfs/dev/random \
      /tmp/rootfs/dev/tty /tmp/rootfs/dev/ptmx
mknod -m 666 /tmp/rootfs/dev/null    c 1 3
mknod -m 666 /tmp/rootfs/dev/zero    c 1 5
mknod -m 666 /tmp/rootfs/dev/urandom c 1 9
mknod -m 666 /tmp/rootfs/dev/random  c 1 8
mknod -m 666 /tmp/rootfs/dev/tty     c 5 0
mknod -m 666 /tmp/rootfs/dev/ptmx    c 5 2

# Make the ISO available inside the chroot at /tmp/iso. We can't bind-mount
# (no SYS_ADMIN), so move it into the rootfs — instant rename on the same
# /tmp filesystem, no copy. debootstrap --foreign (Step 5) is done with the
# ISO, and --second-stage works from extracted .debs already in the rootfs,
# so moving it now is safe. Done after Step 5 so --foreign's extraction
# never runs on a non-empty /tmp/rootfs.
mkdir -p /tmp/rootfs/tmp
mv /tmp/iso /tmp/rootfs/tmp/iso

# resolv.conf so apt can resolve names if it falls back to network
# (file:// sources don't need DNS, but some postinst hooks may).
mkdir -p /tmp/rootfs/etc
cp /etc/resolv.conf /tmp/rootfs/etc/resolv.conf 2>/dev/null \
    || echo "nameserver 8.8.8.8" > /tmp/rootfs/etc/resolv.conf

# ---------------------------------------------------------------------------
# Step 7: Second-stage debootstrap via chroot
# ---------------------------------------------------------------------------
echo "==> [7/14] Second-stage debootstrap via chroot..."
chroot /tmp/rootfs /debootstrap/debootstrap --second-stage --no-check-gpg

# ---------------------------------------------------------------------------
# Step 8: Install packages via chroot + apt
# ---------------------------------------------------------------------------
echo "==> [8/14] Installing packages (linux-image-arm64, initramfs-tools, openssh-server, e2fsprogs, parted)..."

# apt source points at the ISO, now inside the rootfs at /tmp/iso (moved
# in Step 6). trusted=yes: DVD ISOs ship no Release.gpg/InRelease.
echo "deb [trusted=yes] file:///tmp/iso $SUITE main" > /tmp/rootfs/etc/apt/sources.list

chroot /tmp/rootfs apt update
chroot /tmp/rootfs env DEBIAN_FRONTEND=noninteractive \
    apt install -y linux-image-arm64 initramfs-tools openssh-server debian-archive-keyring e2fsprogs parted

# Drop the ISO contents from the rootfs — they were only needed for apt
# install above. Without this, Step 12's du measures ~4 GB of dead ISO
# weight and bakes it into the ext4 image (a bind-mount approach would
# keep the ISO outside the rootfs, so this cleanup wouldn't be needed).
rm -rf /tmp/rootfs/tmp/iso

cat > /tmp/rootfs/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $SUITE main contrib non-free-firmware
deb http://deb.debian.org/debian-security $SUITE-security main contrib non-free-firmware
deb http://deb.debian.org/debian $SUITE-updates main contrib non-free-firmware
EOF
rm -rf /tmp/rootfs/var/lib/apt/lists/*

# Delete SSH host keys generated by the openssh-server postinst during
# the build. If we ship these, anyone who gets the image file has the
# host keys (MITM risk). Deleting them is safe: sshd-keygen.service
# (shipped by openssh-server, already wired into ssh.service.wants via
# ConditionFirstBoot=yes) runs ssh-keygen -A on the first real boot,
# generating fresh unique keys. This matches what Armbian and DietPi do.
rm -f /tmp/rootfs/etc/ssh/ssh_host_*_key /tmp/rootfs/etc/ssh/ssh_host_*_key.pub

# ---------------------------------------------------------------------------
# Step 9: Configure the rootfs (direct file writes — no chroot needed)
# ---------------------------------------------------------------------------
echo "==> [9/14] Configuring rootfs..."

# Hostname
echo "zero3e" > /tmp/rootfs/etc/hostname

# Networking: systemd-networkd for Ethernet DHCP. systemd-resolved is a
# separate package not on DVD-1, so we use a static resolv.conf instead.
# We can't run systemctl enable in the chroot (no /proc, no bus), so create
# the multi-user.target.wants symlink directly (exactly what `systemctl
# enable` writes).
mkdir -p /tmp/rootfs/etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/systemd-networkd.service \
    /tmp/rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd.service

# networkd .network file — DHCP on any Ethernet interface. Name=en* eth0
# covers both predictable (enP*, end0) and legacy (eth0) interface names.
mkdir -p /tmp/rootfs/etc/systemd/network
cat > /tmp/rootfs/etc/systemd/network/10-ethernet.network <<'NET'
[Match]
Name=en* eth0

[Network]
DHCP=yes
NET

# resolv.conf: replace the build-host copy (stale on first boot) with a
# static public resolver. networkd gets connectivity via DHCP; glibc reads
# this file directly for DNS.
rm -f /tmp/rootfs/etc/resolv.conf
cat > /tmp/rootfs/etc/resolv.conf <<'RES'
nameserver 1.1.1.1
nameserver 8.8.8.8
RES

# Root password: "radxa" (generate SHA-512 hash, write directly to /etc/shadow)
HASH="$(openssl passwd -6 radxa)"
sed -i "s|^root:[^:]*:|root:${HASH}:|" /tmp/rootfs/etc/shadow

# Serial console getty (ttyS2 = UART2 @ 0xfe660000, 1500000 baud)
mkdir -p /tmp/rootfs/etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service \
    /tmp/rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service

# HDMI console getty (tty1 — visible once DRM probes)
ln -sf /lib/systemd/system/getty@.service \
    /tmp/rootfs/etc/systemd/system/getty.target.wants/getty@tty1.service

# First-boot warning in root's .bash_login
cat > /tmp/rootfs/root/.bash_login <<'WARN'
echo ""
echo "============================================================="
echo "  WARNING: Default root password is 'radxa'."
echo "           CHANGE IT NOW:  passwd"
echo "============================================================="
echo ""
WARN

# ---------------------------------------------------------------------------
# Step 10: Set up boot files
# ---------------------------------------------------------------------------
echo "==> [10/14] Setting up boot files..."

# Find the installed kernel version
KVER="$(ls /tmp/rootfs/boot/vmlinuz-* | sed 's/.*vmlinuz-//' | sort -V | tail -1)"
if [ -z "$KVER" ]; then
    echo "ERROR: No kernel found under /tmp/rootfs/boot/" >&2
    exit 1
fi
echo "    Kernel version: $KVER"

# Create stable symlinks
cp /tmp/rootfs/boot/vmlinuz-"$KVER"  /tmp/rootfs/boot/vmlinuz
cp /tmp/rootfs/boot/initrd.img-"$KVER" /tmp/rootfs/boot/initrd.img

# Copy the DTB (prefer kernel's own, fall back to /input/board.dtb, else error)
mkdir -p /tmp/rootfs/boot/dtbs
DTB_SRC="/tmp/rootfs/usr/lib/linux-image-$KVER/rockchip/rk3566-radxa-zero-3e.dtb"
if [ -f "$DTB_SRC" ]; then
    cp "$DTB_SRC" /tmp/rootfs/boot/dtbs/
    echo "    DTB: using kernel's own ($DTB_SRC)"
elif [ -f "/input/board.dtb" ]; then
    cp /input/board.dtb /tmp/rootfs/boot/dtbs/rk3566-radxa-zero-3e.dtb
    echo "    DTB: using /input/board.dtb (fallback)"
else
    echo "ERROR: No DTB found — neither kernel DTB at $DTB_SRC nor /input/board.dtb" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 11: Generate PARTUUID and write config files
# ---------------------------------------------------------------------------
echo "==> [11/14] Generating PARTUUID and writing config files..."
PARTUUID="$(uuidgen | tr 'A-F' 'a-f')"
echo "    PARTUUID: $PARTUUID"

# fstab
echo "PARTUUID=$PARTUUID  /  ext4  defaults,rw  0  1" > /tmp/rootfs/etc/fstab

# extlinux.conf — the file U-Boot's distro_bootcmd scans for
mkdir -p /tmp/rootfs/boot/extlinux
cat > /tmp/rootfs/boot/extlinux/extlinux.conf <<EOF
default Debian
timeout 3

label Debian
    kernel /boot/vmlinuz
    initrd /boot/initrd.img
    fdt /boot/dtbs/rk3566-radxa-zero-3e.dtb
    append root=PARTUUID=$PARTUUID rw rootwait console=ttyS2,1500000n8 console=tty1
EOF

# ---------------------------------------------------------------------------
# Step 12: Create ext4 image from rootfs directory (no loop device, no mount)
# ---------------------------------------------------------------------------
echo "==> [12/14] Creating ext4 image from rootfs directory..."

# Calculate size: rootfs + 20% headroom, minimum 1.0 GiB
ROOTFS_SIZE="$(du -sb /tmp/rootfs | awk '{print $1}')"
EXT4_SIZE=$(( ROOTFS_SIZE * 12 / 10 ))
if [ "$EXT4_SIZE" -lt 1073741824 ]; then
    EXT4_SIZE=1073741824
fi
echo "    rootfs: $((ROOTFS_SIZE / 1048576)) MiB  ext4 image: $((EXT4_SIZE / 1048576)) MiB"

# Create sparse file, then build ext4 from directory
truncate -s "$EXT4_SIZE" /tmp/rootfs.ext4
mke2fs -t ext4 -d /tmp/rootfs -L rootfs /tmp/rootfs.ext4
# mke2fs -d builds an ext4 filesystem populated from a directory — no mount
# or loop device needed. It preserves file permissions, ownership, symlinks,
# and device nodes correctly (writes ext4 structures directly to the file).

# ---------------------------------------------------------------------------
# Step 13: Assemble the disk image
# ---------------------------------------------------------------------------
echo "==> [13/14] Assembling disk image..."

# Disk size = partition start + ext4 image + 1 MiB buffer (for backup GPT)
PART_START_BYTES=$(( 32768 * 512 ))  # 16 MiB
DISK_SIZE=$(( PART_START_BYTES + EXT4_SIZE + 1048576 ))

# Create sparse disk image
truncate -s "$DISK_SIZE" /output/debian-zero3e.img

# Create GPT with partition 1 at sector 32768, with fixed PARTUUID
sgdisk --clear \
    --new=1:32768:0 \
    --typecode=1:8300 \
    --partition-guid=1:"$PARTUUID" \
    /output/debian-zero3e.img

# Write bootloader at sector 64 (byte 32,768 — where Rockchip BootROM expects it)
dd if="$UBOOT_BIN" of=/output/debian-zero3e.img \
    seek=64 bs=512 conv=notrunc status=none

# Write ext4 image at partition start (sector 32768 = byte 16,777,216)
dd if=/tmp/rootfs.ext4 of=/output/debian-zero3e.img \
    seek=32768 bs=512 conv=notrunc status=none

# ---------------------------------------------------------------------------
# Step 14: Clean up and print instructions
# ---------------------------------------------------------------------------
# cleanup trap handles temp file removal
echo "==> [14/14] Done."
echo ""
echo "Image built: /output/debian-zero3e.img"
echo "Size: $(du -sh /output/debian-zero3e.img | awk '{print $1}')"