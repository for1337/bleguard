# bleguard

I kept walking away from my desk for ten minutes and coming back to find my laptop unlocked and the dog asleep on the keyboard. The screen lock from the idle service is fine when I leave it on the desk; I wanted something stricter — "if my phone isn't next to the laptop, lock". This is a small Omarchy plugin that watches the BLE link to a paired phone, waits for a 30 s input idle, and locks via `omarchy-system-lock`. With the optional unlock patch installed, it also unlocks itself when the phone comes back, no password.

![preview](preview.png)

## what it does

The plugin watches the BLE link to the phone you picked in the popup and compares the **RSSI value against the threshold**:

- **value ≥ threshold** → the phone is close → stay unlocked
- **value < threshold** → the phone is out of range → the value has to **stay** below the threshold for the grace period (default 5 s) before anything happens; only then the "Phone out of range" notification appears, and after a further 10 s grace period and 30 s of idleness the screen locks via `omarchy-system-lock`

That is the same rule the chart in the popup draws, so the graph and the state can never contradict each other. The threshold is a plain dBm number (default −85, range −100..−30): *above the dashed line = close = unlocked, below it = out of range*.

The grace period is the delay between "the value crossed the threshold" and "the notification appears and the lock procedure starts". A reading that flaps around the threshold never reaches it, so one noisy sample cannot lock the laptop. It stretches across short flaps (a 2 s reconnect does not restart it) but a **stable** return resets it — otherwise the counter would survive the whole session and the second drop would fire the notification instantly. Tune it in the popup (`Grace (s)`, default 5, range 0..300) or with `omarchy-shell bleguard.ctrl setGraceMs <ms>`.

The RSSI arrives through a small helper (`bleguard-discovery.py`) that holds a **filtered discovery session** open on the adapter. BlueZ only republishes the `RSSI` property when the value moves by 8 dBm (`RSSI_THRESHOLD` in `device.c`), which froze the reading at −45 dBm and left the chart stuck; in a filtered session BlueZ republishes it on *every* advertisement, so the property becomes a real heartbeat. The helper streams the values over stdout:

```
ready          discovery is active and the subscription is live
rssi <int>     the device's RSSI changed to <int> dBm
device <path>  the device object moved to a new D-Bus path
error <text>   recoverable error, the helper keeps running
```

The `busctl` poll every 2 s is kept as a fallback for when the helper cannot run.

### How a stale reading is treated

A phone does not advertise continuously — an idle beacon can stay silent for tens of minutes. On top of that, **BlueZ removes the `RSSI` property from the device object as soon as it stops seeing the device**, so during a silence there is no value at all. The plugin therefore never turns silence into "the phone is gone":

| situation | decision |
| --- | --- |
| fresh reading (advertisement within `rssiStaleWindowMs`, 45 s) | the value decides |
| stale reading | the **last known value** decides; a phone last seen close is never reported as lost |
| no reading ever | **no decision**: the state is held. Silence is not evidence of absence |

The last known value is persisted in `~/.local/state/omarchy/bleguard-state.json`, together with the **absolute timestamp** of the measurement, so a shell restart does not throw away the only measurement available — the plugin resumes with the same evidence it had before. The timestamp is stored absolute (not as an age) so the age cannot drift or be rounded away: a reading restored from disk is only "fresh" when it really was measured a few seconds ago. If the file carries no usable timestamp the reading is restored as stale on purpose — an unknown age must never look fresh.

The consequence is deliberate: if the beacon goes silent *and* the last measurement said "close", the laptop stays unlocked. The plugin will only lock once it actually measures a value below the threshold (the phone in the next room), and it will only unlock on **fresh** proof that the phone is back (a live BR/EDR link, a recent advertisement, or a recent RSSI at or above the threshold). A stale value can keep the laptop unlocked but can never open it on its own.

If you become idle while the phone is "lost", the screen locks via `omarchy-system-lock`. If the phone comes back with `autoLockSource=true` (only locks this plugin triggered), the plugin drops the session lock without PAM after `unlockStableMs` (10 s) of stable presence.

