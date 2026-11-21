#!/bin/bash
# Assemble initramfs.cpio.gz for PS4 Linux Desktop.
#
# Base: a real PS4 initramfs that opens the encrypted PS4 drive (EAP key, AES-XTS,
# UFS2 at /ps4hdd). The base is not vendored here; point BASE at one:
#
#   feeRnt/ps4-linux-initramfs (BSD-3-Clause) is the base this was built and
#   validated with. Any better-initramfs derivative that still does
#     cryptsetup -d /key/eap_hdd_key.bin ... create ps4hdd /dev/sd?27
#     mount -t ufs -o ufstype=ufs2 /dev/mapper/ps4hdd /ps4hdd
#   in its init works too; the handoff below is anchored on that mount line.
#
# Our additions:
#
#   functions/55-ps4linux.sh   find the image (internal file or external device),
#                              mount its single ext4 filesystem, boot it
#   hooks/early/1-recovery     a "ps4linux-recovery" file on any USB stick forces
#                              a rescue shell instead of booting
#   a handoff in the base's init, right after it mounts /ps4hdd, so our boot
#                              function runs only when our own manifest is there
#                              and the base's own flow is untouched otherwise
#   bin/zstd                   static: ps4l_populate unpacks rootfs.tar.zst and
#                              the base's busybox has no zstd applet
#
# No firmware is placed in the initramfs. Two reasons, both learned the hard way
# by the reference project: (1) GPU and Wi-Fi firmware are built into the kernel
# (CONFIG_EXTRA_FIRMWARE carries amdgpu/gladius_* and mrvl/sd8897_*), and the
# loader appends this console's own GPU firmware/EDID/HDD key at boot; (2)
# regulatory.db in an initramfs deadlocks the MediaTek vendor driver
# (reg_regdb_apply -> mtk_reg_notify) and takes DHCP down with it - verified on a
# Fat console.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
B=${B:-$HERE/../out}
BASE=${BASE:-$HERE/../src/initramfs.cpio.gz}   # the base release
STAGE=$B/initramfs-stage
OUT=${OUT:-$B/initramfs.cpio.gz}
VARIANT=${VARIANT:-release}
ZSTD=${ZSTD:-}                                # path to a *static* zstd binary

[ -f "$BASE" ] || { echo "no base initramfs at $BASE (see the header: point BASE at one)" >&2; exit 1; }
[ "$VARIANT" = release ] || { echo "only release builds may ship" >&2; exit 1; }

rm -rf "$STAGE"; mkdir -p "$STAGE"
( cd "$STAGE" && zcat "$BASE" | cpio -idm --quiet --no-absolute-filenames )

install -D -m 0755 "$HERE/../initramfs/functions/55-ps4linux.sh" "$STAGE/functions/55-ps4linux.sh"
install -D -m 0755 "$HERE/../initramfs/hooks/early/1-recovery" "$STAGE/hooks/early/1-recovery"

# Production initramfs: no remote access, no RAM-disk speed test.
rm -f "$STAGE/bin/dropbear" "$STAGE/bin/dropbearkey"
rm -f "$STAGE/hooks/early/2-ramdisk-test"

# --- the handoff
# The base's init sources only /functions.sh and then runs its own boot flow, so
# our functions/*.sh would be dead code. Splice three lines in after it mounts
# the PS4 drive; if the anchor is missing the build stops rather than shipping an
# initramfs that silently ignores our boot logic.
awk '
	{ print }
	!done && /^mount -t ufs -o ufstype=ufs2 \/dev\/mapper\/ps4hdd \/ps4hdd[[:space:]]*$/ {
		print ""
		print "# --- PS4 Linux Desktop: hand over when our own install is present"
		print "if [ -f /ps4hdd/data/ps4linux/manifest.txt ]; then"
		print "\tfor _ps4l_f in /functions/*.sh; do [ -f \"$_ps4l_f\" ] && . \"$_ps4l_f\"; done"
		print "\tps4linux_boot"
		print "fi"
		done = 1
	}
' "$STAGE/init" > "$STAGE/init.new"
grep -q 'ps4linux_boot' "$STAGE/init.new" \
	|| { echo "could not splice the handoff into the base init: does it still mount /ps4hdd?" >&2; exit 1; }
chmod 0755 "$STAGE/init.new"
mv -f "$STAGE/init.new" "$STAGE/init"

# --- zstd for the on-console populate path
if [ -n "$ZSTD" ]; then
	file "$ZSTD" 2>/dev/null | grep -q 'statically linked' \
		|| { echo "ZSTD must be a statically linked binary (the initramfs is not glibc)" >&2; exit 1; }
	install -m 0755 "$ZSTD" "$STAGE/bin/zstd"
fi
if [ ! -x "$STAGE/bin/zstd" ]; then
	echo "NOTE: no static zstd in the initramfs - ps4l_populate cannot unpack rootfs.tar.zst," >&2
	echo "      so a first start from an empty image will drop to the rescue shell" >&2
fi

# Firmware must not be present (see the header).
if find "$STAGE/lib/firmware" -type f ! -name .keep 2>/dev/null | grep . >/dev/null; then
	echo "ERROR: initramfs must not carry firmware:" >&2
	find "$STAGE/lib/firmware" -type f ! -name .keep >&2
	exit 1
fi

for f in "$STAGE"/init "$STAGE"/functions/*.sh "$STAGE"/hooks/*/*; do
	sh -n "$f" || { echo "shell syntax error in $f" >&2; exit 1; }
done

echo "$VARIANT" > "$STAGE/PS4_VARIANT"
mkdir -p "$(dirname "$OUT")"
( cd "$STAGE" && find . -print0 | cpio --null -o -H newc -R 0:0 --quiet | gzip -9 ) > "$OUT"
echo "initramfs: $OUT ($(stat -c %s "$OUT") bytes, $(zcat "$OUT" | cpio -t --quiet | wc -l) entries)"
