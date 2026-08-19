<div align="center">

# radxa-zero-3-debian

Your hardware, built in China :cn:  
Your Debian OS, assembled as open-source as possible in the USA :us:.

<img src="radxa-zero-3e.png" alt="Radxa Zero 3E board" width="300">

[![Discord](https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white)](https://discord.gg/XCcQpEehej)

</div>

An easy-to-write Debian arm64 SD card image for the Radxa Zero 3E and 3W.<br>*3E only for now; 3W untested but likely functional.*

## Flash the image

Prebuilt images are available on the
[GitHub Releases page](https://github.com/Warfront1/radxa-zero-3-debian/releases).  
Download `debian-zero3e.img`, then write it to your SD card:

<details>
<summary>Windows</summary>

Use [Rufus](https://rufus.ie): pick the SD card, select `debian-zero3e.img`, hit Start.
</details>

<details>
<summary>Linux / macOS</summary>

```sh
# /dev/sdX = your SD card (use `lsblk` to find it) — not a partition (sdX1)
sudo dd if=debian-zero3e.img of=/dev/sdX bs=4M status=progress conv=fsync
```

On macOS, use `/dev/rdiskN` instead (faster) — find it with `diskutil list`.
</details>

## First boot

- Login: `root` / password: `radxa` &mdash; change immediately: `passwd`
- SSH is installed but not accessible by default (root login is key-only, no key configured)

### Expand the root filesystem

The minimal image ships undersized to keep downloads small. Expand it to fill your SD card:

```sh
# run on the booted board as root — /dev/mmcblk0 is the SD card (use `lsblk` to confirm)
parted /dev/mmcblk0 resizepart 1 100%
resize2fs /dev/mmcblk0p1
```

<details>
<summary>Create a non-root user and lock root (recommended)</summary>

The image ships with only the `root` account. For daily use, create a non-root user with `sudo` access, then lock the `root` password.

```sh
apt update && apt install sudo
useradd -m -s /bin/bash <username>
passwd <username>
usermod -aG sudo <username>
```

Switch to the new user and verify `sudo` works **before** locking root:

```sh
su - <username>
sudo whoami   # should print "root"
```

Once confirmed, lock the root password:

```sh
sudo passwd -l root
```

After locking root, the `root` account can no longer log in via password (serial console included).

</details>

---

Building the image yourself? See [DEVELOPERS.md](DEVELOPERS.md).