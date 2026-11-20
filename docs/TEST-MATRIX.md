# Test matrix

**Status: every console row below is UNTESTED.** No PS4 hardware was available
while this tree was written. Nothing here may be described as working until a row
is filled in with a console, a date and a result.

**Target console:** PS4 Pro, Baikal southbridge, firmware 12.52, GoldHEN. That is
the `Baikal (Pro)` column: fill that one first and leave the others alone until a
console of that type exists. Two facts are already established for it and are not
claims about our software: the Linux loader lists 12.50/12.52 as supported, and a
ChromeOS-for-PS4 install **on the internal drive** has booted on this machine,
which proves the EAP key, AES-XTS and UFS2-with-`--skip 111669149696` path works
on this board, and that an internal install on Baikal is viable at all.

The community guide (`dionkill`) lists internal HDD on Baikal as "still
unsupported". Direct evidence on this console contradicts that for a Pro on 12.52,
so the internal install stays the default path here. Recorded as a contradiction
rather than resolved: one console, one firmware, one project's implementation.
The external/USB path remains the fallback if our own installer behaves
differently from ChromeOS's.

Fill a cell with `pass`, `fail`, or `partial (detail)`. A cell that has not been
run stays `untested` - do not leave it blank and do not infer it from a similar
model.

| Test | Aeolia (base) | Belize (base) | Baikal (Slim) | Baikal (Pro) | Notes |
|---|---|---|---|---|---|
| PKG installs from GoldHEN | untested | untested | untested | untested | |
| Briefing screen, Cancel changes nothing | untested | untested | untested | untested | |
| Space reservation completes | untested | untested | untested | untested | |
| Install resumes after interruption | untested | untested | untested | untested | |
| First boot to desktop | untested | untested | untested | untested | |
| GPU acceleration (radeonsi) | untested | untested | untested | untested | needs PS4-patched Mesa |
| Vulkan device present | untested | untested | untested | untested | `vulkaninfo` |
| HDMI audio | untested | untested | untested | untested | disputed in upstream reports |
| Ethernet | untested | untested | untested | untested | vendor `mts.ko` |
| Wi-Fi 88W8797 | untested | n/a | n/a | n/a | SDIO 02df:9129 |
| Wi-Fi 88W8897 | n/a | untested | untested | untested | SDIO 02df:912d |
| Wi-Fi MT7668 | n/a | untested | untested | untested | SDIO 037a:7608 |
| Bluetooth | untested | untested | untested | untested | |
| DualShock 4 over USB | untested | untested | untested | untested | |
| DualShock 4 over Bluetooth | untested | untested | untested | untested | pairing unproven upstream |
| USB storage | untested | untested | untested | untested | |
| Restart from Linux returns to OrbisOS | untested | untested | untested | untested | |
| Re-launch from the app | untested | untested | untested | untested | |
| `apt update && apt upgrade` | untested | untested | untested | untested | kernel must stay untouched |
| Steam launches | untested | untested | untested | untested | |
| A named game runs | untested | untested | untested | untested | record title + fps |
| ChromeOS removal | untested | untested | untested | untested | verify games/saves intact |
| Uninstall | untested | untested | untested | untested | |
| 10 x GoldHEN restart, no auto-launch | untested | untested | untested | untested | the boot-loop regression test |
| Fan control / thermals under load | untested | untested | untested | untested | fan interface reported missing in one tree |

## What *was* verified, and how

These are host-side checks, not console tests:

| Check | Result |
|---|---|
| `tools/chromeos-scan.c` builds with `-Wall -Wextra` | pass, 0 warnings |
| Removal rules on a synthetic tree (`tools/test-chromeos-scan.sh`) | pass, 28/28 assertions |
| Coexisting plain-Linux install survives ChromeOS removal | pass |
| `tools/hwprofile.c` builds and runs | pass; correctly reports "not a PS4" on a normal machine |
| `pkg/installer/installer/main.c` type-checks against the real Orbis headers | pass (`cc -fsyntax-only`, warnings only from SDK headers) |
| `main.c` compiles to an `eboot.bin` | pass - 87,456 bytes, clang 18, 8-entry SELF layout |
| PKG builds and validates | pass - 6,619,136 bytes, `pkg_validate` 28/28 OK |
| A clean checkout of three files builds the PKG from scratch | pass |
| Every shell script parses (`bash -n`, and `sh -n` for the initramfs hooks) | pass, 13 scripts |
| `scripts/build-rootimg.sh` on a synthetic rootfs | pass - image passes all six checks, fully allocated |
| `scripts/check-image.sh` against an image with `orphan_file` | pass - refuses it, exit 1 |
| `scripts/check-image.sh` against a sparse image | pass - warns, exit 2 |
| mke2fs discarding preallocated blocks | measured: 32 MiB reserved -> 4.3 MB after mke2fs -> 32 MiB after a non-sparse copy |
| No path referenced by any script or doc is missing | pass |
| PKG installs on a console | **not done** - no hardware |
| Kernel build (`scripts/build-kernel.sh`) | **not done** - needs the source tree, ~30 GB and hours |
| Rootfs build (`scripts/build-rootfs.sh`) | **not done** - needs root and debootstrap |
| Initramfs assembly (`scripts/build-initramfs.sh`) | **not done** - needs the initramfs-ps4 base |
| Mesa build (`scripts/build-mesa.sh`) | **not done** - needs the PS4 patch set |

## Reporting a result

Run `ps4-hwprofile` on the console and attach its output. It prints the CPUID
family/model, the SDIO ids that identify the wireless chip, and the driver bound
to each device - so a report says which hardware it was, not which model the
console is supposed to be.
