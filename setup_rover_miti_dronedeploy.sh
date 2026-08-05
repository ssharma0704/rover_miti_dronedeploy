#!/usr/bin/env bash
#########################################################################
# Script Name  : Rover MITI / DroneDeploy Setup                         #
# Description  : One-shot provisioning for the MITI rover used on the    #
#                DroneDeploy deployment. Pulls the patched              #
#                roverrobotics_ros2 and web_video_server from the        #
#                private GitHub repos, installs system + ROS deps,       #
#                CAN / RealSense services, and builds the workspace.     #
# Author       : Shashank Sharma                                         #
#########################################################################
set -euo pipefail

#########################################################################
#                              SETTINGS                                 #
#########################################################################
GITHUB_OWNER="${GITHUB_OWNER:-ssharma0704}"

ROVER_REPO_NAME="roverrobotics_ros2"
# Left empty on purpose: unless --rover-branch says otherwise, this follows the
# selected ROS distro, matching the roverrobotics_ros2 branch convention.
ROVER_REPO_BRANCH=""

WVS_REPO_NAME="web_video_server"
WVS_REPO_BRANCH="ros2"

IMU_REPO="https://github.com/flynneva/bno055.git"
REALSENSE_ROS_REPO="https://github.com/IntelRealSense/realsense-ros.git"
REALSENSE_ROS_BRANCH="ros2-master"

WORKSPACE_NAME="rover_workspace"
WORKSPACE_DIR="$HOME/$WORKSPACE_NAME"

ROS_DISTRO_DEFAULT="humble"
ROBOT_TYPE_DEFAULT="miti"
CAN_IFACE_DEFAULT="can2"

# Runtime user the systemd services run as. Defaults to whoever invoked the
# script (via sudo or not) rather than a hardcoded name, so the units work on
# a Jetson whose login user is not literally "rover".
RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"
RUN_GROUP="$(id -gn "$RUN_USER")"

#########################################################################
#                            FLAG DEFAULTS                              #
#########################################################################
ROS_DISTRO_SEL="$ROS_DISTRO_DEFAULT"
ROBOT_TYPE="$ROBOT_TYPE_DEFAULT"
CAN_IFACE="$CAN_IFACE_DEFAULT"
ROS_PACKAGE_SET="desktop"
DO_ROS_INSTALL=true
DO_BOOTSTRAP_AUTH=false
ASSUME_YES=false
DO_REBOOT=false
DO_REALSENSE=true
DO_LIBREALSENSE_BUILD=true
DO_JETPACK=true
DO_FIREFOX=true
DO_IMU=true
DO_UDEV=true
DO_AUTOSTART=true
DO_BUILD=true

usage() {
    cat <<'USAGE'
Rover MITI / DroneDeploy setup

Usage: ./setup_rover_miti_dronedeploy.sh [options]

Options:
  -d, --distro <humble|jazzy>   ROS 2 distro                (default: humble)
  -r, --robot  <miti|miti_65>   Robot variant               (default: miti)
  -c, --can    <iface>          CAN interface name          (default: can2)
  -o, --owner  <github-user>    GitHub owner of the private repos
                                                            (default: ssharma0704)
      --rover-branch <branch>   Branch of roverrobotics_ros2 to clone
                                                     (default: same as --distro)
      --wvs-branch   <branch>   Branch of web_video_server to clone
                                                            (default: ros2)
  -p, --ros-package <set>       desktop | ros-base, used only when ROS 2 has to
                                be installed                  (default: desktop)
      --skip-ros-install        Fail instead of installing ROS 2 when missing
      --bootstrap-auth          One-time per-machine GitHub setup: generate a
                                per-repo SSH key, register it as a READ-ONLY
                                deploy key, and wire up git. Needs GITHUB_TOKEN
                                or an authenticated gh CLI. Run this on each new
                                computer; afterwards the machine pulls on its own.
  -y, --yes                     Non-interactive: take each prompt's default
      --reboot                  Reboot at the end on success. gs_usb, the udev
                                rules and the dialout group only take effect
                                after a reboot, so a hands-off provision wants
                                this. Skipped if the colcon build failed.
      --skip-realsense          Skip RealSense entirely (SDK + ROS wrapper + service)
      --skip-librealsense       Clone realsense-ros but do NOT rebuild the
                                librealsense SDK (~45 min build)
      --skip-jetpack            Skip nvidia-jetpack install
      --skip-firefox            Skip Firefox install
      --skip-imu                Skip the BNO055 IMU repo
      --skip-udev               Skip udev rules
      --skip-autostart          Do not install roverrobotics.service
      --no-build                Do everything except the final colcon build
  -h, --help                    Show this help

Private repo authentication (checked in this order):
  1. $GITHUB_TOKEN / $GH_TOKEN environment variable (a PAT with 'repo' scope)
  2. an authenticated 'gh' CLI  (gh auth login)
  3. SSH keys                   (git@github.com)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--distro) ROS_DISTRO_SEL="${2:?}"; shift 2 ;;
        -r|--robot)  ROBOT_TYPE="${2:?}"; shift 2 ;;
        -c|--can)    CAN_IFACE="${2:?}"; shift 2 ;;
        -o|--owner)  GITHUB_OWNER="${2:?}"; shift 2 ;;
        --rover-branch) ROVER_REPO_BRANCH="${2:?}"; shift 2 ;;
        --wvs-branch)   WVS_REPO_BRANCH="${2:?}"; shift 2 ;;
        -p|--ros-package) ROS_PACKAGE_SET="${2:?}"; shift 2 ;;
        --skip-ros-install) DO_ROS_INSTALL=false; shift ;;
        --bootstrap-auth)   DO_BOOTSTRAP_AUTH=true; shift ;;
        -y|--yes)    ASSUME_YES=true; shift ;;
        --reboot)    DO_REBOOT=true; shift ;;
        --skip-realsense)    DO_REALSENSE=false; shift ;;
        --skip-librealsense) DO_LIBREALSENSE_BUILD=false; shift ;;
        --skip-jetpack)      DO_JETPACK=false; shift ;;
        --skip-firefox)      DO_FIREFOX=false; shift ;;
        --skip-imu)          DO_IMU=false; shift ;;
        --skip-udev)         DO_UDEV=false; shift ;;
        --skip-autostart)    DO_AUTOSTART=false; shift ;;
        --no-build)          DO_BUILD=false; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Branch follows the distro unless explicitly overridden.
ROVER_REPO_BRANCH="${ROVER_REPO_BRANCH:-$ROS_DISTRO_SEL}"

#########################################################################
#                          HELPER FUNCTIONS                             #
#########################################################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"
BOLD="\e[1m"; ITALICBLUE="\e[3;94m"; BOLDBLUE="\e[1;94m"; ENDCOLOR="\e[0m"

