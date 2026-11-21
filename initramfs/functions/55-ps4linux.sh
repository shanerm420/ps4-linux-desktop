# PS4 Linux - initramfs boot/install logic.
#
# Sourced by the initramfs-ps4 init after ps4hdd_open has mounted the PS4 drive
# at /ps4hdd. POSIX sh (busybox), no bashisms, no set -e: a failing step must
# report and drop to a shell, never exit the initramfs.
#
# Storage model: ONE ext4 filesystem, no partition table. The image is a single
# fully-allocated file (or a whole USB device) that is mounted directly. There is
# no partition to scan and nothing to offset into: see docs/LAYOUT.md for why a
# GPT inside the image cannot work with blockmap/FIBMAP.
#
# UNTESTED ON HARDWARE. Every hardware-dependent step here is marked; see
# docs/TEST-MATRIX.md.

PS4L_STATE=/ps4hdd/data/ps4linux
PS4L_IMG=/ps4hdd/app/ps4linux.img
PS4L_MOUNT=/newroot

ps4l_msg() { echo "[ps4linux] $*"; }

# Read a key from the installer's manifest (target=, state_gib=, label=).
ps4l_manifest() {
	[ -f "$PS4L_STATE/manifest.txt" ] || return 1
	sed -n "s/^$1=//p" "$PS4L_STATE/manifest.txt" | head -n 1
}

# A USB stick with a file called ps4linux-recovery forces a rescue shell. The
# loader checks USB first, so this works even when the install is broken.
ps4l_recovery_requested() {
	for d in /mnt/usb0 /mnt/usb1 /mnt/usb2; do
		[ -f "$d/ps4linux-recovery" ] && return 0
	done
	return 1
}

ps4l_shell() {
	ps4l_msg "$1"
	ps4l_msg "dropping to a rescue shell; the PS4 system is not modified"
	exec /bin/sh
}

# Internal install: one image file on the PS4 drive.
# External install: a whole device, found by the filesystem UUID the installer
# recorded in ext.uuid (a UUID survives re-cabling; a device name does not).
ps4l_locate() {
	if [ "$(ps4l_manifest target)" = external ]; then
		uuid=$(cat "$PS4L_STATE/ext.uuid" 2>/dev/null) || return 1
		[ -n "$uuid" ] || return 1
		for d in /dev/sd?; do
			[ -b "$d" ] || continue
			if [ "$(blkid -s UUID -o value "$d" 2>/dev/null)" = "$uuid" ]; then
				PS4L_DEV=$d
				return 0
			fi
		done
		return 1
	fi
	[ -f "$PS4L_IMG" ] || return 1
	PS4L_DEV=$PS4L_IMG
	return 0
}

# Mount the single filesystem. A file gets the loop driver, a device does not.
ps4l_mount_root() {
	if [ -f "$PS4L_DEV" ]; then
		mount -t ext4 -o loop "$PS4L_DEV" "$PS4L_MOUNT"
	else
		mount -t ext4 "$PS4L_DEV" "$PS4L_MOUNT"
	fi
}

# Populate an image that the installer reserved but nobody formatted.
#
# This is the fallback path: the supported way to get an image is to build it on
# a host (mke2fs -d over the rootfs tarball) and copy it over, because that needs
# no tools on the console. When the PKG carries the tarball and the initramfs has
# mke2fs, the same result can be produced here instead.
#
# -O ^orphan_file is not optional: kernels older than 5.15 cannot mount a
# filesystem with orphan_file, and e2fsprogs 1.47 enables it on some distro
# configs. A 5.4 PS4 kernel then sees an unmountable filesystem.
ps4l_populate() {
	tarfile=/ps4hdd/data/linux/boot/rootfs.tar.zst
	[ -f "$tarfile" ] || return 1
	command -v mke2fs >/dev/null 2>&1 || {
		ps4l_msg "the image is empty and this initramfs has no mke2fs"
		ps4l_msg "build the image on a host with scripts/build-rootimg.sh and copy it over"
		return 1
	}
	ps4l_msg "formatting the reserved image (first start) - do not power off"
	ps4_change_led orange
	mke2fs -q -F -t ext4 -m 1 -O ^orphan_file \
		-L "$(ps4l_manifest label || echo ps4linux)" "$PS4L_IMG" || return 1
	# mke2fs DISCARDS the preallocated blocks (measured: 32 MiB reserved became
	# 4.3 MB allocated), and a hole has no block for FIBMAP to map. Refill it
	# before anything is written, or the image boots corrupt.
	if command -v fallocate >/dev/null 2>&1; then
		fallocate -l "$(stat -c %s "$PS4L_IMG")" "$PS4L_IMG" || {
			ps4l_msg "could not re-allocate the image blocks"
			return 1
		}
	fi
	ps4l_mount_root || return 1
	ps4l_msg "installing the rootfs (first start) - do not power off"
	zstd -dc "$tarfile" | tar -x -C "$PS4L_MOUNT" --numeric-owner || {
		ps4l_msg "unpacking the rootfs failed"
		umount "$PS4L_MOUNT"
		return 1
	}
	sync
	touch "$PS4L_MOUNT/.ps4linux-installed"
	umount "$PS4L_MOUNT"
	return 0
}

