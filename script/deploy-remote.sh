#!/usr/bin/env bash
# Build in WSL/Linux and deploy an IgH EtherCAT master to a Linux SSH host.
set -Eeuo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HOST=192.168.1.124
REMOTE_USER=think
PORT=22
IDENTITY=
DRIVER=igc
JOBS=$(nproc)
WORK_DIR=
MODE=deploy
RESTART=0
EXTRA_SSH_OPTIONS=()
RUNTIME=
REMOTE_DIR=

log() { printf '\n[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: script/deploy-remote.sh [options]

Build locally, then install over SSH. Existing /etc/ethercat.conf is preserved.
Default target: think@192.168.1.124; prefix: /usr/local; driver: igc + generic.

  --host HOST          Target IPv4 address or hostname
  --user USER          SSH user (default: think)
  --port PORT          SSH port (default: 22)
  --identity FILE      SSH private key
  --ssh-option OPTION  Extra ssh -o option; may be repeated
  --driver DRIVER      igc or generic (default: igc; always builds generic)
  --jobs N             Parallel build jobs (default: nproc)
  --work-dir DIR       Cache/output directory outside the source repository
  --cc COMMAND         C compiler (default: gcc matching the target kernel)
  --cxx COMMAND        C++ compiler (default: g++ with the same major as CC)
  --check              Check local/remote prerequisites without building/installing
  --build-only         Build and stage locally without installing remotely
  --restart            Stop the service if necessary, install, then start it
  -h, --help           Show help

Without --restart, deployment requires an inactive service and unloaded modules,
and leaves the service stopped. SSH/sudo request credentials interactively;
passwords are never saved. See docs/remote-deployment.md.
USAGE
}

CC=${CC:-}
CXX=${CXX:-}
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --check|--build-only)
            [[ $MODE == deploy ]] || die '--check and --build-only are mutually exclusive'
            MODE=${1#--}; shift ;;
        --restart) RESTART=1; shift ;;
        --host|--user|--port|--identity|--driver|--jobs|--work-dir|--cc|--cxx|--ssh-option)
            (($# >= 2)) && [[ -n $2 && $2 != --* ]] || die "Missing value for $1"
            case "$1" in
                --host) HOST=$2 ;; --user) REMOTE_USER=$2 ;; --port) PORT=$2 ;;
                --identity) IDENTITY=$2 ;; --driver) DRIVER=$2 ;; --jobs) JOBS=$2 ;;
                --work-dir) WORK_DIR=$2 ;; --cc) CC=$2 ;; --cxx) CXX=$2 ;;
                --ssh-option) EXTRA_SSH_OPTIONS+=(-o "$2") ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ $HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Invalid host (use an IPv4 address or hostname)'
