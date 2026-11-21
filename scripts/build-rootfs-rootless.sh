#!/bin/bash
# Build the Debian rootfs as rootfs.tar.zst without root.
#
# scripts/build-rootfs.sh is the supported recipe: debootstrap plus an XFCE
# package set on a machine where you can be root. This script is the fallback for
# a build host where you cannot, and it is the one that produced the tarball the
# v1.0.0 package carries. It does not chroot anywhere:
#
#   1. apt resolves the dependency tree with Dir= pointing at a scratch tree and
#      downloads every .deb (--download-only, so dpkg never runs);
#   2. dpkg-deb -x unpacks each one into the tree, unprivileged;
#   3. the files Debian normally creates from postinst scripts are written here:
#      /etc/passwd and /etc/group from base-passwd's masters, /etc/shadow with a
#      real hash, machine-id, hostname, fstab, the autologin config and the unit
#      links;
#   4. ldconfig runs under proot (so /etc/ld.so.cache is real);
#   5. tar packs it with uid/gid forced to 0.
#
# What this does NOT do: run package postinst scripts. Fonts, icon caches and a
# few /etc files a postinst would create are therefore missing; systemd, XFCE,
# lightdm and X all work without them.
#
# The PS4-patched Mesa is built separately (scripts/build-mesa.sh, also no root)
# and copied in when PS4_MESA points at it. Without that the image falls back to
# software rendering, because stock Mesa does not bind the PS4 GPU.
#
# Needs: apt-get, dpkg-deb, gcc, tar, a *static* zstd (ZSTD=...), and proot for
# step 4 only (https://github.com/proot-me/proot releases, single binary).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../out/rootfs.tar.zst}
R=${R:-$HERE/../build/rootfs}
PROOT=${PROOT:-proot}
ZSTD=${ZSTD:-zstd}
USER_NAME=${USER_NAME:-ps4}
USER_PASS=${USER_PASS:-ps4linux}
PS4_MESA=${PS4_MESA:-}            # directory produced by scripts/build-mesa.sh

PKGS="xfce4 xfce4-terminal thunar lightdm lightdm-gtk-greeter
	network-manager pipewire pipewire-pulse wireplumber alsa-utils
	xserver-xorg xserver-xorg-video-amdgpu xserver-xorg-input-libinput
	libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers
	dbus dbus-x11 sudo nano htop locales tzdata console-setup keyboard-configuration
	systemd systemd-sysv udev e2fsprogs dosfstools ca-certificates
	wpasupplicant iw rfkill pciutils usbutils
	base-files base-passwd dpkg debianutils mawk grep sed findutils coreutils
	dash bash apt tar gzip login passwd util-linux procps sysvinit-utils
	init-system-helpers adduser"

[ "$(id -u)" = 0 ] && { echo "run this as a normal user, not root" >&2; exit 1; }

rm -rf "$R"
mkdir -p "$R/etc/apt/apt.conf.d" "$R/etc/apt/preferences.d" "$R/etc/apt/trusted.gpg.d" \
	"$R/var/lib/apt/lists/partial" "$R/var/cache/apt/archives/partial" "$R/var/lib/dpkg"

# The archive keyring, so apt can verify what it downloads.
KEYRING_DEB=$(mktemp)
curl -fsSL -o "$KEYRING_DEB" \
	"http://deb.debian.org/debian/pool/main/d/debian-archive-keyring/$(curl -fsSL \
	http://deb.debian.org/debian/pool/main/d/debian-archive-keyring/ \
	| grep -oE 'debian-archive-keyring_[^"]*_all\.deb' | sort -u | tail -1)"
dpkg-deb -x "$KEYRING_DEB" /tmp/.ps4-keyring.$$
cp /tmp/.ps4-keyring.$$/usr/share/keyrings/debian-archive-keyring.gpg "$R/etc/apt/trusted.gpg.d/"
rm -rf /tmp/.ps4-keyring.$$ "$KEYRING_DEB"

cat > "$R/etc/apt/sources.list" <<'SRC'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
SRC
: > "$R/var/lib/dpkg/status"

APT="apt-get -o Dir=$R -o Dir::Etc::sourcelist=$R/etc/apt/sources.list \
	-o Dir::Etc::sourceparts=/dev/null -o Dir::State::status=$R/var/lib/dpkg/status \
	-o Dir::Cache=$R/var/cache/apt -o Dir::State=$R/var/lib/apt \
	-o Dir::Etc::trusted=$R/etc/apt/trusted.gpg -o Dir::Etc::trustedparts=$R/etc/apt/trusted.gpg.d \
	-o APT::Get::List-Cleanup=0 -o Acquire::Retries=3"

