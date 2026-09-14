# First run: vscode-extensions, on real machines

A staged bring-up, ordered so that every step that can fail cheaply fails
before any step that writes to a host you care about. Steps 1-6 change nothing
on any target. Step 7 is the first write.

**Keep your existing batch tool until step 8 passes.** Nothing here removes it,
and it is your rollback.

Throughout: `BASTION` is the DMZ host, `TARGET` is a Linux box you develop on.
Replace them.

---

## 0. Get the code onto the laptop

Chicken-and-egg: the work laptop cannot reach GitHub, but the bastion can.

```bash
# on the bastion
git clone -b claude/airgapped-vscode-extensions-elqrr4 \
    https://github.com/rcswiggy98/sneaker.git sneaker-vscode
tar -czf ~/sneaker-vscode.tar.gz sneaker-vscode
```

```bash
# in WSL on the laptop
scp BASTION:~/sneaker-vscode.tar.gz .
tar -xzf sneaker-vscode.tar.gz && cd sneaker-vscode
./tests/run-all.sh
```

**Expect:** `21 passed`, `23 passed`, `11 checks, 0 failed`, and every `ok`
line from the 3.6 and filesystem checks. If the suite fails here, stop - it
runs entirely offline, so a failure is an environment problem (missing
`python3`, `sha256sum`, a `bash` older than 4.0 for associative arrays) rather
than anything about your network.

---

## 1. Egress from the bastion — the hard gate

Cheapest possible check, and a blocker if it fails. Four hostnames, and your
allowlist may permit some and not others.

```bash
# on the bastion
for h in \
  https://update.code.visualstudio.com/api/update/win32-x64/stable/latest \
  https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery \
  https://ms-vscode-remote.gallery.vsassets.io/ \
  https://ms-vscode-remote.gallerycdn.vsassets.io/ ; do
  printf '%-72s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$h")"
done
python3 --version
```

**Expect:** `200` on the first. The gallery `extensionquery` URL answers `405`
to a GET (it only takes POST) — that is success, it means you reached it. The
two asset hosts may return `200`, `404`, or `403`; any HTTP response at all
means DNS and TLS worked, which is what is being tested. `000` means blocked.

You need the update service, the gallery, and **at least one** asset host. The
fetcher tries every asset host and reports which answered, so one blocked CDN
name is survivable. All of them blocked is not — that is the conversation to
have with whoever runs the allowlist, and the four names above are the list to
hand them.

`python3 --version` should be 3.6 or newer. The code is written to 3.6 because
that is what RHEL 8 ships.

---

## 2. Laptop prerequisites

```bash
# in WSL
code --version
command -v ssh scp tar sha256sum python3
```

**Expect:** three lines from `code --version` — version, commit, arch. If WSL
cannot find `code`, VS Code is not on your Windows PATH; set `VSCODE_CMD` in
config to the full path of `code.cmd`, or re-run the VS Code installer with the
PATH option ticked.

Write down the commit. Everything keys off it.

---

## 3. Config

```bash
cp sneaker.conf.example sneaker.conf
$EDITOR sneaker.conf
```

Minimum to change: `BASTION`, `BASTION_WORKDIR`, `VE_STAGE_DIR`, and
`HOST_ALIAS`. Leave `HOST_PLATFORM` empty for now — step 4 fills it in. Leave
`VE_LAYOUT="auto"`.

Start `DEFAULT_HOSTS` as a **single scratch host** — the least important box you
have. Widen it in step 9.

---

## 4. Probe the hosts — reads only, writes nothing

```bash
./bin/sneaker vscode-extensions probe
```

**Expect** per host: arch, libc, the detected layout, any servers already
present, and a line to paste into config:

```
  ok   HOST_PLATFORM[devbox01]="linux-x64"
```

Paste those into `sneaker.conf`.

**Read the layout line carefully, and do not trust a lone `bin/` tree.** A
host set up by an older tool will show a legacy `bin/` tree. That tree records
what *something* once did; it says nothing about what your current Remote-SSH
looks for. `auto` therefore treats it as residue - uses the modern layout and
warns - rather than as evidence. If you actually need legacy, the two checks in
step 4a settle it in under a minute, and `VE_LAYOUT="legacy"` is the whole fix.

---

## 4a. Settle the layout from the laptop, not the host

The host cannot tell you which layout the client wants. The client can, two
ways:

**The setting.** In VS Code, open Settings and search `useExecServer`. The
setting `Remote.SSH: Use Exec Server` decides it: **on = modern**
(`cli/servers/Stable-<commit>`), **off = legacy** (`bin/<commit>`). It has
defaulted to on for several years, so a leftover `bin/` tree on a host almost
always predates a managed update that flipped the client.

**The log.** After any connection attempt, View > Output, pick **Remote - SSH**
from the dropdown. It prints the exact path it probed. If you see
`~/.vscode-server/bin/<commit>` it is legacy; `cli/servers` is modern.