# A mounted filesystem that has no init is not a rootfs; say so instead of
# switch_root-ing into nothing and leaving a black screen with no explanation.
ps4l_has_root() {
	[ -x "$PS4L_MOUNT/sbin/init" ] || [ -x "$PS4L_MOUNT/usr/lib/systemd/systemd" ] || [ -x "$PS4L_MOUNT/init" ]
}

# Autoload policy, set in the app (Autoload -> Boot behaviour) and stored next to
# the kernel, because there is no UI here to ask with:
#   ask    - leave the entry, leave a note; the app offers to remove it next launch
#   remove - delete the known autoload files now, so this console cannot loop
#   keep   - never touch them
# Only ever acts on entries that exist, and only on the known paths.
ps4l_autoload_entries() {
	ls -d /ps4hdd/data/GoldHEN/autoload 2>/dev/null
	ls -d /ps4hdd/data/GoldHEN/autoload.txt 2>/dev/null
	ls -d /ps4hdd/data/bdj_autoload.cfg 2>/dev/null
	ls -d /ps4hdd/data/payloads/autoload.txt 2>/dev/null
}

ps4l_autoload_policy() {
	ps4l_autoload_entries | grep -q . || return 0
	pol=$(sed -n 's/^[[:space:]]*//;s/[[:space:]]*$//p' \
	      /ps4hdd/data/linux/boot/autoload-policy 2>/dev/null | head -n 1)
	[ -n "$pol" ] || pol=ask
	case "$pol" in
	remove)
		rm -rf /ps4hdd/data/GoldHEN/autoload 2>/dev/null
		rm -f /ps4hdd/data/GoldHEN/autoload.txt \
		      /ps4hdd/data/bdj_autoload.cfg \
		      /ps4hdd/data/payloads/autoload.txt 2>/dev/null
		ps4l_msg "autoload: entries removed during boot (policy: remove)"
		;;
	keep)
		ps4l_msg "autoload: left alone (policy: keep)"
		;;
	*)
		mkdir -p "$PS4L_STATE" 2>/dev/null
		: > "$PS4L_STATE/autoload-seen" 2>/dev/null
		ps4l_msg "autoload: noted for the app to ask about (policy: ask)"
		;;
	esac
}

ps4linux_boot() {
	if ps4l_recovery_requested; then
		ps4l_shell "ps4linux-recovery found on a USB drive"
	fi

	ps4l_locate || ps4l_shell "no PS4 Linux install found (internal image or external drive)"
	mkdir -p "$PS4L_MOUNT"

	if ! ps4l_mount_root; then
		ps4l_populate || ps4l_shell "could not mount $PS4L_DEV and could not populate it"
	fi

	if ! ps4l_has_root; then
		umount "$PS4L_MOUNT"
		ps4l_populate || ps4l_shell "$PS4L_DEV has no init and there is no rootfs to install"
		ps4l_mount_root || ps4l_shell "could not mount the freshly installed root filesystem"
		ps4l_has_root || ps4l_shell "the installed rootfs has no init - the tarball is wrong"
	fi

	# Before the root filesystem takes over: an autoload entry that launched this
	# boot is still armed for the next one. This is the only chance to deal with it
	# from inside Linux, since the app runs in OrbisOS.
	ps4l_autoload_policy

	ps4_change_led white
	mount --move /proc "$PS4L_MOUNT/proc" 2>/dev/null
	mount --move /sys "$PS4L_MOUNT/sys" 2>/dev/null
	mount --move /dev "$PS4L_MOUNT/dev" 2>/dev/null
	exec switch_root "$PS4L_MOUNT" /sbin/init
	ps4l_shell "switch_root failed"
}
