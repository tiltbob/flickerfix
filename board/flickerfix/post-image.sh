#!/bin/sh
# Lay out the EFI binary and the results partition, then build the disk image.
set -eu
BOARD_DIR=$(dirname "$0")
VARIANT=${FLICKERFIX_VARIANT:-baseline}

# bzImage has the EFI stub, the initramfs and the command line built in.
cp "$BINARIES_DIR/bzImage" "$BINARIES_DIR/flickerfix.efi"

cat > "$BINARIES_DIR/results-README.txt" <<README
flickerfix test drive ($VARIANT kernel)

Boot the affected laptop from this drive (Secure Boot off). The test runs
by itself and powers the laptop off when it is done. Each run adds one
directory under results/ on this partition. Send that directory back.

Edit flickerfix.conf to change how many cycles are run.
README

cat > "$BINARIES_DIR/flickerfix.conf" <<CONF
# Settings for the test run. Lines are shell assignments.
DPMS_CYCLES=150        # screen off/on cycles
SUSPEND_CYCLES=15      # suspend/resume cycles (0 to skip)
MEASURE_SECS=3         # how long link errors are counted after each cycle
IDLE_SECS=2            # idle time before the panel is turned off (lets PSR engage)
POWEROFF_SECS=30       # wait before powering off at the end (0 = stay on)
CONF

exec support/scripts/genimage.sh -c "$BOARD_DIR/genimage.cfg"
