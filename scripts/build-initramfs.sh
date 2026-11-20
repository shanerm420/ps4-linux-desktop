#!/bin/bash
# Assemble initramfs.cpio.gz for PS4 Linux Desktop.
#
# Base: initramfs-ps4 (GattoDev-debug) - the same base the reference project
# uses, because it already opens the encrypted PS4 HDD container and mounts
# /ps4hdd. Our additions:
#
#   functions/55-ps4linux.sh   find the image (internal file or external device),
#                              mount its single ext4 filesystem, boot it
#   hooks/early/1-recovery     a "ps4linux-recovery" file on any USB stick forces
#                              a rescue shell instead of booting
#
# No firmware is placed in the initramfs. Two reasons, both learned the hard way
# by the reference project: (1) GPU and Wi-Fi firmware are built into the kernel,
# and the loader appends this console's own GPU firmware/EDID/HDD key at boot;
# (2) regulatory.db in an initramfs deadlocks the MediaTek vendor driver
# (reg_regdb_apply -> mtk_reg_notify) and takes DHCP down with it - verified on a
# Fat console.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
B=${B:-$HERE/../out}
BASE=${BASE:-$HERE/../src/initramfs.cpio.gz}   # initramfs-ps4 release
STAGE=$B/initramfs-stage
OUT=${OUT:-$B/initramfs.cpio.gz}
VARIANT=${VARIANT:-release}

[ -f "$BASE" ] || { echo "no base initramfs at $BASE (download initramfs-ps4)" >&2; exit 1; }
[ "$VARIANT" = release ] || { echo "only release builds may ship" >&2; exit 1; }

rm -rf "$STAGE"; mkdir -p "$STAGE"
( cd "$STAGE" && zcat "$BASE" | cpio -idm --quiet --no-absolute-filenames )

install -D -m 0755 "$HERE/../initramfs/functions/55-ps4linux.sh" "$STAGE/functions/55-ps4linux.sh"
install -D -m 0755 "$HERE/../initramfs/hooks/early/1-recovery" "$STAGE/hooks/early/1-recovery"

# Production initramfs: no remote access, no RAM-disk speed test.
rm -f "$STAGE/bin/dropbear" "$STAGE/bin/dropbearkey"
rm -f "$STAGE/hooks/early/2-ramdisk-test"

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
echo "initramfs: $OUT ($(stat -c %s "$OUT") bytes)"
