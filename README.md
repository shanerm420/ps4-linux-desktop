# PS4 Linux Desktop

A Debian 13 + XFCE Linux desktop for jailbroken PS4 consoles, delivered as PS4
homebrew packages. It replaces a ChromeOS-for-PS4 installation with a normal
desktop distribution that takes ordinary `apt`/Flatpak/Steam updates.

**Status: the packages build and validate; nothing has run on a PS4.** The table
below is the whole truth about what is proven and what is not.

## Reference console

Development target: **PS4 Pro, Baikal southbridge, firmware 12.52, GoldHEN.**

Two facts about that machine are established and are not claims about this code:
the Linux loader lists firmware 12.50/12.52 as supported, and a ChromeOS-for-PS4
install has booted on it from the internal drive, which proves the drive key,
AES-XTS and UFS2 with `--skip 111669149696` work on this board.

## Two packages, two apps

| Package | TITLE_ID | Source | What it does |
|---|---|---|---|
| PS4 Linux Desktop | `PS4LNX001` | `pkg/installer/installer/main.c` | Briefing, target, size, reserve, start Linux |
| PS4 Linux: Remove ChromeOS | `PS4LNX002` | `pkg/installer/installer/remove.c` | Removes a ChromeOS-for-PS4 install, and nothing else |

They are separate on purpose. The installer never deletes a file that existed
before it ran - its `unlink()` calls only clean up temporary files it created -
so "install Linux" cannot erase an existing install. The remover is the only code
that removes user data: it lists every path with its size, asks twice, deletes,
then re-scans to report what actually went.

## What is verified

| Check | Result |
|---|---|
| `eboot.bin` compiles and links | yes - 87,456 bytes, clang 18, `x86_64-pc-freebsd12-elf` |
| SELF layout | 8 entries, matching the layout that launches on hardware |
| `DT_SCE_FILENAME` | relative (`build/remove.elf`), not a host path |
| `pkg_validate` | 28/28 OK - header digest, SC entry hashes, signatures, RIF |
| Inner PFS contents | `eboot.bin`, `libc.prx`, `libSceFios2.prx`, `right.sprx`, `keystone` |
| PKG size | 6,619,136 bytes - identical to the reference working package |
| ChromeOS removal rules | 28/28 assertions on a synthetic tree (games, saves and other installs survive) |
| Image validator | passes a good image, rejects one with `orphan_file` |
| Hardware detection tool | builds and runs on a normal Linux host |

## What is NOT verified

- **Nothing has been installed or launched on a PS4.** No console was available.
- The remover's dialog flow has never been displayed on hardware.
- The installer package builds, but with placeholder assets: it is not shippable
  until it carries a real `bzImage`, `initramfs.cpio.gz`, `ps4linux-loader.bin`
  and optionally `rootfs.tar.zst`.
- Kernel, rootfs image and initramfs have never been built end to end here.

## Build

Requires an OpenOrbis PS4 toolchain (release build, not the git repo) plus clang
and lld. On an ARM64 host, the community ARM64 kit provides `bin/linux/`
wrappers, so this Makefile works unchanged.

```sh
export OO_PS4_TOOLCHAIN=/path/to/OpenOrbis/PS4Toolchain
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1     # PkgTool.Core is .NET; needs this on minimal images

cd pkg/installer
make clean && make APP=remove     # -> IV0000-PS4LNX002_00-PS4LINUXREMOVER0.pkg
make clean && make APP=install    # -> IV0000-PS4LNX001_00-PS4LINUXDESKTOP0.pkg
```

Clean between the two: `eboot.bin`, `pkg.gp4` and `sce_sys/param.sfo` are shared
intermediates. Nothing is committed that the toolchain can supply: the runtime
modules and the package artwork are copied in at build time, so a checkout is
three files and a Makefile.

### Four traps that cost real time

1. `PkgTool.Core` aborts with "Couldn't find a valid ICU package" - set
   `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`.
