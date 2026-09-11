#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
rc=0
echo "== bash syntax =="
for f in bin/sneaker lib/*.sh tests/*.sh; do
  bash -n "$f" && printf '  ok   %s\n' "$f" || { printf '  FAIL %s\n' "$f"; rc=1; }
done
echo "== python 3.6 compatibility =="
python3 tests/py36_check.py || rc=1
echo "== vscode resolution rules =="
python3 tests/vscode_resolve_test.py || rc=1
echo "== filesystem layer =="
./tests/fs_test.sh || rc=1
echo "== end to end =="
./tests/smoke.sh || rc=1
exit $rc
