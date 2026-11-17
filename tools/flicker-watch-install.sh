#!/usr/bin/env bash
# flicker-watch: background collector for the amdgpu eDP resume flicker.
#
#   sudo ./flicker-watch-install.sh            install and start
#   sudo ./flicker-watch-install.sh uninstall  stop and remove (keeps data)
#
# After install:
#   flicker-mark              the screen is flickering NOW
#   flicker-mark boost        while flickering: raise the panel link drive level
#   flicker-mark fixed        the flicker has stopped
#   flicker-mark "any note"   same as plain flicker-mark, with a note attached
#
# Data lives in /var/lib/flicker-watch. Each flicker-mark produces
# /var/lib/flicker-watch/incidents/<time>.tar.gz

set -eu

D=${DESTDIR:-}

if [ -z "$D" ] && [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi

if [ "${1:-install}" = uninstall ]; then
	systemctl disable --now flicker-watch.service 2>/dev/null || true
	rm -f /usr/local/bin/flicker-watchd /usr/local/bin/flicker-mark \
	      /etc/systemd/system/flicker-watch.service \
	      /usr/lib/systemd/system-sleep/flicker-watch
	systemctl daemon-reload
	echo "Removed. Collected data is still in /var/lib/flicker-watch"
	exit 0
fi

mkdir -p "$D/usr/local/bin" "$D/etc/systemd/system" "$D/usr/lib/systemd/system-sleep"

# ---------------------------------------------------------------------------
# daemon
# ---------------------------------------------------------------------------
cat > "$D/usr/local/bin/flicker-watchd" <<'EOF'
#!/usr/bin/env bash
# flicker-watch daemon. Started by flicker-watch.service.
set -u

RUN=${FW_RUN:-/run/flicker-watch}
STATE=${FW_STATE:-/var/lib/flicker-watch}
INTERVAL=${FW_INTERVAL:-60}		# seconds between routine snapshots
FAST_INTERVAL=${FW_FAST_INTERVAL:-10}	# ... after a resume or a mark
RESUME_WINDOW=${FW_RESUME_WINDOW:-90}	# fast period after a resume
MARK_WINDOW=${FW_MARK_WINDOW:-180}	# fast period after a flicker mark
RING_KEEP=${FW_RING_KEEP:-200}		# snapshots kept in the ring
DRM_DEBUG=${FW_DRM_DEBUG:-0x106}
DRM_PARAM=/sys/module/drm/parameters/debug

FIFO=$RUN/mark
RING=$STATE/ring
INCIDENTS=$STATE/incidents
mkdir -p "$RUN" "$RING" "$INCIDENTS"
chmod 755 "$STATE" "$INCIDENTS"

rm -f "$FIFO"
mkfifo -m 0622 "$FIFO"
exec 3<>"$FIFO"		# read-write so the open never blocks

ORIG_DEBUG=$(cat "$DRM_PARAM" 2>/dev/null || echo 0)
EDP_DBG=
DRI_DBG=

now() { printf '%(%s)T' -1; }
stamp() { printf '%(%Y%m%d-%H%M%S)T' -1; }
kmark() { { echo "flicker-watch: $*" > /dev/kmsg; } 2>/dev/null || true; }
drm_debug() { { echo "$1" > "$DRM_PARAM"; } 2>/dev/null || true; }

find_panel() {
	[ -n "$EDP_DBG" ] && [ -d "$EDP_DBG" ] && return
	EDP_DBG=$(ls -d /sys/kernel/debug/dri/*/eDP-* 2>/dev/null | head -n1)
	[ -n "$EDP_DBG" ] && DRI_DBG=$(dirname "$EDP_DBG")
}

dpcd() {	# dpcd <hex-offset> <count> <label> : read DPCD bytes over AUX
	local aux
	aux=$(ls -d /sys/class/drm/card*-eDP-*/drm_dp_aux* 2>/dev/null | head -n1)
	[ -n "$aux" ] && [ -e "/dev/${aux##*/}" ] || return 0
	printf 'dpcd %s (%s): ' "$1" "$3"
	timeout 2 dd if="/dev/${aux##*/}" bs=1 skip=$(($1)) count="$2" 2>/dev/null |
		od -An -tx1 | tr -s ' \n' ' '
	echo
}

link_state() {
	echo "== link"
	dump "$EDP_DBG"/phy_settings
	dpcd 0x100 2 "link rate, lane count"
	dpcd 0x103 4 "lane drive settings in use"
	dpcd 0x202 6 "lane status, align, sink status, adjust requests"
	dpcd 0x210 8 "symbol error counts"
	echo
}

dump() {
	local f
	for f in "$@"; do
		[ -e "$f" ] || continue
		echo "== $f"
		cat "$f" 2>&1
		echo
	done
}

INC=		# directory of the incident being recorded, if any
INC_END=0

snapshot() {	# snapshot <tag>
	local file
	file="$RING/$(stamp)-$1.txt"
	find_panel
	{
		echo "time: $(date '+%F %T')  tag: $1  uptime: $(cut -d' ' -f1 /proc/uptime)"
		echo "dcdebugmask: $(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null)"
		echo
		if [ -n "$EDP_DBG" ]; then
			dump "$EDP_DBG"/psr_capability "$EDP_DBG"/psr_state \
			     "$EDP_DBG"/replay_capability "$EDP_DBG"/replay_state \
			     "$EDP_DBG"/vrr_range "$EDP_DBG"/link_settings \
			     "$EDP_DBG"/dsc_clock_en
			[ "$1" != periodic ] && link_state
			dump "$DRI_DBG"/amdgpu_dm_capabilities \
			     "$DRI_DBG"/amdgpu_dm_ips_status \
			     "$DRI_DBG"/state
		else
			echo "no eDP connector found in debugfs"
		fi
		dump /sys/class/drm/card*-*/status \
		     /sys/class/backlight/*/brightness \
		     /sys/class/backlight/*/actual_brightness \
		     /sys/class/power_supply/A*/online \
		     /sys/firmware/acpi/platform_profile \
		     /sys/power/suspend_stats/last_hw_sleep \
		     /sys/power/suspend_stats/success \
		     /sys/power/suspend_stats/fail \
		     /sys/kernel/debug/amd_pmc/s0ix_stats
	} > "$file" 2>&1
	[ -n "$INC" ] && cp "$file" "$INC/snapshots/"
	return 0
}

prune_ring() {
	ls -1t "$RING" 2>/dev/null | tail -n +"$((RING_KEEP + 1))" |
		while read -r f; do rm -f "$RING/$f"; done
}

klog() {	# klog <file>
	journalctl -k -b --no-pager > "$1" 2>/dev/null || dmesg > "$1" 2>/dev/null || true
}

finish_incident() {
	[ -n "$INC" ] || return
	klog "$INC/kernel.log"
	tar -C "$INCIDENTS" -czf "$INC.tar.gz" "$(basename "$INC")" 2>/dev/null
	chmod -R a+rX "$INC" "$INC.tar.gz" 2>/dev/null
	kmark "incident saved: $INC.tar.gz"
	INC=
	INC_END=0
}

start_incident() {	# start_incident <note>
	local edid
	finish_incident
	INC="$INCIDENTS/$(stamp)"
	mkdir -p "$INC/snapshots"
	{
		echo "marked:      $(date '+%F %T')"
		echo "note:        $1"
		echo "kernel:      $(uname -r)"
		echo "cmdline:     $(cat /proc/cmdline)"
		echo "dcdebugmask: $(cat /sys/module/amdgpu/parameters/dcdebugmask 2>/dev/null)"
		echo "mem_sleep:   $(cat /sys/power/mem_sleep 2>/dev/null)"
	} > "$INC/info.txt"
	cp "$RING"/*.txt "$INC/snapshots/" 2>/dev/null
	edid=$(ls /sys/class/drm/card*-eDP-*/edid 2>/dev/null | head -n1)
	[ -n "$edid" ] && cp "$edid" "$INC/edid.bin" 2>/dev/null
	klog "$INC/kernel-at-mark.log"
	chmod -R a+rX "$INC" 2>/dev/null
}

