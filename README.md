# PS4 Linux Desktop

A full Linux distribution for jailbroken PS4 consoles, installed from a PS4 PKG.
Replaces the ChromeOS-based installer with Debian + XFCE.

**This tree is a working skeleton, not a release.** Read the status table before
assuming anything works.

## Status

| Area | State |
|---|---|
| Installer app source (`pkg/installer/`) | Written; type-checks against the real Orbis headers |
| Installer app compiled to `eboot.bin` | **Built** — 105,008 bytes with clang 18 + `ld.lld` against `link.x` |
| Installer PKG produced | **Built and validated** — `pkg_validate` reports every hash and signature OK; carries the real kernel, but its initramfs and loader are still placeholders |
| Installer PKG installed on a console | **Not done** |
| ChromeOS detection / removal rules | **Implemented and tested** (24 assertions, synthetic tree) |
| Hardware detection tool | **Built and run** on a normal Linux host |
| Image validator (`scripts/check-image.sh`) | **Run** against real images: passes a good one, rejects an `orphan_file` one |
| Kernel build (`scripts/build-kernel.sh`) | **Run** — produced a 14,251,008-byte `bzImage`, release `7.3.4-PS4Linux-baikal+` |
| Rootfs / initramfs build scripts | Written; **never run end to end** |
| Debian rootfs built and booted on a PS4 | **Not done** |
| Anything at all tested on PS4 hardware | **Nothing** |

`docs/TEST-MATRIX.md` lists every hardware test with its real status. Every row
is `untested`, because no console was available.

## The two packages

| Package | TITLE_ID | What it does |
|---|---|---|
| PS4 Linux Desktop | `PS4LNX001` | Installs Linux: briefing, target, size, reserve, start |
| PS4 Linux: Remove ChromeOS | `PS4LNX002` | Removes a ChromeOS-for-PS4 install, and nothing else |

Separate on purpose. The installer never deletes a file that existed before it
ran - its `unlink()` calls only clean up temporary files it created itself - so
"install Linux" cannot erase an existing install, whatever the dialogs do. The
remover is the only code that removes user data, it lists every path with its
size first, and it asks twice. It cannot install anything.

If a ChromeOS install is present, the installer says so and installs beside it,
pointing at the remover for the space. Both apps are built from one tree:
`make APP=install` and `make APP=remove`, which `scripts/make-pkg.sh` runs in
sequence and cleans between, because the intermediate names are shared.

## Reference console

Development target: **PS4 Pro, Baikal southbridge, firmware 12.52, GoldHEN.**

The `Baikal (Pro)` column of the test matrix is the one to fill first. Two facts
about this machine are established, and neither is a claim about this software:
the Linux loader lists firmware 12.50/12.52 as supported, and a ChromeOS-for-PS4
install has booted on it — which proves the drive key, AES-XTS and UFS2 with
`--skip 111669149696` work on this exact board. Everything else here is still
unproven.

Two traps that cost people a boot, both documented upstream:

- **GoldHEN v2.4b18.8 does not boot the loader.** Use the latest GoldHEN.
- **The kernel tree is GitLab `gitlab.com/rmuxnet/linux`, branch `ps4/7.3.4`.**
  One branch covers Aeolia, Belize and Baikal; the southbridge is detected at
  runtime. `scripts/build-kernel.sh` clones exactly that and nothing else.

## Layout

```
pkg/installer/          the PS4 app (OpenOrbis C) + Makefile
scripts/                build-kernel.sh, build-rootfs.sh, build-initramfs.sh, make-pkg.sh
initramfs/              our boot/install function + the early recovery hook
rootfs/                 files installed into the Debian image (apt pins, units, ICD json)
tools/                  hwprofile.c (hardware truth), chromeos-scan.c (removal rules + test)
docs/                   ARCHITECTURE, LAYOUT, RECOVERY, TEST-MATRIX
```

## Fastest path to a result on hardware

`scripts/make-test-usb.sh` builds a testable USB set with **no toolchain and no
PKG**: a prebuilt kernel (pinned URL), an initramfs repacked from the
initramfs-ps4 base, and a Debian rootfs as `distro.tar.xz` (the stock installer
refuses `.zst`). You then use two sticks on the console: a SOURCE stick holding
those three files, and an empty TARGET stick that gets erased and installed onto.

```sh
sudo PROFILE=minimal bash scripts/make-test-usb.sh   # console only, fastest
sudo PROFILE=desktop bash scripts/make-test-usb.sh   # XFCE
```

