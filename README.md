# Rover MITI — DroneDeploy provisioning

One-shot provisioning for the MITI rover computers used on the DroneDeploy
deployment. Takes a **bare Jetson** to a fully built, service-enabled rover.

Verified end-to-end on a Jetson AGX Orin Developer Kit (JetPack 6 / L4T R36.4.7,
Ubuntu 22.04 jammy, ROS 2 Humble).

| Script | Purpose |
|---|---|
| `setup_rover_miti_dronedeploy.sh` | Provisions **the machine it runs on**. |
| `provision_rover_remote.sh` | Provisions **other machines over SSH**. Use for a fleet. |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | Failure modes indexed by error text, all seen on real hardware. |

---

## Quick start

### On the rover itself

```bash
wget https://raw.githubusercontent.com/ssharma0704/rover_miti_dronedeploy/main/setup_rover_miti_dronedeploy.sh
chmod +x setup_rover_miti_dronedeploy.sh

# One-time: let this machine register its own read-only deploy keys.
export GITHUB_TOKEN=<PAT with 'repo' scope>

./setup_rover_miti_dronedeploy.sh --bootstrap-auth
```

Re-running later needs no token — the machine keeps its own deploy keys:

```bash
./setup_rover_miti_dronedeploy.sh
```

### From your workstation, onto one or many rovers

```bash
export GITHUB_TOKEN=<PAT with 'repo' scope>
./provision_rover_remote.sh --follow 192.168.1.50
./provision_rover_remote.sh 192.168.1.50 192.168.1.51 192.168.1.52
```

Runs are detached with `setsid`, so they survive a dropped SSH connection.
Reattach any time with `--follow`.

---

## What it installs

1. Base utilities, `apt-utils`
2. **NVIDIA JetPack** (skipped gracefully on non-Jetson hardware)
3. **CUDA toolkit** — detected first, installed only if missing
4. **Firefox** — the real Mozilla **arm64 deb**, from `packages.mozilla.org`.
   Not the snap: see the gotcha below, the snap cannot run on a Jetson at all
5. **ROS 2** (`humble` by default) — installs it if absent, including apt keyring and repo
6. ROS packages: nav2, slam-toolbox, robot-localization, xacro, joy-linux, …
7. **Dependencies for the patched `web_video_server`** — `async_web_server_cpp`,
   `cv_bridge`, `image_transport`, `pluginlib`, `rclcpp_components`, ffmpeg dev
   libs (`libav*`, `libswscale`), `libx264-dev`, OpenCV, Boost
8. `gs_usb` kernel module via `/etc/modules-load.d/gs_usb.conf`
9. **`60-rover-can.rules`** — udev rule binding the USB-CAN adapter to a stable
   name by VID:PID, plus **`can.service`** + `/usr/sbin/enablecan` (USB reset,
   CAN-FD → classic fallback, link verification) and **`can-watchdog`** +
   timer, which restores the link if it drops, and **`can-selftest`**
   (`sudo can-selftest`), which tells a wedged adapter from a quiet bus
10. Clones `roverrobotics_ros2`, `web_video_server` (private), and `bno055`
    (`ssharma0704/bno055`, branch `fix-startup-race`: upstream plus a retry of
    the serial connect and sensor setup, so the IMU no longer crash-loops the
    stack right after boot or a USB reset; a re-run switches an existing clone
    to it)
11. **RealSense** — librealsense SDK with CUDA, `realsense-ros`,
    `reset_realsense_usb.sh`, `rover-realsense.service`,
    **`realsense-watchdog`** + `realsense-watchdog.timer` (checks that frames are
    actually arriving, since the node can sit `active` publishing nothing)
12. udev rules + `dialout` group — includes **`55-roverrobotics.rules`**, which
    binds the BNO055's FT232H bridge (`0403:6014`) to `/dev/bno055` so the IMU
    does not depend on `ttyUSB*` enumeration order
