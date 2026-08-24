# Power schedule and sleep-phase app policy

Current device policy for the OnePlus PJX110 WG peer:

| Period | WG / WiFi | Chat apps |
|---|---|---|
| 07:00–23:00, first five minutes of each 30-minute slot | `PersistentKeepalive=25`, wakelock held, WiFi PS off | Normal; user can open them |
| 08:00–09:00 | Continuously awake | Normal |
| Other daytime sleep phases | `PersistentKeepalive=0`, wakelock released, WiFi PS on | `com.tencent.mm` and `com.tencent.wework` are force-stopped once on entry |
| 23:00–07:00 | `PersistentKeepalive=0`, RTC alarm until 07:00 | Both packages are force-stopped on entry |

The script stops the packages **only when entering a sleep phase**. It does not poll and kill them continuously, so manually opening WeChat or WeCom during a sleep phase is allowed. They are stopped again at the next sleep transition.

Packages:

```text
com.tencent.mm       WeChat
com.tencent.wework    WeCom
```

`am force-stop` also stops notifications and background delivery until the user opens the app again.

Verification on 2026-08-24:

```text
CHAT_PROCESSES_STOPPED
HELD=[PowerManagerService.noSuspend]
latest handshake: 4 seconds ago
```

The sleep transition set `keepalive=0`; WeChat and WeCom had no running processes after the transition.
