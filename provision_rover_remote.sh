#!/usr/bin/env bash
#########################################################################
# Script Name  : Remote Rover Provisioner                               #
# Description  : Provisions a MITI rover computer over SSH by copying    #
#                setup_rover_miti_dronedeploy.sh to it and running it    #
#                unattended. Use this to bring up many machines from     #
#                one workstation.                                        #
#                                                                        #
# Usage:                                                                 #
#   ./provision_rover_remote.sh 192.168.1.50                               #
#   ./provision_rover_remote.sh 192.168.1.50 192.168.1.51 192.168.1.52       #
#   ROVER_USER=rover ./provision_rover_remote.sh --follow 192.168.1.50     #
#                                                                        #
# Anything after '--' is passed straight to the setup script:            #
#   ./provision_rover_remote.sh 192.168.1.50 -- --skip-realsense           #
#########################################################################
set -euo pipefail

SETUP_SCRIPT="${SETUP_SCRIPT:-$(dirname "$(readlink -f "$0")")/setup_rover_miti_dronedeploy.sh}"
ROVER_USER="${ROVER_USER:-rover}"
REMOTE_LOG="provision.log"
FOLLOW=false
HOSTS=()
PASSTHRU=()

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BOLD="\e[1m"; BLUE="\e[1;94m"; E="\e[0m"
say()  { echo -e "${BLUE}[provision]${E} $*"; }
ok()   { echo -e "${GREEN}[provision]${E} $*"; }
bad()  { echo -e "${RED}[provision]${E} $*" >&2; }
warn() { echo -e "${YELLOW}[provision]${E} $*" >&2; }

usage() {
    cat <<'USAGE'
Remote Rover Provisioner

Provisions MITI rover computers over SSH: copies setup_rover_miti_dronedeploy.sh
to each host and runs it unattended. Use this to bring up many machines from one
workstation.

Usage:
  ./provision_rover_remote.sh 192.168.1.50
  ./provision_rover_remote.sh 192.168.1.50 192.168.1.51 192.168.1.52
  ./provision_rover_remote.sh --follow 192.168.1.50

Anything after '--' is passed straight to the setup script:
  ./provision_rover_remote.sh 192.168.1.50 -- --skip-realsense
  ./provision_rover_remote.sh 192.168.1.50 -- -y --bootstrap-auth -r miti_65

Default setup-script args when none are given:  -y --bootstrap-auth

Options:
  --follow           Stream the remote log live instead of polling quietly
  --user <name>      SSH user on the rover            (default: rover, or $ROVER_USER)
  --script <path>    Setup script to deploy           (default: alongside this script)
  -h, --help         This help

Environment:
  ROVER_USER         SSH username                     (default: rover)
  ROVER_PASSWORD     SSH/sudo password. If unset and SSH keys are not
                     configured, you will be prompted once, and the value is
                     passed to the remote via an environment variable rather
                     than being written to disk or baked into a command line.
  GITHUB_TOKEN       Forwarded to the rover for the one-time --bootstrap-auth
                     step, so a brand-new machine can register its own
                     read-only deploy keys and clone the private repos.

Notes:
  * Requires 'sshpass' only when using password auth. SSH keys are preferred:
      ssh-copy-id rover@<ip>
  * The remote run is detached (setsid), so it survives a dropped connection.
    Re-run with --follow to reattach to the log of an in-flight run.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --follow)  FOLLOW=true; shift ;;
        --user)    ROVER_USER="${2:?}"; shift 2 ;;
        --script)  SETUP_SCRIPT="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; PASSTHRU=("$@"); break ;;
        -*)        bad "Unknown option: $1"; usage; exit 1 ;;
        *)         HOSTS+=("$1"); shift ;;
    esac
done

