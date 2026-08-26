# shellcheck shell=bash
# Filesystem probing. The vault may live on ext4 inside WSL, or on NTFS reached
# through DrvFs/9p/virtiofs, and the two behave differently in ways that matter.
# Sourced, never executed.

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# Filesystem type of the nearest existing ancestor of a path.
fs_type_of() {
  local p=$1 t=''
  while [ ! -e "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do p=$(dirname "$p"); done
  if command -v findmnt >/dev/null 2>&1; then
    t=$(findmnt -n -o FSTYPE --target "$p" 2>/dev/null | head -n1)
  fi
  [ -z "$t" ] && t=$(stat -f -c %T "$p" 2>/dev/null)
  printf '%s' "$t"
}

# posix     - real POSIX semantics: modes, atomic rename, case sensitive
# winbacked - Windows-backed or non-POSIX: synthesized modes, case insensitive
# unknown   - treated as winbacked (the conservative choice)
fs_class_of() {
  case "$(fs_type_of "$1")" in
    ext2|ext3|ext4|btrfs|xfs|zfs|f2fs|overlay|overlayfs|tmpfs)
      printf 'posix' ;;
    9p|v9fs|drvfs|virtiofs|ntfs|ntfs3|fuseblk|cifs|smb3|smbfs|msdos|vfat|exfat)
      printf 'winbacked' ;;
    *)
      printf 'unknown' ;;
  esac
}

fs_is_posix() { [ "$(fs_class_of "$1")" = posix ]; }

# Accept a Windows path (C:\Users\... or \\server\share) and hand back a Linux
# one. Refuse the \\wsl.localhost UNC route outright: Obsidian does not reliably
# watch files over it (missed change events, lock complaints), which is exactly
# the silent-data-loss failure this tool must not help you configure.
vault_normalize() {
  local p=$1
  case "$p" in
    '\\wsl.localhost\'*|'\\wsl$\'*|//wsl.localhost/*|'//wsl$/'*)
      if [ "${SNEAKER_ALLOW_UNC:-0}" != 1 ]; then
        err "refusing the \\\\wsl.localhost UNC route: ${p}"
        err "Obsidian does not reliably watch files over it. Point --vault at the"
        err "ext4 path inside WSL and run Obsidian in WSL, or move the vault to NTFS."
        err "Set SNEAKER_ALLOW_UNC=1 to override knowingly. See docs/filesystems.md"
        exit 1
      fi
      warn "SNEAKER_ALLOW_UNC=1: proceeding over a UNC path against advice"
      ;;
  esac
  case "$p" in
    [A-Za-z]:[\\/]*|'\\'*)
      command -v wslpath >/dev/null 2>&1 \
        || die "looks like a Windows path but wslpath is unavailable: ${p}"
      p=$(wslpath -u "$p") || die "wslpath could not convert: ${p}"
      ;;
  esac
  printf '%s' "$p"
}

# Warn once per run about the things that actually cost you on a Windows-backed
# vault. Both are advisory; correctness is enforced by post-copy hash checks.
_SN_FS_WARNED=0
fs_advise() {
  local path=$1 class=$2
  [ "$_SN_FS_WARNED" = 1 ] && return 0
  _SN_FS_WARNED=1
  case "$class" in
    posix)
      info "vault filesystem: $(fs_type_of "$path") (POSIX semantics)" ;;
    winbacked|unknown)
      info "vault filesystem: $(fs_type_of "$path") (Windows-backed)"
      info "  - file modes are synthesized; sneaker will not chmod"
      info "  - directory lookups are case-insensitive"
      if is_wsl; then
        info "  - add this folder to Microsoft Defender's exclusion list;"
        info "    scanning is the dominant cost here, not the filesystem"
      fi
      ;;
  esac
}

# Find an existing plugin directory for ID, tolerating case folding on a
# case-insensitive filesystem. Echoes the on-disk name, or nothing.
plugin_dir_name() {
  local plugins_dir=$1 id=$2 e base
  [ -d "${plugins_dir}/${id}" ] && { printf '%s' "$id"; return 0; }
  [ -d "$plugins_dir" ] || return 0
  for e in "$plugins_dir"/*/; do
    [ -d "$e" ] || continue
    base=${e%/}; base=${base##*/}
    if [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = "$id" ]; then
      printf '%s' "$base"; return 0
    fi
  done
  return 0
}

# Copy SRC to DST and prove the bytes survived. This is the load-bearing check:
# rather than enumerating every way a filesystem or a git checkout can mangle a
# file (CRLF translation being the classic), we verify the destination hash
# against the bundle's recorded hash and fail loudly on any difference.
copy_verified() {
  local src=$1 dst=$2 want=$3 class=$4 got tmp
  tmp="${dst}.sneaker.$$"
  cp -- "$src" "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ "$class" = posix ]; then
    chmod 0644 -- "$tmp" 2>/dev/null || true
  fi
  got=$(sha256_of "$tmp")
  if [ "$got" != "$want" ]; then
    rm -f -- "$tmp"
    err "hash changed on write: $(basename -- "$dst")"
    err "  expected ${want}"
    err "  got      ${got}"
    err "  a filesystem or tool altered the bytes (CRLF translation is the usual cause)"
    return 1
  fi
  mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
  return 0
}
