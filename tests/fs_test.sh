#!/usr/bin/env bash
# Filesystem-adaptive layer. The vault may be ext4 in WSL or NTFS via DrvFs/9p,
# and correctness must not depend on which.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "${ROOT}/lib/common.sh"
. "${ROOT}/lib/fsprobe.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1";
          else fail=$((fail+1)); printf '  FAIL %s (want %s, got %s)\n' "$1" "$3" "$2"; fi; }

check "fs_class_of classifies a real filesystem" \
  "$(case "$(fs_class_of "$W")" in posix|winbacked|unknown) echo yes ;; *) echo no ;; esac)" yes
check "tmpfs/ext4 reads as posix" "$(fs_class_of /tmp)" posix

printf 'hello\n' > "${W}/src"
want=$(sha256_of "${W}/src")
copy_verified "${W}/src" "${W}/dst" "$want" posix >/dev/null 2>&1
check "copy_verified accepts matching bytes" $? 0
check "destination exists" "$( [ -f "${W}/dst" ] && echo yes || echo no)" yes

copy_verified "${W}/src" "${W}/bad" "0000000000000000000000000000000000000000000000000000000000000000" posix >/dev/null 2>&1
check "copy_verified rejects a hash mismatch" $? 1
check "rejected copy leaves no file behind" "$( [ -f "${W}/bad" ] && echo yes || echo no)" no

# The realistic mangling: CRLF translation somewhere in the path.
printf 'a\r\nb\r\n' > "${W}/crlf"
printf 'a\nb\n'     > "${W}/lf"
check "CRLF and LF hash differently (so translation is detectable)" \
  "$( [ "$(sha256_of "${W}/crlf")" != "$(sha256_of "${W}/lf")" ] && echo yes || echo no)" yes

mkdir -p "${W}/plugins/Dataview"
check "case-insensitive lookup finds a differently-cased dir" \
  "$(plugin_dir_name "${W}/plugins" dataview)" "Dataview"
mkdir -p "${W}/plugins2/dataview"
check "exact match preferred" "$(plugin_dir_name "${W}/plugins2" dataview)" "dataview"
check "absent plugin returns nothing" "$(plugin_dir_name "${W}/plugins2" templater)" ""

( vault_normalize '\\wsl.localhost\Ubuntu\home\user\vault' ) >/dev/null 2>&1
check "UNC path refused" $? 1
( SNEAKER_ALLOW_UNC=1 vault_normalize '/home/user/vault' ) >/dev/null 2>&1
check "plain posix path passes through" $? 0
check "posix path unchanged" "$(vault_normalize /home/user/vault)" "/home/user/vault"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