13. `rosdep`
14. **`reset_bno055_usb.sh`** + `/etc/sudoers.d/rover-bno055` — an
    `ExecStartPre` that flushes the IMU's UART before each driver start, so a
    restart loop cannot sustain itself on a desynced serial port
15. **`roverrobotics.service`** autostart (`<robot>_teleop.launch.py`). It stops
    gracefully (`KillMode=mixed`, `SIGINT`) so the driver brakes the motors on
    exit, and it also brings up the **BNO055 IMU** when `accessories.yaml` enables it, and
    the **PS5 (DualSense) gamepad** — `miti_teleop.launch.py` includes
    `ps5_controller.launch.py`, which loads `ps5_controller_config_jp6.yaml`
    (the JetPack 6 axis/button map; the non-`_jp6` file has the sticks and
    triggers on the wrong indices for this kernel)
16. `colcon build`
17. **`lo-multicast.service`** and `ROS_LOCALHOST_ONLY=1` for the driver,
    camera and watchdog: the DroneDeploy ROS plugin is localhost-only, and
    CycloneDDS cannot discover over `lo` without the MULTICAST flag

Everything is **idempotent** — a re-run skips what's already installed.

---

## How long it takes

Every run writes `=== PROVISION START <ISO8601> ===` and
`=== PROVISION END <ISO8601> EXIT_CODE=<n> ===` to the log, so the wall clock for
any run is two `grep`s away:

```bash
grep -E 'PROVISION (START|END)' provision.log
```

Measured on a Jetson AGX Orin Developer Kit (JetPack 6, ROS 2 Humble already
installed):

| Run | Wall clock | Notes |
|---|---|---|
| **Genuinely bare machine, full run** | **48 min** | measured; see breakdown below |
| Full, librealsense built from source | **30 min** | on a machine that already had ROS 2 |
| `--skip-librealsense`, SDK already present | **~2 min** | the normal re-provision |
| `-y --skip-realsense` | **~3 min** | everything except the camera |

**The bare-machine number is now measured, not estimated.** A freshly flashed
AGX Orin (NVMe root, no ROS 2, no CUDA, no Firefox) took **47 min 56 s** end to
end, exit code 0, 9/9 packages:

| Phase | Wall clock |
|---|---|
| Steps 1–10 — base, JetPack, CUDA, Firefox, **full ROS 2 Humble desktop**, repos | **14 min** |
| Step 11 — librealsense CUDA build | **~15 min** |
| Step 16 — `colcon build`, 9 packages | **1 min 26 s** |

Two things that breakdown corrects:

- **CUDA is free.** `nvidia-jetpack` in step 2 pulls in CUDA 12.6, so step 3
  detects it and skips. Budget nothing for it.
- **The old 25–50 min estimate for a clean image was pessimistic**, and so was
  the ~27 min figure for librealsense. Download speed dominates, so your own
  numbers will move with your link — but 48 min is a real figure from a real
  log, not an extrapolation.

---

## Common options

```
-d, --distro <humble|jazzy>   ROS 2 distro                    (default: humble)
-r, --robot  <miti|miti_65>   Robot variant                   (default: miti)
-c, --can    <iface>          CAN interface, udev-bound to the
                              adapter VID:PID              (default: rovercan)
-o, --owner  <github-user>    Owner of the private repos      (default: ssharma0704)
    --bootstrap-auth          One-time per-machine GitHub key setup
-y, --yes                     Non-interactive: take each prompt's default
    --reboot                  Reboot at the end on success (gs_usb, udev rules
                              and the dialout group need it)
    --skip-realsense          Skip RealSense entirely
    --skip-librealsense       Skip only the SDK build (the longest step)
    --no-build                Skip the final colcon build
```

Full list: `./setup_rover_miti_dronedeploy.sh --help`

---

## GitHub access

The rover packages are private, so each machine needs read access. Rather than
placing an account-wide token on a robot, `--bootstrap-auth` gives every machine
its **own read-only deploy key per repository**.

