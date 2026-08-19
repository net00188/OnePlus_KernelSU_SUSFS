# Custom Build: persistent sysfs wakelocks (screen-off VPN reachability fix)

> This fork exists to build **one specific kernel**: WildKernels OP-ACE-3-PRO
> (SM8650 / Android 15 / android14-6.1.75) **without** the
> `add_timeout_wakelocks_globally` behaviour, so that a rooted phone running
> **kernel WireGuard** stays reachable from the WG LAN with the screen off.
> The fork tracks upstream untouched — all customization lives in
> `.github/workflows/build-custom.yml` (injected into the composite actions at
> job start, see [What this workflow changes](#what-this-workflow-changes)).

**中文摘要见文末。**

---

## Background

Device: OnePlus PJX110 (SM8650, `ro.board.platform=pineapple`), ColorOS 15,
kernel `6.1.75-android14-OP-WILD` (WildKernels KSU+SUSFS build, 2026-07-21).

Setup: kernel WireGuard `wg0` (192.168.11.15) managed by a KernelSU boot
script under `/data/adb/wireguard/` (wg-quick + NAT endpoint self-healing),
`adbd` listening on the WG address. The phone is accessed **only** through the
WG tunnel.

## The problem

Screen off → phone unreachable from the WG LAN within ~30 s (ping >95 % loss,
~1 reply per 70 s, adb reconnect hammering for 420 s got **zero** successes).
Unlock → reachable again within seconds. RTC `wakealarm` fired but did not
restore reachability (userspace stayed frozen).

## Root cause

[WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)
ships `common/add_timeout_wakelocks_globally.patch`, which changes
`kernel/power/wakelock.c`:

```diff
 	} else {
-		__pm_stay_awake(wl->ws);
+		__pm_wakeup_event(wl->ws, 500);
 	}
```

Intent (upstream): kill stuck wakelocks like `tx_swr_ctrl` that drain battery.
Side effect: **every** wakelock written to `/sys/power/wake_lock` without an
explicit timeout now expires in 500 ms — including ones you explicitly need.
Writes with an explicit timeout (`"name <ms>"`) also failed to hold.

Measured on stock (evidence numbers):

| probe | result |
|---|---|
| `/sys/kernel/debug/wakeup_sources` after N lock acquires | `active_count == expire_count == 11`, `max_time = 526 ms`, `prevent_suspend_time = 0` |
| `/sys/power/suspend_stats/success` during 25 min locked | **+864** (device suspends constantly) |
| locked-screen ping | >95 % loss, ~1 reply / 70 s (micro wake windows only) |
| adb TCP | sessions ESTABLISHED but frozen; 420 s of reconnect attempts: 0 success |

Consequence chain: nothing can block suspend → screen-off Doze → CPU sleeps →
`adbd` frozen + kernel WG `PersistentKeepalive=25` timers stop → NAT mapping
expires → unreachable. (Excluded along the way: `poweropt-service` — stopping
it changed nothing; `CONFIG_PM_WAKELOCKS_DEFAULT_TIMEOUT` — not set in
`/proc/config.gz`, this is pure patch code. kprobes are unavailable on this
LTO build, so the case was proven via wakeup_sources counters + patch source.)

If you rely on **any** long-lived sysfs wakelock (VPN keepalive, remote adb,
termux services, cron daemons…), this patch is a functional regression.

## What this workflow changes

`.github/workflows/build-custom.yml` (push-triggered, also `workflow_dispatch`)
checks out the fork **unmodified**, then injects 5 edits into the checked-out
composite actions before `uses: ./.github/actions/build-kernel` runs:

1. **The fix** — right after `add_timeout_wakelocks_globally.patch` is applied:
   ```sh
   sed -i 's/__pm_wakeup_event(wl->ws, 500)/__pm_stay_awake(wl->ws)/' kernel/power/wakelock.c
   grep -q '__pm_stay_awake(wl->ws)' kernel/power/wakelock.c || exit 1
   ```
   One-line surgical revert. Everything else from the optimisation patch set
   stays.
2. **Toolchain cache miss → direct download** instead of `FATAL ERROR`
   (a fork has no `toolchain-cache` release of its own).
3. **`TARGET_REPO` → `WildKernels/OnePlus_KernelSU_SUSFS`** so the toolchain
   cache reads the *upstream public release assets* (clang-r487747c 831 MB,
   build-tools, AnyKernel3 — all present).
4. **Internal `uses: ./action-source/.github/actions/*` refs → `./.github/actions/*`**.
   Upstream's composite action re-checks-out the pristine repo into
   `action-source/` and calls sub-actions from there, which would bypass every
   injection above.
5. **ccache save steps disabled** (`if: false`): they upload to this repo's
   release bucket and fail on a fork, poisoning an otherwise green build.

### Version pins (important)

| component | ref | why |
|---|---|---|
| config | `configs/a15/OP-ACE-3-PRO-6.1.75.json` | SM8650 GKI, matches device tree manifest `oneplus_ace3_pro_6.1.75_v.xml` |
| KernelSU-Next | `234f6e040fcbca18b16d2398e1aa225712ec99ad` (= v33239, dev @ 2026-08-11) | the exact combo of upstream release **v2.2.0-r4** (2026-08-12, last green) |
| SUSFS | `e287d59066380bf6de4396532d4a42edf4408701` (gki-android14-6.1 @ 2026-07-31) | r4-era head; today's branch head has drifted |
| optimize / LTO | O2 / thin | same as config default |

Do **not** pin KSUN to an older release (e.g. v33223 from v2.2.0-r3) nor use
`dev` HEAD blindly — the `fix_*.patch` set under `kernel_patches/next/susfs_fix_patches/v2.2.0/`
tracks a moving KSUN; mismatched combos produce hunk rejects
(`kernel/feature/sucompat.c.rej` …) and the build dies. If upstream publishes a
new `-r5`, copy its KSUN/SUSFS combo from the release asset names.

## Building

Fork → push any change to `.github/workflows/build-custom.yml` (or run it via
*Run workflow*). ~25 min on `ubuntu-latest`: source sync (upstream cache) +
full build (no ccache persistence) + **Release** `custom-ace3pro-noWL-*`
containing the flashable AK3 zip.

Successful build (this fork): release `custom-ace3pro-noWL-20260819-1314` →
`AK3_OP-ACE-3-PRO_A15_android14-6.1.75_KSUN_33239_SuSFS_v2.2.0.zip`,
Image `sha256 33cb07326d32433a5275889e82a5f694b977dc4e5863fb7f304020f80f13c1ca`.

## Flashing

Preferred: flash the AK3 zip with KernelFlasher / Franco Manager / custom
recovery (it writes `block=boot`, slot-aware, same as upstream releases).

Manual (what was actually used on the device — root shell):

```sh
MB=/data/adb/ksu/bin/magiskboot
# 0) backup first!
dd if=/dev/block/by-name/boot_a of=/sdcard/boot_backup.img bs=4M
# 1) extract Image from the release zip, then:
cd /data/local/tmp
$MB unpack /sdcard/boot_backup.img
cp new_Image kernel
$MB repack /sdcard/boot_backup.img new_boot.img
# 2) flash ACTIVE slot (check: getprop ro.boot.slot_suffix)
dd if=new_boot.img of=/dev/block/by-name/boot_a bs=4M
sync && reboot
```

Rollback: `dd if=/sdcard/boot_backup.img of=/dev/block/by-name/boot_a` (or
fastboot). Nothing else on the device is touched — same GKI, same modules,
same KSU manager (v33239 manager vs v33223 kernel-side is fine).

## Verification (2026-08-19, on-device)

| check | stock WILD | this build |
|---|---|---|
| `echo test-wl > /sys/power/wake_lock`, re-read after 13 s | gone in 500 ms | **still held** |
| locked-screen ping 6.5 min | >95 % loss | **281/281 replies, 0 loss** |
| `suspend_stats/success` while locked | +864 / 25 min | **0** (wakelock held) |
| adb over WG while locked | frozen, unrecoverable | instant all along |
| KernelSU / root / wg0 | — | OK (uid=0, wg0 self-healed at boot) |
| uname | `…#1 Tue Jul 21 2026` | `…#1 Wed Aug 19 12:55:02 UTC 2026` |

## Device-side keepalive (optional)

With persistent wakelocks restored, holding one is a plain sysfs write.
`device/wg-keepalive-sysfs.sh` (in this repo) does that on boot via
`/data/adb/service.d/`:

```sh
# install
cp device/wg-keepalive-sysfs.sh /data/adb/service.d/ && chmod 755 $_
# disable
touch /data/adb/wireguard/DISABLE_WAKELOCK && reboot
```

Re-arms every 5 min + sets `iw dev wlan0 set power_save off`. On stock WILD
this script is useless (the lock dies in 500 ms) — it only works on this build.

## Battery honesty

Holding a wakelock keeps the SoC awake: measured ~80–155 mA idle-locked
(≈ +1.5–2 %/h on a 6100 mAh pack) **while you want screen-off reachability**.
Screen-on use and charging are unaffected. If you don't need round-the-clock
reachability, don't install the keepalive script — you still get correct
wakelock semantics for anything else that needs them. A future "suspend + RTC
wake every 30 s to feed WG keepalive" mode could drop the cost to ~+0.3–0.5 %/h
at the price of intermittent-only adb.

---

## 中文摘要

- **问题**：刷了 WildKernels 内核的 OnePlus 手机（内核态 WireGuard，仅经 WG 内网访问）锁屏后 ~30 秒失联，解锁秒恢复。
- **根因**：WildKernels 补丁 `add_timeout_wakelocks_globally.patch` 把所有 sysfs wakelock 强制 500ms 过期（`__pm_stay_awake` → `__pm_wakeup_event(ws,500)`），实测 `wakeup_sources` 的 `expire_count == active_count`、单次最长 526ms → 锁屏后无人能阻止 suspend → adbd 冻结、WG keepalive 停摆、NAT 过期。
- **本 fork 改动**：workflow 在构建时注入 5 处修改（补丁回退 / 工具链缓存 miss 降级 / 工具链缓存指向上游 release / 子 action 引用改回工作区副本 / 禁用 ccache save），版本组合锁定上游 v2.2.0-r4（KSUN v33239 + SUSFS e287d59）。
- **刷入**：Release 下载 AK3 zip 用刷机工具刷，或 magiskboot unpack→替换 kernel→repack→dd 到活动槽位；回滚 dd 备份即可。
- **验证**：wakelock 13 秒仍持有；锁屏 6.5 分钟 ping 281/281 零丢包；suspend 计数 0 增长；锁屏态 adb 秒响应。
- **代价**：持锁期间锁屏耗电约 +1.5~2%/h（可接受则装 `device/wg-keepalive-sysfs.sh`，不需要 24h 可达可不装）。
