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
4. **Firefox**
5. **ROS 2** (`humble` by default) — installs it if absent, including apt keyring and repo
6. ROS packages: nav2, slam-toolbox, robot-localization, xacro, joy-linux, …
7. **Dependencies for the patched `web_video_server`** — `async_web_server_cpp`,
   `cv_bridge`, `image_transport`, `pluginlib`, `rclcpp_components`, ffmpeg dev
   libs (`libav*`, `libswscale`), `libx264-dev`, OpenCV, Boost
8. `gs_usb` kernel module via `/etc/modules-load.d/gs_usb.conf`
9. **`60-rover-can.rules`** — udev rule binding the USB-CAN adapter to a stable
   name by VID:PID, plus **`can.service`** + `/usr/sbin/enablecan` (USB reset,
   CAN-FD → classic fallback, link verification) and **`can-watchdog`** +
   timer, which restores the link if it drops
10. Clones `roverrobotics_ros2`, `web_video_server` (private), and `bno055`
11. **RealSense** — librealsense SDK with CUDA, `realsense-ros`,
    `reset_realsense_usb.sh`, `rover-realsense.service`
12. udev rules + `dialout` group
13. `rosdep`
14. **`roverrobotics.service`** autostart (`<robot>_teleop.launch.py`)
15. `colcon build`

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
| Full, librealsense built from source | **30 min** | step 11 alone is ~27 min of it |
| `--skip-librealsense`, SDK already present | **~2 min** | the normal re-provision |
| `-y --skip-realsense` | **~3 min** | everything except the camera |

Where the time actually goes:

- **librealsense CUDA build: ~27 min.** Everything else together is a rounding
  error next to it. `--skip-librealsense` is the single biggest lever.
- `colcon build`, 9 packages: **~1 min**
- apt, `gs_usb`, CAN service, udev, repos, rosdep, services: **~2 min** combined

**Not yet measured: a genuinely bare machine.** Every run above had ROS 2,
JetPack and CUDA already present — steps 2–5 were no-ops. Expect a clean image to
add roughly **25–50 min** for ROS 2 desktop + JetPack + CUDA, dominated by
download speed, but treat that as an estimate rather than a number from a log.
**When you next provision a fresh Jetson, grab the START/END pair and replace
this paragraph with the real figure.**

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
    --skip-librealsense       Skip only the ~45 min SDK build
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

---

## After provisioning

```bash
sudo reboot          # for gs_usb, udev rules and the dialout group
systemctl status can.service roverrobotics.service rover-realsense.service
```

Video stream, once `rover-realsense.service` is up:

```
http://<rover-ip>:8080/stream?topic=/camera/camera/color/image_raw&type=h264&bitrate=2000000
```

Drop `&bitrate` for CRF mode; add `&crf=<n>` to tune quality. Both come from the
patched `h264_streamer` — upstream hardcodes CRF 20 with no CBR path.
