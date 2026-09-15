# vscode-extensions

Staging VS Code extensions and the VS Code Server into an isolated network.

The Obsidian domain moves one kind of artifact to one kind of place. This one
does not. What crosses is three different artifact families, each keyed to a
different thing, and getting any of the keys wrong produces a component that
installs without complaint and then does not work.

## Why this is harder than plugins

Installing `ms-vscode-remote.remote-ssh` on the laptop does not give you remote
development. On first connection VS Code SSHes to the target and downloads a
**VS Code Server** — a Node runtime and extension host, roughly 100 MB — onto
that host. The download is keyed to the **exact commit hash** of the laptop's
build, not its version number. On an isolated host that download cannot happen
and the symptom is a "Downloading VS Code Server" notification that hangs.

So the bundle carries the server too, and three keys have to line up:

| artifact | keyed to | wrong value gives you |
|---|---|---|
| server tarball | laptop's **commit hash** | Remote-SSH tries to fetch its own, hangs |
| VSIX | target's **`targetPlatform`** | extension installs, fails to activate |
| VSIX version | laptop's **`engines.vscode`** | extension installs, fails to load |

None of the three failures announces itself. That is the whole reason this
domain hashes everything and records what landed.

## The asymmetry that matters

Extension breakage on a VS Code update is rare. Server breakage is guaranteed.

`engines.vscode` constraints are effectively floors — `^1.85.0` keeps matching
as VS Code climbs — so VSIXs generally survive an update untouched. The server
tarball is keyed to an exact commit and never survives one. When IT moves the
managed install, the thing that breaks is the server on every host, all at once.

The exception is Remote-SSH itself, which is versioned in lockstep with VS Code:
at 1.133.0 its constraint is `^1.133.0`, and only 97 of its 375 published
versions are usable. It is the one extension where the compatibility check earns
its keep on every release.

## What crosses

One bundle per run, scoped to the targets in that run:

```
vsix/<platform>/<publisher>.<name>-<version>.vsix
server/<commit>/vscode-server-<platform>.tar.gz
server/<commit>/vscode_cli_<platform>_cli.tar.gz
SHA256SUMS
MANIFEST.json
```

Platforms are the union of `HOST_PLATFORM` across this run's targets, plus the
laptop's own platform (read from `code --version`, not configured), plus
`EXTRA_PLATFORMS`. Two commits of server are staged: the one you are on, and
current latest stable, as a hedge against the next managed update.

Scoping to the run matters. Server tarballs are ~100 MB each; three platforms
times two commits is ~600 MB across an scp you are babysitting.

## Resolution

All compatibility work happens on the bastion, before any download, from the
gallery query API. Per version it returns a properties bag containing
`Microsoft.VisualStudio.Code.Engine`, `...ExtensionKind`, `...ExtensionPack`,
`...ExtensionDependencies` and `...PreRelease`.

Four rules, each of which exists because violating it is silent:

1. **Never index into the version list.** It interleaves target platforms —
   `versions[0]` for `ms-vscode.cpptools` comes back `alpine-x64`. Filter on
   `targetPlatform`, and treat an absent `targetPlatform` as universal.
2. **Exclude `PreRelease == "true"` unless the pin asks for it.** The newest
   version of an extension is frequently a pre-release and is not otherwise
   distinguished. Opt in per line with `@pre`, never globally.
3. **Walk `ExtensionPack` as well as `ExtensionDependencies`.** Remote-SSH's
   requirement is expressed entirely through the pack; its dependency field is
   empty. Walking only dependencies finds nothing. Dependencies on the
   publisher `vscode` are the exception: those are VS Code's own bundled
   extensions, they are not on the Marketplace, and nothing can stage them.
   `ms-vscode.powershell` declares `vscode.powershell` and installs happily
   without it. They are reported and skipped; demanding one be listed is a
   dead end, since adding the line only fails differently next run.
4. **Never fall back across architectures.** Exact `targetPlatform`, then a
   universal build if the publisher ships one, then a hard error naming the
   extension and the platform. Extensions wrapping native binaries frequently
   publish `linux-x64` and nothing else; you want to learn that on the bastion.

`ExtensionKind` routes the result: `ui` installs on the laptop, `workspace` on
the targets. It is a comma-separated list — `ms-vscode.remote-explorer` is
`ui,web` — so parse it as a set.

Resolved versions are recorded in `extensions.lock`. Pin an exact version in
`extensions.txt` with `@1.2.3` to freeze it.

## Placement

