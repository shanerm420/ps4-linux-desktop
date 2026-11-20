#!/bin/bash
# Test the ChromeOS removal rules against a synthetic tree. No PS4 needed.
#
# What this proves: the scanner claims exactly the ChromeOS-owned files, and
# leaves shared/foreign files alone - including a coexisting plain-Linux
# install that uses the same /data/linux/boot directory.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$HERE/chromeos-scan}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

say() { printf '%s\n' "$*"; }
check() { if eval "$2"; then say "  ok   $1"; else say "  FAIL $1"; fail=1; fi; }

# --- build a tree that contains a ChromeOS install AND a plain Linux install
mkdir -p "$T/user/app/CUSA12345/sce_sys" "$T/user/home/1234567/savedata" \
         "$T/data/linux/boot" "$T/data/payloads" "$T/data/pkg" "$T/mnt/usb0"

head -c 4096 /dev/zero > "$T/user/app/chromeos.img"          # ChromeOS image
head -c 2048 /dev/zero > "$T/data/linux/boot/chromeos.img.xz"
# A reserve that was interrupted leaves these behind, and they are large: the
# whole point of reclaiming an internal install is deleting them.
head -c 8192 /dev/zero > "$T/data/linux/boot/chromeos.img.alloc"
head -c 4096 /dev/zero > "$T/data/linux/boot/chromeos.img.alloc.part"
printf '4096\n'       > "$T/data/linux/boot/chromeos.img.size"
head -c 1024 /dev/zero > "$T/data/linux/boot/ps4-layer.sqfs"
head -c  512 /dev/zero > "$T/data/linux/boot/ps4-chromeos-loader.bin"
printf 'target=internal\n' > "$T/data/linux/boot/chromeos-target"
printf 'abc123\n'     > "$T/data/linux/boot/build-id"
head -c  512 /dev/zero > "$T/data/payloads/ps4-chromeos-loader.bin"

# ... a coexisting plain-Linux install using the same shared directory
head -c 8192 /dev/zero > "$T/data/linux/boot/bzImage"
head -c 4096 /dev/zero > "$T/data/linux/boot/initramfs.cpio.gz"
printf 'root=/dev/sda2\n' > "$T/data/linux/boot/bootargs.txt"

# ... unrelated user data that must never be touched
printf 'game data\n'  > "$T/data/pkg/CUSA12345.pkg"
printf 'save\n'       > "$T/user/home/1234567/savedata/s.dat"
printf 'other\n'      > "$T/data/payloads/payload-guest.bin"
printf 'save\n'       > "$T/user/app/CUSA12345/sce_sys/param.sfo"

say "== dry run =="
OUT=$("$BIN" --root="$T")
printf '%s\n' "$OUT" | sed 's/^/    /'

DEL=$(printf '%s\n' "$OUT" | grep '^  DELETE' || true)
say "== assertions =="

check "finds the install"            'printf "%s" "$OUT" | grep -q "ChromeOS for PS4: FOUND"'
check "claims the image"             'printf "%s" "$DEL" | grep -q "user/app/chromeos.img"'
check "claims chromeos.img.xz"       'printf "%s" "$DEL" | grep -q "chromeos.img.xz"'
check "claims the leftover reserve"   'printf "%s" "$DEL" | grep -q "chromeos.img.alloc "'
check "claims a partial reserve"      'printf "%s" "$DEL" | grep -q "chromeos.img.alloc.part"'
check "claims the layer"             'printf "%s" "$DEL" | grep -q "ps4-layer.sqfs"'
check "claims both payload copies"   '[ $(printf "%s" "$DEL" | grep -c "ps4-chromeos-loader.bin") -eq 2 ]'
check "claims chromeos-target"       'printf "%s" "$DEL" | grep -q "chromeos-target"'

check "does NOT claim bzImage"       '! printf "%s" "$DEL" | grep -q "bzImage"'
check "does NOT claim initramfs"     '! printf "%s" "$DEL" | grep -q "initramfs"'
check "does NOT claim bootargs.txt"  '! printf "%s" "$DEL" | grep -q "bootargs"'
check "does NOT claim other payload" '! printf "%s" "$DEL" | grep -q "payload-guest"'
check "does NOT claim game pkg"      '! printf "%s" "$DEL" | grep -q "CUSA12345.pkg"'
check "does NOT claim saves"         '! printf "%s" "$DEL" | grep -q "savedata"'

say "== apply without token (must refuse) =="
"$BIN" --root="$T" --apply >/dev/null 2>&1
check "refuses without --confirm"    '[ $? -ne 0 ]'
check "image still there"            '[ -f "$T/user/app/chromeos.img" ]'

say "== apply with token =="
"$BIN" --root="$T" --apply --confirm=ERASE-CHROMEOS >/dev/null 2>&1
check "image removed"                '[ ! -f "$T/user/app/chromeos.img" ]'
check "leftover reserve removed"     '[ ! -f "$T/data/linux/boot/chromeos.img.alloc" ]'
check "partial reserve removed"      '[ ! -f "$T/data/linux/boot/chromeos.img.alloc.part" ]'
check "layer removed"                '[ ! -f "$T/data/linux/boot/ps4-layer.sqfs" ]'
check "payload removed (boot dir)"   '[ ! -f "$T/data/linux/boot/ps4-chromeos-loader.bin" ]'
check "payload removed (payloads)"   '[ ! -f "$T/data/payloads/ps4-chromeos-loader.bin" ]'

check "coexisting bzImage survived"  '[ -f "$T/data/linux/boot/bzImage" ]'
check "coexisting initramfs survived" '[ -f "$T/data/linux/boot/initramfs.cpio.gz" ]'
check "coexisting bootargs survived" '[ -f "$T/data/linux/boot/bootargs.txt" ]'
check "other payload survived"       '[ -f "$T/data/payloads/payload-guest.bin" ]'
check "game pkg survived"            '[ -f "$T/data/pkg/CUSA12345.pkg" ]'
check "save survived"                '[ -f "$T/user/home/1234567/savedata/s.dat" ]'

say ""
if [ "$fail" = 0 ]; then say "ALL CHECKS PASSED"; else say "SOME CHECKS FAILED"; fi
exit "$fail"
