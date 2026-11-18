#!/bin/sh
# Install a flickerfix EFI binary on this machine's EFI system partition,
# boot it once, and fetch the results afterwards.
#
#   tools/flickerfix.sh run baseline      install, sign, boot it once now
#   tools/flickerfix.sh run patched
#   tools/flickerfix.sh results           copy the result tarballs here
#   tools/flickerfix.sh remove            delete everything again
#
#   tools/flickerfix.sh install <variant> install and sign, do not reboot
#
# Options (after the command):
#   -f <file>   install this local .efi instead of downloading the release
#   -e <dir>    mount point of the EFI system partition (default: detected)
#   -n          do not sign (Secure Boot must be off then)
#   -y          do not ask before rebooting or removing
#
# The binary goes to EFI/flickerfix/flickerfix-<variant>.efi and is signed
# in place with the local sbctl keys. "run" sets the firmware's BootNext,
# so only the next boot starts the test; the boot order is not changed.
# The test saves EFI/flickerfix/results/<run>.tar.gz and reboots.
#
# Run it as your normal user; it calls sudo where it has to.
# Needs: curl, sha256sum, sbctl, efibootmgr, findmnt, lsblk, sudo.
set -eu

REPO=${FLICKERFIX_REPO:-tiltbob/flickerfix}
RELEASE_URL=https://github.com/$REPO/releases/download/latest
DIR=EFI/flickerfix

die() { echo "flickerfix: $*" >&2; exit 1; }
usage() { sed -n '2,24s/^# \{0,1\}//p' "$0"; exit "${1:-1}"; }

[ $# -ge 1 ] || usage
CMD=$1; shift
VARIANT=
case $CMD in
run|install)
	[ $# -ge 1 ] || usage
	VARIANT=$1; shift
	case $VARIANT in
	patched|baseline) ;;
	*) die "variant must be 'patched' or 'baseline', not '$VARIANT'" ;;
	esac ;;
results|remove) ;;
-h|--help|help) usage 0 ;;
*) usage ;;
esac

FILE= ESP=${FLICKERFIX_ESP:-} SIGN=1 YES=
while getopts f:e:nyh opt; do
	case $opt in
	f) FILE=$OPTARG ;;
	e) ESP=$OPTARG ;;
	n) SIGN= ;;
	y) YES=1 ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done

SUDO=sudo
[ "$(id -u)" -eq 0 ] && SUDO=

confirm() {	# confirm <question>
	[ -n "$YES" ] && return 0
	printf '%s Type "yes" to continue: ' "$1"
	read -r answer
	[ "$answer" = yes ] || die "aborted"
}

# --- Find the EFI system partition -----------------------------------------

if [ -z "$ESP" ]; then
	ESP=$(bootctl --print-esp-path 2>/dev/null || true)
fi
if [ -z "$ESP" ]; then
	for d in /efi /boot/efi /boot; do
		if $SUDO test -d "$d/EFI" && [ "$(findmnt -no FSTYPE --target "$d")" = vfat ]; then
			ESP=$d
			break
		fi
	done
fi
[ -n "$ESP" ] || die "EFI system partition not found; give its mount point with -e"
[ "$(findmnt -no FSTYPE --target "$ESP")" = vfat ] ||
	die "$ESP is not on a FAT filesystem; give the EFI system partition with -e"
$SUDO test -d "$ESP/EFI" || die "$ESP has no EFI directory; is it the EFI system partition?"

# Boot entry number (4 hex digits) of a variant, empty if there is none.
entry_of() {
	efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\}[[:space:]]\{1,\}flickerfix-$1\([[:space:]].*\)\{0,1\}\$/\1/p" | head -n1
}

# --- results ---------------------------------------------------------------

if [ "$CMD" = results ]; then
	found=
	for f in $($SUDO sh -c "ls '$ESP/$DIR/results/'*.tar.gz 2>/dev/null" || true); do
		name=${f##*/}
		$SUDO cp "$f" "./$name"
		$SUDO chown "$(id -u):$(id -g)" "./$name"
		echo "$PWD/$name"
		found=1
	done
	[ -n "$found" ] || die "no results in $ESP/$DIR/results"
	exit 0
fi

# --- remove ----------------------------------------------------------------

if [ "$CMD" = remove ]; then
	confirm "Delete $ESP/$DIR (binaries and results) and the flickerfix boot entries?"
	for v in patched baseline; do
		num=$(entry_of "$v")
		[ -n "$num" ] && $SUDO efibootmgr -q -b "$num" -B
	done
	$SUDO rm -rf "${ESP:?}/$DIR"
	echo "Removed."
	exit 0
fi

# --- install ---------------------------------------------------------------

NAME=flickerfix-$VARIANT.efi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$FILE" ]; then
	[ -f "$FILE" ] || die "$FILE not found"
	SRC=$FILE
	SOURCE=$FILE
else
	SRC="$WORK/$NAME"
	echo "Downloading $NAME from the latest release of $REPO"
	curl -fL --retry 3 -o "$SRC" "$RELEASE_URL/$NAME" ||
		die "download failed: $RELEASE_URL/$NAME"
	curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" ||
		die "download failed: $RELEASE_URL/SHA256SUMS"
	(cd "$WORK" && grep " $NAME\$" SHA256SUMS | sha256sum -c --quiet -) ||
		die "checksum mismatch for $NAME"
	COMMIT=$(curl -fsSL --retry 3 "$RELEASE_URL/COMMIT" 2>/dev/null || true)
	SOURCE="$REPO latest release${COMMIT:+ (commit $COMMIT)}"
fi

if [ -n "$SIGN" ]; then
	command -v sbctl >/dev/null || die "sbctl not found (use -n to install unsigned)"
fi

need_kb=$(( $(stat -c %s "$SRC") / 1024 + 20480 ))	# binary + 20 MB for results
free_kb=$(df -Pk "$ESP" | awk 'NR == 2 {print $4}')
[ "$free_kb" -ge "$need_kb" ] ||
	die "not enough space on $ESP: ${free_kb} kB free, ${need_kb} kB needed"

$SUDO mkdir -p "$ESP/$DIR/results"
$SUDO cp "$SRC" "$ESP/$DIR/$NAME"
if [ -n "$SIGN" ]; then
	# Signs in place; the file is not added to sbctl's database.
	$SUDO sbctl sign "$ESP/$DIR/$NAME"
	$SUDO sbctl verify "$ESP/$DIR/$NAME" >/dev/null || die "signature check failed"
fi
sync
echo "Installed $SOURCE as $ESP/$DIR/$NAME${SIGN:+ (signed)}"

# A boot entry that is not in the boot order: it only ever runs through
# BootNext.
NUM=$(entry_of "$VARIANT")
if [ -z "$NUM" ]; then
	PART_DEV=$(findmnt -no SOURCE --target "$ESP")
	PART_NUM=$(cat "/sys/class/block/${PART_DEV#/dev/}/partition")
	DISK=/dev/$(lsblk -dno PKNAME "$PART_DEV")
	$SUDO efibootmgr -q -C -d "$DISK" -p "$PART_NUM" \
		-L "flickerfix-$VARIANT" -l "\\EFI\\flickerfix\\$NAME"
	NUM=$(entry_of "$VARIANT")
	[ -n "$NUM" ] || die "could not create the boot entry"
fi
echo "Boot entry: Boot$NUM flickerfix-$VARIANT"

[ "$CMD" = run ] || exit 0

confirm "Reboot into the $VARIANT test now? It takes about 30 minutes and reboots back when done."
$SUDO efibootmgr -q -n "$NUM"
$SUDO systemctl reboot
