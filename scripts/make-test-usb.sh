#!/bin/bash
# Build a testable PS4 Linux USB set. Works on a normal x86-64 Linux PC and,
# with a prebuilt rootfs, on Termux/Android (arm64) - no root, no toolchain.
#
# Produces the three files the stock initramfs-ps4 installer understands:
#   bzImage             prebuilt PS4 kernel (pinned URL, magic-checked)
#   initramfs.cpio.gz   repacked from the initramfs-ps4 base tree
#   distro.tar.xz       Debian amd64 rootfs  (the stock installer refuses .zst)
#
# Two ways to get the rootfs:
#   ROOTFS_TARBALL=<url|path>  use a prebuilt amd64 rootfs (default on non-x86
#                              hosts, e.g. a phone). No root, no emulation.
#   (unset)                    build one with debootstrap - needs an x86-64 host
#                              and root.
#
# Then install the desktop ON THE CONSOLE, natively:
#   apt update && apt install xfce4
# That also proves networking and package management, which is the point of the
# first test.
set -euo pipefail

PROFILE=${PROFILE:-minimal}
KERNEL_URL=${KERNEL_URL:-}
ROOTFS_TARBALL=${ROOTFS_TARBALL:-}
INITRAMFS_REPO=${INITRAMFS_REPO:-https://github.com/theJetsetlife/chromeos-ps4}
OUT=${OUT:-$PWD/ps4linux-usb}
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SECURITY=${SECURITY:-http://security.debian.org/debian-security}
XZ_LEVEL=${XZ_LEVEL:-6}
ROOT_PASS=${ROOT_PASS:-ps4}
USER_NAME=${USER_NAME:-ps4}
HOST_ARCH=$(uname -m)
IS_TERMUX=0
[ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ] && IS_TERMUX=1
HERE=$(cd "$(dirname "$0")" && pwd)

# Verified: HTTP 200, 93 MB, Debian 13 amd64 rootfs. The directory name changes
# with every build, so the newest one is resolved at run time.
LXC_INDEX="https://images.linuxcontainers.org/images/debian/$SUITE/amd64/default/"

if [ -z "$KERNEL_URL" ]; then
	KERNEL_URL="https://github.com/feeRnt/ps4-linux-12xx/releases/download/v6.15.4__crashnt-4.8.3/bzImage"
fi

pkg_hint() { if [ "$IS_TERMUX" = 1 ]; then echo "pkg install $1"; else echo "apt install $1"; fi; }
need() { command -v "$1" >/dev/null || { echo "missing: $1   ($(pkg_hint "${2:-$1}"))" >&2; exit 1; }; }

if [ "${1:-}" = "--check" ]; then
	echo "host: $HOST_ARCH ($([ "$IS_TERMUX" = 1 ] && echo Termux || echo 'regular Linux'))"
	for c in curl xz cpio gzip git tar od; do
		if command -v "$c" >/dev/null; then echo "  ok      $c"; else echo "  MISSING $c   ($(pkg_hint "$c"))"; fi
	done
	if [ "$HOST_ARCH" = x86_64 ]; then
		echo "  rootfs: debootstrap possible ($(command -v debootstrap >/dev/null && echo present || echo "install: $(pkg_hint debootstrap)"))"
	else
		echo "  rootfs: debootstrap cannot run on $HOST_ARCH; use ROOTFS_TARBALL (prebuilt amd64)"
	fi
	echo "  FAT32 limit: keep distro.tar.xz under 4 GiB (a 93 MB base rootfs is fine)"
	exit 0
fi

need curl curl
need xz xz-utils
need gzip gzip
need git git
need tar tar
need od coreutils

mkdir -p "$OUT" "$OUT/.work"
WORK=$OUT/.work

# ---------------------------------------------------------------- 1. kernel
echo "== 1/4 kernel =="
if [ -s "$OUT/bzImage" ]; then
	echo "   already there, keeping it"
else
	curl -fL --retry 3 -o "$OUT/bzImage.part" "$KERNEL_URL"
	# A bzImage carries the setup-header magic "HdrS" at offset 0x202. Do NOT
	# test the first two bytes: real images start with 0xff or 0xeb depending on
	# the build, so that check rejects good kernels (found by testing this).
	if [ "$(od -An -c -j514 -N4 "$OUT/bzImage.part" | tr -d ' ')" != "HdrS" ]; then
		echo "ERROR: $KERNEL_URL did not return a kernel image" >&2
		exit 1
	fi
	mv "$OUT/bzImage.part" "$OUT/bzImage"
fi
ls -l "$OUT/bzImage"

# ---------------------------------------------------------------- 2. initramfs
echo "== 2/4 initramfs (repacked from the initramfs-ps4 base) =="
if [ "${SKIP_INITRAMFS:-0}" = 1 ]; then
	echo "   skipped (SKIP_INITRAMFS=1): using the existing $OUT/initramfs.cpio.gz"
else
need cpio cpio   # only this step needs it, so the rootfs path works without it
BASE=$WORK/chromeos-ps4/initramfs/src
if [ ! -f "$BASE/init" ]; then
	rm -rf "$WORK/chromeos-ps4"
	git clone --depth 1 "$INITRAMFS_REPO" "$WORK/chromeos-ps4"
fi
[ -f "$BASE/init" ] || { echo "ERROR: no init in $BASE" >&2; exit 1; }
chmod +x "$BASE/init" 2>/dev/null || true
chmod +x "$BASE"/bin/*.sh 2>/dev/null || true
chmod +x "$BASE"/hooks/*/* 2>/dev/null || true
rm -f "$BASE/bin/dropbear" "$BASE/bin/dropbearkey"    # no SSH daemon on a test image
( cd "$BASE" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet | gzip -9 ) \
	> "$OUT/initramfs.cpio.gz"
ls -l "$OUT/initramfs.cpio.gz"
fi

# ---------------------------------------------------------------- 3. rootfs
# Patch a rootfs tree without executing anything from it (works on arm64 hosts).
patch_rootfs() {
	R=$1
	# root password (sha512-crypt), so there is a login on the console
	hash=""
	if command -v openssl >/dev/null; then
		hash=$(openssl passwd -6 "$ROOT_PASS" 2>/dev/null || true)
	fi
	if [ -z "$hash" ] && command -v python3 >/dev/null; then
		hash=$(python3 -c 'import crypt,sys;print(crypt.crypt(sys.argv[1],crypt.mksalt(crypt.METHOD_SHA512)))' "$ROOT_PASS" 2>/dev/null || true)
	fi
	if [ -n "$hash" ] && [ -f "$R/etc/shadow" ]; then
		sed -i "s|^root:[^:]*:|root:$hash:|" "$R/etc/shadow"
		echo "   root password set"
	else
		echo "   WARNING: could not set a root password (no openssl/python3 hash tool)" >&2
	fi
	# a login prompt on the TV: getty on tty1
	if [ -f "$R/lib/systemd/system/getty@.service" ]; then
		mkdir -p "$R/etc/systemd/system/getty.target.wants"
		ln -sf /lib/systemd/system/getty@.service \
			"$R/etc/systemd/system/getty.target.wants/getty@tty1.service"
		echo "   getty on tty1 enabled"
	fi
	# apt sources (LXC images ship deb822 .sources; keep ours additive)
	[ -f "$R/etc/apt/sources.list" ] || : > "$R/etc/apt/sources.list"
	if ! grep -q "$MIRROR" "$R/etc/apt/sources.list" 2>/dev/null; then
		cat >> "$R/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb $SECURITY $SUITE-security main contrib non-free non-free-firmware
EOF
	fi
	install -D -m 0644 "$HERE/../rootfs/etc/apt/preferences.d/ps4-components" \
		"$R/etc/apt/preferences.d/ps4-components"
	# the hardware report, shell version: no compiler needed on any host
	install -D -m 0755 "$HERE/../tools/hwprofile.sh" "$R/usr/local/bin/ps4-hwprofile"
	# make sure the console is usable even if metadata is dropped on extraction
	chmod 1777 "$R/tmp" "$R/var/tmp" 2>/dev/null || true
	: > "$R/etc/fstab"
	rm -f "$R/etc/machine-id" "$R/var/lib/dbus/machine-id" 2>/dev/null || true
}

echo "== 3/4 Debian rootfs ($PROFILE) =="
if [ -s "$OUT/distro.tar.xz" ] && [ "${FORCE_ROOTFS:-0}" != 1 ]; then
	echo "   already there, keeping it (FORCE_ROOTFS=1 to rebuild)"
elif [ -n "$ROOTFS_TARBALL" ]; then
	echo "   using a prebuilt rootfs: $ROOTFS_TARBALL"
	SRC_TAR=$WORK/rootfs-src.tar.xz
	case "$ROOTFS_TARBALL" in
		http*://*)
			# LXC images: resolve the newest dated directory when given the index
			if [ "$ROOTFS_TARBALL" = "$LXC_INDEX" ]; then
				NEW=$(curl -sL --max-time 60 "$LXC_INDEX" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | tail -1)
				[ -n "$NEW" ] || { echo "ERROR: could not resolve the newest image under $LXC_INDEX" >&2; exit 1; }
				ROOTFS_TARBALL="${LXC_INDEX}${NEW}/rootfs.tar.xz"
				echo "   resolved: $ROOTFS_TARBALL"
			fi
			curl -fL --retry 3 -o "$SRC_TAR" "$ROOTFS_TARBALL" ;;
		*) cp "$ROOTFS_TARBALL" "$SRC_TAR" ;;
	esac
	xz -t "$SRC_TAR"
	R=$WORK/rootfs
	rm -rf "$R"; mkdir -p "$R"
	tar -xJf "$SRC_TAR" -C "$R" --numeric-owner 2>/dev/null || tar -xJf "$SRC_TAR" -C "$R"
	patch_rootfs "$R"
	if [ "$PROFILE" = desktop ]; then
		echo "   NOTE: PROFILE=desktop cannot be built without an x86-64 host + root." >&2
		echo "         Install it on the console instead: apt install xfce4 lightdm firefox-esr" >&2
	fi
	echo "   packing distro.tar.xz"
	tar --numeric-owner -C "$R" -cf - . | xz -"$XZ_LEVEL" -T0 -c > "$OUT/distro.tar.xz.part"
	mv "$OUT/distro.tar.xz.part" "$OUT/distro.tar.xz"
else
	if [ "$HOST_ARCH" != x86_64 ]; then
		echo "ERROR: debootstrap needs an x86-64 host. On $HOST_ARCH use:" >&2
		echo "  ROOTFS_TARBALL=$LXC_INDEX bash $0" >&2
		exit 1
	fi
	[ "$(id -u)" = 0 ] || { echo "ERROR: rootfs build needs root (debootstrap chroots)" >&2; exit 1; }
	need debootstrap debootstrap
	R=$WORK/rootfs
	rm -rf "$R"
	debootstrap --arch=amd64 --variant=minbase \
		--components=main,contrib,non-free,non-free-firmware \
		--include=ca-certificates,systemd,systemd-sysv,dbus,sudo,openssh-server \
		"$SUITE" "$R" "$MIRROR"
	cat > "$R/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb $SECURITY $SUITE-security main contrib non-free non-free-firmware
EOF
	PKGS="network-manager alsa-utils pciutils usbutils htop nano less curl wget file zstd"
	[ "$PROFILE" = desktop ] && PKGS="$PKGS xfce4 lightdm lightdm-gtk-greeter firefox-esr pipewire pipewire-pulse wireplumber mesa-vulkan-drivers libgl1-mesa-dri vulkan-tools network-manager-gnome firmware-misc-nonfree bluez flatpak"
	DEBIAN_FRONTEND=noninteractive chroot "$R" apt-get update -q
	DEBIAN_FRONTEND=noninteractive chroot "$R" apt-get install -y -q --no-install-recommends $PKGS
	bash "$HERE/../rootfs/build-dummy-kernel.sh" "$R" || true
	patch_rootfs "$R"
	if ! chroot "$R" id "$USER_NAME" >/dev/null 2>&1; then
		chroot "$R" useradd -m -s /bin/bash -G sudo,audio,video,input,netdev "$USER_NAME"
		echo "$USER_NAME:$ROOT_PASS" | chroot "$R" chpasswd
	fi
	chroot "$R" systemctl enable NetworkManager >/dev/null 2>&1 || true
	[ "$PROFILE" = desktop ] && chroot "$R" systemctl enable lightdm >/dev/null 2>&1 || true
	tar --numeric-owner -C "$R" -cf - . | xz -"$XZ_LEVEL" -T0 -c > "$OUT/distro.tar.xz.part"
	mv "$OUT/distro.tar.xz.part" "$OUT/distro.tar.xz"
fi
ls -l "$OUT/distro.tar.xz"

# ---------------------------------------------------------------- 4. verify
echo "== 4/4 checks =="
xz -t "$OUT/distro.tar.xz" && echo "   distro.tar.xz: ok"
if [ -s "$OUT/initramfs.cpio.gz" ] && command -v cpio >/dev/null; then
	( zcat "$OUT/initramfs.cpio.gz" | cpio -t --quiet | grep -qx 'init' ) \
		&& echo "   initramfs has /init: ok"
else
	echo "   WARNING: no initramfs.cpio.gz yet (needs cpio: $(pkg_hint cpio))" >&2
fi
for f in bzImage distro.tar.xz; do
	[ -s "$OUT/$f" ] || { echo "   MISSING $f" >&2; exit 1; }
done
SZ=$(stat -c %s "$OUT/distro.tar.xz")
if [ "$SZ" -gt 4294967296 ]; then
	echo "   WARNING: distro.tar.xz is $((SZ / 1073741824)) GiB - FAT32 cannot hold a" >&2
	echo "            file over 4 GiB, and the installer reads the stick from FAT32." >&2
	echo "            Use PROFILE=minimal, or install the desktop on the console." >&2
fi
( cd "$OUT" && find . -maxdepth 1 -type f ! -name '*.part' ! -path './.work*' -print0 \
	| sort -z | xargs -0 sha256sum > SHA256SUMS )

cat <<EOF

== done ==
Files in $OUT:
$(ls -lh "$OUT" | grep -v '^total\|\.work' | sed 's/^/   /')

On the console:
  1. Copy bzImage, initramfs.cpio.gz and distro.tar.xz to the ROOT of a FAT32 stick.
     On a phone: use the Files app over USB-OTG - Termux cannot write a raw USB
     device without root.
  2. Load a Linux payload (1 GB VRAM variant for a first boot):
     https://github.com/ps4boot/ps4-linux-payloads-archive/releases
  3. Plug in that stick, a second empty stick (TARGET) and a USB keyboard.
  4. In the rescue shell: exec install-linux-ext.sh
     Pick the source stick, then the target stick, type YES to erase it.
  5. After INSTALL COMPLETE it boots. Unplug the SOURCE stick.
  6. Log in as root / $ROOT_PASS (or $USER_NAME / $ROOT_PASS), then:
        ps4-hwprofile | tee /tmp/report.txt
        dmesg | tail -100
     Send me both files.
  7. Then, on the console: apt update && apt install xfce4
     (native amd64 - no emulation; this also tests networking and apt)

This build is stock kernel + stock initramfs + a plain Debian rootfs on purpose,
so a failure is attributable. No PKG, no installer app, no /opt Mesa yet.
EOF
