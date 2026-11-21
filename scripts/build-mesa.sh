#!/bin/bash
# Build the PS4-patched Mesa and stage it for /opt/ps4-mesa.
#
# Why this exists: stock Mesa does not bind the PS4 GPU. Its device id is not in
# Mesa's chip tables, so radeonsi refuses the card and the desktop falls back to
# software rendering. The patch is small - it teaches Mesa that Liverpool
# (original/Slim) and Gladius (Pro) are Bonaire-class GFX7 parts - and it is the
# same device-id-and-chip-init patch fail0verflow published in 2016, kept current
# by the ps4-video-archlinux package set that patches Mesa for Arch.
#
# No root and no Docker. The trick is a Debian 13 "sysroot": apt downloads the
# build dependencies with Dir= pointing at a scratch tree, dpkg-deb -x unpacks
# them there, and the compiler from that tree is used with --sysroot. The result
# is built against the exact glibc, libdrm and LLVM the image ships, so the
# binaries load on the console.
#
#   ./scripts/build-mesa.sh                 # -> out/ps4-mesa
#   PS4_MESA=$PWD/out/ps4-mesa bash scripts/build-rootfs-rootless.sh
#
# Verified on a plain x86-64 host (no root, no Docker): 1,470 targets, no
# failures, GLIBC_2.34/2.38 symbols only, LIVERPOOL and GLADIUS present in the
# driver, 42 MB staged. The build has not been run on a PS4, so "it builds and it
# is the right chip" is the claim, not "3D works".
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../out/ps4-mesa}
WORK=${WORK:-$HERE/../build/mesa}
MESA_VER=${MESA_VER:-25.0.7}
# Same version Debian 13 ships, so the rest of the image (libglvnd, libLLVM,
# libdrm) matches the copy in /opt exactly.
MESA_SHA256=${MESA_SHA256:-592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6}
SYS=$WORK/sysroot
PATCH=$HERE/../patches/ps4-mesa.patch

# Everything the configure step needs. LLVM is required for radeonsi (it runs the
# shader compiler); glslang-tools is required by the Vulkan build; byacc/flex/m4
# generate the GLSL parser. libglvnd-dev decides between the vendor layout and a
# private libGL - we want the vendor layout, because Xorg and EGL use libglvnd.
DEBS="build-essential meson ninja-build pkg-config python3-mako python3-yaml
	python3-packaging bison flex byacc m4
	libdrm-dev libx11-dev libx11-xcb-dev libxcb1-dev libxcb-shm0-dev
	libxcb-dri2-0-dev libxcb-dri3-0-dev libxcb-randr0-dev libxcb-xfixes0-dev
	libxcb-shape0-dev libxcb-sync-dev libxcb-present-dev libxcb-glx0-dev
	libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev
	libxext-dev libxfixes-dev libxshmfence-dev libxrandr-dev libxxf86vm-dev
	libzstd-dev zlib1g-dev libexpat1-dev libelf-dev
	llvm-19-dev libz3-4 glslang-tools libglvnd-dev libglvnd-core-dev"

[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 1; }

mkdir -p "$WORK" "$SYS/etc/apt/apt.conf.d" "$SYS/etc/apt/trusted.gpg.d" \
	"$SYS/var/lib/apt/lists/partial" "$SYS/var/cache/apt/archives/partial" \
	"$SYS/var/lib/dpkg"

# --- 1. the sysroot -----------------------------------------------------------
# [trusted=yes] because this scratch tree has no keyring of its own; every
# package still comes from deb.debian.org, and the Mesa tarball is checksummed.
printf 'deb [trusted=yes] http://deb.debian.org/debian trixie main\ndeb [trusted=yes] http://deb.debian.org/debian trixie-updates main\ndeb [trusted=yes] http://security.debian.org/debian-security trixie-security main\n' \
	> "$SYS/etc/apt/sources.list"
: > "$SYS/var/lib/dpkg/status"

APT="apt-get -o Dir=$SYS -o Dir::Etc::sourcelist=$SYS/etc/apt/sources.list \
	-o Dir::Etc::sourceparts=/dev/null -o Dir::State::status=$SYS/var/lib/dpkg/status \
	-o Dir::Cache=$SYS/var/cache/apt -o Dir::State=$SYS/var/lib/apt \
	-o APT::Get::List-Cleanup=0 -o Acquire::Retries=3"