Per-repo is not a stylistic choice: GitHub rejects the same deploy key on a
second repository (`key is already in use`), so one shared key cannot cover both.
Each key is bound to its repo with an SSH `Host` alias plus a git `insteadOf`
rewrite, so ordinary `git@github.com:owner/repo` URLs keep working untouched.

Revoke a machine any time from **Repo → Settings → Deploy keys**.

---

## Notes and gotchas

Behaviour worth knowing about, most of it learned by running this on real hardware:

- **Firefox: never `snap install firefox` on a Jetson.** The L4T Tegra kernel
  ships **without AppArmor**, which snapd requires, so *every* snap fails with
  `required permitted capability cap_dac_override not found`. The trap is that
  `getcap` shows the capability present on `snap-confine` and the rootfs is not
  `nosuid`, so the binary looks perfectly fine and reinstalling snapd or
  re-running `setcap` changes nothing. Worse, Ubuntu's arm64 `firefox` apt
  package is only a ~2.4 kB *transitional shim* to that snap, so
  `command -v firefox` succeeds while no working browser exists — which is how
  this silently shipped a dead browser on every machine. The provisioner now
  installs Mozilla's real arm64 deb and **verifies by running it**. Note the
  install needs `--allow-downgrades`: Ubuntu's shim carries an epoch
  (`1:1snap1-0ubuntu2`) that outranks Mozilla's bare version string.
- **A restart loop can outlive the fault that started it.** `on_exit=Shutdown()`
  means any required node dying tears the whole launch down — so the journal
  tail usually shows several dead nodes and **the last one named is not the
  cause**. Read from the top of one cycle and take the *first* failure, then use
  the exit code: **−2 is a collateral SIGINT, 1 is the node's own error.**
  Seen on real hardware: a rover booted with no CAN adapter looped ~150 times,
  and each teardown killed the `bno055` node mid-transaction, leaving stale
  bytes in the FT232H. After that, **connecting the CAN adapter did not fix it**
  — the loop had stopped being about CAN and was sustaining itself on the
  desynced UART. `reset_bno055_usb.sh` now flushes the port before every start
  so this cannot persist. Do not power-cycle the bridge on every start instead:
  that also reboots the sensor, and the node then opens the port before it can
  answer.
- **`rovercan`, not any `canN`.** The kernel name is *not stable* on the AGX
  Orin: the two native `mttcan` controllers and the USB adapter race for
  `can0`/`can1`/`can2` at boot and the winner changes between boots. The same
  adapter was `can2` for several boots and then came up as `can0`, at which
  point everything hardcoding `can2` configured an onboard controller with
  nothing wired to it — link `UP` and `ERROR-ACTIVE`, `candump` silent, driver
  fataling with "Did not receive any data from the robot", and no log anywhere
  naming the cause. A udev rule binds the adapter by USB VID:PID
  (`1d50:606f`) to a fixed name instead, matching `miti_config.yaml`. Override
  with `--can`, which also patches the driver config to match.
- **`gs_usb` will not re-open after `ip link set down`** — `ip link set up` then
  returns `ENODEV` despite a valid ifindex. That is why `enablecan` toggles the
  adapter's sysfs `authorized` flag first; it matches on VID:PID, not the USB
  product string, because these adapters report `USB2CAN V3.3`. With the old
  product-string match the reset never ran, so `can-watchdog` could detect a
  dropped link but never restore it.
- **CAN restart storm.** The original `can.service` had `Restart=on-failure` with
  no `RestartSec`, so with the adapter unplugged systemd retried every ~100 ms —
  over 2600 restarts in minutes. This version sets `RestartSec=10` for the
  backoff and `StartLimitIntervalSec=0` to retry *forever* — a finite cap left
  the unit permanently dead once the burst was spent
  (`Start request repeated too quickly`), so an adapter plugged in later was
  never picked up. Unlimited retries are safe precisely because `RestartSec`
  provides the spacing. Note `StartLimitIntervalSec` belongs in `[Unit]`; in
  `[Service]` modern systemd ignores it.
