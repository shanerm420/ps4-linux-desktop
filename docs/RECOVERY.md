# Recovery

Nothing in this project modifies the PS4 system, its partitions, games or saves.
Every failure mode below is recoverable, but read the autoload section carefully
— that one is a setting *outside* this project, and it can be deliberate.

## Removing an install: a file, not a partition

A PS4 Linux install — the ChromeOS project's included — is **not a partition on
the PS4 drive**. The drive holds Sony's own encrypted UFS filesystem, and the
install is one large file inside it (`/user/app/chromeos.img` for ChromeOS,
`/user/app/ps4linux.img` for this project) that Linux sees as a loop device.
Deleting the file deletes the install. Nothing is repartitioned, and no live USB
is involved:

- **From the app:** the removal screen lists every file with its size and asks
twice. The dry run prints the same list and changes nothing.
- **From OrbisOS over FTP** (GoldHEN's FTP server): delete
  `/user/app/chromeos.img` and the artifacts in `/data/linux/boot/`
  (`chromeos.img.xz`, `chromeos.img.size`, `chromeos.img.alloc*`,
  `ps4-layer.sqfs`, `chromeos-target`, `build-id`, and the loader `.bin` in both
  `/data/linux/boot` and `/data/payloads`).
- **Never** reach for "Initialize PS4" or any system-format option to get the
  space back. That erases games and saves; the files above are the only things
  that need to go. If free space does not update at once, reboot once.

A PC cannot do this for you either: the PS4 drive is encrypted with the console's
own EAP key, which exists only in the memory of a running, jailbroken console. A
Linux live USB on a laptop sees an unreadable disk, not a filesystem to edit.

## The console will not boot into Linux

1. Hold the power button until it turns off. Start it normally.
2. If it still goes to a black screen or the LED stays white, the kernel started
   before OrbisOS finished writing. Wait a minute, then start the console and
   launch the app again — the install resumes.
3. Check `/data/ps4linux/manifest.txt` and the GoldHEN log (port 3232) over FTP.

## Rescue shell (works even with a broken install)

Put a USB stick (FAT32 or exFAT) with an empty file named `ps4linux-recovery` in
its root, plug it in, and start Linux from the app. The initramfs stops before
touching the image and gives a shell.

This works because the loader checks USB **first** — the flag is read before the
internal image is even opened. From that shell you can mount the image, read
`/var/log/`, fix `fstab`, or copy data off.

## Autoload: a Linux-only console, and the way back

Payload autoload makes the console go straight into Linux: GoldHEN fires the
payload the moment it loads, the loader shuts OrbisOS down, and Linux starts. For
a console used as a computer and nothing else that is exactly right, and it is a
setting in **GoldHEN**, never in this project — the app deliberately writes no
autoload entry, because an entry that fires on every jailbreak is also how
consoles end up restarting forever.

Setup, once Linux starts correctly from the app:

1. The app leaves the real payload at `/data/payloads/ps4linux-loader.bin`, with a
   copy at `/data/linux/boot/ps4linux-loader.bin`.
2. Enable payload autoload in GoldHEN's settings and point it at that file. The
   wording and the location differ between GoldHEN builds: some read a folder
   (`/data/GoldHEN/autoload/`), others a list (`/data/GoldHEN/autoload.txt`,
   `/data/bdj_autoload.cfg`, `/data/payloads/autoload.txt`).
3. Restart and jailbreak. Going straight to Linux is the confirmation; reaching
   the home screen means autoload is not active yet.

**The way back, and why it has to be planned.** With autoload on, this app cannot
undo it: GoldHEN fires the payload the instant it loads, so the PS4 home screen
never appears for you to launch anything.

1. Boot the console and do **not** run the exploit. The PS4 system comes up
   normally — games, saves, the store — just without homebrew.
2. To remove the entry itself, load a homebrew enabler that does not autoload
   payloads (NextHEN is the one reported working; PS4HEN Lite and Mira are the
   same idea), then FTP in and delete the entry plus the payload copy it names.
3. Reboot, re-enable GoldHEN, and confirm the console stays on the home screen.
4. From then on, start Linux from the app only — or turn autoload back on
   deliberately, knowing the above.

## Boot loop after enabling payload autoload

**Symptom:** the console loads the exploit and immediately restarts, over and
over, before you can reach the home screen.

**Cause:** a Linux payload in an autoload location — either the Linux-only setup
above, or an entry somebody else made. Every jailbreak autoloads it, and the
payload immediately shuts OrbisOS down and starts Linux, so the loop never ends.

**Fix (the path that worked on the reporting console):**

1. Power off fully (hold the button).
2. Boot the exploit chain with a homebrew enabler that does **not** autoload
   payloads — NextHEN is what was used successfully. PS4HEN Lite or Mira are the
   same idea.
3. Once you have FTP or a file manager, delete the Linux payload from wherever it
   was autoloaded, and any autoload list entry that names it. Known locations
   differ between GoldHEN builds and third-party loaders:
   `/data/GoldHEN/autoload/`, `/data/GoldHEN/autoload.txt`,
   `/data/bdj_autoload.cfg`, `/data/payloads/autoload.txt`.
4. Reboot, re-enable GoldHEN, and confirm the console stays on the home screen.
5. Launch Linux only from the app from then on.

**Honest limits of this advice:** I could not verify NextHEN's supported-firmware
matrix, so step 2 is not universal. The autoload path also differs by GoldHEN
version. Inspect the GoldHEN menu and folders on *your* firmware instead of
trusting a path from a document. If no non-autoloading enabler exists for your
firmware, treat that firmware as unproven for recovery and record it in
`docs/TEST-MATRIX.md`.

## Linux boots but the desktop does not start

Switch to a text console (`Ctrl+Alt+F2`) and check:

```
systemctl --failed
journalctl -b -p err
cat /var/log/ps4-hwprofile.txt
```

The most likely causes, in order: the PS4-patched Mesa is missing from
`/opt/ps4-mesa` (so `radeonsi` never binds), or `/boot` was not remounted
read-only and something wrote to it.

## A bad update broke the boot

The kernel and initramfs are not managed by apt. If a *PS4 components update*
fails, the boot counter falls back to the previous slot after three attempts. If
both slots are broken, use the USB rescue shell and restore from
`/var/backups/ps4linux/`.

## Uninstall

1. Delete the app from the PS4 home screen.
2. Over FTP, delete `/user/app/ps4linux.img` (or reformat the USB drive).
3. Delete `/data/ps4linux/` and the `ps4linux-*` files in `/data/linux/boot`
   and `/data/payloads`.
4. If `backups.txt` lists files that were moved aside, rename them back.

Nothing else on the console is affected.
