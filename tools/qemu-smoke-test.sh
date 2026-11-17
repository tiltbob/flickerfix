#!/bin/sh
# Boot a flickerfix image in QEMU (UEFI, image attached as a USB drive) and
# print what the test wrote to the results partition.
#
# QEMU has no eDP panel, so the expected verdict is NO_PANEL. This only
# proves that the image boots, finds its results partition, writes a run
# directory and powers off.
#
# Needs: qemu-system-x86_64, OVMF, sfdisk, mtools.
set -eu
IMG=${1:?usage: $0 <flickerfix-*.img>}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
TIMEOUT=${TIMEOUT:-1800}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp --sparse=always "$IMG" "$WORK/disk.img"
cp "$OVMF_VARS" "$WORK/vars.fd"

ACCEL=tcg
[ -w /dev/kvm ] && ACCEL=kvm

# The run ends when the guest powers itself off.
timeout "$TIMEOUT" qemu-system-x86_64 \
	-machine q35,accel=$ACCEL -cpu max -m 2G -smp 2 \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$WORK/vars.fd" \
	-device qemu-xhci \
	-drive if=none,id=stick,format=raw,file="$WORK/disk.img" \
	-device usb-storage,drive=stick,bootindex=0 \
	-display none -serial null -monitor none ${QEMU_EXTRA:-} ||
	{ echo "FAIL: QEMU did not power off within ${TIMEOUT}s (exit $?)"; exit 1; }

# Second partition = FFRESULTS.
START=$(sfdisk -d "$WORK/disk.img" | awk -F'[=,]' '/img2/ {gsub(/ /, "", $2); print $2}')
OFF=$((START * 512))
mkdir "$WORK/out"
mcopy -s -n -i "$WORK/disk.img@@$OFF" ::results "$WORK/out/" 2>/dev/null ||
	{ echo "FAIL: no results directory on the FFRESULTS partition"; exit 1; }

for run in "$WORK"/out/results/*/; do
	echo "== ${run#"$WORK"/out/}"
	ls "$run"
	echo "-- info.txt";    cat "$run/info.txt"
	echo "-- summary.txt"; cat "$run/summary.txt"
done
if [ -n "${KEEP:-}" ]; then
	rm -rf "$KEEP"; cp -r "$WORK/out/results" "$KEEP"; echo "Results copied to $KEEP"
fi
grep -q '^verdict:' "$WORK"/out/results/*/summary.txt && echo "PASS: image booted and wrote results"