- **RealSense service prerequisites.** `rover-realsense.service` runs
  `sudo -n /usr/local/sbin/reset_realsense_usb.sh`, which needs a NOPASSWD
  sudoers entry, and sets `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, which needs
  `ros-humble-rmw-cyclonedds-cpp`. Both are handled here; neither is optional.
- **Service user.** The units run as the invoking user rather than a hardcoded
  `rover`, so they work on a machine whose login is named something else.
- **`apt-daily` lock contention.** A fresh Ubuntu will race the automatic-update
  timers for the dpkg lock. All apt calls wait the lock out and retry.
- **Unattended sudo.** `sudo -v` always tries to validate credentials and fails
  without a TTY *even under `NOPASSWD`*. `provision_rover_remote.sh` grants
  NOPASSWD for the run and removes it on every exit path, including failure.
- **rosdep warning is expected.** `ros-gz-bridge` / `ros-gz-sim` have no Humble
  arm64 build. They're only needed by `roverrobotics_gazebo`, which builds fine
  regardless and isn't used on the robot.
- **A dead BNO055 now takes the whole driver down with it.** As of `a91464f` the
  IMU node carries `on_exit=Shutdown()`, matching the driver node. That is
  deliberate — without it a dead IMU left `roverrobotics.service` reporting
  `active` with `NRestarts=0` while `/imu/data` was silent, the same blind spot
  that once hid the driver crash-loop. The cost is that an IMU fault is no
  longer survivable: the launch tears down and systemd restarts everything, so a
  rover with a failed or unplugged IMU **restart-loops instead of driving
  without an IMU**. If a machine has no BNO055 fitted, set `active: false` under
  `bno055` in `accessories.yaml` — leaving it `true` with no hardware is a
  guaranteed restart loop, not a warning.
- **`/imu/data` is jittery by nature — 32–56 Hz.** Measured across many samples
  on the reference rover: std dev ~0.03 s with occasional 0.13 s gaps. It is a
  UART-polled sensor at 115200 baud, not a fixed-rate publisher. Do not read the
  variation as a fault, and do not write a healthcheck that expects a steady
  rate.

---

## After provisioning

```bash
sudo reboot          # for gs_usb, udev rules and the dialout group
systemctl status can.service roverrobotics.service rover-realsense.service
```

### VESC settings (once per robot, in VESC Tool)

The provisioner cannot reach the motor controllers' own settings. On **every
VESC** (connect over USB, or over CAN through one of them):

1. Motor Settings → FOC → Hall Sensors → **Hall Interpolation ERPM = 50**
   (default 500). At 500 the VESC reports about half the real wheel speed below
   ~0.44 m/s on a MITI, so the robot drives too fast at low speed and odometry
   comes up short (32% short at 0.2 m/s before the change).
2. Enable **CAN status message 5** (tachometer + input voltage) alongside 1 and 4.
3. **Write Motor Configuration** / **Write App Configuration** on each VESC.

The MITI config in `roverrobotics_ros2` (feedforward, gains P 0.0002 /
I 0.00002 / D 0.00002, `wheel_base` 0.60) is tuned for this setting. Do not
combine Hall Interpolation 50 with the September release gains
(P 0.0007 / D 0.00009): on a stand that oscillated with 46-61 A current swings.
Below ~0.07 m/s the speed reading is still unreliable (too few hall edges).

Video stream, once `rover-realsense.service` is up:

```
http://<rover-ip>:8080/stream?topic=/camera/camera/color/image_raw&type=h264&bitrate=2000000
```

Drop `&bitrate` for CRF mode; add `&crf=<n>` to tune quality. Both come from the
patched `h264_streamer` — upstream hardcodes CRF 20 with no CBR path.