cleanup() {
	finish_incident
	drm_debug "$ORIG_DEBUG"
	rm -f "$FIFO"
	exit 0
}
trap cleanup TERM INT

kmark "started"
snapshot start
T=$(now)
NEXT=$((T + INTERVAL))
FAST_UNTIL=0
DEBUG_OFF_AT=0
PARTIAL=

while :; do
	msg=
	if ! read -r -t 5 -u 3 msg; then
		# timed out; keep any partial line for the next round
		PARTIAL=$PARTIAL$msg
	else
		msg=$(printf '%s' "$PARTIAL$msg" | tr -cd '[:print:]' | cut -c1-200)
		PARTIAL=
		T=$(now)
		case "$msg" in
		resume*)
			kmark "resume"
			snapshot resume
			FAST_UNTIL=$((T + RESUME_WINDOW))
			[ "$DEBUG_OFF_AT" -lt "$FAST_UNTIL" ] && DEBUG_OFF_AT=$FAST_UNTIL
			NEXT=$((T + 3))
			;;
		boost*)
			find_panel
			snapshot before-boost
			kmark "raising eDP pre-emphasis: phy_settings <- 1 2 0"
			{ echo "1 2 0" > "$EDP_DBG/phy_settings"; } 2>/dev/null ||
				kmark "phy_settings write failed"
			sleep 1
			snapshot after-boost
			[ -n "$INC" ] && echo "boost:       $(date '+%F %T')" >> "$INC/info.txt"
			NEXT=$((T + FAST_INTERVAL))
			;;
		fixed*)
			kmark "user reports flicker STOPPED: $msg"
			snapshot fixed
			[ -n "$INC" ] && echo "fixed:       $(date '+%F %T')  $msg" >> "$INC/info.txt"
			[ -n "$INC" ] && INC_END=$((T + 20))
			NEXT=$((T + FAST_INTERVAL))
			;;
		*)
			drm_debug "$DRM_DEBUG"
			kmark "user reports FLICKER: $msg"
			start_incident "$msg"
			snapshot FLICKER
			FAST_UNTIL=$((T + MARK_WINDOW))
			INC_END=$FAST_UNTIL
			DEBUG_OFF_AT=$FAST_UNTIL
			NEXT=$((T + FAST_INTERVAL))
			;;
		esac
	fi

	T=$(now)
	if [ "$T" -ge "$NEXT" ]; then
		if [ "$T" -lt "$FAST_UNTIL" ]; then
			snapshot fast
			NEXT=$((T + FAST_INTERVAL))
		else
			snapshot periodic
			NEXT=$((T + INTERVAL))
		fi
		prune_ring
	fi
	if [ -n "$INC" ] && [ "$T" -ge "$INC_END" ]; then
		finish_incident
	fi
	if [ "$DEBUG_OFF_AT" -ne 0 ] && [ "$T" -ge "$DEBUG_OFF_AT" ]; then
		drm_debug "$ORIG_DEBUG"
		DEBUG_OFF_AT=0
	fi
