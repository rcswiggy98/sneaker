#!/usr/bin/env bash
# Smoke tests. No network: bundles are synthesised locally by make_fixture.py
# using the same bundling code the bastion fetcher uses.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STAGE="${WORK}/stage"; mkdir -p "$STAGE"
VAULT="${WORK}/vault"; mkdir -p "${VAULT}/.obsidian"
CONF="${WORK}/sneaker.conf"

pass=0; fail=0
cat > "$CONF" <<CONF
STAGE_DIR="${STAGE}"
LOCK_FILE="${WORK}/plugins.lock"
OBSIDIAN_VERSION="1.5.0"
DEFAULT_VAULTS=( "${VAULT}" )
CONF

sneaker() { "${ROOT}/bin/sneaker" --config "$CONF" "$@"; }
fixture() { python3 "${ROOT}/tests/make_fixture.py" "$@"; }

check()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1";
            else fail=$((fail+1)); printf '  FAIL %s (want %s, got %s)\n' "$1" "$3" "$2"; fi; }
refused() { if [ "$2" -ne 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1";
            else fail=$((fail+1)); printf '  FAIL %s (was accepted)\n' "$1"; fi; }

echo "== hostile bundles must be refused =="
for kind in traversal absolute symlink stray outside corrupt; do
  fixture "$kind" "${STAGE}/obsidian-plugins-hostile.tar.gz" 2>/dev/null
  sneaker obsidian-plugins stage --bundle "${STAGE}/obsidian-plugins-hostile.tar.gz" >/dev/null 2>&1
  refused "reject ${kind}" $?
  rm -f "${STAGE}/obsidian-plugins-hostile.tar.gz"
done

echo "== deterministic bundling =="
fixture good "${WORK}/a.tar.gz" dataview:1.0.0:1.4.0
fixture good "${WORK}/b.tar.gz" dataview:1.0.0:1.4.0
check "same inputs produce identical bytes" \
  "$(sha256sum < "${WORK}/a.tar.gz" | cut -d' ' -f1)" \
  "$(sha256sum < "${WORK}/b.tar.gz" | cut -d' ' -f1)"

echo "== happy path =="
fixture good "${STAGE}/obsidian-plugins-20260101T000000Z.tar.gz" \
  dataview:1.0.0:1.4.0 templater:2.0.0:1.9.9
stage_out=$(sneaker obsidian-plugins stage 2>&1); rc=$?
check "stage accepts a good bundle" $rc 0
check "minAppVersion mismatch surfaced at stage time" \
  "$(printf '%s' "$stage_out" | grep -c 'needs Obsidian >= 1.9.9')" 1
sneaker obsidian-plugins install --yes >/dev/null 2>&1
check "install exits clean" $? 0
check "plugin dir is named by manifest id" \
  "$( [ -f "${VAULT}/.obsidian/plugins/dataview/main.js" ] && echo yes || echo no)" yes
check "styles.css copied" \
  "$( [ -f "${VAULT}/.obsidian/plugins/templater/styles.css" ] && echo yes || echo no)" yes
check "installed version readable" \
  "$(python3 "${ROOT}/lib/vaultinfo.py" installed "$VAULT" | awk -F'\t' '$1=="dataview"{print $2}')" \
  "1.0.0"
check "lockfile recorded the crossing" \
  "$(grep -c dataview "${WORK}/plugins.lock")" 1

echo "== plugins are installed but NOT enabled by default =="
check "no enabled list created" \
  "$( [ -f "${VAULT}/.obsidian/community-plugins.json" ] && echo yes || echo no)" no

echo "== data.json is never touched =="
printf '{"token":"secret"}' > "${VAULT}/.obsidian/plugins/dataview/data.json"
fixture good "${STAGE}/obsidian-plugins-20260102T000000Z.tar.gz" \
  dataview:1.1.0:1.4.0 templater:2.0.0:1.9.9
sneaker obsidian-plugins stage >/dev/null 2>&1
sneaker obsidian-plugins install --yes >/dev/null 2>&1
check "data.json survives an update" \
  "$(cat "${VAULT}/.obsidian/plugins/dataview/data.json")" '{"token":"secret"}'
check "version advanced" \
  "$(python3 "${ROOT}/lib/vaultinfo.py" installed "$VAULT" | awk -F'\t' '$1=="dataview"{print $2}')" \
  "1.1.0"

echo "== idempotency =="
out=$(sneaker obsidian-plugins install --yes 2>&1)
check "second install is a no-op" \
  "$(printf '%s' "$out" | grep -c 'already current')" 1

echo "== opt-in enable =="
printf '[]' > "${VAULT}/.obsidian/community-plugins.json"
fixture good "${STAGE}/obsidian-plugins-20260103T000000Z.tar.gz" dataview:1.2.0:1.4.0
sneaker obsidian-plugins stage >/dev/null 2>&1
sneaker obsidian-plugins install --yes --enable >/dev/null 2>&1
check "id added to the enabled list" \
  "$(python3 -c 'import json,sys;print("dataview" in json.load(open(sys.argv[1])))' \
     "${VAULT}/.obsidian/community-plugins.json")" "True"

echo "== UNC vault paths are refused =="
sneaker obsidian-plugins status --vault '\\wsl.localhost\Ubuntu\home\user\vault' >/dev/null 2>&1
refused "reject \\\\wsl.localhost route" $?

echo "== a non-vault directory is refused =="
mkdir -p "${WORK}/notavault"
sneaker obsidian-plugins install --yes --vault "${WORK}/notavault" >/dev/null 2>&1
refused "reject a directory with no .obsidian" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
