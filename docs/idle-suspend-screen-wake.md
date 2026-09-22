# The "Automatic Suspend" warning wakes the screen it was meant to warn about

**Symptom:** the session goes idle, the screen blanks and locks, and immediately
afterwards the panel powers back on to show an `Automatic Suspend — Suspending
soon because of inactivity` notification. If nobody is there it goes dark again
15 seconds later. If somebody is, the machine has just invited them back to
cancel the suspend it promised — and the suspend it promised is another 15
minutes away.

**Versions this was traced against:** `gnome-settings-daemon-50.1-1.fc44`,
`gnome-shell-50.4-1.fc44`, `mutter-50.4-1.fc44`.

---

## The timings actually in effect

Read from the user dconf database, not from `gsettings` — see the note at the
end of this file about why that distinction matters here.

| Setting | Value | Source |
|---|---|---|
| `org.gnome.desktop.session idle-delay` | 900 s (15 min) | user |
| `…power sleep-inactive-ac-timeout` | 1800 s (30 min) | user |
| `…power sleep-inactive-battery-timeout` | 900 s (15 min) | user |
| `…power sleep-inactive-{ac,battery}-type` | `suspend` | schema default |
| `org.gnome.desktop.screensaver lock-enabled` / `lock-delay` | `true` / 0 | schema default |
| `org.gnome.desktop.notifications show-banners` | `true` | schema default |

gsd-power does not give the sleep warning a fixed lead time. `idle_configure()`
in `plugins/power/gsd-power-manager.c` schedules it at a *fraction* of the sleep
timeout:

```c
timeout_sleep_warning_msec = timeout_sleep * IDLE_DELAY_TO_IDLE_DIM_MULTIPLIER * 1000;
```

and `gsd-power-constants.h` defines `IDLE_DELAY_TO_IDLE_DIM_MULTIPLIER` as
`1.0/2.0`. There is no relation to `idle-delay` at all. So:

- **On AC:** blank/lock at 900 s, warning at `1800 / 2` = **900 s**, suspend at
  1800 s. The blank and the warning land on the *same* idle second — a race —
  and the warning is a full 15 minutes early for the suspend it announces.
- **On battery:** blank/lock at 900 s, warning at `900 / 2` = 450 s (before the
  blank, which is how it is meant to work), suspend at 900 s.

The AC case is the reported one. Whenever the blank wins that 900-second race,
the warning is delivered to a screen that has just gone dark and locked, and
GNOME Shell powers the panel back on to show it.

---

## Root cause chain

1. **The screen goes dark at `idle-delay`.** GNOME Shell activates the lock
   screen; gsd-power's `handle_screensaver_active()` reacts to
   `org.gnome.ScreenSaver.ActiveChanged` with
   `idle_set_mode (GSD_POWER_IDLE_MODE_BLANK)` → `disable_monitors()` →
   `PowerSaveMode = OFF` on `org.gnome.Mutter.DisplayConfig`. The panel is off.

2. **`show_sleep_warning()` posts the warning as a system notification.**
   Urgency `CRITICAL`, timeout `NOTIFY_EXPIRES_NEVER`, hint
   `x-gnome-privacy-scope=system`, hint `desktop-entry=gnome-power-panel`. That
   last hint is set by gsd-power's `create_notification()` for *every*
   notification the power plugin posts, not just this one.

3. **The lock screen deliberately wakes the panel for it.** In
   `js/ui/unlockDialog.js`, `NotificationsBox._sourceAdded()` (when not
   `initial`) and `_countChanged()` both end with
   `_wakeUpScreenForSource(source)`:

   ```js
   _wakeUpScreenForSource(source) {
       if (!this._settings.get_boolean('show-banners'))
           return;
       const obj = this._sources.get(source);
       if (obj?.sourceBox.visible)
           this.emit('wake-up-screen');
   }
   ```

   `obj.visible` is `source.policy.showInLockScreen` and `obj.sourceBox.visible`
   is `obj.visible && source.unseenCount > 0`. The signal is forwarded by
   `ScreenShield._wakeUpScreen()` and re-emitted on the bus as
   `org.gnome.ScreenSaver.WakeUpScreen` by `ScreenSaverDBus` in
   `js/ui/shellDBus.js`.

   (This is also why the race matters: if the warning arrives *before* the lock
   screen exists, `NotificationsBox` picks it up in its constructor with
   `initial = true`, which skips the wake-up.)

4. **gsd-power answers by un-idling for 15 seconds.**
   `screensaver_signal_cb()` → `handle_wake_up_screen()` →
   `update_temporary_unidle_on_ac()`. `should_set_temporary_unidle_on_ac()`
   returns true whenever the lid is open, the session is active and the current
   idle mode is `BLANK` or `DIM` — despite the name it does **not** check
   whether the machine is on AC, so this happens on battery too. Then
   `set_temporary_unidle_on_ac (TRUE)` records `previous_idle_mode = BLANK`,
   calls `idle_set_mode (GSD_POWER_IDLE_MODE_NORMAL)` → `enable_monitors()` —
   the panel comes back on — and arms a `POWER_UP_TIME_ON_AC` (15 s) timer whose
   `temporary_unidle_done_cb()` restores `BLANK`.

## What this does *not* do: cancel the suspend

Nothing in that chain resets mutter's idle time. `ScreenShield._wakeUpScreen()`
calls `_onUserBecameActive()`, which on an already-locked shield only calls
`lightOff()` on the two lightboxes; `meta_idle_manager_reset_idle_time()` is
never reached. The `idle_sleep_id` watch stays armed for 1800 s, and
`idle_set_mode_no_temp()` only defers a `SLEEP` transition while the 15-second
unidle window is open — that window closes at 915 s, long before 1800 s.

