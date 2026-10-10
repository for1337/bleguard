# leo.bleguard

I kept walking away from my desk for ten minutes and coming back to find my laptop unlocked and the dog asleep on the keyboard. The screen lock from the idle service is fine when I leave it on the desk; I wanted something stricter — "if my phone isn't next to the laptop, lock". This is a small Omarchy plugin that watches the BLE link to a paired phone, waits for a 30 s input idle, and locks via `omarchy-system-lock`.

![screenshot placeholder](screenshots/popup.png)

## what it does

Polls `org.bluez.Device1.RSSI` over D-Bus every 5 s for the phone you picked in the popup, and the Wayland `ext-idle-notify-v1` seat-idle counter (30 s threshold). If the phone goes out of range — disconnect, RSSI stale for >15 s, or RSSI below the threshold (default −85 dBm) — a 10 s grace timer starts and a notification is posted. If you're still idle when the grace expires, `omarchy-system-lock` runs and the lock UI takes over. If the phone comes back into range during the grace window, the warning clears. State (target MAC, armed flag, threshold) persists in `~/.local/state/omarchy/bleguard-state.json` so it survives shell restarts.

State machine: `DISARMED → ARMED → WARNING → WAITING → LOCKING → LOCKED → ARMED` (after manual unlock).

## requirements

- Omarchy shell. `omarchy`, `omarchy-shell`, `omarchy bar move` on `$PATH`.
- `bluez` — `sudo systemctl enable --now bluetooth` if it isn't already running.
- `busctl` (from `systemd`) — used to read `org.bluez.Device1.RSSI`. On Arch this ships with `systemd`.
- `jq` — only required if you use `./install.sh --enable` (the script edits `shell.json` for you).
- `omarchy-system-lock` on `$PATH` — installed by Omarchy by default. The plugin will *not* fall back to `hyprlock` / `swaylock` / `loginctl lock-session` because none of those give you the lock UI on this setup.

## install

```
git clone https://github.com/for1337/leo-bleguard.git
cd leo-bleguard
./install.sh --enable
```

`install.sh` symlinks `leo.bleguard/` into `~/.config/omarchy/plugins/`, adds the plugin to `~/.config/omarchy/shell.json`, and asks Omarchy to place the bar widget in the right section. Re-run with `--force` if a previous install left a real folder at the target. `uninstall.sh` is the inverse (`--purge` also deletes the state file).

```
omarchy restart shell
```

## using it

Click the bar widget — first launch shows the device picker (only currently-paired BLE devices). Pick your phone. From then on the bar icon shows the state: shield (armed), warning (phone out), lock (locked), shield-off (disarmed). The popup has an `armed` toggle, RSSI bars, and a `Lock now` button for testing.

Hand-edit the state file and `omarchy restart shell` — the service hydrates from disk on startup.

IPC:

```
omarchy-shell leo.bleguard status   # JSON: state, rssi, idle, threshold
omarchy-shell leo.bleguard arm
omarchy-shell leo.bleguard disarm
omarchy-shell leo.bleguard lockNow
omarchy-shell leo.bleguard setTarget <MAC>   # programmatic pairing
```

## quirks

- **RSSI is polled, not pushed.** BlueZ does not emit `PropertiesChanged` for `RSSI`; the plugin shells out to `busctl get-property` every 5 s. Sub-second polling is wasted.
- **Phone must be paired, not just discoverable.** The picker only lists devices the system already knows (`bluetoothctl devices Paired`). If your phone isn't there, pair it first.
- **Unlock is always manual.** The plugin locks when the phone goes away but does *not* unlock when it comes back — that's left to you, on purpose. Don't want your laptop unlocking when you walk past it.
- **No `hyprlock` / `swaylock` fallback.** Omarchy uses Quickshell's `WlSessionLock`. If you replace that, this plugin's lock call will silently lock you out of the lock UI.
- **Idle threshold is hardcoded to 30 s.** Same grace/abort UX as the built-in idle service, but stricter.
- **RSSI threshold is hardcoded to −85 dBm.** Editable per-VM via the state file (`rssiThreshold`), but not exposed in the popup yet.

## development

Debug logs:

```
tail -f /run/user/1000/quickshell/by-id/$(ls -t /run/user/1000/quickshell/by-id/ | head -1)/log.qslog | grep -i bleguard
```

Inspect RSSI manually:

```
busctl get-property org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1 RSSI
```

Validate the manifest:

```
omarchy plugin validate leo.bleguard/
```

## license

MIT.