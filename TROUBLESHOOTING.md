# Troubleshooting

Failure modes actually hit while bringing up a Jetson AGX Orin, indexed by the
error text you'll see. Every entry below was observed on real hardware.

---

### `TERM environment variable not set.` — exits immediately

Running the script detached (`nohup`, `setsid`, systemd, CI) with no TTY. `clear`
fails and `set -e` aborts before anything happens.

**Fixed in-script.** If you see this, your copy predates the fix — re-pull.

---

### `sudo: a terminal is required to read the password` — even with NOPASSWD

`sudo -v` *always* attempts to validate credentials, so it needs a TTY **even
when `NOPASSWD: ALL` is in effect**. `sudo -n true` is the correct capability
check; `sudo -v` is not.

**Fix:** run via `provision_rover_remote.sh`, which grants NOPASSWD for the run
and removes it on every exit path. Or run the script from a real terminal.

---

### `E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process N`

Ubuntu's `apt-daily` / `unattended-upgrades` timers race you for the dpkg lock on
a fresh machine. Killed a run ~10 minutes in.

**Fixed in-script** — all apt calls wait the lock out (up to 15 min) and retry
once. To confirm who holds it:

```bash
sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
systemctl list-timers | grep -i apt
```

---

### `FATAL: No GitHub credentials available` — but SSH to GitHub works fine

Two distinct causes, and they look identical:

**1. The machine genuinely has no access.** Run with `--bootstrap-auth` and a
`GITHUB_TOKEN`. Verify with:

```bash
git ls-remote --heads git@github.com:<owner>/roverrobotics_ros2.git
```

**2. `pipefail`.** `ssh -T git@github.com` **always exits 1** — GitHub refuses
shell access even on success. Piping it into `grep` under `set -o pipefail` fails
the pipeline regardless of whether the match succeeded. Capture the output to a
variable and inspect it separately.

This one is nasty because testing the probe by hand *without* `pipefail`
"confirms" it works. Reproduce the real behaviour:

```bash
bash -c 'set -o pipefail; ssh -T git@github.com 2>&1 | grep -q "successfully authenticated" \
  && echo detected || echo "NOT detected"'
```

---

### `key is already in use` when registering a deploy key

GitHub deploy keys are **unique across all repositories**. One key cannot serve
both `roverrobotics_ros2` and `web_video_server`.

**Fix:** one key per repo, bound with an SSH `Host` alias plus a git `insteadOf`
rewrite so plain `git@github.com:owner/repo` URLs still work. `--bootstrap-auth`
does this. Re-running on a configured machine is a safe no-op.

---

### `can.service` failed, `restart counter is at 2694`

`Restart=on-failure` with no `RestartSec` retries every ~100 ms forever. With the
USB-CAN adapter unplugged this is a restart storm that burns CPU and floods the
journal.

**Fixed in-script:** `RestartSec=10` plus a start limit. Note
`StartLimitIntervalSec` / `StartLimitBurst` belong in **`[Unit]`** — modern
systemd silently ignores them in `[Service]`.

```bash
systemctl show can.service -p NRestarts
sudo systemctl reset-failed can.service     # clear a stuck counter
```

---

### `can.service` failed, and `can2` does not exist

Usually correct behaviour, not a bug: the USB-CAN adapter is not plugged in.

The Jetson AGX Orin has **two native CAN controllers** that claim `can0` and
`can1`, so the USB adapter enumerates as `can2` — which is what `miti_config.yaml`
expects. Check:

```bash
ip -brief link show type can
lsusb | grep -iE "canable|gs_usb"
lsmod | grep gs_usb
```

If the adapter is present but no `can2` appears, confirm `gs_usb` is loaded
(`/etc/modules-load.d/gs_usb.conf`) and reboot. Override the name with `--can`.

---

### `rover-realsense.service` starts then immediately fails

Two prerequisites, both easy to miss because the unit file alone doesn't reveal
them:

1. `ExecStartPre=/usr/bin/sudo -n /usr/local/sbin/reset_realsense_usb.sh` needs a
   NOPASSWD sudoers entry — `/etc/sudoers.d/rover-realsense`
2. `Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` needs
   `ros-humble-rmw-cyclonedds-cpp` installed

Both are handled by the script. Diagnose with `journalctl -xeu rover-realsense`.

---

### `rosdep reported unresolved dependencies`

Expected. `ros-gz-bridge` / `ros-gz-sim` have no Humble arm64 build. They're only
needed by `roverrobotics_gazebo`, which builds fine anyway and isn't used on the
robot. Not a failure.

---

### A remote poll says "still running" forever

Watch out for this when writing your own monitoring:

```bash
pgrep -f setup_rover_miti_dronedeploy      # matches its own command line!
```

The pattern appears in the polling command's own `ps` entry, so the check never
goes false. Cost me two false "still running" readings on a run that had already
finished successfully. Watch for a completion marker in the log instead:

```bash
tail -f ~/provision.log | sed -u '/=== PROVISION END /q'
```

---

## Useful commands

```bash
# What step is it on?
grep -E '^===== \[' ~/provision.log

# Warnings and fatals only
sed 's/\x1b\[[0-9;]*m//g' ~/provision.log | grep -E 'WARNING:|FATAL:'

# Build result
grep -E 'Finished <<<|Failed  <<<|build succeeded|build FAILED' ~/provision.log

# Confirm the patches are actually in the built tree
grep -n 'use_cbr_' ~/rover_workspace/src/web_video_server/src/streamers/h264_streamer.cpp
grep -n 'battery_voltage_multiplier' \
  ~/rover_workspace/src/roverrobotics_ros2/roverrobotics_driver/src/roverrobotics_ros2_driver.cpp

# No leftover provisioning sudo rights
ls -l /etc/sudoers.d/99-rover-provisioning   # should be absent
```