So the suspend should still arrive, just 15 minutes after the warning claimed it
was imminent. If it does not arrive at all, the likely reason is the ordinary
one: the panel lighting up draws a person back to the machine, and real input
resets the idle timer through `idle_became_active_cb()`. Verify with the
procedure below rather than assuming.

---

## Fix applied

`files/rootfs/etc/dconf/db/local.d/10-fromelicks-power-notifications` declines
lock-screen notifications for `gnome-power-panel`:

```ini
[org/gnome/desktop/notifications/application/gnome-power-panel]
show-in-lock-screen=false
```

Step 3 is the only configurable gate in the chain, and
`NotificationApplicationPolicy.showInLockScreen` ANDs the master setting with
this per-application one, so this is enough: `obj.sourceBox.visible` is false,
no `wake-up-screen` is emitted, no `WakeUpScreen` reaches gsd-power, the panel
stays off. The banner is unchanged while the screen is on, and no other
application's notifications are touched. It also holds whichever way the
900-second race goes, which a timing change would not.

**Trade-off:** gsd-power's battery notifications share the same
`desktop-entry`, so `Battery Low` / `Battery Critically Low` no longer appear on
the lock screen either. They still appear while the screen is on, and the
critical-battery *action* (`sleep-inactive-*-type`, and the separate
critical-battery handling) is unaffected.

### Two mechanism gotchas

1. **A gschema override cannot do this.**
   `org.gnome.desktop.notifications.application` is a relocatable schema.
   `glib-compile-schemas --strict` accepts

   ```ini
   [org.gnome.desktop.notifications.application:/org/gnome/desktop/notifications/application/gnome-power-panel/]
   show-in-lock-screen=false
   ```

   without a word of complaint and then ignores it — verified on
   `glib2-2.88.3`: a plain `[org.gnome.desktop.notifications]` stanza in the
   same file takes effect while this one does not. Anything keyed by a dconf
   *path* rather than a schema id has to go through a dconf system database.

2. **The keyfile alone does nothing.** GSettings reads the compiled binary
   `/etc/dconf/db/local`, not `local.d/`. The base image ships an empty one and
   the `files` module cannot compile it, so `files/scripts/compile-dconf-db.sh`
   runs `dconf compile` at build time and reads every key back afterwards —
   dconf knows nothing about schemas, so a mistyped path would otherwise compile
   cleanly and silently do nothing. `/etc/dconf/profile/user` already lists
   `system-db:local` in the base image; the script asserts that too.

`application-children` is deliberately *not* set here. GNOME Shell's
`NotificationApplicationPolicy.store()` adds `gnome-power-panel` to the user
database by itself the first time gsd-power posts anything, so a system default
for it would only ever be shadowed.

---

## Verification

After `run0 bootc upgrade` and a reboot:

```sh
dconf read /org/gnome/desktop/notifications/application/gnome-power-panel/show-in-lock-screen
# expect: false, and nothing for this key under `dconf dump /org/gnome/desktop/notifications/`
# (a user-db value would shadow the system default)
```

To watch the behaviour without waiting half an hour, shorten the two timeouts,
observe, then put them back:

```sh
gsettings set org.gnome.desktop.session idle-delay 20
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 40
```

That reproduces the real relationship — blank at 20 s, warning at `40 / 2` = 20 s,
suspend at 40 s. Leave the keyboard, touchpad and mouse alone and watch the
panel: before the fix it lights back up right after blanking, after it stays
dark until the machine suspends. A Bluetooth mouse on the desk can generate
input on its own and reset the idle timer — power it off for the test (see
[`bt-mouse-reconnect.md`](bt-mouse-reconnect.md)).

Restore afterwards:

```sh
gsettings reset org.gnome.desktop.session idle-delay
gsettings reset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout
```

`reset`, not `set` back to the old numbers: both keys were user-database values
(900 and 1800), so `reset` drops them to the schema defaults (300 and 900) —
re-set them explicitly afterwards if the 15/30-minute pair is wanted back.

---

## Alternative considered: move the warning before the blank

Because the warning is pinned to `sleep_timeout / 2`, it lands before the blank
whenever `sleep_timeout < 2 × idle-delay`. On AC the two are currently *equal*
(1800 and 2 × 900), which is the one arrangement that turns it into a coin
flip. Lowering the AC suspend timeout below 1800 s, or raising `idle-delay`
above 900 s, would put the warning back on a screen that is still on.

This keeps battery warnings on the lock screen and needs no dconf database, but
it welds two independent preferences together — change either one and the bug
returns, silently — and it does not help the battery profile, where
`sleep-inactive-battery-timeout` (900) is already below `2 × idle-delay`. The
per-application policy was preferred for being independent of both timeouts.

---

## Note on reading these settings

`gsettings get` cannot be trusted from inside a restricted environment with no
session bus: with the dconf backend unable to initialise it silently falls back
to the compiled *schema default* and prints that. That is what happened during
this investigation — `gsettings` reported `idle-delay 300` /
`sleep-inactive-ac-timeout 900` (the schema defaults) where the live values were
900 / 1800. `dconf read` and `dconf dump` go at the gvdb files directly and stay
correct.

## Upstream

The same symptom is reported against Ubuntu's gnome-shell as
[bug #1888983](https://bugs.launchpad.net/bugs/1888983), *"Suspend notification
wakes external monitor"*, and the notification's refusal to expire shows up in
[bug #1766775](https://bugs.launchpad.net/bugs/1766775). Neither is fixed
upstream; `show_sleep_warnings` is only ever set false for a `tablet` or
`handset` chassis, so there is no setting that turns the warning itself off on a
laptop.
