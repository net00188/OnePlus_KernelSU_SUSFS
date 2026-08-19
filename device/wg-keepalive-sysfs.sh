#!/system/bin/sh
# wg-keepalive-sysfs: hold a kernel wakelock so the phone stays reachable
# (kernel WireGuard + adbd over VPN) with the screen off.
#
# Works ONLY on kernels where add_timeout_wakelocks_globally.patch is reverted
# (see CUSTOM-BUILD.md). On stock WildKernels builds every sysfs wakelock is
# force-expired after 500ms, making this script useless there.

BASE=/data/adb/wireguard
LOG=$BASE/wg-remote-keepalive.log
NAME=wg-remote-access

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    log "disabled (DISABLE_WAKELOCK present)"
    exit 0
fi

sleep 15
echo "$NAME" > /sys/power/wake_lock 2>/dev/null
iw dev wlan0 set power_save off 2>/dev/null
log "armed: sysfs wakelock + wifi ps off"

while :; do
    sleep 300
    if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
        echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
        log "disabled at runtime"
        exit 0
    fi
    echo "$NAME" > /sys/power/wake_lock 2>/dev/null
    iw dev wlan0 set power_save off 2>/dev/null
    log "heartbeat held=$(grep -c $NAME /sys/power/wake_lock) wifi_ps=$(iw dev wlan0 get power_save 2>/dev/null)"
done