done
EOF

# ---------------------------------------------------------------------------
# user command
# ---------------------------------------------------------------------------
cat > "$D/usr/local/bin/flicker-mark" <<'EOF'
#!/usr/bin/env bash
# Tell flicker-watch that the screen is flickering (or has stopped).
FIFO=${FW_RUN:-/run/flicker-watch}/mark
msg=${*:-flicker}

say() {
	echo "$1"
	command -v notify-send > /dev/null && notify-send -t 4000 "flicker-watch" "$1" 2>/dev/null
	return 0
}

if [ ! -p "$FIFO" ]; then
	say "flicker-watch is not running (sudo systemctl start flicker-watch)"
	exit 1
fi
if ! timeout 2 bash -c 'printf "%s\n" "$1" > "$2"' _ "$msg" "$FIFO"; then
	say "flicker-watch did not accept the mark"
	exit 1
fi

case "$msg" in
fixed*) say "Recorded: flicker stopped." ;;
boost*)	say "Raised the panel link drive level. Did the flicker stop? If yes: flicker-mark fixed" ;;
*)	say "Recorded: flickering. Leave it flickering ~30s if you can, then fix it and run: flicker-mark fixed" ;;
esac
EOF

# ---------------------------------------------------------------------------
# suspend/resume hook: debug logging on before suspend, tell the daemon after
# ---------------------------------------------------------------------------
cat > "$D/usr/lib/systemd/system-sleep/flicker-watch" <<'EOF'
#!/bin/sh
FIFO=/run/flicker-watch/mark
[ -p "$FIFO" ] || exit 0
case "$1" in
pre)	echo 0x106 > /sys/module/drm/parameters/debug 2>/dev/null ;;
post)	timeout 2 sh -c "echo resume > $FIFO" ;;
esac
exit 0
EOF

cat > "$D/etc/systemd/system/flicker-watch.service" <<'EOF'
[Unit]
Description=Collect amdgpu display state to debug resume flicker

[Service]
ExecStart=/usr/local/bin/flicker-watchd
RuntimeDirectory=flicker-watch
Restart=on-failure
Nice=10

[Install]
WantedBy=multi-user.target
EOF

chmod 755 "$D/usr/local/bin/flicker-watchd" "$D/usr/local/bin/flicker-mark" \
	  "$D/usr/lib/systemd/system-sleep/flicker-watch"

if [ -n "$D" ]; then
	echo "Files written under $D (not started)."
	exit 0
fi

systemctl daemon-reload
systemctl enable flicker-watch.service
systemctl restart flicker-watch.service
sleep 1
systemctl --no-pager --lines=0 status flicker-watch.service || true
cat <<'EOF'

Installed. When the screen flickers:   flicker-mark
After you have stopped it:             flicker-mark fixed
Results: /var/lib/flicker-watch/incidents/*.tar.gz
EOF
