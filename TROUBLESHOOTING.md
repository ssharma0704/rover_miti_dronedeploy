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

### `can.service` failed, and `rovercan` does not exist

Usually correct behaviour, not a bug: the USB-CAN adapter is not plugged in.
`enablecan` says so explicitly — `no 1d50:606f adapter found on the USB bus to
reset`.

The Jetson AGX Orin has **two native CAN controllers**, so a bare `canN` name is
a coin flip — see the `rovercan` note in the README. `60-rover-can.rules` binds
the adapter to `rovercan` by VID:PID, and `miti_config.yaml` expects that name,
**not `can2`**. If you are reading `can2` anywhere outside a historical note,
that reference predates `9661553` and is wrong.

```bash
ip -brief link show type can
lsusb | grep -iE "canable|gs_usb"     # want 1d50:606f
lsmod | grep gs_usb
```

If the adapter is present but no `rovercan` appears, confirm `gs_usb` is loaded
(`/etc/modules-load.d/gs_usb.conf`), confirm the udev rule is installed, and
reboot. Override the name with `--can`.

Expect `can.service` to sit in `activating` and retry every 10 s while the
adapter is absent — that is `StartLimitIntervalSec=0` doing its job, so the link
comes up on its own whenever the adapter is plugged in. Verified: plugging the
adapter into a running rover brought `rovercan` up and the driver connected
within ~2 s, with no intervention.

---

### `roverrobotics.service` restart-loops, and the only clue is the IMU

Since `a91464f` the BNO055 node carries `on_exit=Shutdown()`. If the IMU cannot
be opened, the node exits, the **whole launch tears down**, and systemd restarts
the unit every 5 s — so a missing IMU presents as the *driver* failing, not as a
missing `/imu/data`.

**First: the node named in the last error is usually NOT the cause.** Because
`on_exit=Shutdown()` tears the whole launch down, one node's death kills the
rest, and the journal tail shows them all dying together. Read from the *top* of
a single cycle and take the first failure:

```bash
journalctl -u roverrobotics.service --no-pager -n 400 \
  | grep -E "Started Rover|FATAL|ERROR|died|was required|Scheduled restart"
```

**The exit code settles it:**

| Exit code | Meaning |
|---|---|
| **−2** | Collateral SIGINT — this node was killed by the teardown. A victim. Ignore it. |
| **1** | The node's own error. This is your cause. |

A node dying with `KeyboardInterrupt` inside a Python import is always a victim,
never a cause, however alarming the traceback looks.

```bash
ls -l /dev/bno055          # symlink to ttyUSB*, from 55-roverrobotics.rules
lsusb | grep 0403:6014     # the FT232H bridge
```

Then match the first failure:

1. **`roverrobotics_driver … FATAL: Did not receive any data from the robot`** —
   the CAN adapter is missing or the bus is silent. The IMU is fine; its
   traceback is collateral. See the `can.service` entries above.
2. **The rover has a BNO055 and it is unplugged, or the udev rule is missing.**
   Reconnect it / reinstall `55-roverrobotics.rules`.
   **Reconnecting may not be enough on its own — see the next section.**
3. **The rover has no BNO055 at all.** Then `active: true` under `bno055` in
   `accessories.yaml` is simply wrong for that machine — set it to `false`.
   Leaving it enabled with no hardware is a *guaranteed* permanent restart loop,
   and the rover will not drive.

---

### The loop continues *after* you reconnect the hardware

`bno055 … Communication error: Payload length mismatch detected: received=1,
awaited=45`, **exit code 1**.

This is the failure mode that wastes the most time, because the obvious fix
looks like it should have worked and didn't.

Every teardown kills the `bno055` node mid-transaction, leaving unread bytes in
the FT232H. The next start reads those stale bytes, fails, and triggers another
teardown. **After enough cycles the loop no longer has anything to do with
whatever started it** — one rover looped ~150 times from a missing CAN adapter,
and plugging the adapter in did not recover it.

Since `reset_bno055_usb.sh` exists this should self-clear, because the
`ExecStartPre` flushes the port before each start. If you are on an older
machine, or want to break it by hand:

```bash
sudo systemctl stop roverrobotics.service
sudo /usr/local/sbin/reset_bno055_usb.sh     # flush; power-cycles only if needed
sudo systemctl start roverrobotics.service
```

**Verify with `NRestarts`, not `is-active`.** A looping unit reads `active` for
a second or two of every cycle, so `is-active` will happily tell you it is fine:

```bash
systemctl show -p NRestarts --value roverrobotics.service   # sample twice, ~60s apart
```

Frozen means fixed. Climbing means still looping.