print_red()      { echo -e "${RED}${1}${ENDCOLOR}"; }
print_green()    { echo -e "${GREEN}${1}${ENDCOLOR}"; }
print_yellow()   { echo -e "${YELLOW}${1}${ENDCOLOR}"; }
print_bold()     { echo -e "${BOLD}${1}${ENDCOLOR}"; }
print_italic()   { echo -e "${ITALICBLUE}${1}${ENDCOLOR}"; }
print_boldblue() { echo -e "${BOLDBLUE}${1}${ENDCOLOR}"; }

STEP=0
step() { STEP=$((STEP + 1)); echo ""; print_bold "===== [$STEP] ${1} ====="; }

# Collects non-fatal problems so the run ends with an honest summary instead of
# a green "done" that hides a failed sub-step.
WARNINGS=()
warn() { print_yellow "WARNING: ${1}"; WARNINGS+=("${1}"); }

die() { echo ""; print_red "FATAL: ${1}"; exit 1; }

confirm() {
    # confirm "question" default(yes|no) -> returns 0 for yes
    local q="$1" def="${2:-yes}" yn
    # Under -y take each prompt's OWN default rather than answering yes to
    # everything. "Rebuild librealsense (~45 min)?" defaults to no precisely
    # because it is already installed; answering yes there burned 45 minutes on
    # every re-run of an otherwise idempotent script.
    if [ "$ASSUME_YES" = true ]; then
        if [ "$def" = "no" ]; then return 1; else return 0; fi
    fi
    if [ "$def" = "no" ]; then
        read -rp "$q [y/N]: " yn; yn="${yn:-n}"
    else
        read -rp "$q [Y/n]: " yn; yn="${yn:-y}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# Ubuntu's apt-daily / unattended-upgrades timers grab the dpkg lock on a fresh
# machine and will kill an otherwise-fine provisioning run. Wait them out.
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock"
wait_for_apt() {
    local waited=0 max=900
    command -v fuser >/dev/null 2>&1 || return 0
    while sudo -n fuser $APT_LOCKS >/dev/null 2>&1; do
        [ "$waited" -eq 0 ] && print_italic "  waiting for another apt/dpkg process to release the lock..."
        sleep 5; waited=$((waited + 5))
        if [ "$waited" -ge "$max" ]; then
            warn "apt lock still held after ${max}s; attempting to proceed anyway."
            return 0
        fi
    done
    [ "$waited" -gt 0 ] && print_green "  apt lock released after ${waited}s"
    return 0
}

# Wait for a RealSense camera to appear on USB.
#
# Polled rather than a blocking "press Enter", so an attended run and a -y run
# behave identically: both give the operator a window to plug the camera in, and
# neither hangs forever if nobody is there. Absence is a warning, never fatal --
# a headless provision with the camera fitted later is legitimate.
REALSENSE_USB_RE='8086:0b|realsense'
wait_for_realsense() {
    local waited=0 max="${REALSENSE_WAIT_SECS:-120}" found=""
    command -v lsusb >/dev/null 2>&1 || { print_italic "  lsusb unavailable; skipping camera check"; return 0; }

    while :; do
        found="$(lsusb 2>/dev/null | grep -Ei "$REALSENSE_USB_RE" | head -1 || true)"
        [ -n "$found" ] && break
        if [ "$waited" -eq 0 ]; then
            print_yellow "  Plug the RealSense camera in now."
            print_italic  "  (the SDK build wanted it unplugged; a replug is also what picks up"
            print_italic  "   the new udev rules). Waiting up to ${max}s..."
        fi
        sleep 5; waited=$((waited + 5))
        if [ "$waited" -ge "$max" ]; then
            warn "No RealSense camera detected after ${max}s. Continuing anyway.
       Plug it in, then:  sudo systemctl restart rover-realsense.service"
            return 1
        fi
    done

    [ "$waited" -gt 0 ] && print_green "  camera appeared after ${waited}s"
    print_green "  RealSense camera detected: ${found#*ID }"
    return 0
}

# Run apt-get, waiting out lock contention and retrying once.
apt_get() {
    wait_for_apt
    if sudo apt-get "$@"; then return 0; fi
    print_italic "  apt-get failed; waiting for locks and retrying once..."
    sleep 10
    wait_for_apt
    sudo apt-get "$@"
}

# apt install only what is actually missing, so re-runs are fast and quiet.
apt_ensure() {
    local missing=()
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
        print_green "  already installed: $*"
        return 0
    fi
    print_italic "  installing: ${missing[*]}"
    if apt_get install -y "${missing[@]}"; then
        print_green "  ok: ${missing[*]}"
    else
        # These are hard requirements; stop with a readable message rather than
        # letting 'set -e' kill the run silently before the summary prints.
        die "Could not install required package(s): ${missing[*]}
       Check your apt sources (ROS repo present? 'sudo apt-get update' clean?) and re-run."
    fi
}

# Same as apt_ensure but never aborts the script (for optional extras).
apt_try() {
    local missing=()
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        print_green "  already installed: $*"
        return 0
    fi
    print_italic "  installing (optional): ${missing[*]}"
    if apt_get install -y "${missing[@]}"; then
        print_green "  ok: ${missing[*]}"
    else
        warn "optional package(s) not installed: ${missing[*]}"
    fi
    return 0
}

#########################################################################
#                   PRIVATE REPO CLONE / UPDATE                         #
#########################################################################
AUTH_MODE=""

# One-time per-machine GitHub bootstrap.
#
# Generates a dedicated SSH key PER REPO and registers each as a read-only
# deploy key. Per-repo is not a style choice: GitHub rejects the same deploy
# key on a second repository ("key is already in use"), so one shared key
# cannot cover both. Each key is then bound to its repo via a Host alias plus
# a git 'insteadOf' rewrite, so ordinary git@github.com:owner/repo URLs keep
# working untouched.
#
# Needs a credential that can create deploy keys, exactly once per machine:
#   GITHUB_TOKEN / GH_TOKEN with 'repo' scope, or an authenticated gh CLI.
bootstrap_auth() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

    # Already bootstrapped? Then this is a no-op, and crucially it must not
    # demand a token: a re-provisioned machine has working deploy keys but
    # usually no GITHUB_TOKEN and no gh CLI.
    local already=1 r
    for r in "$ROVER_REPO_NAME" "$WVS_REPO_NAME"; do
        git ls-remote --heads "git@github.com:${GITHUB_OWNER}/${r}.git" >/dev/null 2>&1 || already=0
    done
    if [ "$already" -eq 1 ]; then
        print_green "  GitHub access already configured on this machine; skipping bootstrap"
        return 0
    fi

    if [ -z "$token" ] && ! { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }; then
        die "--bootstrap-auth needs a credential that can create deploy keys.
       Provide one of:
         export GITHUB_TOKEN=<PAT with 'repo' scope>
         gh auth login
       This is required only once per machine."
    fi

    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -F github.com >/dev/null 2>&1 || \
        ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

    local repo keyfile pub alias title rc
    for repo in "$ROVER_REPO_NAME" "$WVS_REPO_NAME"; do
        keyfile="$HOME/.ssh/id_ed25519_${repo}"
        alias="github-${repo}"
        title="$(hostname)-$(date +%Y%m%d 2>/dev/null || echo provisioned)"

        [ -f "$keyfile" ] || ssh-keygen -t ed25519 -N "" -q \
            -C "$(whoami)@$(hostname):${repo}" -f "$keyfile"
        pub="$(cat "${keyfile}.pub")"

        rc=0
        if [ -n "$token" ]; then
            curl -fsS -X POST \
                -H "Authorization: Bearer ${token}" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/${GITHUB_OWNER}/${repo}/keys" \
                -d "$(printf '{"title":"%s","key":"%s","read_only":true}' "$title" "$pub")" \
                >/dev/null 2>&1 || rc=$?
        else
            gh api "repos/${GITHUB_OWNER}/${repo}/keys" -X POST \
                -f title="$title" -f key="$pub" -F read_only=true >/dev/null 2>&1 || rc=$?
        fi
        # A non-zero rc here is usually "key is already in use" from a previous
        # bootstrap on this same machine, which is fine. The ls-remote check
        # below is the real verdict, so don't fail on rc alone.
        [ "$rc" -eq 0 ] && print_green "  registered read-only deploy key for $repo" \
                        || print_italic "  deploy key for $repo already registered (or rejected); verifying access"

        # Bind this repo to its own key.
        touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
        if ! grep -q "^Host ${alias}\$" "$HOME/.ssh/config" 2>/dev/null; then
            {
                echo ""
                echo "Host ${alias}"
                echo "  HostName github.com"
                echo "  User git"
                echo "  IdentityFile ${keyfile}"
                echo "  IdentitiesOnly yes"
            } >> "$HOME/.ssh/config"
        fi
        git config --global \
            "url.git@${alias}:${GITHUB_OWNER}/${repo}.insteadOf" \
            "git@github.com:${GITHUB_OWNER}/${repo}"
    done

    # Verify for real rather than trusting the API calls.
    local failed=0
    for repo in "$ROVER_REPO_NAME" "$WVS_REPO_NAME"; do
        if git ls-remote --heads "git@github.com:${GITHUB_OWNER}/${repo}.git" >/dev/null 2>&1; then
            print_green "  verified read access to ${GITHUB_OWNER}/${repo}"
        else
            print_red "  cannot read ${GITHUB_OWNER}/${repo}"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] || die "GitHub bootstrap failed; the repos are still unreachable."
    print_green "  GitHub bootstrap complete"
}