If either says legacy, set `VE_LAYOUT="legacy"` in `sneaker.conf`. Otherwise
leave `auto`.

**Stop and reconsider if you see** `glibc X is below 2.28` (that host cannot run
a modern server at all) or `no VS Code Server is published for armhf` (32-bit
ARM cannot run Remote-SSH, at any version). Drop those hosts rather than
working around it.

One password prompt per host. They are reused for the rest of the run.

---

## 5. Fetch the smallest useful bundle

Deliberately minimal: one platform, one commit, no catalogue. Roughly 250MB
rather than the ~1GB a full run can reach.

```bash
./bin/sneaker vscode-extensions fetch --no-catalog --no-hedge --host SCRATCH
```

**Expect:** the fetcher pushed to the bastion, a preflight naming which asset
hosts answered, a resolve line per extension, downloads, and a `SNEAKER_BUNDLE`
line. Then the bundle carried down to `VE_STAGE_DIR`.

This is the first time the bastion does real work, and it is the step most
likely to surface an environment problem. Failures name their cause: a blocked
host, a missing extension, a pack member you have not listed.

If it stops with **`extensions.txt is missing required entries`**, that is
working as intended — it prints exactly what to add. Review each on the
Marketplace first.

**Watch the bastion's disk.** `BASTION_WORKDIR/cache` keeps every artifact so a
re-run resumes instead of restarting. That is deliberate, but it grows.

---

## 6. Stage and dry-run — still writes nothing to any host

```bash
./bin/sneaker vscode-extensions stage
./bin/sneaker vscode-extensions install --dry-run
```

**Expect** from `stage`: `archive layout`, `every file matches SHA256SUMS`, and
a `built for VS Code 1.x.y` line that matches your `code --version`.

**Expect** from `--dry-run`: the layout it detected per host, which servers it
would place, and which extensions would go where. Nothing is written.

Check the routing looks sane: Remote-SSH and its two pack members should be
laptop-side; anything language-server-ish should be target-side.

Worth a look before you continue:

```bash
python3 lib/vscodeinfo.py summary "$VE_STAGE_DIR/current/MANIFEST.json"
```

---

## 7. First real write — one scratch host

```bash
./bin/sneaker vscode-extensions install --host SCRATCH
```

**This is the first exercise of the ssh/scp transport.** Everything upstream of
it has been tested; this path has not, because the machine it was built on had
no `ssh` binary. If something is going to break, it breaks here, and it breaks
on a scratch host by design.

**Expect:** the server pushed, `server tarball verified on HOST`, `server placed
at ...`, `cli placed at ...`, then an `ok` line per remote extension.

**Note what it overwrites.** For the commit it manages, `sneaker` does
`rm -rf` on that server directory before unpacking. If your batch tool already
placed a server at the same commit, that tree is replaced. Recoverable — see
Rollback — but know it is happening.

---

## 7a. If a previous tool set this host up: start from nothing

A host with a server placed by an older script, in a layout the current client
no longer reads, possibly with a hand-edited `extensions.json` on top, is not a
state to reason about. Remove it and let `sneaker` rebuild it.

```bash
./bin/sneaker vscode-extensions clean --all --host SCRATCH
./bin/sneaker vscode-extensions install --host SCRATCH
```

`clean --all` removes `~/.vscode-server` entirely on that host - every server,
the CLI, every remote extension and its settings. It asks you to type the host
alias back before doing so. Without `--all` it removes only the server trees
(both layouts) and the CLI, and keeps extensions; that is enough when the only
problem is the layout.

Any extension that lived on the host before but is not in `extensions.txt` is
gone after `--all`. That is the point: what lands is what you reviewed. If you
want it back, review it, add the line, re-run.

## 7b. If Remote-SSH on the laptop is itself broken

VS Code can hold an extension in a half-uninstalled state - directory present,
marked obsolete, not loaded - and `--install-extension --force` on top of that
does not always clear it. `sneaker` will report success because `code` did.
Reset it by hand:

1. **Quit VS Code completely.** Not close-the-window: check Task Manager for
   `Code.exe`. The extension host keeps the directory locked and re-marks it
   obsolete on next start.
2. In PowerShell:
   ```powershell
   code --uninstall-extension ms-vscode-remote.remote-ssh
   code --uninstall-extension ms-vscode-remote.remote-ssh-edit
   code --uninstall-extension ms-vscode.remote-explorer
   Get-ChildItem "$env:USERPROFILE\.vscode\extensions" |
     Where-Object Name -match '^(ms-vscode-remote\.remote-ssh|ms-vscode\.remote-explorer)' |
     Remove-Item -Recurse -Force
   Remove-Item "$env:USERPROFILE\.vscode\extensions\.obsolete" -ErrorAction SilentlyContinue
   code --list-extensions | Select-String remote
   ```
   The last line should print nothing. `.obsolete` is a list of directories VS
   Code intends to delete on next start; removing the file is safe, it is
   rebuilt as needed.
