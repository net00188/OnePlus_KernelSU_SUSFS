#!/system/bin/sh
# wg-keepalive-sysfs: time-windowed kernel wakelock holder.
#
# Day   (07:00 - 01:00): hold 'wg-remote-access' wakelock + wlan0 power_save off
#                        -> phone stays reachable through WG (ping/adbd/frida...)
# Night (01:00 - 07:00): release wakelock -> normal deep sleep (saves ~9%/night)
#                        -> phone NOT reachable (by design). An RTC wakealarm is
#                           armed for 07:00 so the device wakes and the loop
#                           re-arms the lock automatically (a plain `sleep` in a
#                           suspended shell does not advance, so without the
#                           alarm the morning transition would never fire).
#
# Requires: custom kernel with add_timeout_wakelocks_globally.patch reverted
#           (stock WildKernels force-expires sysfs wakelocks after 500 ms).
# Test hook:   echo night > /data/adb/wireguard/WL_TEST_MODE   (force mode)
#              echo day   > /data/adb/wireguard/WL_TEST_MODE
#              rm /data/adb/wireguard/WL_TEST_MODE             (use real clock)
# Disable:     touch /data/adb/wireguard/DISABLE_WAKELOCK && reboot

BASE=/data/adb/wireguard
LOG=$BASE/wg-remote-keepalive.log
NAME=wg-remote-access
RTC=/sys/class/rtc/rtc0/wakealarm

NIGHT_START=1   # 01:00
NIGHT_END=7     # 07:00

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

mode_now() {
    if [ -f "$BASE/WL_TEST_MODE" ]; then head -1 "$BASE/WL_TEST_MODE"/dev/null; return; fi
    h=$(date +%H)
    if [ "$h" -ge $NIGHT_START ] && [ "$h" -lt $NIGHT_END ]; then echo night; else echo day; fi
}

# epoch of the next local 07:00
next_morning() {
    today7=$(date -d "$(date +%Y-%m-%d) 07:00" +%s 2>/dev/null)
    now=$(date +%s)
    if [ -n "$today7" ] && [ "$now" -lt "$today7" ]; then
        echo "$today7"
    elif [ -n "$today7" ]; then
        echo $((today7 + 86400))
    else
        echo $((now + 3600))   # parser failed: hourly fallback keeps the loop alive
    fi
}

arm_day() {
    echo 0 > "$RTC" 2>/dev/null                     # cancel morning alarm
    echo "$NAME" > /sys/power/wake_lock 2>/dev/null
    iw dev wlan0 set power_save off 2>/dev/null
}

arm_night() {
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    iw dev wlan0 set power_save on 2>/dev/null
    nm=$(next_morning)
    [ -n "$nm" ] && echo "$nm" > "$RTC" 2>/dev/null
}

if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    echo 0 > "$RTC" 2>/dev/null
    log "disabled (DISABLE_WAKELOCK present)"
    exit 0
fi

sleep 15
cur=""
while :; do
    if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
        echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
        echo 0 > "$RTC" 2>/dev/null
        log "disabled at runtime"
        exit 0
    fi
    m=$(mode_now)
    if [ "$m" = "night" ]; then
        if [ "$cur" != "night" ]; then
            arm_night
            log "night window: wakelock released, deep sleep allowed, RTC alarm -> $(cat $RTC 2>/dev/null)"
        fi
    else
        if [ "$cur" != "day" ]; then
            arm_day
            log "day window: wakelock armed (RTC alarm cleared)"
        fi
    fi
    cur=$m
    sleep 60
done