detect_auth() {
    local probe
    if [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
        AUTH_MODE="token"
    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        AUTH_MODE="gh"
    else
        # 'ssh -T git@github.com' ALWAYS exits 1 (GitHub refuses shell access)
        # even on success, so its output must be captured and inspected
        # separately. Piping it into grep would fail under 'set -o pipefail'
        # regardless of whether authentication actually worked.
        probe="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
                     -o StrictHostKeyChecking=accept-new \
                     -T git@github.com 2>&1 || true)"
        if printf '%s' "$probe" | grep -q "successfully authenticated"; then
            AUTH_MODE="ssh"
        else
            AUTH_MODE="none"
        fi
    fi
    print_italic "GitHub auth mode: $AUTH_MODE"
}

# clone_or_update <repo-name> <branch> <dest-dir>
clone_or_update() {
    local name="$1" branch="$2" dest="$3"
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

    if [ -d "$dest/.git" ]; then
        print_italic "  $name already present -> fetching branch '$branch'"
        git -C "$dest" fetch --all --prune
        # Do not clobber local work: only fast-forward, and say so if we can't.
        if git -C "$dest" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
            print_green "  $name updated to origin/$branch"
        else
            warn "$name could not fast-forward to origin/$branch (local commits or dirty tree). Left as-is."
        fi
        return 0
    fi

    local rc=0
    case "$AUTH_MODE" in
        token) git clone -b "$branch" \
                   "https://x-access-token:${token}@github.com/${GITHUB_OWNER}/${name}.git" "$dest" || rc=$? ;;
        gh)    gh repo clone "${GITHUB_OWNER}/${name}" "$dest" -- -b "$branch" || rc=$? ;;
        ssh)   git clone -b "$branch" "git@github.com:${GITHUB_OWNER}/${name}.git" "$dest" || rc=$? ;;
        *)
            die "No GitHub credentials available; cannot clone private repo ${GITHUB_OWNER}/${name}.
       Fix with ONE of:
         export GITHUB_TOKEN=<PAT with repo scope>
         gh auth login
         ssh-keygen + add the public key to GitHub"
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        die "Failed to clone ${GITHUB_OWNER}/${name} (branch '${branch}').
       Check that the branch exists and that your credentials can read the repo:
         git ls-remote --heads https://github.com/${GITHUB_OWNER}/${name}.git
       Override the branch with --rover-branch / --wvs-branch if it differs."
    fi

    # A token baked into the clone URL would otherwise persist in .git/config.
    if [ "$AUTH_MODE" = "token" ]; then
        git -C "$dest" remote set-url origin \
            "https://github.com/${GITHUB_OWNER}/${name}.git"
    fi
    print_green "  cloned $name (branch $branch)"
}

#########################################################################
#                            PRE-FLIGHT                                 #
#########################################################################
# Non-fatal: there is no TTY when this runs under nohup/systemd/CI.
clear 2>/dev/null || true
print_bold "====================================================="
print_boldblue " Rover MITI  -  DroneDeploy provisioning"
print_bold "-----------------------------------------------------"
if [ -d "/opt/ros/$ROS_DISTRO_SEL" ]; then
    print_boldblue " ROS distro    : $ROS_DISTRO_SEL (already installed)"
else
    print_boldblue " ROS distro    : $ROS_DISTRO_SEL (WILL INSTALL: ros-$ROS_DISTRO_SEL-$ROS_PACKAGE_SET)"
fi
print_boldblue " Robot type    : $ROBOT_TYPE"
print_boldblue " CAN interface : $CAN_IFACE"
print_boldblue " Workspace     : $WORKSPACE_DIR"
print_boldblue " Service user  : $RUN_USER ($RUN_HOME)"
print_boldblue " Private repos : $GITHUB_OWNER/$ROVER_REPO_NAME @ $ROVER_REPO_BRANCH"
print_boldblue "                 $GITHUB_OWNER/$WVS_REPO_NAME @ $WVS_REPO_BRANCH"
print_boldblue " RealSense     : $DO_REALSENSE (SDK rebuild: $DO_LIBREALSENSE_BUILD)"
print_boldblue " JetPack       : $DO_JETPACK    Firefox: $DO_FIREFOX"
print_boldblue " BNO055 IMU    : $DO_IMU        Autostart: $DO_AUTOSTART"
print_bold "====================================================="
echo ""

