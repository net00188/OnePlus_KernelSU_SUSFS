#!/system/bin/sh
# Duty-cycled WG reachability with sleep-phase WeChat/WeCom stop.
# Sleep phases set PersistentKeepalive=0, release the sysfs wakelock, enable WiFi PS,
# and force-stop WeChat/WeCom once on entry. Manually opening either app is allowed
# until the next sleep transition. Requires the custom kernel and AOD disabled.

BASE=/data/adb/wireguard
LOG=$BASE/wg-remote-keepalive.log
NAME=wg-remote-access
WG=/data/adb/wireguard/bin/wg
IF=wg0
PEER=""
RTC=/sys/class/rtc/rtc0/wakealarm
PING_TARGET=192.168.5.1
NIGHT_START=23
NIGHT_END=7
WINDOW_S=300
SLOT_S=1800
APPS="com.tencent.mm com.tencent.wework"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
init_peer() { PEER=$($WG show "$IF" peers 2>/dev/null | head -1); }
set_keepalive() { [ -n "$PEER" ] || init_peer; [ -n "$PEER" ] && $WG set "$IF" peer "$PEER" persistent-keepalive "$1" >/dev/null 2>&1; }
stop_sleep_apps() { for pkg in $APPS; do am force-stop "$pkg" >/dev/null 2>&1; done; }
phase() { if [ -f "$BASE/WL_TEST_MODE" ] && [ "$(head -1 "$BASE/WL_TEST_MODE")" = night ]; then echo night; return; fi; h=$(date +%H); if [ "$h" -ge $NIGHT_START ] || [ "$h" -lt $NIGHT_END ]; then echo night; else echo day; fi; }
in_window() { if [ -f "$BASE/WL_TEST_MODE" ] && [ "$(head -1 "$BASE/WL_TEST_MODE")" = awake ]; then return 0; fi; [ "$(date +%H)" -eq 8 ] && return 0; [ $(( $(date +%s) % SLOT_S )) -lt $WINDOW_S ]; }
next_slot() { echo $(( ( $(date +%s) / SLOT_S + 1 ) * SLOT_S )); }
next_morning() { today7=$(date -d "$(date +%Y-%m-%d) 07:00" +%s 2>/dev/null); now=$(date +%s); if [ -n "$today7" ] && [ "$now" -lt "$today7" ]; then echo "$today7"; elif [ -n "$today7" ]; then echo $((today7 + 86400)); else echo $((now + 3600)); fi; }
hold() { set_keepalive 25; echo 0 > "$RTC" 2>/dev/null; echo "$NAME" > /sys/power/wake_lock 2>/dev/null; iw dev wlan0 set power_save off 2>/dev/null; }
release_day() { set_keepalive 0; stop_sleep_apps; echo "$NAME" > /sys/power/wake_unlock 2>/dev/null; iw dev wlan0 set power_save on 2>/dev/null; echo "$(next_slot)" > "$RTC" 2>/dev/null; }
release_night() { set_keepalive 0; stop_sleep_apps; echo "$NAME" > /sys/power/wake_unlock 2>/dev/null; iw dev wlan0 set power_save on 2>/dev/null; echo "$(next_morning)" > "$RTC" 2>/dev/null; }
if [ -f "$BASE/DISABLE_WAKELOCK" ]; then set_keepalive 0; echo "$NAME" > /sys/power/wake_unlock 2>/dev/null; echo 0 > "$RTC" 2>/dev/null; log "disabled (DISABLE_WAKELOCK present)"; exit 0; fi
sleep 15
state=""
while :; do
    if [ -f "$BASE/DISABLE_WAKELOCK" ]; then set_keepalive 0; echo "$NAME" > /sys/power/wake_unlock 2>/dev/null; echo 0 > "$RTC" 2>/dev/null; log "disabled at runtime"; exit 0; fi
    p=$(phase)
    if [ "$p" = night ]; then
        if [ "$state" != night_sleep ]; then release_night; log "night: keepalive=0, chat apps stopped, deep sleep until 07:00, alarm=$(cat $RTC 2>/dev/null)"; state=night_sleep; fi
    elif in_window; then
        hold
        if [ "$state" != awake ]; then ping -c1 -W2 "$PING_TARGET" >/dev/null 2>&1 &; log "window+: keepalive=25 reachable 5min slot $(date +%H:%M)"; state=awake; fi
    else
        if [ "$state" != day_sleep ]; then release_day; log "window-: keepalive=0 sleep, chat apps stopped, alarm=$(cat $RTC 2>/dev/null)"; state=day_sleep; fi
    fi
    sleep 10
done
