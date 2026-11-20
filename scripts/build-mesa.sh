#!/bin/bash
# Build the PS4-patched Mesa into a directory that build-rootfs.sh installs as
# /opt/ps4-mesa.
#
#   MESA_SRC=/path/to/mesa-with-ps4-patches scripts/build-mesa.sh
#   PS4_PATCHES=/path/to/patches scripts/build-mesa.sh      # from a clean Mesa
#
# Why a separate Mesa at all: stock Mesa does not bind the PS4 GPU. Liverpool
# (Fat/Slim) and Gladius (Pro) are GCN gfx_v7 parts whose device IDs and chip
# init are not in upstream radeonsi, so without the patch radeonsi never loads,
# there is no Vulkan device, and the desktop falls back to software rendering.
#
# Why it lives in /opt instead of replacing the distro copy: if it overwrote
# /usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0, the next Debian Mesa update would
# either overwrite it (graphics die) or be held back (security updates stop).
# Two copies plus an ICD JSON avoids both. See docs/ARCHITECTURE.md.
#
# NOT VERIFIED: this procedure has not been run against a PS4 here, and the
# patch set is not vendored in this repository. It refuses to continue rather
# than produce a Mesa that looks fine and does not bind the GPU.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../out/ps4-mesa}
BUILD=${BUILD:-$HERE/../out/mesa-build}
MESA_SRC=${MESA_SRC:-}
PS4_PATCHES=${PS4_PATCHES:-}
MESA_TARBALL=${MESA_TARBALL:-}
JOBS=${JOBS:-$(nproc)}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing build tool: $1" >&2; exit 1; }; }
for t in meson ninja; do need "$t"; done

# --- 1. source tree
if [ -n "$MESA_SRC" ]; then
	[ -d "$MESA_SRC/src" ] || { echo "MESA_SRC=$MESA_SRC is not a Mesa tree (no src/)" >&2; exit 1; }
	SRC=$MESA_SRC
	echo "== using existing tree: $SRC =="
else
	[ -n "$MESA_TARBALL" ] || {
		echo "Set one of:" >&2
		echo "  MESA_SRC=<Mesa tree that already carries the PS4 patches>" >&2
		echo "  MESA_TARBALL=<mesa-24.x.tar.xz> PS4_PATCHES=<patch dir>" >&2
		echo >&2
		echo "The PS4 patches are not vendored here on purpose: they are someone" >&2
		echo "else's work under their own licence, and a stale copy would silently" >&2
		echo "build a Mesa that does not match the kernel's firmware." >&2
		exit 1
	}
	mkdir -p "$BUILD"
	tar -xf "$MESA_TARBALL" -C "$BUILD"
	SRC=$(find "$BUILD" -maxdepth 1 -type d -name 'mesa-*' | head -1)
	[ -n "$SRC" ] || { echo "could not find the unpacked Mesa tree in $BUILD" >&2; exit 1; }

	if [ -n "$PS4_PATCHES" ]; then
		[ -d "$PS4_PATCHES" ] || { echo "no patch directory at $PS4_PATCHES" >&2; exit 1; }
		n=0
		for p in "$PS4_PATCHES"/*.patch; do
			[ -f "$p" ] || continue
			echo "   applying $(basename "$p")"
			patch -d "$SRC" -p1 < "$p" || { echo "patch failed: $p" >&2; exit 1; }
			n=$((n + 1))
		done
		[ "$n" -gt 0 ] || { echo "no *.patch files in $PS4_PATCHES" >&2; exit 1; }
	else
		echo "WARNING: no PS4_PATCHES given. A stock Mesa will build and will NOT" >&2
		echo "         bind the PS4 GPU. Continue only to test the build itself." >&2
	fi
fi

# --- 2. build. Only the two drivers that matter: radeonsi for GL, radv for Vulkan.
echo "== configuring =="
meson setup "$BUILD/build" "$SRC" \
	--prefix=/opt/ps4-mesa \
	--libdir=lib/x86_64-linux-gnu \
	-Dplatforms=x11 \
	-Dgallium-drivers=radeonsi \
	-Dvulkan-drivers=amd \
	-Dglx=dri \
	-Degl=enabled \
	-Dllvm=enabled \
	-Dvideo-codecs= \
	-Dbuildtype=release

echo "== building (-j$JOBS) =="
ninja -C "$BUILD/build" -j"$JOBS"

# --- 3. stage
echo "== staging into $OUT =="
rm -rf "$OUT"
DESTDIR="$OUT" ninja -C "$BUILD/build" install

# --- 4. verify the two things the desktop needs
vulkan=$(find "$OUT" -name 'libvulkan_radeon.so' | head -1)
glx=$(find "$OUT" -name 'libGLX_mesa.so.0' | head -1)
[ -n "$vulkan" ] || { echo "ERROR: libvulkan_radeon.so was not built - no Vulkan device" >&2; exit 1; }
[ -n "$glx" ] || { echo "ERROR: libGLX_mesa.so.0 was not built - no GL" >&2; exit 1; }
echo "  vulkan: ${vulkan#$OUT}"
echo "  glx   : ${glx#$OUT}"

# The ICD JSON in rootfs/ points at /opt/ps4-mesa/lib/x86_64-linux-gnu/.
if [ ! -e "$OUT/opt/ps4-mesa/lib/x86_64-linux-gnu/libvulkan_radeon.so" ]; then
	echo "WARNING: the installed path differs from the one in" >&2
	echo "         rootfs/usr/share/vulkan/icd.d/ps4-mesa.json; fix one of them." >&2
fi

cat <<EOF

Built: $OUT

Next:
  PS4_MESA=$OUT scripts/build-rootfs.sh

Unverified: whether radeonsi actually binds Liverpool/Gladius on your console.
That is a test-matrix row, not a build step. Check it after boot with:
  vulkaninfo --summary | grep -i device
  glxinfo -B | grep -i renderer
EOF