if [ ! -x "$SYS/usr/bin/gcc-14" ]; then
	echo "== fetching build dependencies (trixie) =="
	# shellcheck disable=SC2086
	$APT update -qq
	# shellcheck disable=SC2086
	$APT -y -qq --download-only --no-install-recommends install $DEBS
	for d in "$SYS"/var/cache/apt/archives/*.deb; do dpkg-deb -x "$d" "$SYS"; done
fi

# Debian is merged-usr: the linker script inside libc-dev points at /lib and
# /lib64, which only exist as symlinks inside a real system.
ln -sfn usr/lib "$SYS/lib"
mkdir -p "$SYS/usr/lib64"
ln -sfn usr/lib64 "$SYS/lib64"

# llvm-config is a trixie binary that wants libz3; it must NOT see the sysroot's
# libc (that crashes the host tools), so the extra library goes in its own dir.
mkdir -p "$WORK/extras"
for _ in 1 2 3 4 5 6; do
	missing=$(LD_LIBRARY_PATH=$WORK/extras ldd "$SYS/usr/bin/llvm-config-19" 2>/dev/null |
		grep "not found" | awk '{print $1}')
	[ -z "$missing" ] && break
	for lib in $missing; do
		src=$(ls "$SYS"/usr/lib/x86_64-linux-gnu/$lib* 2>/dev/null | head -1)
		[ -n "$src" ] && ln -sf "$src" "$WORK/extras/$lib"
	done
done

# --- 2. compiler and tool wrappers -------------------------------------------
# Meson wants plain program names; these put the sysroot on every invocation and
# let the sysroot's own bison/flex/byacc find their data files.
mkdir -p "$WORK/bin"
for c in gcc g++; do
	printf '#!/bin/sh\nexec %s/usr/bin/%s-14 --sysroot=%s "$@"\n' "$SYS" "$c" "$SYS" > "$WORK/bin/$c"
	chmod +x "$WORK/bin/$c"
done
printf '#!/bin/sh\nexec %s/usr/bin/llvm-config-19 "$@"\n' "$SYS" > "$WORK/bin/llvm-config"
chmod +x "$WORK/bin/llvm-config"
for t in flex bison byacc m4 glslangValidator; do
	[ -e "$SYS/usr/bin/$t" ] && ln -sf "$SYS/usr/bin/$t" "$WORK/bin/$t"
done

# --- 3. Mesa source and the patch --------------------------------------------
cd "$WORK"
if [ ! -f "mesa-$MESA_VER.tar.xz" ]; then
	curl -fL -O "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
fi
echo "$MESA_SHA256  mesa-$MESA_VER.tar.xz" | sha256sum -c - >/dev/null || {
	echo "mesa-$MESA_VER.tar.xz does not match MESA_SHA256" >&2; exit 1; }
[ -d "mesa-$MESA_VER" ] || tar -xf "mesa-$MESA_VER.tar.xz"

if ! grep -q CHIP_LIVERPOOL "mesa-$MESA_VER/src/amd/common/amd_family.h"; then
	echo "== applying patches/ps4-mesa.patch =="
	( cd "mesa-$MESA_VER" && patch -p1 --fuzz=3 < "$PATCH" )
fi

# --- 4. configure ------------------------------------------------------------
# gbm is NOT optional: the DRI driver directory (dri/libdril_dri.so plus the
# radeonsi_dri.so symlink) is only generated when gbm is enabled. Without it the
# build succeeds and installs no driver, which is a very quiet way to end up
# with software rendering.
export PATH="$WORK/bin:$PATH"
export LD_LIBRARY_PATH="$WORK/extras"
export PKG_CONFIG_LIBDIR="$SYS/usr/lib/x86_64-linux-gnu/pkgconfig:$SYS/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYS"
export CC="$WORK/bin/gcc" CXX="$WORK/bin/g++"
export BISON_PKGDATADIR="$SYS/usr/share/bison" M4="$SYS/usr/bin/m4"

MESON=$(command -v meson || echo "$WORK/.venv/bin/meson")
NINJA=$(command -v ninja || echo "$WORK/.venv/bin/ninja")
if [ ! -x "$MESON" ]; then
	python3 -m venv "$WORK/.venv"
	"$WORK/.venv/bin/pip" install --quiet meson ninja mako pyyaml packaging
	MESON="$WORK/.venv/bin/meson"; NINJA="$WORK/.venv/bin/ninja"
fi

if [ ! -f "mesa-$MESA_VER/build/build.ninja" ]; then
	echo "== configure =="
	"$MESON" setup "mesa-$MESA_VER/build" "mesa-$MESA_VER" \
		--buildtype=release \
		-Dprefix=/opt/ps4-mesa -Dlibdir=lib/x86_64-linux-gnu \
		-Dplatforms=x11 -Dgallium-drivers=radeonsi -Dvulkan-drivers=amd \
		-Dglx=dri -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dopengl=true \
		-Dllvm=enabled -Dshared-llvm=enabled \
		-Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-xa=disabled \
		-Dgallium-opencl=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
		-Dzstd=enabled -Dbuild-tests=false -Dtools= -Dvideo-codecs=
fi

echo "== build (1,400-odd targets; 15-40 minutes on 8 cores) =="
"$NINJA" -C "mesa-$MESA_VER/build"

# --- 5. stage ----------------------------------------------------------------
echo "== install =="
rm -rf "$WORK/out"
DESTDIR="$WORK/out" "$MESON" install -C "mesa-$MESA_VER/build" --no-rebuild

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -a "$WORK/out/opt/ps4-mesa" "$OUT"

# --- 6. check what came out ---------------------------------------------------
echo "== result =="
drv=$OUT/lib/x86_64-linux-gnu/dri/libdril_dri.so
for f in "$drv" "$OUT/lib/x86_64-linux-gnu/libvulkan_radeon.so"; do
	[ -f "$f" ] || { echo "MISSING $f" >&2; exit 1; }
	printf '  %-40s %s bytes\n' "$(basename "$f")" "$(stat -c %s "$f")"
done
chips=$(strings "$OUT/lib/x86_64-linux-gnu/libgallium-$MESA_VER.so" | grep -cE '^(LIVERPOOL|GLADIUS)$' || true)
echo "  PS4 chip names in the driver: $chips (want 2)"
glibc=$(objdump -p "$OUT/lib/x86_64-linux-gnu/libvulkan_radeon.so" |
	grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
echo "  newest glibc symbol needed:  $glibc (Debian 13 has 2.41)"
echo "  total:                       $(du -sh "$OUT" | cut -f1) in $OUT"
[ "$chips" = 2 ] || { echo "the patch did not take - the GPU will not bind" >&2; exit 1; }
echo
echo "Next: PS4_MESA=$OUT bash scripts/build-rootfs-rootless.sh"
echo "      then bash scripts/make-pkg.sh - the PKG carries it at /opt/ps4-mesa."
