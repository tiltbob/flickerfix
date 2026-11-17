#!/usr/bin/env bash
# Suspend/resume flicker test for amdgpu eDP panels.
#
# Usage:  sudo ./flicker-test.sh [cycles] [sleep-seconds]
#         defaults: 10 cycles, 30 seconds asleep per cycle
#
# Run it once per kernel command line setting. Everything is collected into
# ~/flicker-test/<setting>-<time>/ and packed into a .tar.gz at the end.

set -u

CYCLES=${1:-10}
SLEEP_SECS=${2:-30}
SETTLE_SECS=8

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi

RUN_USER=${SUDO_USER:-root}
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)

# --- locate the panel ------------------------------------------------------

EDP_DBG=$(ls -d /sys/kernel/debug/dri/*/eDP-* 2>/dev/null | head -n1)
if [ -z "$EDP_DBG" ]; then
	echo "No eDP connector found under /sys/kernel/debug/dri." >&2
	exit 1
fi
DRI_DBG=$(dirname "$EDP_DBG")
EDP_NAME=$(basename "$EDP_DBG")
EDP_SYS=$(ls -d /sys/class/drm/card*-"$EDP_NAME" 2>/dev/null | head -n1)

MASK=$(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null || echo unknown)
LABEL="mask-${MASK}"
OUT="$RUN_HOME/flicker-test/${LABEL}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
RESULTS="$OUT/results.txt"

# --- helpers ---------------------------------------------------------------

dump() {	# dump <file>...  : print each readable file with a header
	local f
	for f in "$@"; do
		[ -e "$f" ] || continue
		echo "== $f"
		cat "$f" 2>&1
		echo
	done
}

snapshot() {	# snapshot <name>
	{
		date '+%F %T'
		dump "$EDP_DBG"/psr_capability "$EDP_DBG"/psr_state \
		     "$EDP_DBG"/replay_capability "$EDP_DBG"/replay_state \
		     "$EDP_DBG"/vrr_range "$EDP_DBG"/link_settings \
		     "$EDP_DBG"/dsc_clock_en \
		     "$DRI_DBG"/amdgpu_dm_capabilities \
		     "$DRI_DBG"/amdgpu_dm_ips_status \
		     "$DRI_DBG"/state \
		     /sys/class/backlight/*/brightness \
		     /sys/class/backlight/*/actual_brightness \
		     /sys/class/power_supply/A*/online \
		     /sys/firmware/acpi/platform_profile \
		     /sys/power/suspend_stats/last_hw_sleep \
		     /sys/power/suspend_stats/success \
		     /sys/power/suspend_stats/fail \
		     /sys/kernel/debug/amd_pmc/s0ix_stats
	} > "$OUT/$1.txt" 2>&1
}

kmark() { echo "flicker-test: $*" > /dev/kmsg; }

ask() {		# ask <prompt>  : read one line from the terminal
	local reply
	read -r -p "$1 " reply < /dev/tty
	echo "$reply"
}

OLD_DRM_DEBUG=$(cat /sys/module/drm/parameters/debug)

finish() {
	echo "$OLD_DRM_DEBUG" > /sys/module/drm/parameters/debug
	journalctl -k -b --no-pager > "$OUT/kernel.log" 2>&1 || dmesg > "$OUT/kernel.log"
	{
		echo
		echo "cycles run: $DONE   flicker: $HITS"
	} >> "$RESULTS"
	tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
	chown -R "$RUN_USER": "$RUN_HOME/flicker-test"
	echo
	echo "Cycles run: $DONE, flicker seen: $HITS"
	echo "Send this file: $OUT.tar.gz"
}

DONE=0
HITS=0
trap finish EXIT
trap 'exit 130' INT

# --- baseline --------------------------------------------------------------

{
	echo "label:        $LABEL"
	echo "date:         $(date '+%F %T')"
	echo "kernel:       $(uname -r)"
	echo "cmdline:      $(cat /proc/cmdline)"
	echo "dcdebugmask:  $MASK"
	echo "mem_sleep:    $(cat /sys/power/mem_sleep)"
	echo "connector:    $EDP_NAME ($EDP_DBG)"
	echo "cycles:       $CYCLES x ${SLEEP_SECS}s"
	echo
} > "$RESULTS"

[ -n "$EDP_SYS" ] && cp "$EDP_SYS/edid" "$OUT/edid.bin" 2>/dev/null
snapshot 00-baseline

cat <<EOF
Testing with dcdebugmask=$MASK, $CYCLES cycles of ${SLEEP_SECS}s.
Output: $OUT

Before starting:
  - close anything that animates (video, games); leave a plain desktop
  - do not change display settings until the script asks you to
  - stay on the same power source (AC or battery) for the whole run

EOF
ask "Press Enter to start." > /dev/null

echo 0x106 > /sys/module/drm/parameters/debug

# --- cycles ----------------------------------------------------------------

for i in $(seq 1 "$CYCLES"); do
	n=$(printf '%02d' "$i")
	echo
	echo "--- cycle $i/$CYCLES: suspending for ${SLEEP_SECS}s"
	kmark "cycle $i suspend"
	if ! rtcwake -m mem -s "$SLEEP_SECS" > /dev/null; then
		echo "cycle $i: rtcwake failed" | tee -a "$RESULTS"
		break
	fi
	kmark "cycle $i resumed"
	DONE=$i
	sleep "$SETTLE_SECS"
	snapshot "$n-resumed"

	echo "Keep the screen still for 5 seconds, then move the mouse around."
	ans=$(ask "Flicker? [y]es / [n]o / [q]uit:")
	case "$ans" in
	y*|Y*)
		HITS=$((HITS + 1))
		kmark "cycle $i FLICKER reported"
		snapshot "$n-flicker"
		still=$(ask "  Does it flicker while the screen is completely still? [y/n]:")
		moving=$(ask "  Does it flicker while you move the mouse? [y/n]:")
		bright=$(ask "  Change brightness a few steps. Does the flicker change or stop? [y/n]:")
		snapshot "$n-flicker-after-brightness"
		ask "  Now change the refresh rate to stop it, then press Enter." > /dev/null
		kmark "cycle $i refresh rate changed by user"
		snapshot "$n-after-rate-change"
		fixed=$(ask "  Did that stop the flicker? [y/n]:")
		ask "  Set the refresh rate back to what it was, then press Enter." > /dev/null
		kmark "cycle $i refresh rate restored by user"
		snapshot "$n-rate-restored"
		back=$(ask "  Did the flicker come back at the original rate? [y/n]:")
		echo "cycle $i: FLICKER still=$still moving=$moving brightness-changes-it=$bright rate-change-fixed=$fixed returned-at-original-rate=$back" >> "$RESULTS"
		;;
	q*|Q*)
		echo "cycle $i: no flicker (quit)" >> "$RESULTS"
		break
		;;
	*)
		echo "cycle $i: no flicker" >> "$RESULTS"
		;;
	esac
done
