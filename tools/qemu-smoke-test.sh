#!/bin/sh
# Boot a flickerfix EFI binary in QEMU (UEFI, from an emulated NVMe drive)
# and print what the test saved to the EFI system partition.
#
# QEMU has no eDP panel, so the expected verdict is NO_PANEL. This only
# proves that the binary boots, finds the partition it was installed on,
# saves a result tarball there and reboots.
#
# Needs: qemu-system-x86_64, OVMF, sfdisk, mkfs.vfat, mtools.
set -eu
EFI=${1:?usage: $0 <flickerfix-*.efi>}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
TIMEOUT=${TIMEOUT:-1800}
ESP_MB=256

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A disk with one EFI system partition, laid out as tools/flickerfix.sh
# installs it. The copy under EFI/BOOT only makes the firmware start it.
mkfs.vfat -F 32 -C "$WORK/esp.img" $((ESP_MB * 1024)) >/dev/null
mmd -i "$WORK/esp.img" ::EFI ::EFI/BOOT ::EFI/flickerfix
mcopy -i "$WORK/esp.img" "$EFI" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$WORK/esp.img" "$EFI" "::EFI/flickerfix/$(basename "$EFI")"
truncate -s $((ESP_MB + 2))M "$WORK/disk.img"
printf 'label: gpt\nstart=2048, size=%d, type=U\n' $((ESP_MB * 2048)) |
	sfdisk -q "$WORK/disk.img"
dd if="$WORK/esp.img" of="$WORK/disk.img" bs=1M seek=1 conv=notrunc status=none
cp "$OVMF_VARS" "$WORK/vars.fd"

ACCEL=tcg
[ -w /dev/kvm ] && ACCEL=kvm

# The test reboots when it is done; -no-reboot turns that into an exit.
timeout "$TIMEOUT" qemu-system-x86_64 \
	-machine q35,accel=$ACCEL -cpu max -m 2G -smp 2 -no-reboot \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$WORK/vars.fd" \
	-drive if=none,id=disk,format=raw,file="$WORK/disk.img" \
	-device nvme,drive=disk,serial=flickerfix,bootindex=0 \
	-display none -serial null -monitor none ${QEMU_EXTRA:-} ||
	{ echo "FAIL: QEMU did not finish within ${TIMEOUT}s (exit $?)"; exit 1; }

dd if="$WORK/disk.img" of="$WORK/esp-after.img" bs=1M skip=1 count=$ESP_MB status=none
mkdir "$WORK/out"
mcopy -s -n -i "$WORK/esp-after.img" ::EFI/flickerfix/results "$WORK/out/" 2>/dev/null ||
	{ echo "FAIL: no EFI/flickerfix/results on the EFI system partition"; exit 1; }

status=1
for tarball in "$WORK"/out/results/*.tar.gz; do
	[ -f "$tarball" ] || { echo "FAIL: no result tarball"; exit 1; }
	echo "== ${tarball##*/}"
	tar -tzf "$tarball"
	echo "-- info.txt";    tar -xzOf "$tarball" --wildcards '*/info.txt'
	echo "-- summary.txt"; tar -xzOf "$tarball" --wildcards '*/summary.txt'
	tar -xzOf "$tarball" --wildcards '*/summary.txt' | grep -q '^verdict:' && status=0
	if [ -n "${KEEP:-}" ]; then
		mkdir -p "$KEEP" && cp "$tarball" "$KEEP/" && echo "Copied to $KEEP/${tarball##*/}"
	fi
done
[ $status -eq 0 ] && echo "PASS: binary booted and saved a result tarball"
exit $status