2. `pkg_build` says "No usable version of libssl was found" - it links OpenSSL
   1.1; supply `libssl1.1` on `LD_LIBRARY_PATH` on a modern distro.
3. The standalone LLVM 18.1.8 tarball needs `libtinfo.so.5`, absent on Ubuntu
   24.04. Installing `clang` from the distro avoids this.
4. `CONTENT_ID` must be exactly 36 characters (`IV0000-` + 9-char TITLE_ID +
   `_00-` + 16 chars). LibOrbisPkg answers a wrong length with a .NET stack
   trace; `make` now checks first.

### Installing on the console

Copy the `.pkg` to the root of a USB stick, then GoldHEN -> Package Installer
(or Debug Settings -> Game -> Package Installer). These are fake-signed packages:
they require GoldHEN and will not install on a stock console. If an older build
with the same content ID is installed, delete it first.

## Storage model

Internal installs are **one fully-allocated ext4 file**, not a partition table.
PS4-Multiboot maps *file* blocks through `blockmap`/`FIBMAP`, so a partition table
inside the image has nothing to map against. Consequences: the image must have no
holes, the label must end in `-PS4`, size is fixed at build time, and the
filesystem must not carry `orphan_file` (kernels older than 5.15 cannot mount it).

Kernel and initramfs live in `/data/linux/boot`, which the loader reads before any
filesystem exists. The loader's search order is fixed upstream, so this project
claims those filenames explicitly and backs up anything it finds there.

## Repository layout

```
pkg/installer/          the two OpenOrbis apps + Makefile
scripts/                toolchain, kernel, rootfs, initramfs, image and PKG builds
docs/                   architecture, storage layout, recovery, test matrix
tools/                  hardware detection and ChromeOS removal scanners
rootfs/                 files installed into the Debian image
initramfs/              the boot/install function sourced by the initramfs
```

| Path | Purpose |
|---|---|
| `scripts/get-toolchain.sh` | fetch and verify the OpenOrbis toolchain |
| `scripts/build-kernel.sh` | one kernel per southbridge, `-march=btver2`, firmware built in |
| `scripts/build-rootfs.sh` | debootstrap trixie, desktop, Mesa check |
| `scripts/build-initramfs.sh` | repack the base initramfs with our boot function |
| `scripts/check-image.sh` | the six properties Multiboot needs, before the console sees it |
| `scripts/make-pkg.sh` | stage assets, build both PKGs, refuse debug kernels |
| `scripts/make-test-usb.sh` | stock-kernel test stick, works on a phone without root |
| `tools/hwprofile.c`, `.sh` | what the kernel actually detects; says "unknown" rather than guessing |
| `tools/chromeos-scan.c` | the removal rule set, with a dry run and a confirmation token |
| `tools/test-chromeos-scan.sh` | 28 assertions on a synthetic tree |

### What is deliberately not in the repository

The kernel tree, the Debian rootfs, the disk image, the loader payload and the
toolchain are all fetched or built, not committed - together they are tens of
gigabytes. The `.pkg` files are build output. `tools/chromeos-scan` is committed
as source only; build it with `cc -O2 -Wall -Wextra -o chromeos-scan chromeos-scan.c`
before running the test script.

## Licence

**GPL-3.0-or-later** for this project's own code - see `LICENSE`.

That is not an arbitrary choice. The packages are built with the GPL-3.0
OpenOrbis toolchain and LibOrbisPkg, so distributing the resulting binaries
carries the GPL's source obligation either way; declaring it means the obligation
can be met by pointing at this repository.

Third-party components keep their own licences and are not relicensed here. See
`NOTICE.md` for the full list and for what is deliberately absent. ChromeOS Flex
is **not** redistributable and is not included. Firmware blobs (AMD GPU, MediaTek
MT7668, Marvell) come from `linux-firmware` under their own terms. This
repository contains no Sony code and no Sony key.