[[ $REMOTE_USER =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'Invalid SSH user'
[[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((PORT <= 65535)) || die 'Invalid SSH port'
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'
[[ $DRIVER == igc || $DRIVER == generic ]] || die '--driver must be igc or generic'
[[ $MODE == deploy || $RESTART == 0 ]] || die '--restart requires deployment mode'
[[ ! $SOURCE_DIR =~ [[:space:]] ]] || die 'Kbuild requires a source path without whitespace'

for cmd in ssh rsync git make autoconf automake libtoolize pkg-config modinfo flock; do
    command -v "$cmd" >/dev/null || die "Missing local command: $cmd (see the dependency list in docs/remote-deployment.md)"
done
[[ -z $IDENTITY || -f $IDENTITY ]] || die "SSH identity does not exist: $IDENTITY"
git -C "$SOURCE_DIR" rev-parse --show-toplevel >/dev/null

RUNTIME=$(mktemp -d /tmp/ethercat-deploy.XXXXXXXX)
SSH_ARGS=(-p "$PORT" -o ConnectTimeout=10 -o ControlMaster=auto
          -o ControlPersist=60 -o "ControlPath=$RUNTIME/ssh")
[[ -z $IDENTITY ]] || SSH_ARGS+=(-i "$IDENTITY")
SSH_ARGS+=("${EXTRA_SSH_OPTIONS[@]}")
TARGET="$REMOTE_USER@$HOST"
cleanup() {
    local result=$?
    trap - EXIT
    if ((result != 0)); then
        printf '\n[deploy] Failed; installation files and backups are retained.\n' >&2
        [[ -z $REMOTE_DIR ]] || printf '[deploy] Remote staging directory: %s:%s\n' "$TARGET" "$REMOTE_DIR" >&2
    fi
    ssh "${SSH_ARGS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
    rm -rf -- "$RUNTIME"
    exit "$result"
}
trap cleanup EXIT

# Quote every argument because ssh passes a command string to the remote shell.
remote() {
    local command
    printf -v command '%q ' "$@"
    ssh "${SSH_ARGS[@]}" "$TARGET" "$command"
}
printf -v RSYNC_SSH '%q ' ssh "${SSH_ARGS[@]}"

log "Inspecting $TARGET"
remote bash -s -- "$MODE" > "$RUNTIME/target-info" <<'REMOTE_CHECK'
set -euo pipefail
for cmd in bash rsync getconf readlink; do
    command -v "$cmd" >/dev/null || { echo "Missing remote command: $cmd" >&2; exit 1; }
done
if [[ $1 != build-only ]]; then
    for cmd in sudo systemctl modinfo ldd tar ldconfig depmod flock; do
        command -v "$cmd" >/dev/null || { echo "Missing remote command: $cmd" >&2; exit 1; }
    done
    [[ -d /run/systemd/system ]] || { echo 'The target must run systemd.' >&2; exit 1; }
fi
kernel=$(uname -r)
headers=$(readlink -f "/lib/modules/$kernel/build")
for file in Makefile include/config/kernel.release Module.symvers; do
    [[ -s $headers/$file ]] || { echo "Missing target kernel file: $headers/$file" >&2; exit 1; }
done
[[ $(cat "$headers/include/config/kernel.release") == "$kernel" ]] || {
    echo 'Kernel headers do not match the running kernel.' >&2; exit 1;
}
gcc_major=$(sed -nE 's/.*gcc-([0-9]+).*/\1/p' /proc/version)
[[ -n $gcc_major ]] || { echo 'Only GCC-built target kernels are supported.' >&2; exit 1; }
printf '%s\n' "$kernel" "$(uname -m)" "$(getconf GNU_LIBC_VERSION)" "$headers" "$gcc_major"
REMOTE_CHECK
mapfile -t INFO < "$RUNTIME/target-info"
((${#INFO[@]} == 5)) || die 'Unexpected remote output; check remote shell startup files'
KVER=${INFO[0]}
ARCH=${INFO[1]}
REMOTE_GLIBC=${INFO[2]#glibc }
HEADERS=${INFO[3]}
GCC_MAJOR=${INFO[4]}
[[ $KVER =~ ^[a-zA-Z0-9._+-]+$ && $GCC_MAJOR =~ ^[0-9]+$ ]] || die 'Invalid remote kernel/compiler metadata'
[[ $HEADERS == /* && ! $HEADERS =~ [[:space:]] ]] || die 'Unsupported remote header path'
[[ $(uname -m) == "$ARCH" ]] || die 'Local/remote architectures differ; this script does not cross-compile'
LOCAL_GLIBC=$(getconf GNU_LIBC_VERSION)
LOCAL_GLIBC=${LOCAL_GLIBC#glibc }
[[ $(printf '%s\n%s\n' "$LOCAL_GLIBC" "$REMOTE_GLIBC" | sort -V | head -n 1) == "$LOCAL_GLIBC" ]] ||
    die "Local glibc $LOCAL_GLIBC is newer than target glibc $REMOTE_GLIBC; use a matching build environment"
CC=${CC:-gcc-$GCC_MAJOR}
CXX=${CXX:-g++-$GCC_MAJOR}
for cmd in "$CC" "$CXX"; do
    command -v "$cmd" >/dev/null || die "Missing compiler: $cmd; install gcc-$GCC_MAJOR and g++-$GCC_MAJOR locally"
done
[[ $("$CC" -dumpversion | cut -d. -f1) == "$GCC_MAJOR" ]] || die "CC must match the target kernel GCC major ($GCC_MAJOR)"
printf 'Target: %s\nKernel: %s (%s)\nHeaders: %s\nCompiler: %s / %s\nglibc: local %s, target %s\n' \
    "$TARGET" "$KVER" "$ARCH" "$HEADERS" "$CC" "$CXX" "$LOCAL_GLIBC" "$REMOTE_GLIBC"
[[ $MODE != check ]] || { log 'Prerequisite checks passed; nothing was built or installed.'; exit 0; }

WORK_DIR=${WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ethercat-deploy/$REMOTE_USER@$HOST-$PORT/$KVER}
mkdir -p -- "$WORK_DIR"
WORK_DIR=$(cd -- "$WORK_DIR" && pwd)
[[ ! $WORK_DIR =~ [[:space:]] ]] || die 'The work directory must not contain whitespace'
[[ $WORK_DIR != "$SOURCE_DIR" && $WORK_DIR != "$SOURCE_DIR/"* ]] || die 'Use a work directory outside the source repository'
exec 9> "$WORK_DIR/.lock"
flock -n 9 || die 'Another deployment is using this work directory'
KDIR="$WORK_DIR/kernel"
mkdir -p "$KDIR"
log 'Synchronizing target kernel headers (including linked build tools)'
rsync -azL -s -e "$RSYNC_SSH" "$TARGET:$HEADERS/" "$KDIR/"
[[ $(cat "$KDIR/include/config/kernel.release") == "$KVER" ]] || die 'Copied kernel headers do not match the target'

RELEASE=$(date +%Y%m%d-%H%M%S)-$$
RELEASE_DIR="$WORK_DIR/releases/$RELEASE"
BUILD="$RELEASE_DIR/build"
STAGE="$RELEASE_DIR/root"
mkdir -p "$BUILD" "$STAGE"

# Snapshot tracked and non-ignored untracked files, including uncommitted edits.
# Generated build products and the documentation-only submodule are excluded.
git -C "$SOURCE_DIR" ls-files --cached --others --exclude-standard -z -- . ':!:doxygen-layout' |
    while IFS= read -r -d '' file; do
        if [[ -f $SOURCE_DIR/$file || -L $SOURCE_DIR/$file ]]; then
            printf '%s\0' "$file"
        fi
    done > "$RUNTIME/source-files"
rsync -a --from0 --files-from="$RUNTIME/source-files" "$SOURCE_DIR/" "$BUILD/"
git -C "$SOURCE_DIR" describe --tags --always --dirty > "$BUILD/revision"
log "Building in $BUILD"
cd "$BUILD"
./bootstrap
CONFIGURE_ARGS=(--prefix=/usr/local --sysconfdir=/etc --disable-initd
                --with-systemdsystemunitdir=/lib/systemd/system
                "--with-linux-dir=$KDIR" --enable-generic)
[[ $DRIVER != igc ]] || CONFIGURE_ARGS+=(--enable-igc)
./configure "CC=$CC" "CXX=$CXX" "${CONFIGURE_ARGS[@]}"
make -j"$JOBS" all
make -j"$JOBS" modules "CC=$CC"
make install "DESTDIR=$STAGE"
make modules_install "INSTALL_MOD_PATH=$STAGE" DEPMOD=true

# Never ship links pointing back into the local WSL build tree, nor replace
# the target's existing configuration. A sample is retained for first installs.
rm -f -- "$STAGE/lib/modules/$KVER/build" "$STAGE/lib/modules/$KVER/source"
mv "$STAGE/etc/ethercat.conf" "$RELEASE_DIR/ethercat.conf.example"
MODULES=("$STAGE/lib/modules/$KVER/ethercat/master/ec_master.ko"
         "$STAGE/lib/modules/$KVER/ethercat/devices/ec_generic.ko")
[[ $DRIVER != igc ]] || MODULES+=("$STAGE/lib/modules/$KVER/ethercat/devices/igc/ec_igc.ko")
for module in "${MODULES[@]}"; do
    [[ -f $module ]] || die "Missing built module: $module"
    vermagic=$(modinfo -F vermagic "$module")
    [[ ${vermagic%% *} == "$KVER" ]] || die "Wrong module vermagic: $module ($vermagic)"
done
printf 'target=%s\nkernel=%s\nrevision=%s\ndriver=%s\ncc=%s\ncxx=%s\n' \
    "$TARGET" "$KVER" "$(cat revision)" "$DRIVER" "$CC" "$CXX" > "$RELEASE_DIR/build-info.txt"
log "Build verified. Installation tree: $STAGE"
[[ $MODE != build-only ]] || exit 0

# This installer runs on the target with sudo. It validates everything before
# stopping a service or replacing a file, and supplies a file-level rollback.
cat > "$RELEASE_DIR/install-remote.sh" <<'REMOTE_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
payload=$1
kernel=$2
restart=$3
driver=$4
root="$payload/root"
fail() { echo "[remote] ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Run this installer with sudo'
exec 8>/run/lock/ethercat-deploy.lock
flock -n 8 || fail 'Another installation or rollback is in progress'
[[ $(uname -r) == "$kernel" ]] || fail 'Target kernel changed during the build; build again'
[[ -f /etc/ethercat.conf ]] || fail "First installation: copy $payload/ethercat.conf.example to /etc/ethercat.conf and configure the EtherCAT interface/driver before deploying"
[[ -x $root/usr/local/bin/ethercat && -f $root/lib/modules/$kernel/ethercat/master/ec_master.ko ]] || fail 'Incomplete installation tree'

# Check runtime dependencies before touching the running installation.
while IFS= read -r -d '' binary; do
    dependencies=$(ldd "$binary" 2>&1) || fail "Unusable runtime dependencies for $binary: $dependencies"
    [[ $dependencies != *'not found'* ]] || fail "$dependencies"
done < <(find "$root/usr/local" -type f \( -name ethercat -o -name 'libethercat.so.*' \) -print0)
for module in "$root/lib/modules/$kernel/ethercat/master/ec_master.ko" \
              "$root/lib/modules/$kernel/ethercat/devices/ec_generic.ko"; do
    magic=$(modinfo -F vermagic "$module")
    [[ ${magic%% *} == "$kernel" ]] || fail "Wrong module version: $module"
done
if [[ $driver == igc ]]; then
    magic=$(modinfo -F vermagic "$root/lib/modules/$kernel/ethercat/devices/igc/ec_igc.ko")
    [[ ${magic%% *} == "$kernel" ]] || fail 'Wrong igc module version'
fi
if [[ $restart == 0 ]] && { systemctl is-active --quiet ethercat || [[ -d /sys/module/ec_master ]]; }; then
    fail 'EtherCAT is active or its modules are loaded. Stop it first, or deploy with --restart during a maintenance window.'
fi

backup=$(mktemp -d /var/backups/ethercat-deploy.XXXXXXXX)
echo "[remote] Backup and rollback: $backup"
trap 'echo "[remote] Installation failed. Inspect the error above; backup: $backup. Service may be stopped." >&2' ERR
cp -a /etc/ethercat.conf "$backup/ethercat.conf"
: > "$backup/previous-files"
: > "$backup/created-files"
cd "$root"
find . \( -type f -o -type l \) -print0 > "$backup/installed-files"
while IFS= read -r -d '' file; do
    if [[ -e /$file || -L /$file ]]; then
        printf '%s\0' "$file" >> "$backup/previous-files"
    else
        printf '%s\0' "$file" >> "$backup/created-files"
    fi
done < "$backup/installed-files"
tar -C / --null -T "$backup/previous-files" -cpf "$backup/previous.tar"
printf '%s\n' "$kernel" > "$backup/kernel-release"

cat > "$backup/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
exec 8>/run/lock/ethercat-deploy.lock
flock -n 8 || { echo 'Another installation or rollback is in progress' >&2; exit 1; }
backup=$(cd -- "$(dirname -- "$0")" && pwd)
kernel=$(cat "$backup/kernel-release")
if systemctl is-active --quiet ethercat || [[ -d /sys/module/ec_master ]]; then
    systemctl stop ethercat
fi
[[ ! -d /sys/module/ec_master ]] || { echo 'EtherCAT modules are still in use; stop their applications first.' >&2; exit 1; }
while IFS= read -r -d '' file; do rm -f -- "/$file"; done < "$backup/created-files"
tar -C / -xpf "$backup/previous.tar"
depmod -a "$kernel"
ldconfig
systemctl daemon-reload
echo 'Previous files restored. /etc/ethercat.conf was preserved. Start ethercat manually when ready.'
ROLLBACK
chmod 700 "$backup/rollback.sh"

if [[ $restart == 1 ]] && { systemctl is-active --quiet ethercat || [[ -d /sys/module/ec_master ]]; }; then
    systemctl stop ethercat
fi
[[ ! -d /sys/module/ec_master ]] || fail 'EtherCAT modules are still in use; stop their applications first'
# --keep-dirlinks preserves Ubuntu's /lib -> usr/lib directory symlink.
# No --delete: unrelated files/modules are not removed.
rsync -a --no-owner --no-group --no-perms --omit-dir-times --keep-dirlinks --checksum \
    --from0 --files-from="$backup/installed-files" "$root/" /
depmod -a "$kernel"
ldconfig
systemctl daemon-reload
installed_modules=(master/ec_master.ko devices/ec_generic.ko)
[[ $driver != igc ]] || installed_modules+=(devices/igc/ec_igc.ko)
for module in "${installed_modules[@]}"; do
    name=${module##*/}
    name=${name%.ko}
    resolved=$(modinfo -n "$name")
    echo "$resolved"
    expected="/lib/modules/$kernel/ethercat/$module"
    [[ $(readlink -f "$resolved") == "$(readlink -f "$expected")" ]] ||
        fail "$name resolves to $resolved instead of $expected; check duplicate module installations"
    magic=$(modinfo -F vermagic "$name")
    [[ ${magic%% *} == "$kernel" ]] || fail "Installed $name resolves to a different kernel version"
done
if [[ $restart == 1 ]]; then
    systemctl start ethercat
    /usr/local/bin/ethercat master
fi
echo "[remote] Deployment complete. Roll back with: sudo bash $backup/rollback.sh"
REMOTE_INSTALL

REMOTE_DIR=$(remote mktemp -d /tmp/ethercat-deploy.XXXXXXXX)
[[ $REMOTE_DIR =~ ^/tmp/ethercat-deploy\.[a-zA-Z0-9]+$ ]] || die 'Unexpected remote staging path'
log "Uploading installation files to $TARGET:$REMOTE_DIR"
rsync -az -s -e "$RSYNC_SSH" "$RELEASE_DIR/" "$TARGET:$REMOTE_DIR/" \
    --exclude=/build/
printf -v INSTALL_COMMAND '%q ' sudo bash "$REMOTE_DIR/install-remote.sh" "$REMOTE_DIR" "$KVER" "$RESTART" "$DRIVER"
# A TTY allows sudo to ask for its own password, independently of SSH login.
ssh -t "${SSH_ARGS[@]}" "$TARGET" "$INSTALL_COMMAND"
remote rm -rf -- "$REMOTE_DIR"
REMOTE_DIR=
log "Deployment succeeded. Local artifacts: $RELEASE_DIR"
