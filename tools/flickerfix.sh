#!/bin/sh
# Install the flickerfix EFI binaries on this machine's EFI system partition,
# reboot into one of them, and fetch the results afterwards.
#
#   tools/flickerfix.sh install           download both binaries, sign them
#   tools/flickerfix.sh boot baseline     reboot into the baseline test, once
#   tools/flickerfix.sh boot patched      reboot into the patched test, once
#   tools/flickerfix.sh results           copy the result tarballs here
#   tools/flickerfix.sh status            show what is installed
#   tools/flickerfix.sh remove            delete everything again
#
# Options (after the command):
#   -f <dir>    install flickerfix-{baseline,patched}.efi from this directory
#               instead of downloading the latest release
#   -e <dir>    mount point of the EFI system partition (default: detected)
#   -n          do not sign (Secure Boot must be off then)
#   -y          do not ask before rebooting or removing
#
# "install" puts the binaries in EFI/flickerfix/, signs them in place with
# the local sbctl keys and creates one boot entry each, outside the boot
# order. "boot" sets the firmware's BootNext to one of them and does a
# normal, clean reboot: only that one boot starts the test. The test saves
# EFI/flickerfix/results/<run>.tar.gz and reboots back by itself.
#
# Run it as your normal user; it calls sudo where it has to.
# Needs: curl, sha256sum, sbctl, efibootmgr, findmnt, lsblk, sudo.
set -eu

REPO=${FLICKERFIX_REPO:-tiltbob/flickerfix}
RELEASE_URL=https://github.com/$REPO/releases/download/latest
DIR=EFI/flickerfix

die() { echo "flickerfix: $*" >&2; exit 1; }
usage() { sed -n '2,26s/^# \{0,1\}//p' "$0"; exit "${1:-1}"; }

[ $# -ge 1 ] || usage
CMD=$1; shift
VARIANT=
case $CMD in
boot)
	[ $# -ge 1 ] || usage
	VARIANT=$1; shift
	case $VARIANT in
	patched|baseline) ;;
	*) die "variant must be 'patched' or 'baseline', not '$VARIANT'" ;;
	esac ;;
install|results|status|remove) ;;
-h|--help|help) usage 0 ;;
*) usage ;;
esac

SRC_DIR= ESP=${FLICKERFIX_ESP:-} SIGN=1 YES=
while getopts f:e:nyh opt; do
	case $opt in
	f) SRC_DIR=$OPTARG ;;
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

# --- status ----------------------------------------------------------------

if [ "$CMD" = status ]; then
	echo "EFI system partition: $ESP"
	for v in baseline patched; do
		f="$ESP/$DIR/flickerfix-$v.efi"
		num=$(entry_of "$v")
		if $SUDO test -f "$f"; then
			printf '%-9s installed, boot entry %s\n' "$v:" "${num:+Boot}${num:-missing}"
		else
			printf '%-9s not installed\n' "$v:"
		fi
	done
	echo "results:"
	$SUDO sh -c "ls '$ESP/$DIR/results/' 2>/dev/null" | sed 's/^/  /'
	exit 0
fi

# --- boot ------------------------------------------------------------------

if [ "$CMD" = boot ]; then
	$SUDO test -f "$ESP/$DIR/flickerfix-$VARIANT.efi" ||
		die "flickerfix-$VARIANT.efi is not installed; run '$0 install' first"
	NUM=$(entry_of "$VARIANT")
	[ -n "$NUM" ] || die "no boot entry for flickerfix-$VARIANT; run '$0 install' again"
	confirm "Reboot into the $VARIANT test now? It takes about 35 minutes and reboots back when done."
	# One-time: the firmware clears BootNext when it uses it.
	$SUDO efibootmgr -q -n "$NUM"
	echo "Rebooting into Boot$NUM flickerfix-$VARIANT."
	$SUDO systemctl reboot
	exit 0
fi

# --- install ---------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$SIGN" ]; then
	command -v sbctl >/dev/null || die "sbctl not found (use -n to install unsigned)"
fi

if [ -n "$SRC_DIR" ]; then
	for v in baseline patched; do
		[ -f "$SRC_DIR/flickerfix-$v.efi" ] || die "$SRC_DIR/flickerfix-$v.efi not found"
	done
	SOURCE=$SRC_DIR
else
	SRC_DIR=$WORK
	echo "Downloading the latest release of $REPO"
	curl -fsSL --retry 3 -o "$WORK/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" ||
		die "download failed: $RELEASE_URL/SHA256SUMS"
	for v in baseline patched; do
		curl -fL --retry 3 -o "$WORK/flickerfix-$v.efi" "$RELEASE_URL/flickerfix-$v.efi" ||
			die "download failed: $RELEASE_URL/flickerfix-$v.efi"
		(cd "$WORK" && grep " flickerfix-$v.efi\$" SHA256SUMS | sha256sum -c --quiet -) ||
			die "checksum mismatch for flickerfix-$v.efi"
	done
	COMMIT=$(curl -fsSL --retry 3 "$RELEASE_URL/COMMIT" 2>/dev/null || true)
	SOURCE="$REPO latest release${COMMIT:+ (commit $COMMIT)}"
fi

# Both binaries, minus what is already there, plus 20 MB for results.
need_kb=20480
for v in baseline patched; do
	need_kb=$((need_kb + $(stat -c %s "$SRC_DIR/flickerfix-$v.efi") / 1024))
	old=$($SUDO stat -c %s "$ESP/$DIR/flickerfix-$v.efi" 2>/dev/null || echo 0)
	need_kb=$((need_kb - old / 1024))
done
free_kb=$(df -Pk "$ESP" | awk 'NR == 2 {print $4}')
[ "$free_kb" -ge "$need_kb" ] ||
	die "not enough space on $ESP: ${free_kb} kB free, ${need_kb} kB needed"

PART_DEV=$(findmnt -no SOURCE --target "$ESP")
$SUDO mkdir -p "$ESP/$DIR/results"
for v in baseline patched; do
	NAME=flickerfix-$v.efi
	$SUDO cp "$SRC_DIR/$NAME" "$ESP/$DIR/$NAME"
	if [ -n "$SIGN" ]; then
		# Signs in place; the file is not added to sbctl's database.
		$SUDO sbctl sign "$ESP/$DIR/$NAME"
		$SUDO sbctl verify "$ESP/$DIR/$NAME" >/dev/null || die "signature check failed for $NAME"
	fi

	# A boot entry that is not in the boot order: it only ever runs
	# through BootNext.
	NUM=$(entry_of "$v")
	if [ -z "$NUM" ]; then
		PART_NUM=$(lsblk -dno PARTN "$PART_DEV" 2>/dev/null | tr -d ' ')
		[ -n "$PART_NUM" ] || PART_NUM=$(cat "/sys/class/block/${PART_DEV#/dev/}/partition")
		DISK=/dev/$(lsblk -dno PKNAME "$PART_DEV")
		$SUDO efibootmgr -q -C -d "$DISK" -p "$PART_NUM" \
			-L "flickerfix-$v" -l "\\EFI\\flickerfix\\$NAME"
		NUM=$(entry_of "$v")
		[ -n "$NUM" ] || die "could not create the boot entry for $NAME"
	fi
	echo "Installed $ESP/$DIR/$NAME${SIGN:+ (signed)}, boot entry Boot$NUM"
done
sync
echo "Source: $SOURCE"
echo "Start a test with: $0 boot baseline   (or: boot patched)"
