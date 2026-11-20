#!/bin/bash
# Build and install a dummy "linux-image-ps4" package into a rootfs.
#
# Its only job is to be the thing that satisfies anything asking for a kernel,
# so apt never reaches for a real distro kernel that cannot boot this console.
# The real kernel is in the read-only boot partition, updated only by the PKG.
set -euo pipefail
ROOT=${1:?usage: build-dummy-kernel.sh ROOTFS}
VER=${VER:-1.0}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/DEBIAN" "$T/boot" "$T/usr/share/doc/linux-image-ps4"
cat > "$T/DEBIAN/control" <<EOF
Package: linux-image-ps4
Version: $VER
Architecture: amd64
Maintainer: PS4 Linux Desktop <noreply@example.invalid>
Section: kernel
Priority: optional
Provides: linux-image, linux-image-2.6, linux-image-amd64
Conflicts: linux-image-amd64, linux-image-generic
Description: PS4 kernel placeholder (real kernel lives in the boot partition)
 This package intentionally contains no kernel image. The PlayStation 4 kernel
 is installed and updated only through the PS4 Linux Desktop PKG, because a
 distribution kernel cannot boot this hardware. Installing this package keeps
 package managers from pulling in one.
EOF
cat > "$T/usr/share/doc/linux-image-ps4/README" <<'EOF'
The kernel for this system is not managed by the package manager.

It lives in the read-only boot partition of the PS4 Linux image and is replaced
only by a signed "PS4 components update" from the PS4 Linux Desktop PKG. See
docs/ARCHITECTURE.md in the release for the update and rollback procedure.
EOF
echo "intentionally empty" > "$T/boot/README.ps4"

dpkg-deb --build --root-owner-group "$T" "$T/../linux-image-ps4_${VER}_amd64.deb" >/dev/null
dpkg-deb -x "$T/../linux-image-ps4_${VER}_amd64.deb" "$ROOT"
dpkg-deb -e "$T/../linux-image-ps4_${VER}_amd64.deb" "$ROOT/var/lib/dpkg/info/linux-image-ps4:amd64"
printf 'linux-image-ps4\t%s\n' "$VER" >> "$ROOT/var/lib/dpkg/status"
echo "installed dummy linux-image-ps4 $VER"