The server unpacks to `~/.vscode-server/cli/servers/Stable-<commit>/server/`
with the CLI at `~/.vscode-server/code-<commit>`. Older clients used
`~/.vscode-server/bin/<commit>/`; the layout is selected by config because it is
a property of the Remote-SSH build, not of this tool.

Placement is idempotent. A commit directory that exists and hashes clean is
skipped, so a routine run against unchanged hosts costs one round trip, not
100 MB.

Remote extensions install through the server's own headless CLI, which does the
`extensions.json` bookkeeping correctly:

```
~/.vscode-server/cli/servers/Stable-<commit>/server/bin/code-server \
  --install-extension <vsix> --extensions-dir ~/.vscode-server/extensions
```

Unpacking a VSIX into the extensions directory by hand and editing
`extensions.json` also works and is not supported here. It breaks quietly across
server versions, which is the failure mode this tool exists to remove.

## Hosts

Targets carry their platform; the platform set is derived from the targets. A
standalone platform list maintained beside a host list has an obvious failure
mode: you add an ARM box, forget the platform, and stage `linux-x64` VSIXs that
install onto it and never activate.

```bash
HOST_ALIAS=(     [devbox01]="you@devbox01" [armlab01]="you@armlab01" )
HOST_PLATFORM=(  [devbox01]="linux-x64"    [armlab01]="linux-arm64"  )
HOST_HOME_GROUP=( [devbox01]="nfs-eng"     [devbox02]="nfs-eng"      )
```

`HOST_HOME_GROUP` marks hosts that share a home directory, so `~/.vscode-server`
is staged once for the group rather than once per host. Ungrouped hosts are
staged individually.

`sneaker vscode-extensions probe` fills `HOST_PLATFORM` in rather than having
you maintain it by hand. It reports `uname -m`, musl versus glibc, and — the one
that will actually bite — the **glibc version**. VS Code Server 1.86 and later
require glibc 2.28 or newer. Anything on RHEL or CentOS 7 (glibc 2.17) cannot
run a modern server at all, and the symptom is a crash loop rather than a
message. Same contract as the `minAppVersion` check in the Obsidian domain: tell
me before I install, not after.

## Working without a scheduler

There is no crontab on the bastion and authentication is interactive password by
design. Both are deliberate, and neither is worked around here. Leaving a
detached fetcher running between logins is technically possible and is not done:
a persistent process on a DMZ host that reaches the internet on its own schedule
is the thing that removing key auth is meant to prevent. If scheduling is
wanted, it is asked for.

The cadence is assembled from two pieces that need no privilege:

* **Drift detection on the laptop.** A scheduled local job runs `code --version`
  and compares the commit against the lock. No network, no credentials, nothing
  crossing. This is what turns a managed VS Code update from "everything broke"
  into a notification naming the cause, before you meet it as a hung connection.
* **Staleness reported on login.** The fetcher records its last run and resolved
  versions in `BASTION_WORKDIR` and reports on the run you are already doing:
  how long since the last fetch, which extensions have newer compatible
  versions, whether latest stable has moved past what you have staged.

The laptop tells you when to go. The bastion tells you what is stale when you
arrive.

## Consequences of interactive auth

Every bastion session costs a typed password and cannot be re-established
unattended, so a transfer that dies partway must not start over.

`update.code.visualstudio.com` answers range requests with HTTP 206, so tarball
downloads resume mid-file rather than restarting. `BASTION_WORKDIR` is a durable
cache: any artifact already present and hashing clean is skipped on a re-run.
The scp down is verified per file, so a partial transfer resumes at a file
boundary instead of invalidating the bundle.

`ControlPersist` is raised for this domain. The Obsidian default of 180 seconds
covers back-to-back commands but not fetch, read the plan, install — which is
this workflow, and the cost of getting it wrong is retyping a password mid-run.

This is also why the WSL requirement is not a preference. Windows OpenSSH has no
`ControlMaster`, so a native PowerShell port would prompt for that password on
every single `ssh` and `scp` invocation.

## Two download traps

Both produce a file that looks right and is not, and both are caught by
`SHA256SUMS` rather than by inspection.

* The `vspackage` endpoint serves **gzip-encoded** content. A fetcher that
  ignores `Content-Encoding` writes a double-gzipped `.vsix` that stays valid
  looking until VS Code rejects it.
* VS Code verifies VSIX signatures on install. Fetching the published
  `VSIXPackage` asset preserves the signature; re-zipping anywhere in the
  pipeline destroys it. Nothing in this pipeline repacks a VSIX.