# shellcheck disable=SC2086
$APT update
# shellcheck disable=SC2086
$APT -y --download-only --no-install-recommends install $PKGS

COUNT=$(ls -1 "$R"/var/cache/apt/archives/*.deb | wc -l)
echo "unpacking $COUNT packages"
# A partial download used to produce a tarball that looked fine and had no shell
# in it. Refuse to pack a tree that cannot be booted.
[ "$COUNT" -ge 300 ] || { echo "only $COUNT packages downloaded - refusing to pack a partial image" >&2; exit 1; }
: > "$R/var/lib/dpkg/status"
for d in "$R"/var/cache/apt/archives/*.deb; do
	dpkg-deb -x "$d" "$R" || { echo "unpack failed: $d" >&2; exit 1; }
	# One status entry per package, so apt inside the image knows what is already
	# installed. Without this, `apt install` inside Linux tries to reinstall the
	# whole system and dpkg refuses.
	ctl=$(mktemp)
	dpkg-deb -f "$d" > "$ctl" 2>/dev/null || true
	grep -q '^Status:' "$ctl" || printf 'Status: install ok installed\n' >> "$ctl"
	cat "$ctl" >> "$R/var/lib/dpkg/status"
	printf '\n' >> "$R/var/lib/dpkg/status"
	rm -f "$ctl"
done
for f in bin/sh usr/bin/sh usr/bin/ls usr/bin/apt usr/bin/dpkg usr/sbin/init; do
	[ -e "$R/$f" ] || { echo "$f is missing after unpacking - refusing to pack an image that cannot boot" >&2; exit 1; }
done
echo "  status entries: $(grep -c '^Package:' "$R/var/lib/dpkg/status")"

# --- accounts. Debian's own masters, then the desktop user.
cp "$R/usr/share/base-passwd/passwd.master" "$R/etc/passwd"
cp "$R/usr/share/base-passwd/group.master" "$R/etc/group"
grep -q "^$USER_NAME:" "$R/etc/group" || echo "$USER_NAME:x:1000:" >> "$R/etc/group"
for g in adm sudo audio video plugdev netdev; do
	grep -q "^$g:" "$R/etc/group" || echo "$g:x:$((100 + $(grep -c '^' "$R/etc/group"))):" >> "$R/etc/group"
done
grep -q "^$USER_NAME:" "$R/etc/passwd" \
	|| echo "$USER_NAME:x:1000:1000:PS4 Linux:/home/$USER_NAME:/bin/bash" >> "$R/etc/passwd"
mkdir -p "$R/home/$USER_NAME"
cp -a "$R/etc/skel/." "$R/home/$USER_NAME/" 2>/dev/null || true

HASH=$(openssl passwd -6 -salt ps4linux "$USER_PASS")
while IFS=: read -r name _rest; do
	[ -z "$name" ] && continue
	case "$name" in
		"$USER_NAME"|root) printf '%s:%s:20300:0:99999:7:::\n' "$name" "$HASH" ;;
		*) printf '%s:*:20300:0:99999:7:::\n' "$name" ;;
	esac
done < "$R/etc/passwd" > "$R/etc/shadow"
chmod 0640 "$R/etc/shadow"; chmod 0644 "$R/etc/passwd" "$R/etc/group"

# --- identity and services
echo ps4linux > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tps4linux\n::1\tlocalhost ip6-localhost\n' > "$R/etc/hosts"
head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$R/etc/machine-id"
echo 'C.UTF-8' > "$R/etc/default/locale"
ln -sf /usr/share/zoneinfo/Etc/UTC "$R/etc/localtime"
printf '/dev/root\t/\text4\tdefaults,noatime\t0 1\n' > "$R/etc/fstab"
mkdir -p "$R/etc/lightdm/lightdm.conf.d" "$R/etc/sudoers.d" \
	"$R/etc/systemd/system/multi-user.target.wants" "$R/etc/systemd/system/sysinit.target.wants" \
	"$R/usr/local/bin" "$R/var/log" "$R/tmp" "$R/run"
chmod 1777 "$R/tmp"
cat > "$R/etc/lightdm/lightdm.conf.d/50-autologin.conf" <<L
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
L
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$R/etc/sudoers.d/10-$USER_NAME"
chmod 0440 "$R/etc/sudoers.d/10-$USER_NAME"

# --- our own overlay from the repository
for f in etc/apt/preferences.d/ps4-components etc/environment \
         etc/ld.so.conf.d/00-ps4-mesa.conf \
         etc/systemd/system/ps4-boot-ro.service etc/systemd/system/ps4-hwprofile.service \
         usr/share/vulkan/icd.d/ps4-mesa.json \
         usr/share/glvnd/egl_vendor.d/10-ps4-mesa.json; do
	install -D -m 0644 "$HERE/../rootfs/$f" "$R/$f"
done
gcc -O2 -Wall -Wextra -o "$R/usr/local/bin/ps4-hwprofile" "$HERE/../tools/hwprofile.c"
chmod 0755 "$R/usr/local/bin/ps4-hwprofile"

# --- the PS4-patched Mesa, if one was built (scripts/build-mesa.sh).
# Stock Mesa does not bind the PS4 GPU, so without this the image boots into
# software rendering. The libraries stay in /opt so an apt upgrade cannot
# replace them; libglvnd reaches them through these two symlinks, which are
# named ps4-mesa to match __GLX_VENDOR_LIBRARY_NAME in etc/environment.
if [ -n "$PS4_MESA" ] && [ -d "$PS4_MESA" ]; then
	mkdir -p "$R/opt/ps4-mesa" "$R/usr/lib/x86_64-linux-gnu"
	cp -a "$PS4_MESA/." "$R/opt/ps4-mesa/"
	ln -sf /opt/ps4-mesa/lib/x86_64-linux-gnu/libGLX_mesa.so.0.0.0 \
		"$R/usr/lib/x86_64-linux-gnu/libGLX_ps4-mesa.so.0"
	ln -sf /opt/ps4-mesa/lib/x86_64-linux-gnu/libEGL_mesa.so.0.0.0 \
		"$R/usr/lib/x86_64-linux-gnu/libEGL_ps4-mesa.so.0"
	for g in "$R"/opt/ps4-mesa/lib/x86_64-linux-gnu/libgallium-*.so; do
		[ -e "$g" ] || continue
		ln -sf "/opt/ps4-mesa/lib/x86_64-linux-gnu/$(basename "$g")" \
			"$R/usr/lib/x86_64-linux-gnu/$(basename "$g")"
	done
	echo "  mesa: $(du -sh "$R/opt/ps4-mesa" | cut -f1) in /opt/ps4-mesa (PS4-patched)"
else
	echo "WARNING: PS4_MESA not set - the image gets stock Mesa, which does not" >&2
	echo "         bind the PS4 GPU. Run scripts/build-mesa.sh first." >&2
fi

# Unit links. `systemctl --root` cannot enable lightdm here: lightdm ships a SysV
# script, and systemd-sysv-install then wants a real chroot.
ln -sf /usr/lib/systemd/system/lightdm.service "$R/etc/systemd/system/display-manager.service"
for u in NetworkManager.service NetworkManager-dispatcher.service; do
	ln -sf "/usr/lib/systemd/system/$u" "$R/etc/systemd/system/multi-user.target.wants/$u"
done
ln -sf /usr/lib/systemd/system/graphical.target "$R/etc/systemd/system/default.target"
ln -sf /etc/systemd/system/ps4-boot-ro.service "$R/etc/systemd/system/sysinit.target.wants/ps4-boot-ro.service"
ln -sf /etc/systemd/system/ps4-hwprofile.service "$R/etc/systemd/system/multi-user.target.wants/ps4-hwprofile.service"

# --- ld.so.cache, for real
# proot is the only unprivileged way to run the target's own ldconfig, so the
# cache records target paths. It crashes on some hardened kernels (seccomp or
# ptrace restrictions, "terminated with signal 11"), and that must not cost us
# the image: without a cache the loader still searches /lib and /usr/lib, and
# everything this build installs lives there or is reached through the glvnd
# symlinks. So a failure here is a warning, not an exit.
if ! "$PROOT" -0 -r "$R" -b /proc -b /dev -b /sys -w / /sbin/ldconfig; then
	echo "WARNING: ldconfig under proot failed - no /etc/ld.so.cache in this image." >&2
	echo "         Default library paths still resolve; nothing here depends on the cache." >&2
fi

# --- clean and pack
rm -rf "$R"/var/cache/apt/archives/*.deb "$R"/var/lib/apt/lists/* \
	"$R"/var/cache/apt/pkgcache.bin "$R"/var/cache/apt/srcpkgcache.bin
mkdir -p "$(dirname "$OUT")"
( cd "$R" && tar --owner=0 --group=0 --numeric-owner -cf - . ) | "$ZSTD" -19 -T0 -q -f -o "$OUT"
"$ZSTD" -t "$OUT"
echo "rootfs: $OUT ($(stat -c %s "$OUT") bytes, $( ( cd "$R" && find . | wc -l ) ) entries)"
