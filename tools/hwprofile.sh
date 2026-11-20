#!/bin/sh
# hwprofile.sh - report what this kernel actually detects on a PS4.
#
# Shell version of tools/hwprofile.c, for hosts that cannot cross-compile an
# x86-64 binary (for example a phone building the USB stick). Same rules: every
# line is read from /proc or /sys, and anything not found is reported as unknown
# rather than guessed. Never infers the southbridge from the console model.
#
# Install on the console:  cp hwprofile.sh /usr/local/bin/ps4-hwprofile && chmod +x
# Usage:                   ps4-hwprofile | tee /tmp/report.txt

have() { [ -e "$1" ]; }

echo "ps4-hwprofile (shell) - what this kernel actually detects"
echo "========================================================="
echo

# ---------------------------------------------------------------- console
evidence=""
[ -d /sys/firmware/ps4 ] && evidence="confirmed (/sys/firmware/ps4, ps4-ccp driver)"
if [ -z "$evidence" ]; then
	for m in ps4_ccp xhci_aeolia ps4_bridge snd_ps4 mts; do
		[ -d "/sys/module/$m" ] && { evidence="probable (module $m)"; break; }
	done
fi
[ -z "$evidence" ] && evidence="not found"

# Southbridge: PCI 0000:00:14.4 device id, the same method the PS4 initramfs and
# the loader use. 0x90a1 Aeolia, 0x90cc Belize, 0x90db Baikal. Driver names are
# only a fallback, and the console model is never used.
sbdev=/sys/bus/pci/devices/0000:00:14.4
sb=""
if [ -r "$sbdev/device" ]; then
	id=$(cat "$sbdev/device" 2>/dev/null)
	rev=$(cat "$sbdev/revision" 2>/dev/null)
	case "$id" in
		0x90a1) sb="aeolia" ;;
		0x90cc) sb="belize" ;;
		0x90db) sb="baikal" ;;
		*)      sb="unrecognised device $id" ;;
	esac
	sb="$sb (PCI 0000:00:14.4 = $id${rev:+, rev $rev})"
else
	for d in /sys/bus/pci/drivers/* /sys/bus/platform/drivers/*; do
		case "$d" in
			*aeolia*) sb="aeolia (driver $(basename "$d"))" ;;
			*baikal*) sb="baikal (driver $(basename "$d"))" ;;
			*ps4sb*|*belize*) sb="belize (driver $(basename "$d"))" ;;
		esac
		[ -n "$sb" ] && break
	done
fi
[ -z "$sb" ] && sb="unknown - not guessed (no PCI 0000:00:14.4, no driver name)"

echo "console"
echo "  PS4 evidence      : $evidence"
echo "  southbridge       : $sb"
echo

# ---------------------------------------------------------------- cpu
# Field extraction with sed, not awk: "model" and "model name" both start with
# "model", and an awk /^model/ rule silently picks up whichever comes first.
field() { sed -n "s/^$1[[:space:]]*:[[:space:]]*//p" /proc/cpuinfo | head -n 1; }

echo "cpu"
vendor=$(field vendor_id)
model_name=$(field 'model name')
fam=$(field 'cpu family')
mod=$(field model)
step=$(field stepping)
ncpu=$(grep -c '^processor' /proc/cpuinfo)
echo "  vendor            : ${vendor:-unknown}"
echo "  family/model/step : ${fam:-?} / ${mod:-?} / ${step:-?}"
echo "  logical cpus      : $ncpu"
echo "  model name        : ${model_name:-(none reported)}"
if [ "$fam" = "22" ] && [ -n "$mod" ] && [ "$mod" -ge 48 ] 2>/dev/null && [ "$mod" -le 63 ] 2>/dev/null; then
	echo "  family id         : AMD Jaguar (16h, model $mod) - matches the PS4 CPU"
else
	echo "  family id         : not Jaguar (no claim made)"
fi

echo "  features          :"
for f in sse4_2 avx f16c bmi1 aes xsave avx2 fma bmi2; do
	if grep -qw "$f" /proc/cpuinfo; then
		echo "    $f      yes"
	else
		case "$f" in
			avx2) echo "    $f     no  absent - Jaguar does NOT have this; never require it" ;;
			fma)  echo "    $f      no  absent - Jaguar does NOT have this" ;;
			bmi2) echo "    $f     no  absent - Jaguar does NOT have this" ;;
			*)    echo "    $f      no  absent" ;;
		esac
	fi