if [ "$(id -u)" -eq 0 ]; then
    print_red "Do not run this script as root. Run it as the rover user; it calls sudo where needed."
    exit 1
fi

if [ -z "$RUN_HOME" ]; then
    print_red "Could not resolve home directory for user '$RUN_USER'."
    exit 1
fi

confirm "Proceed with these settings?" yes || { echo "Aborted."; exit 0; }

# Prime sudo so long unattended stretches don't stall on a password prompt.
# Non-fatal: 'sudo -v' always tries to validate credentials and fails without a
# TTY even under NOPASSWD, so a real capability check is used instead.
sudo -v 2>/dev/null || true
if ! sudo -n true 2>/dev/null; then
    die "This script needs sudo, but sudo is not usable non-interactively here.
       Run it from a terminal, or grant NOPASSWD sudo for the duration of the run."
fi

# Priming sudo once is not enough: sudo's timestamp_timeout is 15 min by
# default, and the librealsense build alone runs ~45 min without invoking sudo.
# The first sudo call after that build would then re-prompt for a password and
# stall an otherwise unattended run. Refresh the timestamp in the background for
# the life of the script.
sudo_keepalive() {
    while true; do
        sudo -n true 2>/dev/null || return 0
        sleep 60
    done
}
sudo_keepalive &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

#########################################################################
step "System package index + base utilities"
#########################################################################
apt_get update
# apt-utils first: several later packages emit debconf warnings without it.
apt_ensure apt-utils
apt_ensure \
    build-essential cmake pkg-config git curl wget gnupg2 lsb-release \
    software-properties-common ca-certificates net-tools setserial \
    python3-pip python3-serial python3-smbus can-utils

#########################################################################
step "NVIDIA JetPack"
#########################################################################
if [ "$DO_JETPACK" = true ]; then
    if dpkg -s nvidia-jetpack >/dev/null 2>&1; then
        print_green "  nvidia-jetpack already installed"
    elif apt-cache show nvidia-jetpack >/dev/null 2>&1; then
        apt_try nvidia-jetpack
    else
        warn "nvidia-jetpack not available from apt (not a Jetson, or the L4T apt source is missing). Skipped."
    fi
else
    print_italic "  skipped (--skip-jetpack)"
fi

#########################################################################
step "CUDA toolkit"
#########################################################################
CUDA_OK=false
if command -v nvcc >/dev/null 2>&1; then
    print_green "  found: $(nvcc --version | grep -i release | sed 's/^ *//')"
    CUDA_OK=true
elif [ -x /usr/local/cuda/bin/nvcc ]; then
    print_green "  found: $(/usr/local/cuda/bin/nvcc --version | grep -i release | sed 's/^ *//')"
    CUDA_OK=true
else
    print_italic "  nvcc not found -> installing CUDA development packages"
    # nvidia-cuda-dev only: on a Jetson, JetPack already supplies the CUDA
    # runtime, and pulling nvidia-cuda-toolkit as well can fight with it.
    apt_try nvidia-cuda-dev
    if command -v nvcc >/dev/null 2>&1 || [ -x /usr/local/cuda/bin/nvcc ]; then
        CUDA_OK=true
        print_green "  CUDA installed"
    else
        warn "CUDA still not detected after install attempt. librealsense will be built without CUDA."
    fi
fi

# Put CUDA on PATH for this shell and for future logins (idempotent).
if [ -d /usr/local/cuda/bin ]; then
    if ! grep -q "/usr/local/cuda/bin" "$RUN_HOME/.bashrc" 2>/dev/null; then
        {
            echo ""
            echo "# CUDA path (added by rover MITI setup)"
            echo 'export PATH=/usr/local/cuda/bin:$PATH'
            echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH'
        } >> "$RUN_HOME/.bashrc"
        print_green "  added CUDA paths to ~/.bashrc"
    fi
    export PATH=/usr/local/cuda/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
fi

#########################################################################
step "Firefox"
#########################################################################
if [ "$DO_FIREFOX" = true ]; then
    if command -v firefox >/dev/null 2>&1; then
        print_green "  firefox already installed"
    else
        apt_try firefox
        command -v firefox >/dev/null 2>&1 || \
            warn "Firefox not installed. On Jetson/arm64 the apt 'firefox' package is a snap shim; try: sudo snap install firefox"
    fi
else
    print_italic "  skipped (--skip-firefox)"
fi

#########################################################################
step "ROS 2 $ROS_DISTRO_SEL"
#########################################################################
if [ -d "/opt/ros/$ROS_DISTRO_SEL" ]; then
    print_green "  found existing /opt/ros/$ROS_DISTRO_SEL"
elif [ "$DO_ROS_INSTALL" = false ]; then
    die "ROS 2 '$ROS_DISTRO_SEL' is not installed and --skip-ros-install was given."
else
    print_italic "  ROS 2 '$ROS_DISTRO_SEL' not found -> installing ros-$ROS_DISTRO_SEL-$ROS_PACKAGE_SET"

    UBUNTU_CODENAME_DETECTED="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    case "$ROS_DISTRO_SEL" in
        humble) REQUIRED_CODENAME="jammy" ;;
        jazzy)  REQUIRED_CODENAME="noble" ;;
        *)      REQUIRED_CODENAME="" ;;
    esac
    if [ -n "$REQUIRED_CODENAME" ] && [ "$UBUNTU_CODENAME_DETECTED" != "$REQUIRED_CODENAME" ]; then
        die "ROS 2 '$ROS_DISTRO_SEL' expects Ubuntu '$REQUIRED_CODENAME' but this host is '$UBUNTU_CODENAME_DETECTED'."
    fi

    wait_for_apt
    sudo add-apt-repository -y universe

    ROS_KEYRING="/usr/share/keyrings/ros-archive-keyring.gpg"
    if [ ! -f "$ROS_KEYRING" ]; then
        print_italic "  installing ROS apt keyring"
        sudo curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
            -o "$ROS_KEYRING" || die "Could not download the ROS apt key."
    fi

    ROS_LIST="/etc/apt/sources.list.d/ros2.list"
    REPO_LINE="deb [arch=$(dpkg --print-architecture) signed-by=${ROS_KEYRING}] http://packages.ros.org/ros2/ubuntu ${UBUNTU_CODENAME_DETECTED} main"
    if [ ! -f "$ROS_LIST" ] || ! grep -Fq "$REPO_LINE" "$ROS_LIST"; then
        echo "$REPO_LINE" | sudo tee "$ROS_LIST" >/dev/null
        print_green "  configured $ROS_LIST"
    fi

    apt_get update
    apt_ensure "ros-${ROS_DISTRO_SEL}-${ROS_PACKAGE_SET}"
    apt_try python3-argcomplete python3-colcon-clean ros-dev-tools

    [ -d "/opt/ros/$ROS_DISTRO_SEL" ] || \
        die "ros-${ROS_DISTRO_SEL}-${ROS_PACKAGE_SET} installed but /opt/ros/$ROS_DISTRO_SEL is missing."
    print_green "  ROS 2 $ROS_DISTRO_SEL installed"