3. Back in WSL, reinstall just the laptop side:
   ```bash
   ./bin/sneaker vscode-extensions install --host SCRATCH \
       --only ms-vscode-remote.remote-ssh,ms-vscode-remote.remote-ssh-edit,ms-vscode.remote-explorer
   ```
4. Start VS Code and confirm the extension shows as installed and enabled in
   the Extensions view before trying to connect.

---

## 8. Prove it works — connect for real

In VS Code on the laptop: **Remote-SSH: Connect to Host**, pick the scratch
host.

**Expect:** it connects without a "Downloading VS Code Server" notification,
because the server is already there. That absence is the whole point.

Then check a remote extension actually activated — open a file it handles and
confirm it behaves. An extension that installs and does not activate is the
exact failure mode all the platform matching exists to prevent, so this is
worth doing properly rather than assuming.

If it hangs on "Downloading VS Code Server", the commit or the layout is wrong,
and the **Remote - SSH output log** (step 4a) names which: it prints the exact
path it probed. Compare against the host:

```bash
ssh SCRATCH 'ls ~/.vscode-server/ ~/.vscode-server/cli/servers/ ~/.vscode-server/bin/ 2>/dev/null'
code --version   # in WSL, second line
```

The directory the log probes must exist and contain the commit `code
--version` prints. If the log probes `cli/servers` and the server sits under
`bin/` (or vice versa), the layout is wrong: set `VE_LAYOUT` to match the log,
`clean --host SCRATCH`, and re-run step 7. If the path is right but the commit
differs, VS Code moved under you: `drift` will say so, and it is a bastion
trip.

---

## 9. Widen

Once step 8 passes, add the rest of `DEFAULT_HOSTS` and take the full bundle,
with the hedge commit and the offline catalogue:

```bash
./bin/sneaker vscode-extensions sync
```

This is bigger — a second server commit per platform, plus a few MB of
catalogue. Then the catalogue is searchable with no Marketplace:

```bash
./bin/sneaker vscode-extensions search yaml
```

Add extensions by reviewing them and appending to `extensions.txt`, one
`publisher.name` per line.

Check hosts sharing a home directory are grouped in `HOST_HOME_GROUP` — without
it you push the same 100MB once per host across the same NFS mount.

```bash
./bin/sneaker vscode-extensions status
```

---

## 10. The drift job

The piece that answers a managed VS Code update. No network, no credentials,
nothing crossing any boundary.

```bash
./bin/sneaker vscode-extensions drift
```

**Expect** `staged bundle matches the installed commit` today. After IT moves
you it says so, names both commits, and tells you the servers are stale.

Put it on a schedule in WSL — `crontab -e`:

```
0 9 * * 1  cd $HOME/sneaker-vscode && ./bin/sneaker vscode-extensions drift
```

Weekly on Monday morning is enough; the thing it watches for changes on IT's
cadence, not continuously. Route the output somewhere you will see it.

Note that `install` performs the same check and refuses a mismatch on its own,
so `drift` is early warning rather than the only guard.

---

## Rollback

Nothing here is destructive beyond the server directory for one commit, and
`clean` is the supported way to go further than that.

```bash
# remove every server tree and the CLI on a host, keep extensions
./bin/sneaker vscode-extensions clean --host TARGET
# remove ~/.vscode-server entirely
./bin/sneaker vscode-extensions clean --all --host TARGET

# or by hand, for one commit
ssh TARGET 'rm -rf ~/.vscode-server/cli/servers/Stable-<commit> \
                  ~/.vscode-server/bin/<commit> \
                  ~/.vscode-server/code-<commit>'
```

Then re-run your batch tool, or just let Remote-SSH download the server itself
if that host has any route out. Extensions under
`~/.vscode-server/extensions/` are additive and safe to leave; remove a single
one by deleting its directory and its entry in `extensions.json`.

On the laptop, `code --uninstall-extension publisher.name` reverses a local
install.

To start completely clean on the bastion: `rm -rf "$BASTION_WORKDIR"`. That
only discards the download cache, so the next run is slower, not different.

---

## If it breaks, this is what is worth capturing

* The failing command and its full output — everything names its cause, so the
  message usually is the diagnosis.
* `code --version` (all three lines).
* `./bin/sneaker vscode-extensions probe` for the host involved.
* `ssh TARGET 'ls -la ~/.vscode-server/ ~/.vscode-server/cli/servers/ 2>&1'`.
* From the bastion, the step 1 egress table.

The untested seam is the ssh/scp transport in steps 7 and 9 — server
placement, per-file hash verification after transfer, and the remote
`code-server --install-extension` call. Resolution, downloading, bundling,
staging, layout selection and the refusal paths are all covered by
`tests/run-all.sh`, and server unpack plus headless extension install were
verified against a real linux-x64 tarball.