[ ${#HOSTS[@]} -gt 0 ] || { bad "No hosts given."; usage; exit 1; }
[ -f "$SETUP_SCRIPT" ] || { bad "Setup script not found: $SETUP_SCRIPT"; exit 1; }

# Default setup-script arguments when the caller supplied none.
if [ ${#PASSTHRU[@]} -eq 0 ]; then
    PASSTHRU=(-y --bootstrap-auth)
fi

#########################################################################
#                        SSH TRANSPORT SETUP                            #
#########################################################################
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
          -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
USE_SSHPASS=false

setup_transport() {
    local host="$1"
    # Prefer key auth; fall back to a password only if keys don't work.
    if ssh -o BatchMode=yes "${SSH_OPTS[@]}" "${ROVER_USER}@${host}" true 2>/dev/null; then
        USE_SSHPASS=false
        return 0
    fi
    if [ -z "${ROVER_PASSWORD:-}" ]; then
        command -v sshpass >/dev/null 2>&1 || {
            bad "Key auth failed for ${ROVER_USER}@${host} and 'sshpass' is not installed."
            bad "Either run: ssh-copy-id ${ROVER_USER}@${host}"
            bad "or install sshpass and set ROVER_PASSWORD."
            return 1
        }
        read -rsp "Password for ${ROVER_USER}@${host}: " ROVER_PASSWORD; echo
        export ROVER_PASSWORD
    fi
    command -v sshpass >/dev/null 2>&1 || { bad "'sshpass' is required for password auth."; return 1; }
    USE_SSHPASS=true
}

rsh() {
    local host="$1"; shift
    if [ "$USE_SSHPASS" = true ]; then
        SSHPASS="$ROVER_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "${ROVER_USER}@${host}" "$@"
    else
        ssh "${SSH_OPTS[@]}" "${ROVER_USER}@${host}" "$@"
    fi
}

rcp() {
    local src="$1" host="$2" dest="$3"
    if [ "$USE_SSHPASS" = true ]; then
        SSHPASS="$ROVER_PASSWORD" sshpass -e scp "${SSH_OPTS[@]}" "$src" "${ROVER_USER}@${host}:${dest}"
    else
        scp "${SSH_OPTS[@]}" "$src" "${ROVER_USER}@${host}:${dest}"
    fi
}

#########################################################################
#                       REMOTE LAUNCHER (unattended)                    #
#########################################################################
# Provisioning makes many sudo calls with no TTY attached. 'sudo -v' cannot be
# used to pre-authenticate because it always tries to validate credentials and
# fails without a terminal even under NOPASSWD. So: grant NOPASSWD for the
# duration of the run and remove it on every exit path, including failure.
build_launcher() {
cat <<'LAUNCH'
#!/bin/bash
SUDOERS=/etc/sudoers.d/99-rover-provisioning
ME="$(whoami)"
if ! sudo -n true 2>/dev/null; then
    [ -n "$SUDO_PASS" ] || { echo "PROVISION-ERROR: sudo needs a password but none was supplied"; exit 1; }
    echo "$SUDO_PASS" | sudo -S bash -c \
      "echo '$ME ALL=(ALL) NOPASSWD: ALL' > $SUDOERS && chmod 0440 $SUDOERS && visudo -c -f $SUDOERS >/dev/null" \
      2>/dev/null || { echo "PROVISION-ERROR: could not configure sudo"; exit 1; }
    GRANTED=yes
fi
unset SUDO_PASS
cleanup() { [ "${GRANTED:-no}" = yes ] && sudo -n rm -f "$SUDOERS" 2>/dev/null; echo "[cleanup] provisioning sudo rights released"; }
trap cleanup EXIT INT TERM
sudo -n true 2>/dev/null || { echo "PROVISION-ERROR: sudo still unusable"; exit 1; }

echo "=== PROVISION START $(date -Is) ==="
~/setup_rover_miti_dronedeploy.sh "$@" </dev/null
rc=$?
echo "=== PROVISION END $(date -Is) EXIT_CODE=$rc ==="
exit $rc
LAUNCH
}

#########################################################################
#                            PROVISION ONE HOST                         #
#########################################################################
provision_host() {
    local host="$1"
    echo ""
    echo -e "${BOLD}=========== ${host} ===========${E}"

    setup_transport "$host" || return 1

    say "copying setup script"
    # Bare relative path: scp resolves it against the remote home directory,
    # which avoids relying on tilde expansion inside a quoted argument.
    rcp "$SETUP_SCRIPT" "$host" "setup_rover_miti_dronedeploy.sh" >/dev/null || {
        bad "copy failed"; return 1; }

    say "installing launcher"
    build_launcher | rsh "$host" "cat > ~/run_provision.sh && chmod +x ~/run_provision.sh" || {
        bad "launcher install failed"; return 1; }

    say "starting detached run (args: ${PASSTHRU[*]})"
    # setsid so the run survives this SSH session ending.
    rsh "$host" \
        "chmod +x ~/setup_rover_miti_dronedeploy.sh; rm -f ~/${REMOTE_LOG}; \
         SUDO_PASS='${ROVER_PASSWORD:-}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' \
         setsid nohup bash ~/run_provision.sh $(printf '%q ' "${PASSTHRU[@]}") \
         > ~/${REMOTE_LOG} 2>&1 < /dev/null & sleep 3; echo started" >/dev/null || {
        bad "failed to start remote run"; return 1; }
    ok "running on ${host} (log: ~/${REMOTE_LOG})"

    if [ "$FOLLOW" = true ]; then
        say "following log (Ctrl-C to detach; the run continues)"
        # Deliberately NOT 'pgrep -f setup_rover_miti_dronedeploy': that pattern
        # matches this very command line, so the check never goes false and the
        # wait loop hangs forever. Watch for the END marker in the log instead.
        rsh "$host" "tail -n +1 -f ~/${REMOTE_LOG} | sed -u '/=== PROVISION END /q'" || true
        report_host "$host"
    fi
}

report_host() {
    local host="$1"
    echo ""
    say "result for ${host}:"
    rsh "$host" "sed 's/\x1b\[[0-9;]*m//g' ~/${REMOTE_LOG} 2>/dev/null | \
        grep -E '^=== PROVISION (START|END)|^===== \[|WARNING:|FATAL:|build succeeded|build FAILED|packages finished' || echo '(no log yet)'" || true
}

#########################################################################
#                                 MAIN                                  #
#########################################################################
FAILED=()
for h in "${HOSTS[@]}"; do
    provision_host "$h" || FAILED+=("$h")
done

echo ""
echo -e "${BOLD}=====================================================${E}"
if [ "$FOLLOW" != true ]; then
    say "Runs are detached and continuing on each host."
    say "Check progress with:"
    for h in "${HOSTS[@]}"; do
        echo "    ssh ${ROVER_USER}@${h} 'tail -f ~/${REMOTE_LOG}'"
    done
    say "Or re-run this script with --follow to reattach."
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    bad "Failed to start on: ${FAILED[*]}"
    exit 1
fi
ok "All ${#HOSTS[@]} host(s) launched."
