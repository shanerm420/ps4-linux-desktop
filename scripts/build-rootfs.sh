#!/bin/bash
# Build the Debian rootfs for PS4 Linux Desktop.
#
# Run on an x86-64 Linux host as root (debootstrap + chroot). Produces
# out/rootfs.tar.zst, which the PKG ships and the initramfs unpacks into the
# reserved image.
#
# Design notes:
#  * Debian 13 (trixie): Mesa there is new enough for conformant Vulkan 1.3 on
#    GFX6/7 (RADV gained that in Mesa 24.2). Debian 12's Mesa 22.3 is NOT, which
#    is why bookworm is not supported.
#  * i386 multiarch is enabled because the Steam client is 32-bit.
#  * The PS4 kernel is never installed by apt; a dummy package + pin block it
#    (see rootfs/etc/apt/preferences.d/ps4-components).
#  * The PS4-patched Mesa goes to /opt/ps4-mesa so distro Mesa upgrades cannot
#    replace it.
set -euo pipefail

SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SECURITY=${SECURITY:-http://security.debian.org/debian-security}
ARCH=amd64
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$HERE/../out/rootfs}
OUT=${OUT:-$HERE/../out}
PS4_MESA=${PS4_MESA:-}          # directory produced by scripts/build-mesa.sh
USER_NAME=${USER_NAME:-ps4}

[ "$(id -u)" = 0 ] || { echo "must run as root (debootstrap + chroot)" >&2; exit 1; }
command -v debootstrap >/dev/null || { echo "install debootstrap" >&2; exit 1; }
command -v zstd >/dev/null || { echo "install zstd" >&2; exit 1; }

echo "== debootstrap $SUITE =="
rm -rf "$ROOT"; mkdir -p "$ROOT" "$OUT"
debootstrap --arch=$ARCH --variant=minbase --components=main,contrib,non-free,non-free-firmware \
	--include=ca-certificates,apt-utils,locales,tzdata "$SUITE" "$ROOT" "$MIRROR"

# --- apt sources: stable + security + backports, all signed
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb $SECURITY $SUITE-security main contrib non-free non-free-firmware
deb $MIRROR $SUITE-backports main contrib non-free non-free-firmware
EOF

# --- our policy files, installed before any package so pins apply from the start
install -D -m 0644 "$HERE/../rootfs/etc/apt/preferences.d/ps4-components" \
	"$ROOT/etc/apt/preferences.d/ps4-components"

echo "== multiarch i386 (Steam) =="
chroot "$ROOT" dpkg --add-architecture i386

echo "== base system =="
chroot "$ROOT" apt-get update -q
DEBIAN_FRONTEND=noninteractive chroot "$ROOT" apt-get install -y -q --no-install-recommends \
	linux-image-generic 2>/dev/null || true   # deliberately allowed to fail: pinned out
DEBIAN_FRONTEND=noninteractive chroot "$ROOT" apt-get install -y -q \
	systemd systemd-sysv dbus sudo \
	xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
	firefox-esr \
	network-manager network-manager-gnome \
	pipewire pipewire-pulse wireplumber alsa-utils \
	bluez bluez-tools \
	cups cups-client system-config-printer \
	mesa-utils mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 \
	vulkan-tools \
	firmware-misc-nonfree firmware-realtek \
	flatpak xdg-desktop-portal-gtk \
	ntfs-3g exfatprogs \
	htop nano less curl wget git rsync \
	openssh-client

echo "== Steam (i386) =="
# steam-installer pulls the 32-bit client; skip cleanly on images where it is absent.
DEBIAN_FRONTEND=noninteractive chroot "$ROOT" apt-get install -y -q --install-recommends \
	steam-installer || echo "note: steam-installer unavailable in $SUITE; install via Flatpak"

echo "== dummy PS4 kernel package (blocks apt from ever installing a kernel) =="
"$HERE/../rootfs/build-dummy-kernel.sh" "$ROOT"

echo "== PS4-patched Mesa in /opt (update-proof) =="
if [ -n "$PS4_MESA" ] && [ -d "$PS4_MESA" ]; then
	mkdir -p "$ROOT/opt/ps4-mesa"
	cp -a "$PS4_MESA/." "$ROOT/opt/ps4-mesa/"
	install -D -m 0644 "$HERE/../rootfs/usr/share/vulkan/icd.d/ps4-mesa.json" \
		"$ROOT/usr/share/vulkan/icd.d/ps4-mesa.json"
	install -D -m 0644 "$HERE/../rootfs/etc/environment" "$ROOT/etc/environment"
