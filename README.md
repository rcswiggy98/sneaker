# sneaker

Staged transfer of internet artifacts into an isolated network, one domain at a
time. Today that domain is `obsidian-plugins`.

```
sneaker obsidian-plugins sync --vault wsl
```

## What this is, and what it deliberately is not

`sneaker` has two halves that cannot talk to each other.

* **`bastion/fetch-obsidian-plugins.py`** runs on the internet-facing bastion.
  It resolves pinned repositories to their current release, downloads the
  release assets, records hashes, and writes one tarball into a staging
  directory. It contains no knowledge of the receiving side, and no code that
  could reach it.
* **`bin/sneaker`** runs on your laptop and on vault hosts. It contains
  no network code beyond `ssh`/`scp` invoked with hosts you configure. It
  cannot fetch anything.

Between them sits you. The bundle crosses on a session you authenticated by
hand; you approve the plan before anything is written to a vault. `sneaker sync`
cannot run unattended, because it stops at a password prompt.

**This does not make importing plugins safe.** `main.js` is minified, bundled
JavaScript that Obsidian executes in Electron with full Node privileges:
filesystem, network, `child_process`. There is no sandbox and no code signing
anywhere in the Obsidian plugin ecosystem. The community listing is a one-time
review at submission, not of each subsequent release; a maintainer, or someone
who takes over a maintainer's account, can publish anything in the next tag.

The control is that **you review each repository on GitHub before its line
enters `plugins.txt`**. Everything here exists to ensure what lands is exactly
what you reviewed, and to leave a record proving it. `plugins.lock` is that
record. Nothing in this tool substitutes for the review, and nothing in it
substitutes for whatever transfer process your environment requires.

## Layout

```
plugins.txt      pinned owner/repo lines - the input you review
plugins.lock     append-only record of what crossed, when, with hashes
sneaker.conf     your hosts and vaults (gitignored; copy the .example)
bin/sneaker      the CLI
sneaker.ps1      PowerShell shim that forwards into the WSL install
lib/             shared bash, the filesystem layer, the JSON helper
bastion/         the fetcher that runs on the internet-facing host
tests/           smoke, filesystem, and Python 3.6 compatibility checks
```

Built plugins are **not** version controlled. They are environment state,
reproducible by re-running `sync`. Committing them would put multi-megabyte
minified bundles into git permanently (a minified `main.js` has no useful delta
compression, so every update is a full new blob), and it would make `git pull`
an automatic path for executable code across a network boundary — which is the
thing this tool exists to keep manual.

## Everyday use

```bash
sneaker obsidian-plugins sync                     # fetch, verify, install
sneaker obsidian-plugins sync dataview templater  # just these
sneaker obsidian-plugins sync --only-updates      # nothing new, refresh what is there
sneaker obsidian-plugins status                   # what each vault has
sneaker obsidian-plugins stage --dry-run          # verify a bundle, write nothing
```

The verbs are separable on purpose. `sync` is what you will type; `fetch`,
`stage` and `install` are what you reach for the day something looks wrong.

### From Windows

`sneaker.ps1` forwards a PowerShell invocation into the WSL installation. It is
a shim, not a port: all the logic stays in one implementation.

```powershell
.\sneaker.ps1 obsidian-plugins sync
.\sneaker.ps1 obsidian-plugins install --vault C:\Users\you\vault-work
```

Drive-letter paths are converted with `wslpath`. `SNEAKER_WSL_DISTRO` and
`SNEAKER_WSL_PATH` override the distribution and install location.

A native PowerShell port is deliberately not offered. It would mean a second
copy of the tar allowlist and the hash verification - the two things that must
not drift - and Windows OpenSSH has [no ControlMaster
support](https://github.com/PowerShell/Win32-OpenSSH/issues/1328), so it would
prompt separately for every `ssh` and `scp`.

Multiple vaults, local or remote, in one run:

```bash
sneaker obsidian-plugins sync \
  --vault laptop --vault workstation --vault lab
```

One bastion trip. The skip list is the union across every target, so a plugin
is only fetched if at least one vault needs it, and each vault gets only what
it is missing. Remote targets are handled by pushing `sneaker` itself into
`~/.cache/sneaker` on that host and re-invoking it there, so there is exactly
one implementation of the install logic. Expect one password prompt per host.

## Guarantees the tests actually check

* Archive members outside the bundle root, containing `..`, absolute, symlinks,
  or not on the filename allowlist are refused before extraction.
* Every file is verified against `SHA256SUMS` after unpacking, and again after
  being written into a vault. A filesystem or tool that alters bytes in transit
  (CRLF translation being the usual culprit) fails loudly instead of silently
  breaking your hashes later.
* `data.json` — where plugins keep their settings, including tokens — can never
  appear in a bundle and is never touched on update.
* Plugin directories are named by the manifest `id`, never the repo name.
* Plugins install **disabled**. `--enable` is opt-in, and refuses to edit the
  enabled list while Obsidian is running, because Obsidian owns that file and
  would overwrite the change.
* `minAppVersion` is checked against `OBSIDIAN_VERSION` so a plugin that will
  silently fail to load tells you before you install it.
* Bundles are byte-reproducible: identical inputs produce identical bytes.
  `MANIFEST.json` carries a `content_id` that ignores the fetch timestamp, so
  "did anything actually change" is one comparison.

```bash
tests/smoke.sh        # 21 checks, no network
tests/fs_test.sh      # 13 checks on the filesystem layer
python3 tests/py36_check.py
```

## Constraints worth knowing

**Version resolution does not use the GitHub API.** Unauthenticated API access
is 60 requests/hour *per source IP*, and a NAT'd bastion shares one address with
everyone behind it. `sneaker` follows the `/releases/latest` redirect instead,
which has no such limit and needs no token on an internet-facing box. Release
tags are never constructed by hand — some repos tag `1.4.2`, others `v1.4.2` —
only read from the redirect.

**The staging host may be old.** Mine runs Python 3.6.8 (RHEL 8). No walrus, no dataclasses, no f-string `=`,
no `subprocess` `capture_output`. `tests/py36_check.py` enforces this, because
it cannot be reproduced on a modern interpreter.

**POSIX only.** `sha256sum`, `tar`, `install`. A native Windows/PowerShell
target would be a rewrite, not a flag. See `docs/filesystems.md`.

## Not in scope

Obsidian's Remote-SSH plugin (immature, and its RPC transport wants to download
a daemon from the internet — which would itself need staging through this
tool); cloud sync backends, which have no route out of an isolated network by
definition; and anything that syncs vault *content*, which is `obsidian-git`'s
job and is out of scope here.
