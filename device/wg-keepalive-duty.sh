#!/system/bin/sh
# wg-keepalive-duty: duty-cycled remote reachability with deep sleep.
#
# Schedule (daily):
#   07:00 - 23:00  every half-hour slot, the FIRST 5 MINUTES are "awake":
#                  wakelock held + wlan0 PS off + one NAT-kick ping ->
#                  phone reachable (adb/ssh/frida over WG). Remaining 25 min:
#                  wakelock released, system free to suspend (RTC alarm armed
#                  for the next slot start).
#   08:00 - 09:00  SPECIAL WINDOW: continuously awake the whole hour
#                  (overrides the duty cycle; transitions align because
#                  08:00 is itself a slot boundary).
#   23:00 - 07:00  full deep sleep, single RTC alarm at 07:00.
#
# Why RTC alarm: while suspended, this shell's `sleep` is frozen (monotonic
# clock stops), so the loop cannot wake itself. /sys/class/rtc/rtc0/wakealarm
# is armed BEFORE releasing the wakelock for every sleep phase.
#
# REQUIREMENTS:
#   - custom kernel with add_timeout_wakelocks_globally.patch reverted
#     (stock WildKernels force-expires sysfs wakelocks after 500 ms)
#   - 息屏显示 / AOD DISABLED in Settings UI: SystemUI DozeService
#     (dream:doze) otherwise holds PowerManagerService.noSuspend 24/7 and
#     NO sleep phase ever suspends (measured: 96 mA day AND night).
#     (settings put system Setting_AodEnable 0 does NOT work - UI toggle only)
#
# Battery model (6100 mAh): awake ~90-96 mA, deep ~16 mA ->
#   ~0.5 %/h duty-cycled daytime, ~0.4 %/h at night, +1 h awake for the
#   08:00 special window  =>  ~13-15 %/day idle.
#
# Test hook:  echo awake|night > /data/adb/wireguard/WL_TEST_MODE
# Disable:    touch /data/adb/wireguard/DISABLE_WAKELOCK && reboot

BASE=/data/adb/wireguard
LOG=$BASE/wg-remote-keepalive.log
NAME=wg-remote-access
RTC=/sys/class/rtc/rtc0/wakealarm
PING_TARGET=192.168.5.1

NIGHT_START=23   # 23:00
NIGHT_END=7      # 07:00
WINDOW_S=300     # awake seconds per slot (first 5 min)
SLOT_S=1800      # slot length (30 min). CST=UTC+8 -> epoch%1800 aligns to :00/:30

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

phase() {  # night | day
    if [ -f "$BASE/WL_TEST_MODE" ] && [ "$(head -1 "$BASE/WL_TEST_MODE")" = night ]; then echo night; return; fi
    h=$(date +%H)
    if [ "$h" -ge $NIGHT_START ] || [ "$h" -lt $NIGHT_END ]; then echo night; else echo day; fi
}

in_window() {  # 1 when inside the awake part of a day slot (or forced awake)
    if [ -f "$BASE/WL_TEST_MODE" ] && [ "$(head -1 "$BASE/WL_TEST_MODE")" = awake ]; then return 0; fi
    [ "$(date +%H)" -eq 8 ] && return 0        # special: 08:00-09:00 fully awake
    [ $(( $(date +%s) % SLOT_S )) -lt $WINDOW_S ]
}

next_slot() { echo $(( ( $(date +%s) / SLOT_S + 1 ) * SLOT_S )); }

next_morning() {
    today7=$(date -d "$(date +%Y-%m-%d) 07:00" +%s 2>/dev/null)
    now=$(date +%s)
    if [ -n "$today7" ] && [ "$now" -lt "$today7" ]; then echo "$today7"
    elif [ -n "$today7" ]; then echo $((today7 + 86400))
    else echo $((now + 3600)); fi
}

hold() {
    echo 0 > "$RTC" 2>/dev/null                    # no alarm needed while awake
    echo "$NAME" > /sys/power/wake_lock 2>/dev/null
    iw dev wlan0 set power_save off 2>/dev/null
}

release_day() {   # sleep until next slot
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    iw dev wlan0 set power_save on 2>/dev/null
    echo "$(next_slot)" > "$RTC" 2>/dev/null
}

release_night() { # sleep until 07:00
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    iw dev wlan0 set power_save on 2>/dev/null
    echo "$(next_morning)" > "$RTC" 2>/dev/null
}

if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
    echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
    echo 0 > "$RTC" 2>/dev/null
    log "disabled (DISABLE_WAKELOCK present)"
    exit 0
fi

sleep 15
state=""   # awake | day_sleep | night_sleep
while :; do
    if [ -f "$BASE/DISABLE_WAKELOCK" ]; then
        echo "$NAME" > /sys/power/wake_unlock 2>/dev/null
        echo 0 > "$RTC" 2>/dev/null
        log "disabled at runtime"
        exit 0
    fi
    p=$(phase)
    if [ "$p" = night ]; then
        if [ "$state" != night_sleep ]; then
            release_night
            log "night: deep sleep until 07:00, alarm=$(cat $RTC 2>/dev/null)"
            state=night_sleep
        fi
    elif in_window; then
        # re-assert every tick: wifi reconnects reset wlan0 PS; lock must persist
        hold
        if [ "$state" != awake ]; then
            ping -c1 -W2 "$PING_TARGET" >/dev/null 2>&1 &   # kick WG NAT mapping
            log "window+: reachable 5min slot $(date +%H:%M)"
            state=awake
        fi
    else
        if [ "$state" != day_sleep ]; then
            release_day
            log "window-: sleep, alarm=$(cat $RTC 2>/dev/null)"
            state=day_sleep
        fi
    fi
    sleep 10
done
