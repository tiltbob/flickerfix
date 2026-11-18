# flickerfix

Buildroot external tree that builds a self-contained EFI test binary for an
amdgpu eDP link-training fix (see `patches/linux/`).

The Samsung OLED panel `SDC 0x41B3` in the HP ZBook Ultra G1a 14 sometimes
finishes link training at pre-emphasis level 1 instead of 2. The link then
runs with symbol errors and the screen flickers until the next training.
The patch makes the driver refuse to train this panel below level 2.

## Status

**The test works on the laptop, but it has not reproduced the bug yet.**

First hardware run (baseline, PSR disabled, booted from a USB image): 150
screen off/on cycles and 15 suspend/resume cycles, 165 link trainings,
every one ended at pre-emphasis level 2 with no link errors. The installed
system gives a bad training about once in 30. So that run says nothing
about the fix.

It did show that the harness works on the hardware: amdgpu loads its
firmware from the built-in initramfs, blanking the framebuffer console
retrains the eDP link, the DPCD reads over `/dev/drm_dp_aux*` work, and
`rtcwake` suspend and resume returns.

Since then PSR is left enabled, as on the installed system, and the USB
image is gone: the EFI binary is installed on the machine's own EFI system
partition and saves its results there.

Verified for the current design: CI builds both variants; a binary boots in
QEMU under OVMF from an emulated NVMe drive, saves a result tarball to the
EFI system partition and reboots (`tools/qemu-smoke-test.sh`, verdict
`NO_PANEL`); `tools/flickerfix.sh` against a fake partition with stand-ins
for sbctl and efibootmgr.

Not verified, needs the laptop: finding and writing the real EFI system
partition on NVMe, signing with real sbctl keys, creating the boot entry,
and booting through BootNext.

## Build

```
make            # both variants
make patched    # kernel with the fix    -> flickerfix-patched.efi
make baseline   # kernel without the fix -> flickerfix-baseline.efi
```

The wrapper clones Buildroot 2026.08.1 into `buildroot/` and builds into
`output/`. The kernel is mainline 7.4-rc3, the tree the patch was written
against. Downloads are kept in `dl/` and the compiler cache in `ccache/`.

Both variants share one userland: the toolchain, BusyBox, the firmware and
the root filesystem are built once, and only the kernel is built per
variant. The variant is named in the kernel release (`uname -r` ends in
`-patched` or `-baseline`), not in the root filesystem.

`.github/workflows/build.yml` builds both variants on GitHub Actions. Builds
of `main` are published as the `latest` release, which can be downloaded
without a GitHub login.

## Use

On the affected laptop, from a checkout of this repository:

```
tools/flickerfix.sh run baseline    # or: run patched
```

This downloads the binary from the latest release, copies it to
`EFI/flickerfix/` on the EFI system partition, signs it there with the local
sbctl keys, creates a boot entry that is not in the boot order, sets the
firmware's BootNext to it and reboots. The test runs by itself (about 30
minutes) and reboots back into the installed system. Then:

```
tools/flickerfix.sh results         # copies the result tarballs here
tools/flickerfix.sh remove          # deletes binaries, results, boot entries
```

Each run leaves one `flickerfix-run-NNN-<variant>.tar.gz`. It contains the
EDID and machine details, so do not post it publicly.

`-n` installs unsigned (Secure Boot must be off), `-f <file>` installs a
local build. An optional `EFI/flickerfix/flickerfix.conf` on the partition
sets the cycle counts (`DPMS_CYCLES`, `SUSPEND_CYCLES`, `MEASURE_SECS`,
`IDLE_SECS`) and what happens at the end (`END_ACTION=reboot|poweroff|stay`).

## What the binary is

One EFI binary: the kernel (EFI stub) with the command line and the
initramfs built in. The initramfs is the whole test system (BusyBox, amdgpu
firmware, the test script). It is about 55 MB and unsigned as built.

It finds the partition it was installed on by looking for a FAT partition
with an `EFI/flickerfix` directory. Results are collected in RAM; the
partition is mounted only for the moment a tarball is written (at the
start, every 10 cycles, before each suspend and at the end), so a hang or a
forced power-off finds it unmounted. No other partition is mounted.

## What the test does

`board/flickerfix/rootfs-overlay/usr/sbin/flickerfix-test` turns the panel
off and on (framebuffer blank, then suspend/resume). Each cycle makes the
driver retrain the eDP link. After each retrain it records:

- the voltage swing and pre-emphasis the training ended on
  (`phy_settings` in debugfs),
- the panel's symbol error counters (DPCD 0x210-0x217 over AUX),
- whether the kernel log shows the "early sync" signature of a bad training,
- the PSR state before the power-off and after the retrain.

`summary.txt` gives a verdict: GOOD if every training ended at level 2 or
above with no link errors, BAD otherwise.

## Layout

- `configs/flickerfix_defconfig` - Buildroot configuration
- `board/flickerfix/` - kernel and BusyBox config fragments, build hooks,
  root filesystem overlay with the test script
- `patches/linux/` - the kernel fix (applied in the `patched` variant only)
- `tools/` - `flickerfix.sh` (install, run, fetch results) and
  `qemu-smoke-test.sh` for the binary; scripts used on the installed system
  to find the bug (`flicker-watch-install.sh` collector service,
  `flicker-test.sh`)
