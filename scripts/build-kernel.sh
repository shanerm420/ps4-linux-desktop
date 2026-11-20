#!/bin/bash
# Build the PS4 kernel for one southbridge.
#
#   SB=aeolia-belize scripts/build-kernel.sh     # Aeolia + Belize
#   SB=baikal        scripts/build-kernel.sh     # Slim / Pro
#
# Source trees (pick per southbridge, keep the license files with the sources):
#   https://github.com/rmuxnet/linux   branches zaebiz/7.1.7-Stable (Aeolia/Belize),
#                                      baikal/7.0.8-Stable  (Slim/Pro Baikal)
#     Verified from the tree's own README: Baikal is a SEPARATE branch on a
#     different version, not one kernel for all three boards.
#   https://github.com/feeRnt/ps4-linux-12xx  alternative with Torus 2 fixes
#
# Everything here is deliberately explicit: -march=btver2 (Jaguar, no AVX2),
# GPU and Wi-Fi firmware built in, and a hard failure if any requested option
# silently did not stick.
set -euo pipefail

SB=${SB:-}
case "$SB" in
	aeolia-belize) BRANCH=${BRANCH:-zaebiz/7.1.7-Stable} ;;
	baikal)        BRANCH=${BRANCH:-baikal/7.0.8-Stable} ;;
	*) echo "set SB=aeolia-belize or SB=baikal" >&2; exit 1 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE/../src/linux}
O=${O:-$HERE/../out/kbuild-$SB}
VARIANT=${VARIANT:-release}
JOBS=${JOBS:-$(nproc)}

[ -d "$SRC" ] || { echo "no kernel source at $SRC (clone rmuxnet/linux, branch $BRANCH)" >&2; exit 1; }
[ "$VARIANT" = release ] || { echo "only release builds may ship; debug is build-host only" >&2; exit 1; }

# Jaguar is btver2: SSE4.2/AVX/F16C/BMI1, but NO AVX2, FMA or BMI2.
export KCFLAGS="-march=btver2 -mtune=btver2 -Os"
export KAFLAGS="-march=btver2 -mtune=btver2"

MAKE=(make -C "$SRC" O="$O" -j"$JOBS" LLVM=1 ARCH=x86_64
      HOSTCFLAGS="-Wno-error=incompatible-pointer-types-discards-qualifiers")
mkdir -p "$O"

# --- build host preflight --------------------------------------------------
# Strawberry builds with clang + ThinLTO. On a small laptop it is the LINK step
# that fails, not the compile: it is single-threaded and wants several GB. Fail
# with a sentence, not with an OOM-killed linker four hours in.
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing build tool: $1" >&2; exit 1; }; }
for t in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip bc flex bison make gzip; do
	need "$t"
done
for h in openssl/opensslv.h libelf.h zstd.h; do
	[ -e "/usr/include/$h" ] ||
		echo "WARNING: /usr/include/$h missing (apt install libssl-dev libelf-dev libzstd-dev)" >&2
done
ram_mib=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
free_mib=$(df -Pm "$O" | awk 'NR==2{print $4}')
echo "build host: $(nproc) cpus, ${ram_mib} MiB RAM, $(clang --version | head -1 | awk '{print $3}') clang, ${free_mib} MiB free"
if [ "$ram_mib" -lt 6000 ]; then
	echo "WARNING: ${ram_mib} MiB RAM. ThinLTO needs several GB at link time." >&2
	echo "         Add swap, or build with a non-LTO profile if the tree offers one," >&2
	echo "         or boot the prebuilt bzImage artifact from the tree's CI first." >&2
fi
if [ "$free_mib" -lt 12000 ]; then
	echo "WARNING: only ${free_mib} MiB free; a kernel tree plus output wants ~10-15 GB" >&2
fi

cp "$SRC/config" "$O/.config"
cfg() { "$SRC/scripts/config" --file "$O/.config" "$@"; }

cfg --set-str CONFIG_LOCALVERSION "-PS4Linux-$SB"
cfg --disable CONFIG_LOCALVERSION_AUTO

