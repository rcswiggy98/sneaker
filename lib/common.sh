# shellcheck shell=bash
# Shared helpers for sneaker. Sourced, never executed.

SNEAKER_VERSION="0.1.0"

_c_red=''; _c_yel=''; _c_grn=''; _c_dim=''; _c_bld=''; _c_off=''
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'
  _c_dim=$'\033[2m';  _c_bld=$'\033[1m';  _c_off=$'\033[0m'
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
ok()   { printf '%s  ok%s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
err()  { printf '%s fail%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$_c_bld" "$*" "$_c_off" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# ver_lt A B  -> true when A sorts strictly before B (version order)
ver_lt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# Strip a leading v from a release tag: v1.2.3 -> 1.2.3
untag() { printf '%s' "${1#v}"; }

# ---------------------------------------------------------------- ssh plumbing
# One authenticated master per host, reused by every later ssh/scp, so an
# interactive password is typed once per host per run rather than per command.

SNEAKER_CM_DIR="${TMPDIR:-/tmp}/sneaker-cm-$(id -u)"

ssh_setup() {
  mkdir -p "$SNEAKER_CM_DIR" && chmod 700 "$SNEAKER_CM_DIR"
}

# Emit ssh options as separate words. Callers use: $(ssh_opts)
ssh_opts() {
  printf '%s' "-o ControlMaster=auto -o ControlPath=${SNEAKER_CM_DIR}/%C -o ControlPersist=${SNEAKER_CONTROL_PERSIST:-180} -o ConnectTimeout=20"
}

# ssh_master HOST -- open the shared connection now, so the password prompt
# happens once, up front, where the user expects it.
ssh_master() {
  local host=$1
  ssh_setup
  if ssh -O check $(ssh_opts) "$host" >/dev/null 2>&1; then
    return 0
  fi
  info "opening ssh session to ${host} (authenticate when prompted)"
  ssh $(ssh_opts) -o ControlMaster=yes -f -N "$host" \
    || die "could not open ssh session to ${host}"
}

ssh_close() {
  local host=$1
  ssh -O exit $(ssh_opts) "$host" >/dev/null 2>&1 || true
}

sn_ssh() { local host=$1; shift; ssh $(ssh_opts) "$host" "$@"; }
sn_scp() { scp $(ssh_opts) "$@"; }

# ------------------------------------------------------------------- targets
# A vault target is either  /local/path  or  host:/remote/path
target_host() { case "$1" in *:*) printf '%s' "${1%%:*}" ;; *) printf '' ;; esac; }
target_path() { case "$1" in *:*) printf '%s' "${1#*:}" ;; *) printf '%s' "$1" ;; esac; }
target_is_remote() { [ -n "$(target_host "$1")" ]; }