fi

# Make sure future logins source ROS (idempotent).
ROS_SOURCE_LINE="source /opt/ros/$ROS_DISTRO_SEL/setup.bash"
if ! grep -Fq "$ROS_SOURCE_LINE" "$RUN_HOME/.bashrc" 2>/dev/null; then
    echo "$ROS_SOURCE_LINE" >> "$RUN_HOME/.bashrc"
    print_green "  added ROS sourcing to ~/.bashrc"
fi

# The services below pin RMW_IMPLEMENTATION=rmw_cyclonedds_cpp. Without the
# same pin in .bashrc an interactive shell falls back to Humble's FastDDS
# default and silently sees none of the topics the services publish -- the
# failure looks like "the camera node isn't running" rather than a mismatch.
RMW_LINE="export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
if ! grep -Fq "$RMW_LINE" "$RUN_HOME/.bashrc" 2>/dev/null; then
    echo "$RMW_LINE" >> "$RUN_HOME/.bashrc"
    print_green "  pinned RMW_IMPLEMENTATION=rmw_cyclonedds_cpp in ~/.bashrc"
fi

#########################################################################
step "ROS 2 $ROS_DISTRO_SEL packages"
#########################################################################

R="ros-$ROS_DISTRO_SEL"

# --- rover driver + navigation stack -----------------------------------
apt_try \
    "$R-slam-toolbox" "$R-navigation2" "$R-nav2-bringup" \
    "$R-robot-localization" "$R-robot-state-publisher" \
    "$R-joint-state-publisher" "$R-xacro" "$R-joy-linux" \
    "$R-tf2-geometry-msgs" "$R-diagnostic-updater" \
    "$R-nav-msgs" "$R-sensor-msgs" "$R-std-msgs" "$R-rcpputils"

# --- explicitly requested ----------------------------------------------
apt_ensure "$R-image-transport"

# --- rmw_cyclonedds: rover-realsense.service sets
#     RMW_IMPLEMENTATION=rmw_cyclonedds_cpp, so the unit fails to start
#     without this package present.
apt_ensure "$R-rmw-cyclonedds-cpp"

# --- dependencies of the patched web_video_server ----------------------
# From its package.xml / CMakeLists: async_web_server_cpp, cv_bridge,
# image_transport, pluginlib, rclcpp_components, OpenCV, Boost.system, and the
# ffmpeg dev libraries probed via pkg-config (avcodec/avformat/avutil/swscale).
# The H.264 CBR patch additionally exercises libx264 through libavcodec.
step "Dependencies for the patched web_video_server"
apt_ensure \
    "$R-async-web-server-cpp" \
    "$R-cv-bridge" \
    "$R-image-transport" \
    "$R-pluginlib" \
    "$R-rclcpp-components" \
    "$R-camera-calibration-parsers"

apt_ensure \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    libavdevice-dev libx264-dev \
    libopencv-dev libboost-system-dev libboost-thread-dev \
    libssl-dev

# --- colcon / rosdep tooling -------------------------------------------
apt_try \
    python3-colcon-common-extensions python3-rosdep python3-vcstool \
    "$R-ament-cmake" "$R-ament-cmake-ros"

#########################################################################
step "gs_usb kernel module (USB-CAN adapter)"
#########################################################################
sudo tee /etc/modules-load.d/gs_usb.conf >/dev/null <<'EOF_GSUSB'
#gs_usb module
gs_usb
EOF_GSUSB
print_green "  wrote /etc/modules-load.d/gs_usb.conf"

if sudo modprobe gs_usb 2>/dev/null; then
    print_green "  gs_usb module loaded"
else
    warn "Could not modprobe gs_usb now (it will still load at boot via modules-load.d)."
fi

#########################################################################
step "CAN service ($CAN_IFACE)"
#########################################################################
# /usr/sbin/enablecan  -- resets the USB-CAN adapter to recover from a stale
# state after a hot reboot, then brings up the CAN-FD interface.
sudo tee /usr/sbin/enablecan >/dev/null <<EOF_ENABLECAN
#!/bin/bash

