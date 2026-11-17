# flickerfix

Buildroot external tree that builds a bootable USB test image for an amdgpu
eDP link-training fix (see `patches/linux/`).

The Samsung OLED panel `SDC 0x41B3` in the HP ZBook Ultra G1a 14 sometimes
finishes link training at pre-emphasis level 1 instead of 2. The link then
runs with symbol errors and the screen flickers until the next training.
The patch makes the driver refuse to train this panel below level 2.

## Status

**The image works on the laptop, but it has not reproduced the bug yet.**

First hardware run (baseline image, PSR disabled): 150 screen off/on cycles
and 15 suspend/resume cycles, 165 link trainings, every one ended at
pre-emphasis level 2 with no link errors. The installed system gives a bad
training about once in 30. So that run says nothing about the fix.

It did show that the harness works on the hardware: amdgpu loads its
firmware from the built-in initramfs, blanking the framebuffer console
retrains the eDP link, the DPCD reads over `/dev/drm_dp_aux*` work, and
`rtcwake` suspend and resume returns.

The image now leaves PSR enabled, as the installed system does, and
records the PSR state around every power cycle. That version has not run
on the laptop yet.

Also verified: CI builds both variants; the released images boot in QEMU
under OVMF (`tools/qemu-smoke-test.sh`, verdict `NO_PANEL`).

Not verified: `tools/sign-usb.sh` and `tools/flash-usb.sh` were used for
the first run, but no report on them has been recorded here.

The EFI binary is about 55 MB. It is unsigned: turn Secure Boot off, or
sign it on the written drive with `sudo tools/sign-usb.sh` (sbctl).

## Build

```
make            # kernel with the fix    -> flickerfix-patched.img
make baseline   # kernel without the fix -> flickerfix-baseline.img
make both
```

The wrapper clones Buildroot 2026.08.1 into `buildroot/` and builds into
`output/<variant>/`. The kernel is mainline 7.4-rc3, the tree the patch was
written against.

Downloads are kept in `dl/` and the compiler cache in `ccache/`, both
shared by the two variants.

`.github/workflows/build.yml` builds both variants on GitHub Actions and
uploads each image as a zstd-compressed artifact. It caches `dl/` and
`ccache/` between runs. Builds of `main` are also published as the
`latest` release, which can be downloaded without a GitHub login.

## Use

1. Write the image to a USB drive of 4 GB or more. Either a local build:
   `dd if=flickerfix-patched.img of=/dev/sdX bs=4M conv=fsync`
   or the image from the latest release (asks before
   writing, refuses anything that is not a USB drive):
   `tools/flash-usb.sh patched /dev/sdX` (add `-s` to sign it as well).
   The device can be left out if a `.usb-device` file at the top of the
   repository names the drive (not committed).
2. Turn Secure Boot off on the laptop, or sign the drive with
   `sudo tools/sign-usb.sh`, and boot from the drive.
3. The test runs by itself and powers the laptop off when it is done.
4. Send back the `results/run-NNN-<variant>/` directory from the
   `FFRESULTS` partition of the drive.

`flickerfix.conf` on the `FFRESULTS` partition sets the number of cycles.

## What the image is

- One EFI binary, `EFI/BOOT/BOOTX64.EFI`: the kernel (EFI stub) with the
  command line and the initramfs built in. The initramfs is the whole test
  system (BusyBox, amdgpu firmware, the test script).
- A FAT32 partition labelled `FFRESULTS` that takes the results.

## What the test does

`board/flickerfix/rootfs-overlay/usr/sbin/flickerfix-test` turns the panel
off and on (framebuffer blank, then suspend/resume). Each cycle makes the
driver retrain the eDP link. After each retrain it records:

- the voltage swing and pre-emphasis the training ended on
  (`phy_settings` in debugfs),
- the panel's symbol error counters (DPCD 0x210-0x217 over AUX),
- whether the kernel log shows the "early sync" signature of a bad training.

`summary.txt` gives a verdict: GOOD if every training ended at level 2 or
above with no link errors, BAD otherwise. The baseline image is expected to
come out BAD about once in 30 cycles.

## Layout

- `configs/flickerfix_defconfig` - Buildroot configuration
- `board/flickerfix/` - kernel and BusyBox config fragments, image layout,
  build hooks, root filesystem overlay with the test script
- `patches/linux/` - the kernel fix (applied in the `patched` variant only)
- `tools/` - `qemu-smoke-test.sh`, `flash-usb.sh` and `sign-usb.sh` for the
  image; scripts
  used on the installed system to find the bug (`flicker-watch-install.sh`
  collector service, `flicker-test.sh`)
