#!/bin/sh
# Download a flickerfix image built by GitHub Actions and write it to a USB
# drive.
#
#   tools/flash-usb.sh patched [/dev/sdX]
#   tools/flash-usb.sh baseline [/dev/sdX]
#
# Without a device, the drive named in the file .usb-device at the top of
# this repository is used (one line, best a /dev/disk/by-id/usb-... path,
# which always means the same physical drive). That file is not committed.
#
# Options (before the variant):
#   -r <run-id>   take the artifact of this GitHub Actions run instead of
#                 the latest release (needs gh, logged in)
#   -f <file>     write this local image (.img or .img.zst), no download
#   -s            sign the drive afterwards with tools/sign-usb.sh (sbctl)
#   -y            do not ask before writing
#
# By default the image comes from the "latest" release of the repository,
# which GitHub Actions refreshes on every push to main. That download
# needs no GitHub login.
#
# Run it as your normal user; only the write (and the signing) go through
# sudo. Needs: curl, sha256sum, zstd, lsblk, sudo.
set -eu

REPO=${FLICKERFIX_REPO:-tiltbob/flickerfix}
RELEASE_URL=https://github.com/$REPO/releases/download/latest
RUN= FILE= SIGN= YES=

die() { echo "flash-usb: $*" >&2; exit 1; }
usage() { sed -n '2,24s/^# \{0,1\}//p' "$0"; exit "${1:-1}"; }

while getopts r:f:syh opt; do
	case $opt in
	r) RUN=$OPTARG ;;
	f) FILE=$OPTARG ;;
	s) SIGN=1 ;;
	y) YES=1 ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || [ $# -eq 2 ] || usage
VARIANT=$1
DEV=${2:-}
DEV_FILE=$(dirname "$0")/../.usb-device
if [ -z "$DEV" ]; then
	[ -f "$DEV_FILE" ] || die "no device given and no .usb-device file in the repository"
	DEV=$(sed -n '/^[^#]/{p;q}' "$DEV_FILE")
	[ -n "$DEV" ] || die ".usb-device is empty"
	[ -e "$DEV" ] || die "the drive from .usb-device is not plugged in: $DEV"
fi

case $VARIANT in
patched|baseline) ;;
*) die "variant must be 'patched' or 'baseline', not '$VARIANT'" ;;
esac

# --- Check the target before downloading anything -------------------------

[ -b "$DEV" ] || die "$DEV is not a block device"
DEV=$(readlink -f "$DEV")	# /dev/disk/by-id/... -> /dev/sdX
[ "$(lsblk -dno TYPE "$DEV")" = disk ] ||
	die "$DEV is not a whole disk (give the drive, not a partition)"
TRAN=$(lsblk -dno TRAN "$DEV")
[ "$TRAN" = usb ] ||
	die "$DEV is not a USB drive (transport: ${TRAN:-unknown}); refusing to write to it"
if lsblk -nro MOUNTPOINTS "$DEV" | grep -q .; then
	die "$DEV has mounted partitions; unmount them first"
fi
DEV_BYTES=$(lsblk -dnbo SIZE "$DEV")

# --- Get the image ---------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$FILE" ]; then
	[ -f "$FILE" ] || die "$FILE not found"
	IMG=$FILE
	SOURCE=$FILE
elif [ -n "$RUN" ]; then
	command -v gh >/dev/null || die "gh not found (needed for -r)"
	SOURCE="$REPO run $RUN"
	echo "Downloading flickerfix-$VARIANT from $SOURCE"
	gh run download "$RUN" -R "$REPO" -n "flickerfix-$VARIANT" -D "$WORK"
	IMG="$WORK/flickerfix-$VARIANT.img.zst"
	[ -f "$IMG" ] || die "the artifact did not contain flickerfix-$VARIANT.img.zst"
else
	command -v curl >/dev/null || die "curl not found"
	NAME=flickerfix-$VARIANT.img.zst
	IMG="$WORK/$NAME"
	echo "Downloading $NAME from the latest release of $REPO"
	curl -fL --retry 3 -o "$IMG" "$RELEASE_URL/$NAME" ||
		die "download failed: $RELEASE_URL/$NAME"
	curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" ||
		die "download failed: $RELEASE_URL/SHA256SUMS"
	(cd "$WORK" && grep " $NAME\$" SHA256SUMS | sha256sum -c --quiet -) ||
		die "checksum mismatch for $NAME"
	COMMIT=$(curl -fsSL --retry 3 "$RELEASE_URL/COMMIT" 2>/dev/null || true)
	SOURCE="$REPO latest release${COMMIT:+ (commit $COMMIT)}"
fi

case $IMG in
*.zst)
	command -v zstd >/dev/null || die "zstd not found"
	zstd -t -q "$IMG" || die "$IMG is damaged"
	IMG_BYTES=$(zstd -l -v "$IMG" 2>/dev/null | awk '/Decompressed Size/ {gsub(/[()]/, ""); print $(NF-1)}')
	;;
*)
	IMG_BYTES=$(stat -c %s "$IMG")
	;;
esac
case ${IMG_BYTES:-} in
''|*[!0-9]*) IMG_BYTES= ;;	# size unknown; dd will fail if it does not fit
*) [ "$IMG_BYTES" -le "$DEV_BYTES" ] ||
	die "image ($IMG_BYTES bytes) does not fit on $DEV ($DEV_BYTES bytes)" ;;
esac

# --- Confirm and write -----------------------------------------------------

echo
echo "Image:  $SOURCE, $VARIANT${IMG_BYTES:+, $IMG_BYTES bytes}"
echo "Target: $DEV"
lsblk -o NAME,SIZE,TRAN,VENDOR,MODEL,LABEL "$DEV"
echo
if [ -z "$YES" ]; then
	printf 'Everything on %s will be erased. Type "yes" to continue: ' "$DEV"
	read -r answer
	[ "$answer" = yes ] || die "aborted"
fi

case $IMG in
*.zst) zstd -dc "$IMG" ;;
*) cat "$IMG" ;;
esac | sudo dd of="$DEV" bs=4M iflag=fullblock conv=fsync status=progress

# Make the kernel read the new partition table.
sudo blockdev --rereadpt "$DEV" 2>/dev/null || true
command -v udevadm >/dev/null && sudo udevadm settle || true

if [ -n "$SIGN" ]; then
	sudo "$(dirname "$0")/sign-usb.sh" "$DEV"
fi

echo
echo "Done: $VARIANT image written to $DEV. The drive can be removed."
