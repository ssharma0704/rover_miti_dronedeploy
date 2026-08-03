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
9. **`can.service`** + `/usr/sbin/enablecan` (USB-CAN reset, CAN-FD bring-up)
10. Clones `roverrobotics_ros2`, `web_video_server` (private), and `bno055`
11. **RealSense** — librealsense SDK with CUDA, `realsense-ros`,
    `reset_realsense_usb.sh`, `rover-realsense.service`
12. udev rules + `dialout` group
13. `rosdep`
14. **`roverrobotics.service`** autostart (`<robot>_teleop.launch.py`)
15. `colcon build`

Everything is **idempotent** — a re-run skips what's already installed. A full
re-provision of an already-configured machine takes about 30 seconds.

---

## Common options

```
-d, --distro <humble|jazzy>   ROS 2 distro                    (default: humble)
-r, --robot  <miti|miti_65>   Robot variant                   (default: miti)
-c, --can    <iface>          CAN interface                   (default: can2)
-o, --owner  <github-user>    Owner of the private repos      (default: ssharma0704)
    --bootstrap-auth          One-time per-machine GitHub key setup
-y, --yes                     Non-interactive
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

- **`can2`, not `can0`.** The Jetson AGX Orin's two *native* CAN controllers take
  `can0`/`can1`, so the USB-CAN adapter enumerates as `can2`. That matches
  `miti_config.yaml`. Override with `--can`.
- **CAN restart storm.** The original `can.service` had `Restart=on-failure` with
  no `RestartSec`, so with the adapter unplugged systemd retried every ~100 ms —
  over 2600 restarts in minutes. This version sets `RestartSec=10` and a start
  limit. Note `StartLimitIntervalSec`/`StartLimitBurst` belong in `[Unit]`; in
  `[Service]` modern systemd ignores them.
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
