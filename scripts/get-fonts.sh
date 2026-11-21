#!/bin/sh
# Copies the DejaVu fonts the on-console screens draw with into the package
# staging area.
#
# They are not committed: pkg/installer/assets/ is build output, and shipping a
# 1.8 MB binary in git for a file every Debian host already has is worse than
# fetching it here. Install fonts-dejavu-core if this fails.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DST="$HERE/../pkg/installer/assets/fonts"
SRC=${FONT_DIR:-/usr/share/fonts/truetype/dejavu}

for f in DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSansMono.ttf; do
	[ -f "$DST/$f" ] && continue
	[ -f "$SRC/$f" ] || {
		echo "missing $SRC/$f - install fonts-dejavu-core (or set FONT_DIR)" >&2
		exit 1
	}
	mkdir -p "$DST"
	cp "$SRC/$f" "$DST/$f"
done