# --- GPU firmware must be built in, or amdgpu never starts Liverpool/Gladius
#     and HDMI stays dark. Same list the reference project uses.
cfg --set-str CONFIG_EXTRA_FIRMWARE_DIR "$SRC/extra_firmware"
fw=""
add_fw() {
	[ -f "$SRC/extra_firmware/$1" ] || { echo "missing firmware blob: $SRC/extra_firmware/$1" >&2; exit 1; }
	case " $fw " in *" $1 "*) ;; *) fw="${fw:+$fw }$1" ;; esac
}
for blob in $(sed -n '/^REQUIRED_PS4_AMDGPU_FW=(/,/^)/p' "$SRC/build.sh" | grep -o 'amdgpu/[^\"]*\.bin'); do
	add_fw "$blob"
done

# --- Wi-Fi / Bluetooth firmware. Which chip is present is decided at runtime by
#     the SDIO ids (02df:9129/912a = 88W8797, 02df:912d/912e = 88W8897,
#     037a:7608/7668 = MT7668), so all supported sets are built in.
for blob in mrvl/sd8797_uapsta.bin mrvl/sd8897_uapsta.bin; do
	[ -f "$SRC/extra_firmware/$blob" ] && add_fw "$blob"
done
cfg --set-str CONFIG_EXTRA_FIRMWARE "$fw"

# --- drivers and subsystems the distro needs
cfg --enable CONFIG_MWIFIEX
cfg --enable CONFIG_MWIFIEX_SDIO
cfg --enable CONFIG_BT_MRVL
cfg --enable CONFIG_BT_MRVL_SDIO
cfg --enable CONFIG_HID_PLAYSTATION       # DualShock 4 over USB and Bluetooth
cfg --enable CONFIG_DRM_AMDGPU
cfg --enable CONFIG_DRM_AMDGPU_CIK
cfg --enable CONFIG_SND_HDA_INTEL
cfg --enable CONFIG_EXT4_FS
cfg --enable CONFIG_OVERLAY_FS
cfg --enable CONFIG_BLK_DEV_LOOP
cfg --enable CONFIG_DM_CRYPT
cfg --enable CONFIG_DM_VERITY
cfg --enable CONFIG_SQUASHFS
cfg --enable CONFIG_ZSTD_DECOMPRESS         # rootfs.tar.zst
cfg --enable CONFIG_BLK_DEV_NVME
cfg --enable CONFIG_USB_STORAGE
cfg --enable CONFIG_UAS
cfg --enable CONFIG_BINFMT_MISC

# --- MT7668 is an out-of-tree vendor driver (noob404yt/mt7668-wifi-bt).
#     It is added by the source tree's own build.sh when present; never patched
#     into the kernel here, because a silent failure would look like a hardware
#     problem later.
if ! grep -q mt7668 "$SRC/build.sh" 2>/dev/null; then
	echo "WARNING: this tree has no MT7668 driver; Slim/Pro consoles with the" >&2
	echo "         MediaTek chip will have no Wi-Fi. Use feeRnt/ps4-linux-12xx" >&2
	echo "         or add noob404yt/mt7668-wifi-bt." >&2
fi

"${MAKE[@]}" olddefconfig

# Every option we asked for must have stuck.
for opt in CONFIG_DRM_AMDGPU CONFIG_MWIFIEX_SDIO CONFIG_HID_PLAYSTATION CONFIG_EXT4_FS \
           CONFIG_ZSTD_DECOMPRESS CONFIG_DM_CRYPT; do
	grep -q "^$opt=y" "$O/.config" || { echo "ERROR: $opt did not stick" >&2; exit 1; }
done
grep -q 'amdgpu/liverpool_rlc.bin\|amdgpu/gladius_rlc.bin' "$O/.config" \
	|| { echo "ERROR: GPU firmware not in CONFIG_EXTRA_FIRMWARE" >&2; exit 1; }
# No debug interfaces in anything that ships.
for opt in CONFIG_NETCONSOLE CONFIG_MAGIC_SYSRQ CONFIG_DEBUG_FS CONFIG_KEXEC; do
	grep -q "^$opt=y" "$O/.config" && { echo "ERROR: release kernel has $opt" >&2; exit 1; }
done

time "${MAKE[@]}" bzImage
mkdir -p "$O/out"
cp "$O/arch/x86/boot/bzImage" "$O/.config" "$O/out/"
echo "kernel ($SB, $BRANCH): $O/out/bzImage ($(cat "$O/include/config/kernel.release"))"
