# Where the vault lives

Two workable arrangements, and one that looks workable and is not.

## Do not: Obsidian on Windows reading a WSL vault over `\\wsl.localhost`

Obsidian does not reliably watch files over that UNC route. The reported
symptoms are missed file-change events and occasional lock or corruption
complaints. Missed `fs.watch` events are worse than slowness: Obsidian shows
you a stale file while an agent writes underneath it, and your next edit
clobbers the agent's work — silent data loss, below the layer any mtime
protocol in the vault tooling can see.

`sneaker` refuses `--vault` paths of this shape. `SNEAKER_ALLOW_UNC=1`
overrides it if you decide otherwise, knowingly.

## Option A: Obsidian inside WSL2 via WSLg

One filesystem, native speed on both sides, no bridge. Everything is Linux, so
line endings, file modes and case sensitivity stop being questions at all.

Check availability, cheapest first:

```powershell
wsl --version     # a "WSLg version" line means yes.
                  # "unrecognized option" means you are on the old inbox WSL,
                  # which is common on managed images - stop here, use Option B.
wsl -l -v         # VERSION must be 2; WSLg does not work with WSL 1
```

```bash
echo "$DISPLAY | $WAYLAND_DISPLAY"   # expect ":0 | wayland-0"
ls /mnt/wslg/                        # expect .X11-unix, runtime-dir
sudo apt install -y x11-apps && xeyes
```

`xeyes` proves the stack. It does not prove Obsidian: Electron is a far heavier
client, GPU acceleration is optional with software rendering as the fallback,
and that fallback is where an Electron app gets sluggish. Open a real vault
before committing.

**This changes your staging manifest.** You need the Linux Obsidian build —
`.deb` or AppImage plus its Electron dependencies — not the Windows installer.
That is a bigger and fussier sneakernet payload than three-file plugin bundles.

Then: `--vault ~/vault-work`, filesystem class `posix`.

## Option B: vault on NTFS, Obsidian native on Windows

WSL reaches it through `/mnt/c`. Slower for CLI tooling, but for a few-hundred
file markdown vault the dominant cost is Microsoft Defender, not the
filesystem — **add the vault folder to Defender's exclusion list**.

Then: `--vault /mnt/c/Users/you/vault-work`, or pass the Windows path
`C:\Users\you\vault-work` and `sneaker` converts it with `wslpath`. Filesystem
class `winbacked`.

## What `sneaker` does differently per class

Detection is `findmnt -o FSTYPE`, falling back to `stat -f`. `unknown` is
treated as `winbacked`, the conservative choice.

| | `posix` (ext4, btrfs, xfs) | `winbacked` (9p, drvfs, virtiofs, ntfs, cifs) |
|---|---|---|
| file modes | `chmod 0644` after copy | not touched; modes are synthesized |
| plugin directory lookup | exact | falls back to a case-insensitive scan |
| Defender advice | none | printed once per run |
| byte integrity | re-hashed after write | re-hashed after write |

That last row is the point. Rather than enumerating every way a filesystem or a
git checkout can alter a file, every copy is re-hashed at its destination
against the bundle's recorded hash and fails loudly on any difference. CRLF
translation is the realistic case: JavaScript runs fine either way, so the
plugin still works, and you would only discover the mangling months later when
a hash check fails and looks like tampering.

Plugin ids are lowercase-and-hyphens by the manifest specification, so a
case-insensitive filesystem cannot produce a collision between two different
plugins. One thing that is not a problem.
