#!/bin/bash
# get-toolchain.sh - fetch the OpenOrbis PS4 toolchain (a release build, not the
# git repository: the repo ships no binaries on purpose).
#
#   scripts/get-toolchain.sh                    # download and unpack
#   scripts/get-toolchain.sh --from FILE        # use an archive you already have
#   DEST=/opt/oo scripts/get-toolchain.sh
#
# What the real v0.5.4 asset contains (verified by unpacking it, not by reading
# the Dockerfile):
#
#   toolchain-llvm-18.tar.gz                152 MB
#   OpenOrbis/PS4Toolchain/                 <- OO_PS4_TOOLCHAIN points HERE
#     bin/linux/{PkgTool.Core,create-fself,create-gp4,readoelf}   x86-64 ELF
#     bin/macos/... bin/windows/...         the same tools per platform
#     samples/dialogs/sce_module/{libc.prx,libSceFios2.prx}
#
# Two things that are NOT in it, despite the asset name:
#   * clang and lld. Install them yourself (apt install clang lld).
#   * bin/data/modules. The runtime modules live under samples/.
#
# Architecture note: every tool is x86-64. That is fine on any x86-64 machine. On
# arm64 (a phone in Termux, say) create-fself/create-gp4/readoelf can be rebuilt
# from their Go sources for arm64, and PkgTool.Core is .NET - use an arm64 .NET
# runtime, or run the x86-64 build under qemu-user.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${DEST:-$HERE/../src/oo}
VERSION=${VERSION:-v0.5.4}
ASSET=${ASSET:-toolchain-llvm-18.tar.gz}
URL="https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain/releases/download/$VERSION/$ASSET"
FROM=

while [ $# -gt 0 ]; do
	case "$1" in
		--from)   FROM=${2:?--from needs a file}; shift 2 ;;
		--from=*) FROM=${1#*=}; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

mkdir -p "$DEST"
tgz=${FROM:-$DEST/$ASSET}
if [ -z "$FROM" ] && [ ! -f "$tgz" ]; then
	echo "downloading $URL"
	curl -fL --retry 3 -o "$tgz" "$URL"
fi
[ -f "$tgz" ] || { echo "no archive at $tgz" >&2; exit 1; }

echo "unpacking into $DEST"
tar -xzf "$tgz" -C "$DEST"

# The archive is nested: OpenOrbis/PS4Toolchain/. Pointing OO_PS4_TOOLCHAIN at
# the extraction root is the mistake this check exists to catch.
TC=$DEST/OpenOrbis/PS4Toolchain
[ -d "$TC" ] || {
	echo "unexpected archive layout: $DEST/OpenOrbis/PS4Toolchain is missing" >&2
	exit 1
}

missing=0
for t in PkgTool.Core create-fself create-gp4; do
	[ -x "$TC/bin/linux/$t" ] || { echo "missing tool: bin/linux/$t" >&2; missing=1; }
done
MOD=""
for d in "$TC/bin/data/modules" "$TC/src/modules" "$TC/samples/dialogs/sce_module"; do
	if [ -f "$d/libc.prx" ] && [ -f "$d/libSceFios2.prx" ]; then MOD=$d; break; fi
done
[ -n "$MOD" ] || { echo "missing runtime modules (libc.prx, libSceFios2.prx)" >&2; missing=1; }
[ "$missing" = 0 ] || exit 1

echo
echo "toolchain ready: $TC"
echo "  modules: $MOD"
echo
echo "add this to your shell (or to the make command):"
echo "  export OO_PS4_TOOLCHAIN=$TC"
echo
for t in clang ld.lld; do
	command -v "$t" >/dev/null 2>&1 || \
		echo "WARNING: $t is not installed and the release does not ship it (apt install clang lld)"
done
exit 0