# Reset USB-CAN adapter to recover from stale state after hot reboot
for dev in /sys/bus/usb/devices/*/product; do
  if grep -qi "canable\\|gs_usb" "\$dev" 2>/dev/null; then
    usb_path=\$(dirname "\$dev")
    auth_file="\${usb_path}/authorized"
    if [[ -w "\$auth_file" ]]; then
      echo 0 > "\$auth_file"
      sleep 2
      echo 1 > "\$auth_file"
    fi
  fi
done

# Wait for device to re-enumerate
sleep 3

if ! ip link show $CAN_IFACE >/dev/null 2>&1; then
  echo "enablecan: $CAN_IFACE does not exist -- USB-CAN adapter not connected?" >&2
  exit 1
fi

# The bitrate cannot be changed while the interface is up.
sudo ip link set down $CAN_IFACE 2>/dev/null

# The CANable/gs_usb adapters used on these rovers support neither CAN-FD nor
# berr-reporting, and 'ip' rejects the whole command with "RTNETLINK answers:
# Operation not supported" if any one option is unsupported. The bitrate still
# lands, because the kernel commits the bit-timing attribute before it reaches
# the unsupported ctrlmode -- but relying on that ordering means the script
# cannot tell a configured bus from a broken one. Degrade one capability at a
# time instead, so better adapters still get the richer config.
if sudo ip link set $CAN_IFACE type can bitrate 500000 sjw 2 \\
        dbitrate 2000000 dsjw 15 berr-reporting on fd on 2>/dev/null; then
  echo "enablecan: $CAN_IFACE configured with CAN-FD (500000/2000000)"
elif sudo ip link set $CAN_IFACE type can bitrate 500000 sjw 2 berr-reporting on 2>/dev/null; then
  echo "enablecan: $CAN_IFACE configured as classic CAN (500000) with berr-reporting"
elif sudo ip link set $CAN_IFACE type can bitrate 500000 sjw 2; then
  echo "enablecan: $CAN_IFACE configured as classic CAN (500000), no FD or berr-reporting"
else
  echo "enablecan: failed to configure $CAN_IFACE" >&2
  exit 1
fi

sudo ip link set up $CAN_IFACE || {
  echo "enablecan: failed to bring up $CAN_IFACE" >&2; exit 1; }

# Verify rather than assume. Without this the unit reports "active" whenever
# the last command happened to exit 0, so can.service's Restart=on-failure
# would never fire on a silently misconfigured bus.
#
# Note this checks the LINK is up, not that the bus is healthy. A bus with no
# other node powered still comes UP and then sits in ERROR-PASSIVE; use
# 'candump $CAN_IFACE' and 'ip -details link show $CAN_IFACE' to check that.
for _ in \$(seq 10); do
  if [ "\$(ip -brief link show $CAN_IFACE 2>/dev/null | awk '{print \$2}')" = "UP" ]; then
    echo "enablecan: $CAN_IFACE is UP"
    exit 0
  fi
  sleep 0.5
done
echo "enablecan: $CAN_IFACE did not come UP" >&2
exit 1
EOF_ENABLECAN
sudo chmod +x /usr/sbin/enablecan
print_green "  wrote /usr/sbin/enablecan"

sudo tee /etc/systemd/system/can.service >/dev/null <<'EOF_CANSVC'
[Unit]
Description=Bring up CAN interface
After=network.target
Wants=network.target
# Retry forever rather than giving up: a finite cap left the unit permanently
# dead once the burst was spent ("Start request repeated too quickly"), so an
# adapter plugged in later was never picked up. Safe *because* RestartSec
# below provides the backoff. On modern systemd this key belongs in [Unit].
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/sbin/enablecan
RemainAfterExit=true
TimeoutStartSec=45
Restart=on-failure
# Without an explicit RestartSec, systemd retries every ~100ms. With the
# USB-CAN adapter unplugged this becomes a restart storm (observed >2600
# restarts in minutes), burning CPU and flooding the journal.
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_CANSVC
print_green "  wrote /etc/systemd/system/can.service"

# --- can-watchdog ------------------------------------------------------
# can.service is Type=oneshot + RemainAfterExit, so systemd reports it active
# forever once the link is up and Restart= can never fire again -- an adapter
# knocked loose mid-mission would go unnoticed. Poll the link instead.
sudo tee /usr/sbin/can-watchdog >/dev/null <<EOF_CANWD
#!/bin/bash
IFACE=$CAN_IFACE
state=\$(ip -brief link show "\$IFACE" 2>/dev/null | awk '{print \$2}')
[ "\$state" = "UP" ] && exit 0
echo "can-watchdog: \$IFACE is \${state:-missing}; restarting can.service"
systemctl restart can.service
EOF_CANWD
sudo chmod +x /usr/sbin/can-watchdog

sudo tee /etc/systemd/system/can-watchdog.service >/dev/null <<'EOF_CANWDSVC'
[Unit]
Description=Restart can.service if the CAN link has dropped
After=can.service
# Deliberately not Requires=/Wants=can.service: this must still run when
# can.service is failed, which is exactly when it is needed.

[Service]
Type=oneshot
ExecStart=/usr/sbin/can-watchdog
EOF_CANWDSVC

sudo tee /etc/systemd/system/can-watchdog.timer >/dev/null <<'EOF_CANWDTMR'
[Unit]
Description=Periodically verify the CAN link is up

[Timer]
# Give can.service a chance to bring the link up at boot before checking.
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5
Unit=can-watchdog.service

[Install]
WantedBy=timers.target
EOF_CANWDTMR
print_green "  wrote can-watchdog.service + .timer"

sudo systemctl daemon-reload
sudo systemctl enable can.service >/dev/null 2>&1 || warn "Could not enable can.service"
sudo systemctl enable --now can-watchdog.timer >/dev/null 2>&1 || \
    warn "Could not enable can-watchdog.timer"

if sudo systemctl restart can.service; then
    sleep 2
    if ip link show "$CAN_IFACE" >/dev/null 2>&1; then
        print_green "  $CAN_IFACE is up"
    else
        warn "$CAN_IFACE did not come up. Check the USB-CAN adapter is plugged in and the rover is powered."
    fi
else
    warn "can.service failed to start (adapter probably not connected yet). It will retry at boot."
fi

#########################################################################
step "Workspace + repositories"
#########################################################################
if [ "$DO_BOOTSTRAP_AUTH" = true ]; then
    print_italic "Bootstrapping per-machine GitHub access"
    bootstrap_auth
fi
detect_auth
mkdir -p "$WORKSPACE_DIR/src"
cd "$WORKSPACE_DIR/src"

print_italic "roverrobotics_ros2 (private, patched: battery calibration + $CAN_IFACE)"
clone_or_update "$ROVER_REPO_NAME" "$ROVER_REPO_BRANCH" "$WORKSPACE_DIR/src/$ROVER_REPO_NAME"

print_italic "web_video_server (private, patched: configurable H.264 rate control)"
clone_or_update "$WVS_REPO_NAME" "$WVS_REPO_BRANCH" "$WORKSPACE_DIR/src/$WVS_REPO_NAME"

if [ "$DO_IMU" = true ]; then
    print_italic "bno055 IMU"
    if [ -d "$WORKSPACE_DIR/src/bno055/.git" ]; then
        print_green "  bno055 already present"
    elif git clone "$IMU_REPO" "$WORKSPACE_DIR/src/bno055"; then
        print_green "  cloned bno055"
    else
        warn "Failed to clone the BNO055 repository"
    fi
else
    print_italic "  BNO055 skipped (--skip-imu)"
fi

#########################################################################
step "RealSense"
#########################################################################
if [ "$DO_REALSENSE" = true ]; then

    # --- librealsense SDK (built with CUDA when available) --------------
    if [ "$DO_LIBREALSENSE_BUILD" = true ]; then
        if command -v realsense-viewer >/dev/null 2>&1 && \
           ! confirm "  librealsense already appears installed. Rebuild it (~45 min)?" no; then
            print_green "  keeping the existing librealsense install"
        else
            print_yellow "  Make sure the RealSense camera is NOT plugged in during the SDK build."
            confirm "  Camera unplugged, continue?" yes || { echo "Aborted."; exit 0; }

            apt_try libssl-dev libusb-1.0-0-dev libudev-dev \
                    libgtk-3-dev libglfw3-dev libgl1-mesa-dev libglu1-mesa-dev \
                    at libomp-dev

            cd "$HOME"
            wget -qO libuvc_installation.sh \
                https://github.com/IntelRealSense/librealsense/raw/master/scripts/libuvc_installation.sh

            # Patch the cmake invocation to build with CUDA support.
            if [ "$CUDA_OK" = true ]; then
                sed -i 's|cmake \.\./.*|cmake ../ -DFORCE_LIBUVC=true -DCMAKE_BUILD_TYPE=release -DBUILD_EXAMPLES=true -DBUILD_GRAPHICAL_EXAMPLES=true -DBUILD_WITH_CUDA=on|' \
                    libuvc_installation.sh
            else
                sed -i 's|cmake \.\./.*|cmake ../ -DFORCE_LIBUVC=true -DCMAKE_BUILD_TYPE=release -DBUILD_EXAMPLES=true -DBUILD_GRAPHICAL_EXAMPLES=true -DBUILD_WITH_CUDA=off|' \
                    libuvc_installation.sh
            fi

            # Intel's script prompts "Remove all RealSense cameras attached"
            # whenever /dev/video* exists, and it runs under 'bash -xe'. An
            # unattended run has stdin on /dev/null, so 'read' returns EOF
            # non-zero and -e kills the build in seconds -- a plugged-in camera
            # is what breaks it. Neutralize the prompt: with FORCE_LIBUVC the
            # build never touches the kernel uvc driver, so a connected camera
            # is harmless (replug afterwards to pick up the new udev rules).
            sed -i 's|^\([[:space:]]*\)read -p .*|\1true|' libuvc_installation.sh
            if grep -q '^[[:space:]]*read ' libuvc_installation.sh; then
                warn "libuvc_installation.sh still has an interactive prompt after patching;
       upstream may have changed. The build will likely abort on EOF."
            fi

            chmod +x ./libuvc_installation.sh
            print_italic "  building librealsense (this can take ~45 minutes)..."
            if ./libuvc_installation.sh; then
                print_green "  librealsense installed. You can plug the D435 back in."
            else
                warn "librealsense build failed. Verify with: realsense-viewer"
            fi
            cd "$WORKSPACE_DIR/src"
        fi
    else
        print_italic "  librealsense SDK rebuild skipped (--skip-librealsense)"
    fi

    # --- RealSense ROS 2 wrapper ---------------------------------------
    if [ -d "$WORKSPACE_DIR/src/realsense-ros/.git" ]; then
        print_green "  realsense-ros already present"
    elif git clone "$REALSENSE_ROS_REPO" -b "$REALSENSE_ROS_BRANCH" \
            "$WORKSPACE_DIR/src/realsense-ros"; then
        print_green "  cloned realsense-ros ($REALSENSE_ROS_BRANCH)"
    else
        warn "Failed to clone realsense-ros"
    fi

    # --- USB reset helper ----------------------------------------------
    sudo tee /usr/local/sbin/reset_realsense_usb.sh >/dev/null <<'EOF_RSRESET'
#!/bin/bash
# Reset RealSense USB device before starting the camera node
# This helps recover from USB enumeration issues

for dev in /sys/bus/usb/devices/*/product; do
  if grep -qi "RealSense" "$dev" 2>/dev/null; then
    usb_path=$(dirname "$dev")
    auth_file="${usb_path}/authorized"
    if [[ -w "$auth_file" ]]; then
      echo 0 > "$auth_file"
      sleep 1
      echo 1 > "$auth_file"
    fi
  fi
