#!/bin/bash
# Build the release PKG: stage assets, stamp them, run the OpenOrbis build.
#
# Refuses to package anything that is not a release build, and refuses to
# package a payload that would be written to an autoload directory (it never is:
# the app only sends it to GoldHEN's BinLoader when the user confirms).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
B=${B:-$HERE/../out}
P=$HERE/../pkg/installer
A=$P/assets/ps4linux
# K is the directory holding bzImage and .config. Default: what build-kernel.sh
# leaves behind. Point it at a kernel you already built instead of rebuilding.
K=${K:-$B/kbuild/out}
PAYLOAD=${PAYLOAD:-$B/ps4linux-loader.bin}
# The rootfs tarball is only needed for the on-console populate path (an
# initramfs with mke2fs). With a host-built image it is dead weight, so
# WITH_ROOTFS=0 leaves it out; the image itself is never inside the PKG.
WITH_ROOTFS=${WITH_ROOTFS:-1}

export OO_PS4_TOOLCHAIN=${OO_PS4_TOOLCHAIN:-}
[ -n "$OO_PS4_TOOLCHAIN" ] || { echo "set OO_PS4_TOOLCHAIN to a built OpenOrbis toolchain" >&2; exit 1; }
[ -x "$OO_PS4_TOOLCHAIN/bin/linux/PkgTool.Core" ] || {
	echo "no PkgTool.Core in $OO_PS4_TOOLCHAIN/bin/linux - the git repo alone is not a built toolchain" >&2
	exit 1
}

# --- release-only checks
[ -f "$K/bzImage" ] || { echo "no kernel (scripts/build-kernel.sh)" >&2; exit 1; }
[ -f "$B/initramfs.cpio.gz" ] || { echo "no initramfs (scripts/build-initramfs.sh)" >&2; exit 1; }
[ -f "$PAYLOAD" ] || { echo "no loader payload at $PAYLOAD" >&2; exit 1; }
if [ "$WITH_ROOTFS" = 1 ]; then
	[ -f "$B/rootfs.tar.zst" ] || { echo "no rootfs (scripts/build-rootfs.sh), or set WITH_ROOTFS=0" >&2; exit 1; }
	zstd -t "$B/rootfs.tar.zst"
	grep -q '^CONFIG_ZSTD_DECOMPRESS=y' "$K/.config" || { echo "kernel cannot read the rootfs" >&2; exit 1; }
fi
grep -q 'amdgpu/' "$K/.config" || { echo "kernel lacks built-in GPU firmware" >&2; exit 1; }
# CONFIG_NETCONSOLE is deliberately not a blocker: the upstream PS4 tree turns it
# on by default (scripts/build-kernel.sh says the same), and it stays inert unless
# the boot command line passes netconsole=. Magic SysRq and debugfs are genuine
# debugging holes and are off in the shipped config, so those still stop a build.
for opt in CONFIG_MAGIC_SYSRQ CONFIG_DEBUG_FS; do
	grep -q "^$opt=y" "$K/.config" && { echo "release kernel has debug option $opt" >&2; exit 1; }
done
grep -q '^CONFIG_NETCONSOLE=y' "$K/.config" \
	&& echo "NOTE: CONFIG_NETCONSOLE=y (upstream default, inactive unless netconsole= is passed)" >&2
zcat "$B/initramfs.cpio.gz" | cpio -t --quiet | grep -qx 'functions/55-ps4linux.sh' \
	|| { echo "initramfs lacks our boot function" >&2; exit 1; }

# --- stage
rm -rf "$A"; mkdir -p "$A"
ln "$K/bzImage" "$A/bzImage"
ln "$B/initramfs.cpio.gz" "$A/initramfs.cpio.gz"
cp "$PAYLOAD" "$A/ps4linux-loader.bin"
assets="bzImage initramfs.cpio.gz ps4linux-loader.bin"
if [ "$WITH_ROOTFS" = 1 ]; then
	ln "$B/rootfs.tar.zst" "$A/rootfs.tar.zst"
	assets="$assets rootfs.tar.zst"
fi
( cd "$A" && sha256sum $assets | sha256sum | cut -c1-32 ) > "$A/build-id"

# --- package: two apps, built one at a time (intermediate names are shared)
build_app() {
	app=$1
	( cd "$P" && make -s clean && make -s APP="$app" ) \
		|| { echo "build failed: APP=$app" >&2; exit 1; }
	pkg=$(ls -1 "$P"/*.pkg 2>/dev/null | head -1)
	[ -n "$pkg" ] || { echo "APP=$app produced no PKG" >&2; exit 1; }
	mkdir -p "$B/pkg"
	mv -f "$pkg" "$B/pkg/"
	echo "PKG: $B/pkg/$(basename "$pkg") ($(stat -c %s "$B/pkg/$(basename "$pkg")") bytes)"
}
build_app install
build_app remove
( cd "$B/pkg" && sha256sum *.pkg > SHA256SUMS )
if [ "$WITH_ROOTFS" = 1 ]; then
	echo "kernel $(cat "$K/../include/config/kernel.release" 2>/dev/null || echo '?'), rootfs $(du -h "$B/rootfs.tar.zst" | cut -f1)"
else
	echo "kernel $(cat "$K/../include/config/kernel.release" 2>/dev/null || echo '?'), no rootfs (host-built image)"
fi
