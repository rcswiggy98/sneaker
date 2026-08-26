<#
.SYNOPSIS
    Run sneaker from a Windows PowerShell prompt against the WSL installation.

.DESCRIPTION
    A forwarding shim, not a port. All logic - the tar allowlist, hash
    verification, the filesystem layer, ssh connection multiplexing - stays in
    the one bash implementation inside WSL. This script only:

      1. finds the sneaker install in WSL,
      2. converts Windows-style path arguments to their WSL equivalents,
      3. execs it with the console attached so password and confirmation
         prompts still work,
      4. propagates the exit code.

    Why a shim rather than a native port: a second implementation of the
    security-critical paths is a second thing that can drift from the first,
    and Windows OpenSSH has no ControlMaster, so a native port would prompt
    separately for every ssh and scp invocation.

.PARAMETER (none)
    Configuration is by environment variable rather than by PowerShell
    parameters, so that every argument reaches sneaker verbatim without
    PowerShell trying to bind it:

      SNEAKER_WSL_DISTRO   WSL distribution name. Default: your default distro.
      SNEAKER_WSL_PATH     Path to bin/sneaker inside WSL.
                           Default: $HOME/sneaker/bin/sneaker

.EXAMPLE
    .\sneaker.ps1 obsidian-plugins sync

.EXAMPLE
    .\sneaker.ps1 obsidian-plugins install --vault C:\Users\you\vault-work

.NOTES
    If PowerShell ever swallows an argument, stop its parser first:
        .\sneaker.ps1 --% obsidian-plugins sync --vault C:\Users\you\vault-work
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PowerShell 7.4+ can turn a nonzero exit from a native command into a
# terminating error. We inspect $LASTEXITCODE deliberately, so opt out.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Die([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die "wsl.exe not found. sneaker's logic lives in WSL; install WSL or use the Linux CLI directly."
}

# -d only when explicitly asked, so the user's default distro is respected.
$distroArgs = @()
if ($env:SNEAKER_WSL_DISTRO) {
    $distroArgs = @('-d', $env:SNEAKER_WSL_DISTRO)
}

function Invoke-Wsl {
    # No param block on purpose. An advanced function would try to bind tokens
    # like -c and -x as PowerShell parameters; $args takes them verbatim.
    # -e runs the binary directly with no login shell, so nothing on the Linux
    # side re-interprets quoting or globs our arguments.
    & wsl.exe @distroArgs -e @args
}

# --------------------------------------------------------------- locate sneaker
$sneaker = $env:SNEAKER_WSL_PATH
if (-not $sneaker) {
    $wslHome = (Invoke-Wsl sh -c 'printf %s "$HOME"')
    if ($LASTEXITCODE -ne 0 -or -not $wslHome) {
        Die "could not reach WSL. Is the distribution installed and started?"
    }
    $sneaker = "$wslHome/sneaker/bin/sneaker"
}

Invoke-Wsl test -x $sneaker | Out-Null
if ($LASTEXITCODE -ne 0) {
    Die @"
sneaker not found or not executable in WSL at:
    $sneaker
Install it there, or set SNEAKER_WSL_PATH to its location, e.g.
    `$env:SNEAKER_WSL_PATH = '/home/you/src/sneaker/bin/sneaker'
"@
}

# ------------------------------------------------------------ path translation
# Only drive-letter paths (C:\... or C:/...) are converted. Deliberately NOT
# converted:
#   \\wsl.localhost\...  - passed through so sneaker's own guard rejects it with
#                          the explanation, rather than being silently rewritten
#                          into something that looks acceptable
#   host:/remote/path    - a remote vault target, not a local path
#   alias names          - resolved against VAULT_ALIAS inside sneaker
#
# Caveat: a single-letter vault alias followed by a path (g:/srv/vault) is
# indistinguishable from a drive path and would be converted. Use alias names
# of two or more characters.
function ConvertTo-WslPath([string]$Value) {
    if ($Value -notmatch '^[A-Za-z]:[\\/]') { return $Value }
    $converted = (Invoke-Wsl wslpath -u $Value)
    if ($LASTEXITCODE -ne 0 -or -not $converted) {
        Die "wslpath could not convert: $Value"
    }
    return $converted.Trim()
}

$forward = @()
foreach ($a in $args) {
    $forward += (ConvertTo-WslPath ([string]$a))
}

# ------------------------------------------------------------------------- run
# The console stays attached, so ssh password prompts and sneaker's own
# "apply this plan?" confirmation both work.
& wsl.exe @distroArgs -e $sneaker @forward
exit $LASTEXITCODE