done
exit 0
EOF_RSRESET
    sudo chmod +x /usr/local/sbin/reset_realsense_usb.sh
    print_green "  wrote /usr/local/sbin/reset_realsense_usb.sh"

    # The unit runs 'sudo -n' as $RUN_USER, which fails without a NOPASSWD
    # rule. Scoped to this one script rather than a blanket grant.
    echo "$RUN_USER ALL=(root) NOPASSWD: /usr/local/sbin/reset_realsense_usb.sh" \
        | sudo tee /etc/sudoers.d/rover-realsense >/dev/null
    sudo chmod 0440 /etc/sudoers.d/rover-realsense
    if sudo visudo -cf /etc/sudoers.d/rover-realsense >/dev/null 2>&1; then
        print_green "  wrote /etc/sudoers.d/rover-realsense (NOPASSWD for the reset helper)"
    else
        sudo rm -f /etc/sudoers.d/rover-realsense
        warn "sudoers drop-in failed validation and was removed; rover-realsense.service will not be able to reset USB."
    fi

    # --- systemd unit ---------------------------------------------------
    sudo tee /etc/systemd/system/rover-realsense.service >/dev/null <<EOF_RSSVC
[Unit]
Description=Intel RealSense Camera ROS2 Node
Wants=network-online.target
After=network-online.target
# Restart forever. systemd's default limit is 5 starts per 10s, which
# RestartSec=5 below stays clear of -- but only just, and tripping it would
# leave the camera permanently down until someone intervened. Disable it.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$RUN_HOME
Environment=HOME=$RUN_HOME
Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ExecStartPre=/usr/bin/sudo -n /usr/local/sbin/reset_realsense_usb.sh
ExecStart=/usr/bin/env bash -lc '\\
  source /opt/ros/$ROS_DISTRO_SEL/setup.bash; \\
  source $WORKSPACE_DIR/install/setup.bash; \\
  ros2 launch realsense2_camera rs_launch.py & \\
  sleep 5; \\
  ros2 run web_video_server web_video_server & \\
  wait'
Restart=always
# Every restart re-runs the ExecStartPre USB reset, so keep some distance
# between attempts when the camera is missing or wedged.
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_RSSVC
    print_green "  wrote /etc/systemd/system/rover-realsense.service"
    sudo systemctl daemon-reload
    sudo systemctl enable rover-realsense.service >/dev/null 2>&1 || \
        warn "Could not enable rover-realsense.service"

    # The SDK build asks for the camera to be unplugged, and nothing ever asked
    # for it back -- so a run could finish "successfully" with no camera
    # attached and rover-realsense.service starting against nothing. A replug is
    # wanted here anyway, to pick up the udev rules written below. Poll rather
    # than block on a keypress, so this behaves the same attended or under -y.
    # '|| true' matters: the script runs under 'set -e' and the not-found path
    # returns 1, which would otherwise abort the run on the very case this is
    # meant to survive.
    wait_for_realsense || true
else
    print_italic "  RealSense skipped (--skip-realsense)"
fi

#########################################################################
step "udev rules"
#########################################################################
if [ "$DO_UDEV" = true ]; then
    sudo tee /etc/udev/rules.d/55-roverrobotics.rules >/dev/null <<'EOF_UDEV'
# creates fixed name for rover serial communication
# WARNING this will overwrite any FTDI device that have the similar signature

# Sensor Udev Rules
KERNEL=="ttyUSB*", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE:="0777", SYMLINK+="rplidar"
KERNEL=="ttyUSB*", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", MODE:="0777", SYMLINK+="bno055"
KERNEL=="ttyACM*", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a9", MODE:="0777", SYMLINK+="ublox-gps"

# Rover ESC Udev Rules
KERNEL=="ttyUSB[0-9]", ATTRS{idVendor}=="0403", ATTRS{serial}=="Rover Zero 2", MODE:="0777", SYMLINK+="rover-control", RUN+="/bin/setserial /dev/%k low_latency"
KERNEL=="ttyUSB[0-9]", ATTRS{idVendor}=="0403", ATTRS{serial}=="Rover Pro", MODE:="0777", SYMLINK+="rover-pro", RUN+="/bin/setserial /dev/%k low_latency"
KERNEL=="ttyUSB[0-9]", ATTRS{idVendor}=="10c4", ATTRS{serial}=="Rover Pro", MODE:="0777", SYMLINK+="rover-pro", RUN+="/bin/setserial /dev/%k low_latency"
KERNEL=="ttyACM[0-9]", ATTRS{idVendor}=="0483", MODE:="0777", SYMLINK+="rover-control", RUN+="/bin/setserial /dev/%k low_latency"
EOF_UDEV
    print_green "  wrote /etc/udev/rules.d/55-roverrobotics.rules"
    sudo udevadm control --reload-rules >/dev/null 2>&1 || warn "udevadm reload-rules failed"
    sudo udevadm trigger >/dev/null 2>&1 || warn "udevadm trigger failed"
    print_green "  udev rules reloaded (a reboot may still be needed)"

    # dialout gives the rover user access to the serial devices above.
    if ! id -nG "$RUN_USER" | grep -qw dialout; then
        sudo usermod -aG dialout "$RUN_USER"
        warn "Added $RUN_USER to 'dialout'. Log out and back in for it to take effect."
    fi
