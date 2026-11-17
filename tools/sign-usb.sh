#!/bin/sh
# Sign the EFI binary on an already written flickerfix USB drive with the
# local sbctl Secure Boot keys, so the drive boots with Secure Boot on.
#
# Not part of the build. Run it by hand, as root, on the machine whose sbctl
# keys are enrolled in the laptop's firmware, after writing the image:
#
#   sudo tools/sign-usb.sh            # finds the drive by its FFBOOT label
#   sudo tools/sign-usb.sh /dev/sdX   # or name the drive (or its partition 1)
#
# The key database of sbctl is not changed (no "sbctl sign -s").
set -eu

die() { echo "sign-usb: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sbctl keys and mount need it)"
command -v sbctl >/dev/null || die "sbctl not found"

label_of() { lsblk -dno LABEL "$1" 2>/dev/null; }

if [ $# -ge 1 ]; then
	[ -b "$1" ] || die "$1 is not a block device"
	PART=
	for p in "$1" "$1"1 "$1"p1; do
		if [ -b "$p" ] && [ "$(label_of "$p")" = FFBOOT ]; then PART=$p; break; fi
	done
	[ -n "$PART" ] || die "no partition labelled FFBOOT on $1; not a flickerfix drive?"
else
	set -- $(lsblk -lnpo NAME,LABEL | awk '$2 == "FFBOOT" {print $1}')
	[ $# -ge 1 ] || die "no partition labelled FFBOOT found; is the drive plugged in?"
	[ $# -eq 1 ] || die "more than one FFBOOT partition ($*); name the drive"
	PART=$1
fi

MNT=$(mktemp -d)
MOUNTED=
cleanup() {
	[ -n "$MOUNTED" ] && umount "$MNT"
	rmdir "$MNT"
}
trap cleanup EXIT

mount -t vfat "$PART" "$MNT"
MOUNTED=1
EFI="$MNT/EFI/BOOT/BOOTX64.EFI"
[ -f "$EFI" ] || die "EFI/BOOT/BOOTX64.EFI not found on $PART"

echo "Signing EFI/BOOT/BOOTX64.EFI on $PART"
# Signs in place; says so and does nothing if it is already signed.
sbctl sign "$EFI"
sync
sbctl verify "$EFI" || die "signature check failed"

umount "$MNT"
MOUNTED=
echo "Done. $PART is unmounted; the drive can be removed."