done
if grep -qw avx2 /proc/cpuinfo; then
	echo "  WARNING           : AVX2 reported - unexpected on a Jaguar, verify the CPU"
else
	echo "  x86-64 level      : v2 is safe; v3 is NOT (needs AVX2)"
fi

for i in 0 1 2 3; do
	[ -d "/sys/devices/system/cpu/cpu0/cache/index$i" ] || continue
	printf "  cache L%s %-5s    : %s shared by cpus %s\n" \
		"$(cat /sys/devices/system/cpu/cpu0/cache/index$i/level 2>/dev/null)" \
		"$(cat /sys/devices/system/cpu/cpu0/cache/index$i/type 2>/dev/null)" \
		"$(cat /sys/devices/system/cpu/cpu0/cache/index$i/size 2>/dev/null)" \
		"$(cat /sys/devices/system/cpu/cpu0/cache/index$i/shared_cpu_list 2>/dev/null)"
done
echo

# ---------------------------------------------------------------- pci
echo "display"
found=0
for d in /sys/bus/pci/devices/*; do
	cls=$(cat "$d/class" 2>/dev/null)
	case "$cls" in
		0x03*) found=1
			printf "  %s  %s:%s  driver=%s\n" "$(basename "$d")" \
				"$(sed 's/^0x//' "$d/vendor" 2>/dev/null)" \
				"$(sed 's/^0x//' "$d/device" 2>/dev/null)" \
				"$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
		;;
	esac
done
[ "$found" = 0 ] && echo "  no display-class PCI device found"
echo "  note: PS4 GPUs are GCN (amdgpu gfx_v7). Stock Mesa does not bind them."
echo

# ---------------------------------------------------------------- wifi/bt
echo "wifi / bluetooth"
n=0
for d in /sys/bus/sdio/devices/*; do
	[ -e "$d" ] || continue
	n=$((n + 1))
	id=$(grep -h '^SDIO_ID=' "$d/uevent" 2>/dev/null | cut -d= -f2)
	drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)
	echo "  sdio ${id:-?}  driver=${drv:-none (no driver bound)}"
done
[ "$n" = 0 ] && echo "  no SDIO devices"
echo "  known PS4 parts: 88W8797 02df:9129, 88W8897 02df:912d, MT7668 037a:7608"
echo "  the SDIO id above decides which chip this console has."
echo

# ---------------------------------------------------------------- net
echo "network interfaces"
for i in /sys/class/net/*; do
	[ -e "$i" ] || continue
	name=$(basename "$i")
	[ "$name" = lo ] && continue
	drv=$(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)
	printf "  %-10s state=%-6s mac=%s driver=%s\n" "$name" \
		"$(cat "$i/operstate" 2>/dev/null)" "$(cat "$i/address" 2>/dev/null)" "${drv:-none}"
done
echo

# ---------------------------------------------------------------- audio
echo "audio"
if [ -r /proc/asound/cards ]; then
	grep -v '^ *$' /proc/asound/cards | grep -v '^---' | sed 's/^/  /'
else
	echo "  no /proc/asound - ALSA not available"
fi
echo

# ---------------------------------------------------------------- storage
echo "storage"
for b in /sys/block/sd*; do
	[ -e "$b" ] || continue
	name=$(basename "$b")
	sz=$(cat "$b/size" 2>/dev/null)
	drv=$(basename "$(readlink -f "$b/device/driver" 2>/dev/null)" 2>/dev/null)
	printf "  %-6s %6s GiB removable=%s driver=%s\n" "$name" \
		"$(( ${sz:-0} / 2097152 ))" "$(cat "$b/removable" 2>/dev/null)" "${drv:-?}"
done
echo "  note: on Aeolia the internal drive is a USB-attached SATA bridge (shows as"
echo "        a USB disk); on Belize/Baikal it is AHCI."
echo
echo "Unknown values are reported as unknown on purpose. Paste this whole output"
echo "when reporting a compatibility result."
