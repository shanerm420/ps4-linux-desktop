#!/bin/bash
# Build a bootable PS4 root image from a rootfs directory or tarball.
#
#   scripts/build-rootimg.sh out/rootfs                 # directory
#   scripts/build-rootimg.sh out/rootfs.tar.zst         # tarball (.tar.zst/.tar.xz/.tar.gz)
#   SIZE=64G LABEL=DEBIAN-PS4 scripts/build-rootimg.sh out/rootfs
#
# Why this script exists at all: the console has no compiler, no debootstrap and
# no mke2fs, so the image is built on a host and copied over as bytes. This is
# the step that turns the rootfs into the one file the console mounts.
#
# The image is ONE ext4 filesystem with no partition table. PS4-Multiboot opens
# it as a flat block device and maps *file* blocks through blockmap/FIBMAP, so a
# partition table inside the file has nothing to map against. See docs/LAYOUT.md.
#
# Three properties are not negotiable and are checked before this script says it
# worked:
#   1. the label ends in -PS4      (Multiboot's discovery rule)
#   2. no orphan_file feature      (kernels < 5.15 cannot mount it; PS4 5.4 can't)
#   3. every block allocated       (a hole has no block for FIBMAP to return)
#
# mke2fs -d populates the filesystem in one pass, which is why this needs no
# root, no loop device and no chroot. mke2fs also DISCARDS the preallocated
# blocks while writing (measured: 32 MiB reserved became 4.3 MB allocated), so
# the image is materialised afterwards with a non-sparse copy.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:?usage: build-rootimg.sh ROOTFS_DIR_OR_TARBALL}
OUT=${OUT:-$HERE/../out/debian-ps4.img}
SIZE=${SIZE:-32G}
LABEL=${LABEL:-DEBIAN-PS4}
FEATURES=${FEATURES:-^orphan_file,^metadata_csum_seed}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -e "$SRC" ] || { echo "no such rootfs: $SRC" >&2; exit 1; }
case "$LABEL" in
	*-PS4) ;;
	*) echo "ERROR: LABEL must end in -PS4 (Multiboot will not find it otherwise): '$LABEL'" >&2
	   exit 1 ;;
esac
command -v mke2fs >/dev/null || { echo "install e2fsprogs (mke2fs, dumpe2fs, e2fsck, debugfs)" >&2; exit 1; }

# --- 1. get a directory to populate from
echo "== 1/4 unpacking $SRC =="
if [ -d "$SRC" ]; then
	TREE=$SRC
else
	case "$SRC" in
		*.tar.zst|*.tzst) tar --zstd -xf "$SRC" -C "$WORK" ;;
		*.tar.xz)        tar -xJf "$SRC" -C "$WORK" ;;
		*.tar.gz|*.tgz)  tar -xzf "$SRC" -C "$WORK" ;;
		*) echo "unknown archive type: $SRC (use .tar.zst, .tar.xz or .tar.gz)" >&2; exit 1 ;;
	esac
	TREE=$WORK
fi

# A tree without an init is not a rootfs; say so here rather than at boot.
found=""
for p in sbin/init usr/lib/systemd/systemd init; do
	[ -x "$TREE/$p" ] && { found=$p; break; }
done
[ -n "$found" ] || { echo "ERROR: $SRC has no init (sbin/init, usr/lib/systemd/systemd or init)" >&2; exit 1; }
echo "   init: $found"

# --- 2. refuse a size that cannot hold the contents
USED_KB=$(du -sk "$TREE" | cut -f1)
SIZE_KB=$(numfmt --from=iec "$SIZE" | awk '{print int($1/1024)}')
if [ "$SIZE_KB" -lt $((USED_KB * 2)) ]; then
	echo "ERROR: $SIZE is too small for $((USED_KB / 1024)) MiB of contents;" >&2
	echo "       an ext4 image needs roughly twice the content size for inodes and" >&2
	echo "       working space. Use SIZE=$(( (USED_KB * 2 / 1048576) + 1 ))G or more." >&2
	exit 1
fi
echo "== 2/4 contents: $((USED_KB / 1024)) MiB into a $SIZE image =="

# --- 3. build the filesystem in one pass
mkdir -p "$(dirname "$OUT")"
TMP="$OUT.build"
rm -f "$TMP"
echo "== 3/4 mke2fs -d (features: $FEATURES) =="
mke2fs -q -F -t ext4 -b 4096 -L "$LABEL" -O "$FEATURES" \
	-d "$TREE" "$TMP" "$SIZE" || {
	echo "ERROR: mke2fs failed" >&2
	rm -f "$TMP"
	exit 1
}

# --- 4. make it non-sparse, then verify
echo "== 4/4 allocating every block =="
rm -f "$OUT"
# cp --sparse=never writes the zero runs out as real blocks. This is the whole
# reason the image boots: a hole is a block FIBMAP cannot return.
cp --sparse=never "$TMP" "$OUT"
rm -f "$TMP"
apparent=$(stat -c %s "$OUT")
allocated=$(du -B1 "$OUT" | cut -f1)
if [ "$allocated" -lt "$apparent" ]; then
	echo "ERROR: image is still sparse ($allocated of $apparent bytes)" >&2
	echo "       free space on $(dirname "$OUT") may be short of $SIZE" >&2
	exit 1
fi

if [ -x "$HERE/check-image.sh" ]; then
	echo
	if "$HERE/check-image.sh" "$OUT" --label "$LABEL"; then
		echo
		echo "image ready: $OUT ($(stat -c %s "$OUT") bytes, label $LABEL)"
	else
		rc=$?
		echo
		echo "check-image.sh reported a problem (exit $rc) - do not copy this to a console" >&2
		exit 1
	fi
fi

cat <<EOF

Next:
  1. Copy it to the console WITHOUT preserving holes - FTP or dd, never rsync -S.
  2. Put it at /user/app/ps4linux.img, or write it to a USB device for an
     external install and record the filesystem UUID.
  3. The label is '$LABEL'; Multiboot discovers the image by that suffix.

Size is fixed now. Growing it later means copying the whole file again.
EOF