**A fast cross-check from the CAN side:** continuous Rx with only intermittent
Tx means the bus and the VESCs are healthy and the *driver's lifetime* is the
problem — it only transmits during the ~2 s it is alive each cycle. Healthy is
`0x101`–`0x104` sustained at ~60 Hz.

---

### The IMU keeps re-enumerating — `USB disconnect` every few seconds

```
usb 1-4.1: USB disconnect, device number 78
usb 1-4.1: new high-speed USB device number 79 using tegra-xusb
usb 1-4.1: Detected FT232H
```

**This is hardware, and no software change will fix it.** Distinguish it from
the desync above, because *both produce the same `Payload length mismatch` in
the ROS log* — every re-enumeration severs the serial link mid-read. Above the
kernel they are indistinguishable.

`dmesg` is the discriminator:

```bash
sudo dmesg | grep -cE "usb .*disconnect"       # healthy: 0 spontaneous
sudo dmesg | grep -E "Detected FT232H"         # healthy: once, at boot
```

A healthy machine enumerates the bridge **once** and its device number never
changes. Climbing device numbers mean the bridge is dropping off the bus. Look
at the cable, the connector (rovers vibrate), port power, a powered hub, or a
failing FT232H board. A disconnect immediately followed by `authorized to
connect` is somebody's deliberate reset, not a fault.

This is a deliberate trade, not a regression: before the change a dead IMU left
the unit reporting `active` with `NRestarts=0` while `/imu/data` was silent.
Loud beats invisible — but it does mean the IMU is now load-bearing for driving.

---

### The camera publishes nothing, but every indicator says it is fine

`systemctl is-active rover-realsense.service` says `active`, `NRestarts=0`, the
node logged `RealSense Node Is Up!`, the topics are listed — and no frames ever
arrive. Nothing in the journal is an error.

systemd cannot see this. The node stays alive while publishing nothing, so the
main process never exits and `Restart=always` never fires. **Judge the topic,
not the unit:**

```bash
ros2 topic hz /camera/camera/color/image_raw     # the only answer that counts
```

Do **not** use `ros2 topic list` to decide whether the camera is alive — see the
daemon entry below; it reports nothing while the camera streams at 28 Hz.

Two things address this:

* `ExecStartPre=/bin/sleep 20` in `rover-realsense.service` is the actual fix.
  Started immediately after boot the node opens a D435 that is not ready yet and
  never recovers. With the delay, topics are live ~45s after boot.
* `realsense-watchdog.timer` is the backstop, checking every 20s that frames are
  actually arriving and restarting the unit if not. It should normally never
  fire; if it is firing every boot, the delay above is missing or too short.

`systemctl restart rover-realsense` always clears it by hand.

### `ros2 topic list` shows nothing, or dies with `!rclpy.ok()`

```
xmlrpc.client.Fault: <Fault 1: "<class 'RuntimeError'>:!rclpy.ok()">
```

The ros2 CLI daemon has wedged. The robot is almost certainly fine — confirm
with `ros2 topic hz` on a known topic, which does not use the daemon.

```bash
pkill -KILL -f '[r]os2cli'      # SIGTERM does not shift a wedged one
```

The bracket around the first letter matters: `pkill -f ros2cli` run over SSH
matches its own command line and kills your shell instead.

A second cause is an RMW split. `~/.bashrc` exports `RMW_IMPLEMENTATION` but
Ubuntu's `.bashrc` returns early for non-interactive shells, so scripts and
`ssh host 'ros2 ...'` get the FastDDS default while an interactive login gets
CycloneDDS. Each spawns its own daemon and they disagree about what exists. The
provisioner now also writes both `RMW_IMPLEMENTATION` and `ROS_DOMAIN_ID` to
`/etc/environment`, which PAM applies to every session. Check with:

```bash
ssh rover@<ip> 'echo $RMW_IMPLEMENTATION'        # must not be empty
ps -eo pid,stat,cmd | grep ros2cli.daemon        # shows the rmw it started with
```

### `rover-realsense.service` starts then immediately fails

Two prerequisites, both easy to miss because the unit file alone doesn't reveal
them:

1. `ExecStartPre=/usr/bin/sudo -n /usr/local/sbin/reset_realsense_usb.sh` needs a
   NOPASSWD sudoers entry — `/etc/sudoers.d/rover-realsense`
2. `Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` needs
   `ros-humble-rmw-cyclonedds-cpp` installed

Both are handled by the script. Diagnose with `journalctl -xeu rover-realsense`.

---

### The gamepad connects but the rover drives wrong, or not at all