State machine: `DISARMED → ARMED → WARNING → WAITING → LOCKING → LOCKED → UNLOCKING → ARMED`. Manual unlock routes `LOCKED → ARMED` directly; auto-unlock routes through `UNLOCKING`. State (target MAC, armed flag, threshold) persists in `~/.local/state/omarchy/bleguard-state.json` so it survives shell restarts.

## requirements

- Omarchy shell. `omarchy`, `omarchy-shell`, `omarchy bar move` on `$PATH`.
- `bluez` — `sudo systemctl enable --now bluetooth` if it isn't already running.
- `busctl` (from `systemd`) — used to read `org.bluez.Device1.RSSI` and `AdvertisingFlags`. Ships with `systemd` on Arch.
- `python3` with `PyGObject` (`gi.repository.Gio`) — the discovery helper needs it. On Arch: `sudo pacman -S python-gobject`.
- `jq` — only required if you use `./install.sh --enable` (the script edits `shell.json` for you).
- `omarchy-system-lock` on `$PATH` — installed by Omarchy by default. The plugin will *not* fall back to `hyprlock` / `swaylock` / `loginctl lock-session` because none of those give you the Omarchy lock UI.

## install

```
git clone https://github.com/for1337/bleguard.git
cd bleguard
./install.sh --enable
```

`install.sh` copies `manifest.json`, `Panel.qml`, `Service.qml`, `BleLogic.js` and `bleguard-discovery.py` into `~/.config/omarchy/plugins/bleguard/`, adds the plugin to `~/.config/omarchy/shell.json`, and asks Omarchy to place the bar widget in the right section. Re-run with `--force` to overwrite. `uninstall.sh` is the inverse (`--purge` also deletes the state file).

For the auto-unlock on return (optional, but **required** for the "phone comes back → laptop unlocks" behaviour):

```
sudo bash patches/install-lock-unlock-ipc.sh   # exposes an `unlock` IPC on the lock plugin
```

Idempotent; re-run to no-op. Revert with `--revert`.

Verify that it actually landed — `qs` exits 0 even when the method is missing, so check the *output*:

```
qs -p /usr/share/omarchy/shell ipc call lock unlock
# ok / not-locked  → patched
# Function not found. → not patched
```

Without the patch the plugin can lock the laptop but never unlock it, and it now says so with a notification instead of failing silently.

Reload the shell so the new code loads:

```
omarchy restart shell
```

## using it

Click the bar widget — first launch shows the device picker (only currently-paired BLE devices). Pick your phone. From then on the bar icon shows the state: shield (armed), warning (phone out), lock (locked), shield-off (disarmed). The popup has:

- an `armed` toggle
- current RSSI value and a signal-bar indicator (a stale value is shown greyed out and marked `old`, never hidden)
- a `Presence` row that spells out the decision: the channel that carries it (`connected`, `rssi`, `rssi-stale`), the comparison (`-45 dBm ≥ thr -85 → in range`) and whether the value is live or the last known one
- a rolling RSSI chart (last 5 minutes) with the threshold line drawn in and the rule written next to it (`thr -85 · below = out of range`); when the phone goes quiet the chart **breaks the line** and marks the last point as `old` instead of drawing a frozen curve
- a `Threshold (dBm)` field (default −85, range −100..−30) that becomes the new lock boundary the moment you change it
- a `Grace (s)` field (default 5, range 0..300) — the delay between the value crossing the threshold and the "Phone out of range" notification appearing
- a `Lock now` button for testing

Hand-edit the state file and `omarchy restart shell` — the service hydrates from disk on startup.

IPC:

