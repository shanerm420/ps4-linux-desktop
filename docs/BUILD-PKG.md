# Building the PKGs (verified recipe)

Everything here was run, not inferred. On Ubuntu 24.04 x86-64, with no root.

## What you need

| Thing | Where | Size |
|---|---|---|
| OpenOrbis toolchain | `github.com/OpenOrbis/OpenOrbis-PS4-Toolchain/releases/download/v0.5.4/toolchain-llvm-18.tar.gz` | 158 MB |
| clang + lld | LLVM 18.1.8 release, `clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz` | 997 MB |

The toolchain archive contains `bin/linux/{PkgTool.Core,create-gp4,create-fself}`,
`include/`, `lib/` (with `crt1.o`), `link.x`, and the runtime modules at
**`src/modules/`** (not `bin/data/modules` - check both, as the Makefile does).
It contains **no clang**: that is installed separately.

## The three traps

Each of these fails with an error that does not name the real problem.

1. **`PkgTool.Core` dies on a minimal Linux**: "Couldn't find a valid ICU package
   installed on the system". It is a .NET binary and wants ICU.
   Fix: `export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`.

2. **"No usable version of libssl was found"** when running `pkg_build`. The
   .NET runtime inside `PkgTool.Core` links OpenSSL 1.1, and Ubuntu 24.04 ships
   only libssl3. Fix: fetch `libssl1.1` from Debian bullseye, unpack it, and put
   its directory on `LD_LIBRARY_PATH`.

3. **clang 18.1.8 (ubuntu-18.04 build) needs `libtinfo.so.5`**, which Ubuntu
   24.04 does not have (it has libtinfo6). Fix: unpack Ubuntu's `libtinfo5` and
   add it to `LD_LIBRARY_PATH` as well.

A fourth, in our own tree: **`CONTENT_ID` must be exactly 36 characters**
(`IV0000-` + 9-char TITLE_ID + `_00-` + 16 chars). LibOrbisPkg answers a wrong
length with a .NET stack trace. `make` now checks it before building.

## Build

```sh
export OO_PS4_TOOLCHAIN=/path/to/OpenOrbis/PS4Toolchain
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export LD_LIBRARY_PATH=/path/to/libtinfo5/usr/lib/x86_64-linux-gnu:/path/to/libssl1.1/usr/lib/x86_64-linux-gnu
export PATH=/path/to/clang+llvm-18.1.8/bin:$PATH

cd pkg/installer
make clean && make APP=remove    # -> IV0000-PS4LNX002_00-PS4LINUXREMOVER0.pkg
make clean && make APP=install   # -> IV0000-PS4LNX001_00-PS4LINUXDESKTOP0.pkg
```

Clean between the two: the intermediate names (`eboot.bin`, `pkg.gp4`,
`sce_sys/param.sfo`) are shared. `scripts/make-pkg.sh` does both in sequence and
stages the install assets first.

Verify a package before trusting it:

```sh
PkgTool.Core pkg_validate IV0000-...pkg      # every hash and signature [OK]
PkgTool.Core pkg_extract  IV0000-...pkg /tmp/x
```

## What was actually produced

- `eboot.bin`, 87,456 bytes - compiled with clang 18 targeting
  `x86_64-pc-freebsd12-elf`, linked with `ld.lld` against `link.x` and `crt1.o`.
- `IV0000-PS4LNX002_00-PS4LINUXREMOVER0.pkg`, 6,619,136 bytes - `pkg_validate`
  reports OK for the header digest, both SC entry hashes, the header signature
  and the debug RIF signature. Contents: `uroot/eboot.bin`,
  `uroot/sce_module/{libc,libSceFios2}.prx`, `uroot/sce_sys/about/right.sprx`,
  `uroot/sce_sys/keystone`.
- The installer package also builds to completion with placeholder assets, which
  proves its graph; it is **not shippable** until it carries a real `bzImage`,
  `initramfs.cpio.gz`, `ps4linux-loader.bin` and (optionally) `rootfs.tar.zst`.

## Status

Built, packaged and validated on x86-64 Linux. **Not installed or run on a PS4.**
The remover has never displayed a dialog on hardware, so its flow is unproven
even though the package structure is valid. Record it in `docs/TEST-MATRIX.md`
when it runs.