This deliberately uses the stock kernel and stock initramfs, so a failure is
attributable. Our installer app, the PKG, the recovery flag and the `/opt` Mesa
come in later stages.

## Build order

Prerequisites: x86-64 Linux host, ~30 GB free, `debootstrap`, `zstd`,
`squashfs-tools`, `sgdisk`, Docker (Mesa), and a **built** OpenOrbis toolchain.

```sh
# The scripts are invoked through bash because the executable bit is not set in
# this repository yet (`git update-index --chmod=+x scripts/*.sh` fixes that).

# Use the toolchain *release*, not the git repository: bin/linux/ is empty until
# a release build. This is the archive the PKGs here were built with.
curl -LO https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain/releases/download/v0.5.4/toolchain-llvm-18.tar.gz
tar -xzf toolchain-llvm-18.tar.gz
export OO_PS4_TOOLCHAIN=$PWD/OpenOrbis/PS4Toolchain

SB=baikal        bash scripts/build-kernel.sh          # -> out/kbuild/out/bzImage
# already have a bzImage + .config? skip the build and point K at that directory:
#   K=/path/to/kernel  bash scripts/make-pkg.sh
PS4_MESA=...     bash scripts/build-rootfs.sh
                 bash scripts/build-initramfs.sh
                 bash scripts/make-pkg.sh
```

The git repository of the toolchain is **not** enough: `bin/linux/` is empty
until `build.sh` runs, and `PkgTool.Core` (Sony's packaging tool) is only present
in a built toolchain. `make-pkg.sh` fails with a clear message if it is missing.

## What has actually been checked

| Check | Command | Result |
|---|---|---|
| Hardware tool builds, runs | `cc -O2 -Wall -Wextra -o hwprofile tools/hwprofile.c` | 0 warnings; reports "not a PS4" on a PC, as designed |
| Removal rules | `tools/test-chromeos-scan.sh` | 24/24 assertions pass |
| Installer type-checks | `cc -fsyntax-only -D__ORBIS__ -I$OO/include -isystem $OO/include/orbis pkg/installer/installer/main.c` | pass |
| Shell scripts parse | `bash -n scripts/*.sh` | pass |
| Dummy kernel package builds | `dpkg-deb --build` | pass |
| Kernel builds | `SB=baikal bash scripts/build-kernel.sh` | pass — `bzImage` 14,251,008 bytes, sha256 `a70b0935…b889`, `HdrS` at 0x202 |
| Installer app compiles | `make APP=install` | pass — `eboot.bin`, 105,008 bytes |
| Installer PKG builds and validates | `WITH_ROOTFS=0 bash scripts/make-pkg.sh`, `PkgTool.Core pkg_validate` | pass — 17,039,360 bytes, 28/28 checks OK, kernel inside the PKG matches the built one byte for byte |

Not checked: any rootfs or initramfs build, installing a PKG on a console, and
every hardware behaviour. The installer PKG is structurally valid but not
bootable yet: `initramfs.cpio.gz` and `ps4linux-loader.bin` inside it are
placeholders, marked as such in their own bytes.

## Design decisions worth knowing before you change anything

- **The boot directory cannot be namespaced.** The loader's search path is fixed
  upstream, so we own `/data/linux/boot` explicitly and back up what was there.
  See `docs/LAYOUT.md`.
- **Space is reserved from OrbisOS, not Linux.** Linux's UFS driver writes at
  ~13 MB/s; OrbisOS reaches 60–150 MB/s. The reserve also must settle before
  booting, or the console crashes (measured by the reference project: no picture
  at 32 GB, panic at 64 GB).
- **Never put firmware in the initramfs.** GPU/Wi-Fi firmware is built into the
  kernel; `regulatory.db` there deadlocks the MediaTek driver and takes DHCP down
  with it.
- **Never write a payload autoload entry.** A boot loop is the result. The app
  warns if it finds one, and `docs/RECOVERY.md` has the escape route.

## Licensing

Kernel GPL-2.0 (publish sources and patches), Mesa MIT (publish the patch),
initramfs base GPL-3.0/BSD, OpenOrbis GPL-3.0. Debian packages keep their
copyright files.

**Do not bundle Sony-extracted blobs** — `liverpool_*.bin`, `gladius_*.bin`, or the
EAP HDD key. The loader extracts those from OrbisOS memory at boot; that is what
keeps the release distributable. ChromeOS Flex is not redistributable at all,
which is one more reason this project ships Debian.