```
omarchy-shell bleguard.ctrl status                  # JSON: state, rssi, idle, threshold, history, presence, unlock result
omarchy-shell bleguard.ctrl arm
omarchy-shell bleguard.ctrl disarm
omarchy-shell bleguard.ctrl lockNow
omarchy-shell bleguard.ctrl setTarget <MAC>          # programmatic pairing
omarchy-shell bleguard.ctrl setThreshold <dBm>       # e.g. -75
omarchy-shell bleguard.ctrl setGraceMs <ms>         # e.g. 15000
```

The `status` JSON exposes the fields that explain *why* the plugin behaves the way it does:

| field | meaning |
| --- | --- |
| `presence` / `presenceLevel` | which channel currently carries the decision: `acl` (BR/EDR link up), `rssi` (a fresh reading), `rssi-stale` (the last known value, still used), `adv` (advertisement only), `none` (nothing at all) |
| `presenceWarmup` | true while the plugin has no evidence yet — it never alarms in that window |
| `rssi` / `rssiAt` / `rssiAgeMs` | the last reading, when it arrived, how old it is |
| `rssiFresh` | true when the reading is recent enough to be a heartbeat |
| `rssiSource` | `helper` (the filtered-discovery session), `poll` (the busctl fallback) or `none` |
| `phonePresent` | positive proof that the phone is back — what gates the auto-unlock |
| `helperReady` / `helperError` / `helperRestarts` | state of the discovery helper; `helperRestarts` climbing means the helper keeps dying |
| `unlockResult` | raw result of the last unlock IPC attempt (`ok`, `not-locked`, or the error string) |
| `unlockFailures` | consecutive failed unlock attempts |
| `advAt` | when the advertisement payload last changed |
| `lostEntryMs` | the grace period in ms — how long the reading has to stay out of range before the warning fires |
| `phoneLostSince` | when the reading went out of range (0 = not out of range); the warning fires `lostEntryMs` after this |

Note: `omarchy-shell bleguard status` (without `.ctrl`) is the Omarchy base Panel handler (`show`/`hide`/`toggle`) — `status` lives on the `.ctrl` target.

## quirks

- **BlueZ republishes `RSSI` only every 8 dBm.** `device.c` defines `RSSI_THRESHOLD 8`, so a phone sitting on the desk left the exported value frozen at −45 dBm and the chart stuck. The filtered-discovery helper fixes this: in a filtered session BlueZ calls `device_set_rssi_with_delta(dev, rssi, 0)` and republishes on every advertisement. The filter has to be installed by the *same* D-Bus connection that later calls `StartDiscovery` — `SetDiscoveryFilter` only pre-sets a filter for its own caller — which is why a one-shot `busctl` cannot do it.
- **The filter must stay permissive.** The helper uses `RSSI = -127` and no UUID restriction, so a phone walking out of range is still reported with its fading signal instead of being filtered out of the session entirely.
- **A phone advertises in bursts.** Measured on an OPPO Find X9 Pro: roughly one advertisement every 15 s, but in blocks — 14 minutes of traffic, then ~32 minutes of silence, then ~37 minutes again. During a silence there is *no* signal at all (BlueZ even removes the `RSSI` property), so the plugin holds its state: it neither locks nor unlocks. This is the price of never guessing: the laptop stays as it was until the beacon speaks again. If you walk away while the beacon is muted, the automatic lock cannot fire; if you come back while it is muted, the automatic unlock cannot fire either and you type your password.
- **BlueZ serves a cached advertisement payload, so it cannot prove liveness.** `AdvertisingFlags`, `AdvertisingData`, `ManufacturerData` and `ServiceData` are *caches* of the last advertisement BlueZ processed. On a paired+trusted phone every one of them stayed byte-identical for minutes while the phone sat next to the laptop.
- **Some phones drop BR/EDR while still broadcasting BLE advertisements.** This is the "fast sleep" pattern: BR/EDR idles or suspends to save power, but the BLE radio keeps sending advertisements. The plugin therefore treats the RSSI value — refreshed by the helper on every advertisement — as the primary signal and the BR/EDR ACL as a bonus.
- **Auto-unlock bypasses PAM.** When the patch is installed, the plugin can drop the lock UI without a password after `unlockStableMs` of stable presence. Equivalent to macOS / Windows smart-unlock — a relay attacker within BLE range could trigger it. Auto-unlock only fires for locks this plugin triggered (manual locks via `omarchy-system-lock` keybind are left alone). `autoLockSource` is per-lock state.
- **No `hyprlock` / `swaylock` fallback.** Omarchy uses Quickshell's `WlSessionLock`. If you replace that, this plugin's lock call will silently lock you out of the lock UI.
- **Idle threshold is hardcoded to 30 s.** Same grace/abort UX as the built-in idle service, but stricter.