else
	echo "WARNING: PS4_MESA not set - the rootfs will use stock Mesa, which does not" >&2
	echo "         bind the PS4 GPU. Graphics will not work. See docs/ARCHITECTURE.md." >&2
fi

echo "== hardware tool + services =="
# tools/hwprofile is a compiled binary and is not committed. Build it here; if
# there is no C compiler on the host, fall back to the shell version, which does
# the same job from /proc and /sys.
HW="$HERE/../tools/hwprofile"
if [ ! -x "$HW" ] && command -v cc >/dev/null; then
	cc -O2 -Wall -Wextra -o "$HW" "$HERE/../tools/hwprofile.c" \
		|| { echo "warning: could not build hwprofile.c; using the shell version" >&2; rm -f "$HW"; }
fi
if [ -x "$HW" ]; then
	install -D -m 0755 "$HW" "$ROOT/usr/local/bin/ps4-hwprofile"
else
	install -D -m 0755 "$HERE/../tools/hwprofile.sh" "$ROOT/usr/local/bin/ps4-hwprofile"
fi
install -D -m 0644 "$HERE/../rootfs/etc/systemd/system/ps4-boot-ro.service" \
	"$ROOT/etc/systemd/system/ps4-boot-ro.service"
install -D -m 0644 "$HERE/../rootfs/etc/systemd/system/ps4-hwprofile.service" \
	"$ROOT/etc/systemd/system/ps4-hwprofile.service"
chroot "$ROOT" systemctl enable lightdm NetworkManager bluetooth ps4-boot-ro ps4-hwprofile >/dev/null

echo "== user =="
if ! chroot "$ROOT" id "$USER_NAME" >/dev/null 2>&1; then
	chroot "$ROOT" useradd -m -s /bin/bash -G sudo,audio,video,input,netdev,plugdev "$USER_NAME"
	echo "$USER_NAME:ps4" | chroot "$ROOT" chpasswd
	chroot "$ROOT" chage -d 0 "$USER_NAME"   # force a password change on first login
fi

echo "== verify the things that silently break a PS4 install =="
MESA_VER=$(chroot "$ROOT" dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || echo none)
echo "  mesa: $MESA_VER"
case "$MESA_VER" in
	24.*|25.*|26.*) ;;
	*) echo "ERROR: Mesa $MESA_VER is too old for RADV Vulkan 1.3 on GFX6/7 (need >= 24.2)" >&2; exit 1 ;;
esac
if chroot "$ROOT" dpkg-query -W -f='${Status}' linux-image-amd64 2>/dev/null | grep -q 'install ok installed'; then
	echo "ERROR: a distro kernel got installed - the pin did not work" >&2; exit 1
fi
echo "  no distro kernel installed: ok"

echo "== package =="
rm -f "$ROOT/etc/machine-id" "$ROOT/var/lib/dbus/machine-id"
# The stock initramfs-ps4 installer refuses .zst ("recompress it as distro.tar.xz"),
# so xz is the default. The custom initramfs in initramfs/ reads either.
FORMAT=${FORMAT:-xz}
case "$FORMAT" in
	xz)  tar --numeric-owner --xattrs --acls -C "$ROOT" -cf - . | xz -6 -T0 -c > "$OUT/distro.tar.xz"
	     ( cd "$OUT" && sha256sum distro.tar.xz > distro.tar.xz.sha256 )
	     echo "rootfs: $OUT/distro.tar.xz ($(stat -c %s "$OUT/distro.tar.xz") bytes)" ;;
	zst) tar --numeric-owner --xattrs --acls -C "$ROOT" -cf - . | zstd -19 -T0 -o "$OUT/rootfs.tar.zst" -f
	     ( cd "$OUT" && sha256sum rootfs.tar.zst > rootfs.tar.zst.sha256 )
	     echo "rootfs: $OUT/rootfs.tar.zst ($(stat -c %s "$OUT/rootfs.tar.zst") bytes)" ;;
	*) echo "FORMAT must be xz or zst" >&2; exit 1 ;;
esac
