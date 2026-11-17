# flickerfix

Buildroot external tree that builds a bootable USB test image for an amdgpu
eDP link-training fix (see `patches/linux/`).

The Samsung OLED panel `SDC 0x41B3` in the HP ZBook Ultra G1a 14 sometimes
finishes link training at pre-emphasis level 1 instead of 2. The link then
runs with symbol errors and the screen flickers until the next training.
The patch makes the driver refuse to train this panel below level 2.

## Status

**Work in progress. The image has never been built or booted.** Only this
much is verified: Buildroot 2026.08.1 accepts `flickerfix_defconfig`, and the
shell scripts pass a syntax check.

## Build

```
make            # kernel with the fix    -> flickerfix-patched.img
make baseline   # kernel without the fix -> flickerfix-baseline.img
make both
```

The wrapper clones Buildroot 2026.08.1 into `buildroot/` and builds into
`output/<variant>/`. The kernel is mainline 7.4-rc3, the tree the patch was
written against.

## Use

1. Write the image to a USB drive of 4 GB or more:
   `dd if=flickerfix-patched.img of=/dev/sdX bs=4M conv=fsync`
2. Turn Secure Boot off on the laptop and boot from the drive.
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
- `tools/` - scripts used on the installed system to find the bug
  (`flicker-watch-install.sh` collector service, `flicker-test.sh`)