## troubleshooting

**"Phone out of range" keeps showing up while the phone is right next to the laptop.**

That was the BlueZ 8 dBm publishing threshold plus the phone's burst advertising: the value froze at −45 dBm, the chart stopped moving, and the old code read "no fresh reading" as "the phone is gone". The current code decides on the **value** and never declares a phone lost on a stale reading. Check what the plugin sees now:

```
omarchy-shell bleguard.ctrl status | python3 -m json.tool | grep -E '"rssi"|presence|helper'
```

- `rssiSource: "helper"` and `helperReady: true` → the heartbeat works.
- `helperRestarts` climbing → the helper keeps dying (BlueZ restart, missing `python3-gobject`); `helperError` says why.
- `presenceLevel: "rssi-stale"` → the phone is quiet right now; `rssiAgeMs` tells you for how long. The last known value is still driving the decision.

**The laptop locks but never unlocks when I come back with the phone.**

1. Check the unlock IPC — it is the usual culprit, because the plugin needs an `unlock` method on Omarchy's lock plugin:
   ```
   qs -p /usr/share/omarchy/shell ipc call lock unlock
   ```
   `Function not found.` means the patch is missing → `sudo bash patches/install-lock-unlock-ipc.sh && omarchy restart shell`.
2. Check which channel is proving presence:
   ```
   omarchy-shell bleguard.ctrl status | python3 -m json.tool | grep -E '"presence"|unlock'
   ```
   - `presenceLevel: "none"` → the plugin sees no sign of the phone at all.
   - `presenceLevel: "acl"` → the link is up and the phone counts as present; if the unlock still doesn't happen, look at `unlockResult`.
   - `phonePresent: false` → the phone is not close enough yet (or the reading is stale, and a stale reading never unlocks).
3. `unlockResult: "Function not found."` → patch missing (step 1). Any other value → the lock plugin rejected the request.

**The plugin locks the laptop while the phone is lying next to it.**

Only if the *value* says so: the last RSSI was below the threshold. Lower the threshold (for example −90) or check `rssi` in the status output — a phone on the desk usually reads −35..−50 dBm.

## development

Unit tests for the presence logic (the mirror of `Service.qml`'s `phoneLost()`):

```
node --test test/ble-logic.test.js
```

`qmllint` is not enough on its own: it does not catch **duplicate property names**, which is a QML *runtime* error — the widget then silently refuses to load and the panel just never opens. After changing `Panel.qml` or `Service.qml`, reload the shell and check that the widget actually loaded:

```
./install.sh --force && omarchy restart shell
journalctl --user --since "1 min ago" | grep -i "bleguard failed"
```

No output means the widget loaded. `Plugin widget bleguard failed: ...: Duplicate property name` means it did not.

Debug logs:

```
tail -f /run/user/1000/quickshell/by-id/$(ls -t /run/user/1000/quickshell/by-id/ | head -1)/log.qslog | grep -i bleguard
```

Inspect the live signals for the paired phone:

```
busctl get-property org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1 RSSI
busctl get-property org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1 AdvertisingFlags
busctl get-property org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1 Connected
```

Diagnostic dump (also reachable via the popup chart footer):

```
omarchy-shell bleguard.ctrl status | python3 -m json.tool
```

Validate the manifest:

```
omarchy plugin validate bleguard/
```

## license

MIT.