else
    print_italic "  udev skipped (--skip-udev)"
fi

#########################################################################
step "rosdep"
#########################################################################
if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    sudo rosdep init || warn "rosdep init failed"
fi
rosdep update || warn "rosdep update failed"

cd "$WORKSPACE_DIR"
# librealsense2 is installed from source above, so rosdep must not try to
# satisfy it from apt.
rosdep install -i --from-path src --rosdistro "$ROS_DISTRO_SEL" \
    --skip-keys=librealsense2 -y || \
    warn "rosdep reported unresolved dependencies; the build may still succeed."

#########################################################################
step "Autostart service (roverrobotics.service)"
#########################################################################
if [ "$DO_AUTOSTART" = true ]; then
    sudo tee /usr/sbin/roverrobotics >/dev/null <<EOF_RRSCRIPT
#!/bin/bash
source /opt/ros/$ROS_DISTRO_SEL/setup.bash
source $WORKSPACE_DIR/install/setup.bash
ros2 launch roverrobotics_driver ${ROBOT_TYPE}_teleop.launch.py
EOF_RRSCRIPT
    sudo chmod +x /usr/sbin/roverrobotics
    print_green "  wrote /usr/sbin/roverrobotics ($ROBOT_TYPE)"

    sudo tee /etc/systemd/system/roverrobotics.service >/dev/null <<EOF_RRSVC
[Unit]
Description=Rover Robotics $ROBOT_TYPE driver
After=can.service network.target
Wants=can.service
# Same reasoning as can.service: retry forever, and rely on RestartSec below
# for the backoff rather than a cap. A cap means that a rover booted before
# its CAN bus is ready stays dead until a human intervenes -- the opposite of
# what an unattended deployment needs.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RUN_USER
Environment=HOME=$RUN_HOME
# Must match rover-realsense.service and the ~/.bashrc pin. systemd units do
# not read .bashrc, so every unit needs its own copy. Mixing RMW
# implementations is unsupported in ROS 2: the driver and the camera node
# would each come up fine yet never see each other's topics.
Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ExecStart=/bin/bash /usr/sbin/roverrobotics
# 'always', not 'on-failure': a driver that exits 0 has still stopped driving
# the robot, so treat a clean exit as something to recover from too.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_RRSVC
    print_green "  wrote /etc/systemd/system/roverrobotics.service"
    sudo systemctl daemon-reload
    sudo systemctl enable roverrobotics.service >/dev/null 2>&1 || \
        warn "Could not enable roverrobotics.service"
else
    print_italic "  autostart skipped (--skip-autostart)"
fi

#########################################################################
step "Build the workspace"
#########################################################################
BUILD_OK=false
if [ "$DO_BUILD" = true ]; then
    cd "$WORKSPACE_DIR"
    set +u
    # shellcheck disable=SC1090
    source "/opt/ros/$ROS_DISTRO_SEL/setup.bash"
    set -u

    print_italic "  colcon build (this will take a while)..."
    if colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release; then
        BUILD_OK=true
        print_green "  build succeeded"

        WS_SOURCE_LINE="source $WORKSPACE_DIR/install/setup.bash"
        if ! grep -Fq "$WS_SOURCE_LINE" "$RUN_HOME/.bashrc" 2>/dev/null; then
            echo "$WS_SOURCE_LINE" >> "$RUN_HOME/.bashrc"
            print_green "  added workspace sourcing to ~/.bashrc"
        fi
    else
        warn "colcon build FAILED. Inspect $WORKSPACE_DIR/log/latest_build/ for details."
    fi
else
    print_italic "  build skipped (--no-build)"
fi

#########################################################################
#                              SUMMARY                                  #
#########################################################################
echo ""
print_bold "====================================================="
if [ ${#WARNINGS[@]} -eq 0 ]; then
    print_green " Setup completed with no warnings."
else
    print_yellow " Setup completed with ${#WARNINGS[@]} warning(s):"
    for w in "${WARNINGS[@]}"; do
        print_yellow "   - $w"
    done
fi
print_bold "-----------------------------------------------------"
echo ""
print_bold "Installed:"
echo "  workspace          : $WORKSPACE_DIR"
echo "  rover driver       : $GITHUB_OWNER/$ROVER_REPO_NAME @ $ROVER_REPO_BRANCH"
echo "  web_video_server   : $GITHUB_OWNER/$WVS_REPO_NAME @ $WVS_REPO_BRANCH"
[ "$DO_IMU" = true ]       && echo "  bno055 IMU         : $WORKSPACE_DIR/src/bno055"
[ "$DO_REALSENSE" = true ] && echo "  realsense-ros      : $WORKSPACE_DIR/src/realsense-ros"
echo ""
print_bold "Services:"
echo "  can.service              -> /usr/sbin/enablecan ($CAN_IFACE)"
[ "$DO_AUTOSTART" = true ] && echo "  roverrobotics.service    -> ${ROBOT_TYPE}_teleop.launch.py"
[ "$DO_REALSENSE" = true ] && echo "  rover-realsense.service  -> realsense2_camera + web_video_server"
echo ""
print_bold "Next steps:"
echo "  1. Reboot so gs_usb, udev rules and the dialout group take effect:"
echo "       sudo reboot"
echo "  2. Check status:"
echo "       systemctl status can.service roverrobotics.service rover-realsense.service"
echo "  3. Video stream (once rover-realsense.service is up):"
echo "       http://<rover-ip>:8080/stream?topic=/camera/camera/color/image_raw&type=h264&bitrate=2000000"
echo "       (drop &bitrate to use CRF mode; add &crf=<n> to tune quality)"
echo ""
print_bold "====================================================="

if [ "$DO_BUILD" = true ] && [ "$BUILD_OK" != true ]; then
    exit 1
fi

# Deliberately last, and deliberately opt-in: over SSH this drops the
# connection, and rebooting a machine nobody asked to reboot is a bad default.
# Never reached when the build failed -- the exit above sees to that, so a
# broken provision stays up for inspection instead of rebooting into it.
if [ "$DO_REBOOT" = true ]; then
    print_bold "Rebooting now (--reboot) so gs_usb, udev rules and the dialout group take effect."
    sync
    sudo shutdown -r +1 "rover provisioning complete; rebooting" || sudo reboot
fi
exit 0
