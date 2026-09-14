#!/usr/bin/env bash
# vscode-extensions smoke tests. No network and no ssh: bundles are synthesised
# locally with the same bundling code the bastion fetcher uses, and only the
# parts that run on the laptop are exercised. The transport itself is not
# mocked, because a mock of ssh would test the mock.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STAGE="${WORK}/stage"; mkdir -p "$STAGE"
CONF="${WORK}/sneaker.conf"
COMMIT=$(printf 'a%.0s' $(seq 40))

pass=0; fail=0
cat > "$CONF" <<CONF
VE_STAGE_DIR="${STAGE}"
VE_LOCK_FILE="${WORK}/extensions.lock"
VSCODE_VERSION="1.133.0"
VSCODE_COMMIT="${COMMIT}"
DEFAULT_HOSTS=( )
CONF

sneaker() { "${ROOT}/bin/sneaker" --config "$CONF" vscode-extensions "$@"; }
fixture() { python3 "${ROOT}/tests/make_vscode_fixture.py" "$@"; }

check()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1";
            else fail=$((fail+1)); printf '  FAIL %s (want %s, got %s)\n' "$1" "$3" "$2"; fi; }
refused() { if [ "$2" -ne 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1";
            else fail=$((fail+1)); printf '  FAIL %s (was accepted)\n' "$1"; fi; }

echo "== hostile bundles must be refused =="
for kind in traversal absolute symlink stray outside corrupt; do
  rm -f "${STAGE}"/vscode-extensions-*.tar.gz
  fixture "$kind" "${STAGE}/vscode-extensions-hostile.tar.gz" 2>/dev/null
  sneaker stage >/dev/null 2>&1
  refused "reject ${kind}" $?
done

echo "== a good bundle stages =="
rm -f "${STAGE}"/vscode-extensions-*.tar.gz
fixture good "${STAGE}/vscode-extensions-20260101T000000Z.tar.gz"
sneaker stage >/dev/null 2>&1
check "stage accepts a good bundle" $? 0
[ -f "${STAGE}/current/MANIFEST.json" ]
check "payload moved into place" $? 0

echo "== deterministic bundling =="
fixture good "${WORK}/a.tar.gz"; fixture good "${WORK}/b.tar.gz"
[ "$(sha256sum < "${WORK}/a.tar.gz")" = "$(sha256sum < "${WORK}/b.tar.gz")" ]
check "same inputs produce identical bytes" $? 0

echo "== manifest routing =="
info() { python3 "${ROOT}/lib/vscodeinfo.py" "$@" "${STAGE}/current/MANIFEST.json"; }
n=$(python3 "${ROOT}/lib/vscodeinfo.py" extensions "${STAGE}/current/MANIFEST.json" local win32-x64 | wc -l)
check "ui extensions route to the laptop" "$n" 1
n=$(python3 "${ROOT}/lib/vscodeinfo.py" extensions "${STAGE}/current/MANIFEST.json" remote linux-x64 | wc -l)
check "workspace extensions route to targets" "$n" 1
n=$(python3 "${ROOT}/lib/vscodeinfo.py" extensions "${STAGE}/current/MANIFEST.json" remote win32-x64 | wc -l)
check "no remote extensions for the laptop platform" "$n" 0
n=$(python3 "${ROOT}/lib/vscodeinfo.py" commits "${STAGE}/current/MANIFEST.json" linux-x64 | wc -l)
check "one commit staged" "$n" 1

echo "== server layout is switchable and both forms are addressable =="
layout() {
  bash -c '
    SNEAKER_LIB='"${ROOT}"'/lib
    # Left unexpanded on purpose, exactly as bin/sneaker declares it: the
    # remote shell expands it, not ours.
    VE_SERVER_DIR=\$HOME/.vscode-server; VE_LAYOUT=auto; VE_LAYOUT_DEFAULT=modern
    . "$SNEAKER_LIB/common.sh"; . "$SNEAKER_LIB/vscode-extensions.sh"
    '"$1"''
}
got=$(layout 've_server_root modern deadbeef')
check "modern server path" "$got" '$HOME/.vscode-server/cli/servers/Stable-deadbeef/server'
got=$(layout 've_server_root legacy deadbeef')
check "legacy server path" "$got" '$HOME/.vscode-server/bin/deadbeef'
got=$(layout 've_cli_dest modern deadbeef')
check "modern layout places a CLI" "$got" '$HOME/.vscode-server/code-deadbeef'
got=$(layout 've_cli_dest legacy deadbeef')
check "legacy layout has no separate CLI" "$got" ''

echo "== the client's own footprint decides the layout =="
decide() { layout "ve_layout_decide $1; printf '%s' \"\$VE_LAYOUT_DETECTED\""; }
#              mc lc ma la
got=$(decide "0 1 0 1"); check "bin/<commit> the client built for the commit in use means legacy" "$got" legacy
got=$(decide "0 1 1 1"); check "...even when an old modern tree also exists" "$got" legacy
got=$(decide "1 0 1 1"); check "cli/servers/<commit> the client built means modern" "$got" modern
got=$(decide "0 0 1 1"); check "a modern tree for other commits means modern" "$got" modern
got=$(decide "0 0 0 1"); check "a legacy tree for other commits alone is residue: default" "$got" modern
got=$(decide "0 0 0 0"); check "nothing on the host: default" "$got" modern
got=$(layout "ve_layout_decide 0 0 0 1; printf '%s' \"\$VE_LAYOUT_NOTE\"" | grep -c "left behind")
check "residue is explained, not silently defaulted" "$got" 1
got=$(layout "VE_LAYOUT=legacy; ve_detect_layout unused-host x; printf '%s' \"\$VE_LAYOUT_DETECTED\"")
check "an explicit VE_LAYOUT wins without touching the host" "$got" legacy

echo "== an invalid layout is refused rather than guessed at =="
sneaker stage --layout sideways >/dev/null 2>&1
refused "reject --layout sideways" $?

echo "== commit drift =="
sneaker drift >/dev/null 2>&1
check "drift is clean when commits match" $? 0
cat > "${WORK}/drift.conf" <<CONF
VE_STAGE_DIR="${STAGE}"
VSCODE_VERSION="1.137.0"
VSCODE_COMMIT="$(printf 'b%.0s' $(seq 40))"
DEFAULT_HOSTS=( )
CONF
"${ROOT}/bin/sneaker" --config "${WORK}/drift.conf" vscode-extensions drift >/dev/null 2>&1
refused "drift refuses after a managed VS Code update" $?
"${ROOT}/bin/sneaker" --config "${WORK}/drift.conf" vscode-extensions install >/dev/null 2>&1
refused "install refuses against a mismatched commit" $?

echo "== clean is gated and dry-runnable =="
cat > "${WORK}/clean.conf" <<CONF
VE_STAGE_DIR="${STAGE}"
VSCODE_VERSION="1.133.0"
VSCODE_COMMIT="${COMMIT}"
HOST_ALIAS=( [scratch]="nobody@nowhere.invalid" )
DEFAULT_HOSTS=( scratch )
CONF
out=$("${ROOT}/bin/sneaker" --config "${WORK}/clean.conf" vscode-extensions clean --dry-run 2>&1)
check "clean --dry-run touches nothing and needs no ssh" $? 0
printf '%s' "$out" | grep -q 'keeps extensions'
check "default tier keeps extensions" $? 0
out=$("${ROOT}/bin/sneaker" --config "${WORK}/clean.conf" vscode-extensions clean --all --dry-run 2>&1)
printf '%s' "$out" | grep -q 'entirely'
check "--all tier removes everything" $? 0
"${ROOT}/bin/sneaker" --config "${WORK}/clean.conf" vscode-extensions clean --bogus >/dev/null 2>&1
refused "unknown option is refused" $?

echo "== local install: errors are surfaced, success is verified =="
# A stand-in `code` on PATH. The real one is exercised at work; what is
# tested here is that sneaker neither hides what it says nor believes it.
FAKEBIN="${WORK}/bin"; mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/code" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --version) printf '1.133.0\n%s\nx64\n' "$FAKE_COMMIT" ;;
  --install-extension)
    [ "$FAKE_MODE" = refuse ] && { echo "Failed Installing Extensions: boom-from-code" >&2; exit 1; }
    exit 0 ;;
  --list-extensions)
    [ "$FAKE_MODE" = lie ] || echo "pub.local"
    ;;
esac
FAKE
chmod +x "${FAKEBIN}/code"
local_run() { PATH="${FAKEBIN}:${PATH}" FAKE_COMMIT="$COMMIT" FAKE_MODE="$1" \
  "${ROOT}/bin/sneaker" --config "$CONF" vscode-extensions install 2>&1; }

out=$(local_run refuse)
refused "a refusal from code fails the install" $?
printf '%s' "$out" | grep -q 'boom-from-code'
check "what code said is shown, not swallowed" $? 0

out=$(local_run lie)
refused "success that does not list afterwards is not believed" $?
printf '%s' "$out" | grep -q 'does not list it afterwards'
check "the post-install check names the failure" $? 0

out=$(local_run ok)
check "a verified install succeeds" $? 0
grep -q 'laptop	pub.local	1.0.0	win32-x64' "${WORK}/extensions.lock"
check "the crossing is recorded in the lock" $? 0

echo "== offline catalogue search =="
out=$(sneaker search yaml 2>&1)
printf '%s' "$out" | grep -q 'pub.yaml'
check "search finds an id in the staged catalogue" $? 0
printf '%s' "$out" | grep -q 'pub.other'
check "search excludes non-matches" $? 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