`joy_node` logs `Opened joystick: /dev/input/js0`, `/joy` publishes, `/cmd_vel`
looks alive — and the rover still misbehaves. Nothing in the logs is red,
because at this layer nothing *is* wrong: the axis indices are.

Since `77e36c1`, `miti_teleop.launch.py` includes **`ps5_controller.launch.py`**
(PS5 / DualSense), not `ps4_controller.launch.py`. Two ways that bites:

1. **You are holding a PS4 pad.** Point `miti_teleop.launch.py` back at
   `/ps4_controller.launch.py`. All the launch files and configs are installed.
2. **PS5 pad, wrong map.** `ps5_controller.launch.py` loads
   `ps5_controller_config_jp6.yaml`, and it must. The JetPack 6 kernel
   enumerates the DualSense axes differently from the stock map:

   | Control | stock `ps5_controller_config.yaml` | `_jp6` (correct on JP6) |
   |---|---|---|
   | Right stick horizontal | 3 | **2** |
   | Right stick vertical | 4 | **5** |
   | Right trigger | 5 | **4** |
   | Left trigger | 2 | **3** |
   | Button A | 0 | **1** |

Check what the kernel actually reports before editing a map:

```bash
ros2 topic echo /joy          # move one stick at a time, watch which index changes
jstest /dev/input/js0         # or, without ROS
```

A warning you can ignore: `Couldn't open joystick force feedback: Bad file
descriptor`. Rumble is unavailable; input works fine.

---

### Re-provision dies at step 10: `could not read Username for 'https://github.com'`

```
roverrobotics_ros2 already present -> fetching branch 'humble'
fatal: could not read Username for 'https://github.com': No such device or address
error: Could not fetch origin
=== PROVISION END ... EXIT_CODE=1 ===
```

The first run cloned in **token** mode, and the token was then stripped out of
`.git/config` — correct, but it left `origin` as a bare HTTPS URL that cannot
authenticate. Every later run then died here, even on a machine whose
`--bootstrap-auth` deploy keys were working perfectly.

Fixed: `origin` is now pointed at the per-repo deploy key after a token clone,
and a failed fetch re-points and retries instead of aborting the provision. You
should see:

```
  re-pointed origin to a credential this machine holds
```

To repair a machine provisioned before the fix, or by hand:

```bash
cd ~/rover_workspace/src/roverrobotics_ros2
git remote set-url origin git@github.com:<owner>/roverrobotics_ros2.git
git fetch --all --prune          # works via the deploy key + insteadOf rewrite
```

Confirm no token is left behind — `git remote get-url origin` must not contain
`x-access-token`.

---

### Firefox is "installed" but will not start

```
snap-confine is packaged without necessary permissions and cannot continue
required permitted capability cap_dac_override not found in current capabilities
```

**Do not `snap install firefox`, and do not trust `command -v firefox`.**

The Jetson's L4T kernel has no AppArmor module, which snapd requires, so *no*
snap can run — check with `cat /sys/module/apparmor/parameters/enabled`
(absent = no AppArmor) or `snap run --shell <any-snap>`, which fails the same
way. The misleading part is that `getcap /usr/lib/snapd/snap-confine` shows
`cap_dac_override` **present** and the rootfs is not `nosuid`, so reinstalling
snapd or re-running `setcap` accomplishes nothing.

Ubuntu's arm64 `firefox` package is only a transitional shim to that snap, so
the binary exists whether or not a browser does. **Test by running it:**

```bash
firefox --version | grep -qi "^Mozilla Firefox" && echo OK
```

Install the real Mozilla arm64 deb:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
     -o /etc/apt/keyrings/packages.mozilla.org.asc      # fpr 35BAA0B3…DC6315A3
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  | sudo tee /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
  | sudo tee /etc/apt/preferences.d/mozilla
sudo apt-get update && sudo apt-get install -y --allow-downgrades firefox
sudo snap remove --purge firefox          # works even though snaps cannot run
```

`--allow-downgrades` is **required**: Ubuntu's shim carries an epoch
(`1:1snap1-0ubuntu2`) that outranks Mozilla's bare `153.x~build1`, so apt reads
the real browser as a downgrade and refuses under plain `-y`. The repo serves an
uncompressed `Packages` index for arm64 — a 404 on `Packages.gz` does not mean
arm64 is unsupported.

---

### SSH fails after reflashing a machine that keeps its IP

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
scp: Connection closed
[provision] copy failed
```

A reflashed machine generates a new host key. `provision_rover_remote.sh` then
fails at the copy step before anything starts.

```bash
ssh-keygen -f ~/.ssh/known_hosts -R <rover-ip>
```

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
