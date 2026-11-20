#!/bin/bash
# check-image.sh - verify a PS4 root image against the contract PS4-Multiboot
# expects. Encodes the checks that otherwise fail on the console, hours later.
#
#   ./check-image.sh debian-ps4.img [--label DEBIAN-PS4]
#
# Checks:
#   1. ext4 magic 0x53ef at byte 1080 (Multiboot's installed-image test)
#   2. volume label, and that it ends in -PS4 (Multiboot's discovery rule)
#   3. an init exists (/sbin/init, /usr/lib/systemd/systemd or /init)
#   4. e2fsck -fn is clean
#   5. NO orphan_file feature: kernels older than 5.15 cannot mount it, and
#      e2fsprogs 1.47 enables it on some distro configs by default. The PS4 5.4
#      kernels cannot mount such an image at all.
#   6. fully allocated (no holes): blockmap/FIBMAP rejects a hole, and a
#      sparse-preserving copy leaves real holes on the PS4.
#
# Exit 0 = usable, 1 = a hard failure, 2 = warning only.
set -uo pipefail
IMG=${1:?usage: check-image.sh IMAGE.img [--label LABEL]}
shift
WANT_LABEL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--label) WANT_LABEL=${2:?}; shift 2 ;;
		--label=*) WANT_LABEL=${1#*=}; shift ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -f "$IMG" ] || { echo "no such file: $IMG" >&2; exit 1; }

fail=0; warn=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
note() { printf '  warn  %s\n' "$*"; warn=1; }

echo "checking $IMG ($(stat -c %s "$IMG") bytes)"

# 1. magic
magic=$(dd if="$IMG" bs=1 skip=1080 count=2 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$magic" = 53ef ] && ok "ext4 magic at byte 1080" || bad "no ext4 magic at byte 1080 (got '${magic:-nothing}')"

# 2. label
label=$(dumpe2fs -h "$IMG" 2>/dev/null | sed -n 's/^Filesystem volume name:[[:space:]]*//p')
if [ -n "$label" ] && [ "$label" != "<none>" ]; then
	ok "label: $label"
	case "$label" in
		*-PS4) ;;
		*) note "label does not end in -PS4; Multiboot's label scan will not find this image" ;;
	esac
	[ -z "$WANT_LABEL" ] || [ "$label" = "$WANT_LABEL" ] || bad "label is '$label', expected '$WANT_LABEL'"
else
	bad "filesystem has no label"
fi

# 3. init
found=""
for p in /sbin/init /usr/lib/systemd/systemd /init; do
	if ! debugfs -R "stat $p" "$IMG" 2>&1 | grep -q 'File not found'; then found=$p; break; fi
done
[ -n "$found" ] && ok "init present: $found" || bad "no init (/sbin/init, /usr/lib/systemd/systemd or /init)"

# 4. e2fsck
if e2fsck -fn "$IMG" >/dev/null 2>&1; then ok "e2fsck -fn clean"; else bad "e2fsck -fn reported errors"; fi

# 5. orphan_file - the one that bricks a 5.4 kernel
feats=$(dumpe2fs -h "$IMG" 2>/dev/null | sed -n 's/^Filesystem features:[[:space:]]*//p')
case " $feats " in
	*" orphan_file "*)
		bad "filesystem has orphan_file; kernels < 5.15 cannot mount it (PS4 5.4 kernels included)"
		echo "        rebuild with: mke2fs ... -O ^orphan_file   (or -O ^orphan_file,^metadata_csum_seed)" ;;
	*) ok "no orphan_file feature" ;;
esac
case " $feats " in
	*" metadata_csum_seed "*)
		note "metadata_csum_seed present; fine on 7.x kernels, check before targeting an older one" ;;
esac

# 6. allocation
apparent=$(stat -c %s "$IMG")
allocated=$(du -B1 "$IMG" | cut -f1)
if [ "$allocated" -ge "$apparent" ]; then
	ok "fully allocated ($allocated bytes for $apparent apparent)"
else
	note "sparse: $allocated of $apparent bytes allocated - blockmap rejects holes;"
	echo "        copy without preserving holes (FTP does; rsync -S does not)"
fi

echo
if [ "$fail" = 1 ]; then echo "RESULT: not usable on a PS4"; exit 1; fi
if [ "$warn" = 1 ]; then echo "RESULT: usable, with warnings above"; exit 2; fi
echo "RESULT: usable"
exit 0
