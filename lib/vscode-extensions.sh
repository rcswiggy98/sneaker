# shellcheck shell=bash
# sneaker / vscode-extensions : laptop-side staging and install.
#
# Contains no network code beyond ssh/scp against hosts you configure. It
# cannot fetch anything; the bastion half does that and knows nothing about
# this side.
#
# Unlike the obsidian domain, this one does not push sneaker onto the target
# and re-invoke it there. Placing a server tarball and running its own headless
# CLI needs nothing but sh, tar and sha256sum, so requiring Python or bash on a
# target host would buy nothing and rule hosts out. The logic lives here, once.

VE_BUNDLE_ROOT="sneaker-vscode-extensions"

# A run here is fetch, read the plan, then install, with hundred-megabyte
# transfers in between. The obsidian default of 180s covers back-to-back
# commands but expires in the gap where you are reading, and the cost of that
# is retyping a bastion password mid-run. Raised, not removed: the master still
# ages out rather than persisting past the session.
SNEAKER_CONTROL_PERSIST=${VE_CONTROL_PERSIST:-1800}

# ------------------------------------------------------------------- layout
#
# Where Remote-SSH expects the server is decided by the Remote-SSH build on the
# laptop, not by us, and it changed between client generations:
#
#   modern  ~/.vscode-server/cli/servers/Stable-<commit>/server
#           ~/.vscode-server/code-<commit>              (the CLI that manages it)
#   legacy  ~/.vscode-server/bin/<commit>
#
# 'auto' reads the host: whichever tree already exists is the one its client
# built, and that is better evidence than anything we could configure. A host
# with neither gets VE_LAYOUT_DEFAULT, which is modern because current VS Code
# bootstraps that way.

# Remote paths are built with a literal $HOME so the remote shell expands them,
# not ours. Printed raw that looks like a failed substitution, so messages show
# the ~ form instead.
# The replacement half of ${var/pat/repl} is tilde-expanded by bash, so a bare
# ~ here becomes the LOCAL home - actively misleading when the remote user is
# someone else. Going through a variable suppresses that.
ve_display_path() {
  local tilde='~'
  printf '%s' "${1/#\$HOME\//${tilde}/}"
}

# Every remote path is keyed to a commit. An empty one silently produces
# .vscode-server/bin//bin/code-server and a "not found" that reads as a quoting
# fault, so it is refused at the point of use instead.
ve_require_commit() {  # commit context
  [ -n "${1:-}" ] || die "internal: no commit for ${2}. The staged MANIFEST.json \
may be unreadable - re-run stage."
}

ve_server_root() {  # layout commit
  case "$1" in
    legacy) printf '%s/bin/%s' "$VE_SERVER_DIR" "$2" ;;
    *)      printf '%s/cli/servers/Stable-%s/server' "$VE_SERVER_DIR" "$2" ;;
  esac
}

ve_cli_dest() {  # layout commit -> empty when the layout has no separate CLI
  case "$1" in
    legacy) printf '' ;;
    *)      printf '%s/code-%s' "$VE_SERVER_DIR" "$2" ;;
  esac
}

# Decide the layout from four facts about the host. Sets VE_LAYOUT_DETECTED
# and VE_LAYOUT_NOTE; prints nothing, so it can be called without a subshell.
#
#   mc  a cli/servers/Stable-<commit> tree for the CURRENT commit that sneaker
#       did not place
#   lc  a bin/<commit> tree for the CURRENT commit that sneaker did not place
#   ma  any cli/servers tree at all
#   la  any bin tree at all
#
# The first two are the client's own footprint: when Remote-SSH cannot find a
# server it builds the directory it wants and tries to download into it, and
# on an isolated host that leaves the directory - in the legacy case with a
# zero-byte vscode-server.tar.gz inside. A tree for the commit in use that we
# did not create is therefore the client telling us which layout it reads.
# Trees for other commits are residue: they say what some client once did.
ve_layout_decide() {  # mc lc ma la
  local mc=${1:-0} lc=${2:-0} ma=${3:-0} la=${4:-0}
  VE_LAYOUT_NOTE=""
  if [ "$lc" = 1 ] && [ "$mc" != 1 ]; then
    VE_LAYOUT_DETECTED=legacy
    VE_LAYOUT_NOTE="the client built bin/<commit> for the commit in use - its own legacy self-install attempt. This client reads the legacy layout; consider setting VE_LAYOUT=\"legacy\" so this is not re-detected each run."
    return 0
  fi
  if [ "$mc" = 1 ]; then VE_LAYOUT_DETECTED=modern; return 0; fi
  if [ "$ma" = 1 ]; then VE_LAYOUT_DETECTED=modern; return 0; fi
  if [ "$la" = 1 ]; then
    VE_LAYOUT_DETECTED=$VE_LAYOUT_DEFAULT
    VE_LAYOUT_NOTE="only a legacy bin/ tree for other commits exists here - what a previous tool or an older client left behind. It says nothing about what the client wants now; using ${VE_LAYOUT_DEFAULT}. To settle it: connect once and look for bin/<commit>/vscode-server.tar.gz (legacy) on the host, or read the path in View > Output > 'Remote - SSH' on the laptop. If legacy, set VE_LAYOUT=\"legacy\"."
    return 0
  fi
  VE_LAYOUT_DETECTED=$VE_LAYOUT_DEFAULT
}

ve_detect_layout() {  # host commit -> sets VE_LAYOUT_DETECTED, VE_LAYOUT_NOTE
  local host=$1 commit=$2 facts
  VE_LAYOUT_NOTE=""
  case "$VE_LAYOUT" in
    modern|legacy) VE_LAYOUT_DETECTED=$VE_LAYOUT; return 0 ;;
  esac
  facts=$(sn_ssh "$host" "d=\"\$HOME/${VE_SERVER_DIR#\$HOME/}\"; mc=0; lc=0; ma=0; la=0
    [ -d \"\$d/cli/servers/Stable-${commit}\" ] && [ ! -f \"\$d/cli/servers/Stable-${commit}/server/.sneaker-complete\" ] && mc=1
    [ -d \"\$d/bin/${commit}\" ] && [ ! -f \"\$d/bin/${commit}/.sneaker-complete\" ] && lc=1
    [ -d \"\$d/cli/servers\" ] && ma=1
    [ -d \"\$d/bin\" ] && la=1
    echo \"\$mc \$lc \$ma \$la\"" 2>/dev/null | tr -d '\r' | tail -n1)
  # shellcheck disable=SC2086
  ve_layout_decide $facts
}

# ------------------------------------------------------------------- targets

ve_host_list() {
  local h
  if [ ${#VE_HOSTS[@]} -gt 0 ]; then
    printf '%s\n' "${VE_HOSTS[@]}"; return 0
  fi
  if [ ${#DEFAULT_HOSTS[@]} -gt 0 ]; then
    printf '%s\n' "${DEFAULT_HOSTS[@]}"; return 0
  fi
  for h in "${!HOST_ALIAS[@]}"; do printf '%s\n' "$h"; done | sort
}

# These print one value per line. Callers consume them bare, in a loop, or
# through $( ) which strips the trailing newline - so the newline is always
# correct and its absence silently concatenates. Not hypothetical: it turned
# three hosts into one token, "linux-x64linux-x64linux-arm64".
ve_host_dest() {  # alias -> ssh destination
  local alias=$1
  if [ -n "${HOST_ALIAS[$alias]:-}" ]; then printf '%s\n' "${HOST_ALIAS[$alias]}"
  else printf '%s\n' "$alias"; fi
}

ve_host_platform() {
  local alias=$1
  [ -n "${HOST_PLATFORM[$alias]:-}" ] || die \
    "no platform recorded for ${alias}. Run: sneaker vscode-extensions probe --host ${alias}"
  printf '%s\n' "${HOST_PLATFORM[$alias]}"
}

# Platforms the Marketplace and update service publish. The bastion fetcher
# checks this too, but only after the bundle has been pushed and a password
# typed; checking here fails on a typo before any of that.
VE_KNOWN_PLATFORMS="win32-x64 win32-arm64 linux-x64 linux-arm64 linux-armhf \
alpine-x64 alpine-arm64 darwin-x64 darwin-arm64"

ve_check_platform() {  # platform source-description
  case " ${VE_KNOWN_PLATFORMS} " in
    *" $1 "*) return 0 ;;
  esac
  die "$2 is not a VS Code platform: '$1'. Known: ${VE_KNOWN_PLATFORMS}"
}

ve_platform_union() {
  local h p
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    p=$(ve_host_platform "$h") || exit 1
    ve_check_platform "$p" "HOST_PLATFORM[${h}]"
    printf '%s\n' "$p"
  done < <(ve_host_list)
  for p in ${EXTRA_PLATFORMS[@]+"${EXTRA_PLATFORMS[@]}"}; do
    [ -n "$p" ] || continue
    ve_check_platform "$p" "EXTRA_PLATFORMS"
    printf '%s\n' "$p"
  done
}

# ------------------------------------------------------------ local VS Code
#
# The version feeds engine matching; the commit decides which server every
# target needs. Both are read from the install rather than configured, because
# a managed update changes them without telling you and a stale config value
# would resolve against a VS Code that is no longer there.

ve_in_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
}

# Run the VS Code CLI that manages the laptop's own extensions.
#
# From WSL, `code` resolves to a shell wrapper shipped inside the Windows
# install, and it does one of two wrong things. With the Remote-WSL extension
# present it hands off to the WSL *server*: --install-extension then lands in
# ~/.vscode-server inside WSL, and --list-extensions reports that server's
# extensions rather than the laptop's. Remote-SSH is a ui extension; installed
# inside WSL it does not exist as far as the Windows client is concerned. With
# Remote-WSL absent, the wrapper runs the Windows CLI but passes the WSL path
# through untranslated, and the VSIX cannot be opened.
#
# So under WSL the wrapper is bypassed: the Windows CLI is reached through
# cmd.exe and handed Windows paths. VSCODE_CMD, when set, is used verbatim.
ve_code() {
  local c rc
  if [ -n "${VSCODE_CMD:-}" ]; then
    "$VSCODE_CMD" "$@"; return $?
  fi
  if ve_in_wsl && command -v cmd.exe >/dev/null 2>&1; then
    # cmd.exe refuses a UNC working directory, which every WSL path is.
    ( cd /mnt/c 2>/dev/null || cd /; exec cmd.exe /c code "$@" ) | tr -d '\r'
    rc=${PIPESTATUS[0]}
    return "$rc"
  fi
  for c in code code.exe; do
    command -v "$c" >/dev/null 2>&1 && { "$c" "$@"; return $?; }
  done
  return 127
}

# The Windows temp directory, as a WSL path. A VSIX is copied here before
# install so Windows VS Code opens a C:\ path rather than a \\wsl$ UNC one.
ve_win_temp() {
  local t
  t=$( cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r' )
  [ -n "$t" ] || return 1
  wslpath -u "$t"
}

ve_read_code_version() {
  local out
  out=$(ve_code --version 2>/dev/null)
  [ -n "$out" ] || return 1
  VE_VERSION=$(printf '%s\n' "$out" | sed -n 1p)
  VE_COMMIT=$(printf '%s\n' "$out" | sed -n 2p)
  VE_ARCH=$(printf '%s\n' "$out" | sed -n 3p)
  [ -n "$VE_VERSION" ] && [ -n "$VE_COMMIT" ]
}

ve_require_code() {
  if [ -n "${VSCODE_VERSION:-}" ] && [ -n "${VSCODE_COMMIT:-}" ]; then
    VE_VERSION=$VSCODE_VERSION; VE_COMMIT=$VSCODE_COMMIT
    VE_ARCH=${VSCODE_ARCH:-x64}
    warn "using VSCODE_VERSION/VSCODE_COMMIT from config; a managed update will make these stale"
    return 0
  fi
  ve_read_code_version || die "could not run 'code --version'. Set VSCODE_CMD in \
your config, or set VSCODE_VERSION and VSCODE_COMMIT by hand."
}

ve_client_platform() {
  case "${VE_ARCH:-x64}" in
    arm64) printf 'win32-arm64' ;;
    *)     printf 'win32-x64' ;;
  esac
}

# --------------------------------------------------------------------- drift

ve_drift() {
  ve_require_code
  hdr "local VS Code"
  info "version    ${VE_VERSION}"
  info "commit     ${VE_COMMIT}"
  info "platform   $(ve_client_platform)"

  local staged=""
  [ -f "${VE_STAGE_DIR}/current/MANIFEST.json" ] && staged=$(ve_py summary \
    "${VE_STAGE_DIR}/current/MANIFEST.json" | awk -F'\t' '$1=="vscode_commit"{print $2}')
  if [ -z "$staged" ]; then
    warn "nothing staged yet; run: sneaker vscode-extensions sync"
    return 1
  fi
  if [ "$staged" = "$VE_COMMIT" ]; then
    ok "staged bundle matches the installed commit"
    return 0
  fi
  err "staged bundle is for commit ${staged}, VS Code is now ${VE_COMMIT}"
  err "every staged VS Code Server is stale. Remote-SSH will try to download"
  err "its own and hang. Run a bastion trip: sneaker vscode-extensions sync"
  return 1
}

# ---------------------------------------------------------------------- fetch

ve_py() { python3 "${SNEAKER_LIB}/vscodeinfo.py" "$@"; }

ve_fetch() {
  [ -n "${BASTION:-}" ] || die "BASTION is not set in the config"
  ve_require_code
  need ssh scp tar sha256sum python3

  local platforms; platforms=$(ve_platform_union | sort -u | paste -sd, -)
  hdr "fetch on ${BASTION}"
  info "VS Code    ${VE_VERSION} (${VE_COMMIT})"
  info "platforms  $(ve_client_platform)${platforms:+,$platforms}"

  ssh_master "$BASTION"
  info "pushing the fetcher to ${BASTION}"
  sn_ssh "$BASTION" "mkdir -p ${BASTION_WORKDIR}" \
    || die "could not create ${BASTION_WORKDIR} on ${BASTION}"
  sn_scp "${SNEAKER_ROOT}/bastion/fetch-vscode-extensions.py" \
         "${BASTION}:${BASTION_WORKDIR}/fetch-vscode-extensions.py" \
    || die "could not push the fetcher"
  sn_scp "$VE_EXTENSIONS_FILE" "${BASTION}:${BASTION_WORKDIR}/extensions.txt" \
    || die "could not push extensions.txt"
  if [ -s "$VE_LOCK_FILE" ]; then
    sn_scp "$VE_LOCK_FILE" "${BASTION}:${BASTION_WORKDIR}/extensions.lock" \
      || warn "could not push extensions.lock; identity pinning is skipped this run"
  fi

  local out; out=$(sn_ssh "$BASTION" "python3 ${BASTION_WORKDIR}/fetch-vscode-extensions.py \
      --out ${BASTION_WORKDIR}/bundles \
      --workdir ${BASTION_WORKDIR}/cache \
      --extensions ${BASTION_WORKDIR}/extensions.txt \
      --lock ${BASTION_WORKDIR}/extensions.lock \
      --vscode-version $(printf '%q' "$VE_VERSION") \
      --vscode-commit $(printf '%q' "$VE_COMMIT") \
      --client-platform $(printf '%q' "$(ve_client_platform)") \
      ${platforms:+--platform $(printf '%q' "$platforms")} \
      ${VE_NO_HEDGE:+--no-hedge} ${VE_NO_CATALOG:+--no-catalog} \
      --catalog-size ${VE_CATALOG_SIZE}") \
    || die "the fetcher failed on ${BASTION}"

  local path; path=$(printf '%s\n' "$out" | awk '/^SNEAKER_BUNDLE /{print $2}')
  [ -n "$path" ] || die "the fetcher produced no bundle"
  mkdir -p "$VE_STAGE_DIR"
  info "carrying $(basename "$path") down"
  sn_scp "${BASTION}:${path}" "${VE_STAGE_DIR}/" || die "could not carry the bundle down"
  VE_BUNDLE="${VE_STAGE_DIR}/$(basename "$path")"
  ok "bundle in ${VE_STAGE_DIR}"
}

# ---------------------------------------------------------------------- stage

ve_newest_bundle() {
  ls -1t "${VE_STAGE_DIR}"/vscode-extensions-*.tar.gz 2>/dev/null | head -n1
}

# Refuse anything in the archive that could write outside the extraction root,
# or that is not one of the file kinds this format contains. The unpacker is
# the most exposed code here, so this is an allowlist, not a blocklist.
ve_audit_tar() {
  local bundle=$1 bad=0 line kind name
  while IFS= read -r line; do
    kind=${line:0:1}
    name=$(printf '%s' "$line" | sed -e 's/^.* \([^ ]*\)$/\1/')
    case "$kind" in
      -|d) : ;;
      *) err "archive contains a non-regular member (${kind}): ${name}"; bad=1; continue ;;
    esac
    case "$name" in
      "${VE_BUNDLE_ROOT}/"*) : ;;
      *) err "archive member outside ${VE_BUNDLE_ROOT}/: ${name}"; bad=1; continue ;;
    esac
    case "$name" in
      /*|*..*) err "unsafe path in archive: ${name}"; bad=1 ;;
    esac
    case "${name#${VE_BUNDLE_ROOT}/}" in
      MANIFEST.json|SHA256SUMS) : ;;
      catalog/marketplace.tsv.gz) : ;;
      vsix/*/*.vsix) : ;;
      server/*/vscode-server-*.tar.gz|server/*/vscode_cli_*.tar.gz) : ;;
      */) : ;;
      *) err "archive member not on the allowlist: ${name}"; bad=1 ;;
    esac
  done < <(tar -tvzf "$bundle")
  [ "$bad" = 0 ] || die "refusing this bundle"
}

ve_stage() {
  need tar sha256sum python3
  local bundle=${VE_BUNDLE:-$(ve_newest_bundle)}
  [ -n "$bundle" ] && [ -f "$bundle" ] \
    || die "no bundle found in ${VE_STAGE_DIR}; run fetch first"

  hdr "verifying $(basename "$bundle")"
  ve_audit_tar "$bundle"
  ok "archive layout"

  local tmp; tmp=$(mktemp -d "${VE_STAGE_DIR}/.unpack.XXXXXX")
  _ve_unpack_fail() { rm -rf "$tmp"; die "$1"; }

  tar -xzf "$bundle" -C "$tmp" --no-same-owner --no-same-permissions \
    || _ve_unpack_fail "extraction failed"
  ( cd "${tmp}/${VE_BUNDLE_ROOT}" && sha256sum --quiet -c SHA256SUMS ) \
    || _ve_unpack_fail "checksum mismatch inside the bundle"
  ok "every file matches SHA256SUMS"

  rm -rf "${VE_STAGE_DIR}/current"
  mv "${tmp}/${VE_BUNDLE_ROOT}" "${VE_STAGE_DIR}/current" \
    || _ve_unpack_fail "could not move the payload into place"
  rm -rf "$tmp"
  ok "staged to ${VE_STAGE_DIR}/current"

  ve_py summary "${VE_STAGE_DIR}/current/MANIFEST.json" \
    | while IFS=$'\t' read -r key value; do
        case "$key" in
          created)        info "bundle created ${value} UTC" ;;
          content_id)     info "content-id     ${value}" ;;
          vscode_version) info "built for      VS Code ${value}" ;;
          warning)        warn "$value" ;;
        esac
      done
  VE_BUNDLE=$bundle
}

ve_staged_or_die() {
  [ -f "${VE_STAGE_DIR}/current/MANIFEST.json" ] \
    || die "nothing staged; run: sneaker vscode-extensions stage"
}

# ---------------------------------------------------------------------- probe
#
# HOST_PLATFORM decides which VSIXs and which server a host receives, and a
# wrong value produces an extension that installs and never activates. Reading
# it off the host is better than maintaining it by hand.

ve_probe() {
  local alias dest out arch libc glibc layout commits selfinstall
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    dest=$(ve_host_dest "$alias")
    hdr "$alias  (${dest})"
    ssh_master "$dest"
    out=$(sn_ssh "$dest" '
      printf "arch\t%s\n" "$(uname -m)"
      if [ -f /etc/alpine-release ]; then printf "libc\tmusl\n"
      elif ldd --version 2>&1 | head -n1 | grep -qi musl; then printf "libc\tmusl\n"
      else printf "libc\tglibc\n"; fi
      printf "glibc\t%s\n" "$(ldd --version 2>&1 | head -n1 | sed -e "s/.* //")"
      if [ -d "$HOME/.vscode-server/cli/servers" ]; then printf "layout\tmodern\n"
      elif [ -d "$HOME/.vscode-server/bin" ]; then printf "layout\tlegacy\n"
      else printf "layout\tnone\n"; fi
      ls -1 "$HOME/.vscode-server/cli/servers" 2>/dev/null | sed -e "s/^Stable-/server\t/"
      ls -1 "$HOME/.vscode-server/bin" 2>/dev/null | sed -e "s/^/server\t/"
      for t in "$HOME"/.vscode-server/bin/*/vscode-server.tar.gz; do
        [ -f "$t" ] && [ ! -s "$t" ] && printf "selfinstall\tlegacy\t%s\n" "$(basename "$(dirname "$t")")"
      done
      printf "home\t%s\n" "$(stat -c %d:%i "$HOME" 2>/dev/null || echo unknown)"
    ' 2>/dev/null | tr -d '\r')

    arch=$(printf '%s\n' "$out" | awk -F'\t' '$1=="arch"{print $2}')
    libc=$(printf '%s\n' "$out" | awk -F'\t' '$1=="libc"{print $2}')
    glibc=$(printf '%s\n' "$out" | awk -F'\t' '$1=="glibc"{print $2}')
    layout=$(printf '%s\n' "$out" | awk -F'\t' '$1=="layout"{print $2}')
    commits=$(printf '%s\n' "$out" | awk -F'\t' '$1=="server"{print $2}' | paste -sd' ' -)
    selfinstall=$(printf '%s\n' "$out" | awk -F'\t' '$1=="selfinstall"{print $3}' | paste -sd' ' -)

    local plat=""
    case "${libc}-${arch}" in
      musl-x86_64)          plat=alpine-x64 ;;
      musl-aarch64|musl-arm64) plat=alpine-arm64 ;;
      glibc-x86_64)         plat=linux-x64 ;;
      glibc-aarch64|glibc-arm64) plat=linux-arm64 ;;
      glibc-armv7l|glibc-armv6l) plat=linux-armhf ;;
    esac

    info "uname -m   ${arch:-?}"
    info "libc       ${libc:-?}${glibc:+ ${glibc}}"
    info "layout     ${layout:-?}${commits:+  (servers: ${commits})}"
    if [ -n "$selfinstall" ]; then
      # A zero-byte vscode-server.tar.gz under bin/<commit> is Remote-SSH's own
      # legacy bootstrap failing to download. Nothing else writes that file
      # there, and it settles the layout question outright.
      warn "Remote-SSH tried to self-install in the LEGACY layout for ${selfinstall}"
      warn "(zero-byte bin/<commit>/vscode-server.tar.gz). This client reads legacy:"
      warn "set VE_LAYOUT=\"legacy\" in sneaker.conf"
    fi
    if [ -z "$plat" ]; then
      err "no VS Code platform matches ${libc}/${arch}"
    else
      ok "HOST_PLATFORM[${alias}]=\"${plat}\""
    fi
    # VS Code Server 1.86+ needs glibc 2.28. RHEL/CentOS 7 ships 2.17 and the
    # symptom there is a crash loop, not a message.
    if [ "$libc" = glibc ] && [ -n "$glibc" ] && ver_lt "$glibc" 2.28; then
      err "glibc ${glibc} is below 2.28; VS Code Server 1.86+ cannot run here"
    fi
    if [ "$plat" = linux-armhf ]; then
      err "no VS Code Server is published for armhf; this host cannot run Remote-SSH"
    fi
  done < <(ve_host_list)
}

# -------------------------------------------------------------------- install

ve_sha_of_staged() {  # relative path inside the staged payload
  awk -v p="$1" '$2==p{print $1}' "${VE_STAGE_DIR}/current/SHA256SUMS"
}

# Place one server (and its CLI, in the modern layout) for one commit.
# Idempotent: a tree already present and marked complete is left alone, so a
# routine run against unchanged hosts costs a round trip rather than 100MB.
ve_place_server() {
  local dest=$1 layout=$2 commit=$3 platform=$4
  local root cli marker rel sha remote_tmp
  ve_require_commit "$commit" "server placement on ${dest}"

  root=$(ve_server_root "$layout" "$commit")
  marker="${root}/.sneaker-complete"
  if sn_ssh "$dest" "[ -f \"\$HOME/${marker#\$HOME/}\" ]" 2>/dev/null; then
    ok "server ${commit:0:12} already placed (${layout})"
    return 0
  fi

  if sn_ssh "$dest" "[ -d \"\$HOME/${root#\$HOME/}\" ]" 2>/dev/null; then
    warn "replacing a server tree at ${root} that sneaker did not place"
  fi

  rel=$(ve_py servers "${VE_STAGE_DIR}/current/MANIFEST.json" "$platform" "$commit" \
        | awk -F'\t' '$1=="server"{print $3}')
  [ -n "$rel" ] || die "the staged bundle carries no ${platform} server for ${commit}"
  sha=$(ve_sha_of_staged "$rel")

  remote_tmp="${VE_REMOTE_TMP}/$$"
  sn_ssh "$dest" "mkdir -p ${remote_tmp}" || die "could not create ${remote_tmp} on ${dest}"
  info "pushing ${platform} server for ${commit:0:12}"
  sn_scp "${VE_STAGE_DIR}/current/${rel}" "${dest}:${remote_tmp}/server.tar.gz" \
    || die "could not push the server tarball"

  # Verified again after being written: a filesystem or tool that alters bytes
  # in transit fails loudly here rather than as a broken server later.
  sn_ssh "$dest" "cd ${remote_tmp} && printf '%s  server.tar.gz\n' $(printf '%q' "$sha") | sha256sum -c -" \
    >/dev/null 2>&1 || die "server tarball corrupted in transit to ${dest}"
  ok "server tarball verified on ${dest}"

  sn_ssh "$dest" "set -e
    root=\"\$HOME/${root#\$HOME/}\"
    rm -rf \"\$root\" \"\${root}.new\"
    mkdir -p \"\${root}.new\"
    tar -xzf ${remote_tmp}/server.tar.gz -C \"\${root}.new\" --strip-components=1
    mkdir -p \"\$(dirname \"\$root\")\"
    mv \"\${root}.new\" \"\$root\"
    touch \"\${root}/.sneaker-complete\"
    rm -f ${remote_tmp}/server.tar.gz" \
    || die "could not unpack the server on ${dest}"
  ok "server placed at $(ve_display_path "$root")"

  cli=$(ve_cli_dest "$layout" "$commit")
  if [ -n "$cli" ]; then
    rel=$(ve_py servers "${VE_STAGE_DIR}/current/MANIFEST.json" "$platform" "$commit" \
          | awk -F'\t' '$1=="cli"{print $3}')
    if [ -n "$rel" ]; then
      sha=$(ve_sha_of_staged "$rel")
      sn_scp "${VE_STAGE_DIR}/current/${rel}" "${dest}:${remote_tmp}/cli.tar.gz" \
        || die "could not push the CLI tarball"
      sn_ssh "$dest" "cd ${remote_tmp} && printf '%s  cli.tar.gz\n' $(printf '%q' "$sha") | sha256sum -c -" \
        >/dev/null 2>&1 || die "CLI tarball corrupted in transit to ${dest}"
      sn_ssh "$dest" "set -e
        mkdir -p ${remote_tmp}/cli
        tar -xzf ${remote_tmp}/cli.tar.gz -C ${remote_tmp}/cli
        mkdir -p \"\$(dirname \"\$HOME/${cli#\$HOME/}\")\"
        mv ${remote_tmp}/cli/code \"\$HOME/${cli#\$HOME/}\"
        chmod 0755 \"\$HOME/${cli#\$HOME/}\"
        rm -rf ${remote_tmp}/cli ${remote_tmp}/cli.tar.gz" \
        || die "could not place the CLI on ${dest}"
      ok "cli placed at $(ve_display_path "$cli")"
    else
      warn "no CLI build staged for ${platform} ${commit:0:12}"
    fi
  fi
  sn_ssh "$dest" "rmdir ${remote_tmp} 2>/dev/null || true" >/dev/null 2>&1
}

ve_install_remote_extensions() {
  local dest=$1 layout=$2 commit=$3 platform=$4 alias=$5
  local root server_bin remote_tmp id version rel sha n=0
  ve_require_commit "$commit" "extension install on ${alias}"
  root=$(ve_server_root "$layout" "$commit")
  server_bin="${root}/bin/code-server"
  remote_tmp="${VE_REMOTE_TMP}/$$"

  sn_ssh "$dest" "[ -x \"\$HOME/${server_bin#\$HOME/}\" ]" 2>/dev/null \
    || die "no code-server at $(ve_display_path "$server_bin") on ${dest}; \
the ${layout} server for ${commit:0:12} was not placed"

  while IFS=$'\t' read -r id version _plat rel sha _engine _eid _pid; do
    [ -n "$id" ] || continue
    if [ -n "$VE_ONLY" ] && ! printf '%s' ",${VE_ONLY}," | grep -q ",${id},"; then
      continue
    fi
    if [ "$VE_DRY" = 1 ]; then
      info "would install ${id} ${version} on ${alias}"; n=$((n+1)); continue
    fi
    sn_ssh "$dest" "mkdir -p ${remote_tmp}" || die "could not create ${remote_tmp}"
    sn_scp "${VE_STAGE_DIR}/current/${rel}" "${dest}:${remote_tmp}/ext.vsix" \
      || die "could not push ${id}"
    sn_ssh "$dest" "cd ${remote_tmp} && printf '%s  ext.vsix\n' $(printf '%q' "$sha") | sha256sum -c -" \
      >/dev/null 2>&1 || die "${id} corrupted in transit to ${dest}"
    sn_ssh "$dest" "\"\$HOME/${server_bin#\$HOME/}\" --install-extension ${remote_tmp}/ext.vsix \
        --extensions-dir \"\$HOME/${VE_SERVER_DIR#\$HOME/}/extensions\" --force >/dev/null &&
      rm -f ${remote_tmp}/ext.vsix" \
      || die "code-server refused ${id} on ${dest}"
    ok "${id} ${version}"
    ve_lock_append "$alias" "$id" "$version" "$platform"
    n=$((n+1))
  done < <(ve_py extensions "${VE_STAGE_DIR}/current/MANIFEST.json" remote "$platform")
  [ "$n" -gt 0 ] || info "no remote extensions for ${platform}"
}

ve_install_host() {
  local alias=$1 dest platform layout commit staged_commit group
  dest=$(ve_host_dest "$alias")
  platform=$(ve_host_platform "$alias")
  hdr "$alias  (${dest}, ${platform})"
  ssh_master "$dest"
  commit=$(ve_py summary "${VE_STAGE_DIR}/current/MANIFEST.json" \
           | awk -F'\t' '$1=="vscode_commit"{print $2}')
  ve_require_commit "$commit" "${alias}"
  ve_detect_layout "$dest" "$commit"
  layout=$VE_LAYOUT_DETECTED
  info "layout     ${layout}$( [ "$VE_LAYOUT" = auto ] && printf ' (detected)' )"
  [ -z "${VE_LAYOUT_NOTE:-}" ] || warn "$VE_LAYOUT_NOTE"

  group=${HOST_HOME_GROUP[$alias]:-}
  if [ -n "$group" ] && [ -n "${_VE_HOME_DONE[$group]:-}" ]; then
    info "home group ${group} already staged by ${_VE_HOME_DONE[$group]}; skipping server"
  else
    # Distinct from $commit: the bundle may carry several server commits (the
    # installed one and the hedge), while extensions install against the one
    # VS Code is actually running. Reading into $commit here emptied it at
    # EOF, and the install then looked for code-server under bin//bin.
    while IFS=$'\t' read -r staged_commit _version _role; do
      [ -n "$staged_commit" ] || continue
      [ "$VE_DRY" = 1 ] && { info "would place server ${staged_commit:0:12}"; continue; }
      ve_place_server "$dest" "$layout" "$staged_commit" "$platform"
    done < <(ve_py commits "${VE_STAGE_DIR}/current/MANIFEST.json" "$platform")
    [ -n "$group" ] && _VE_HOME_DONE[$group]=$alias
  fi

  [ "$VE_DRY" = 1 ] || ve_install_remote_extensions "$dest" "$layout" "$commit" "$platform" "$alias"
}

ve_install_local() {
  local id version rel sha src arg tmp out rc n=0
  ve_code --version >/dev/null 2>&1 \
    || { warn "no VS Code CLI found; skipping local extensions"; return 0; }
  hdr "laptop  ($(ve_client_platform))"
  while IFS=$'\t' read -r id version _plat rel sha _engine _eid _pid; do
    [ -n "$id" ] || continue
    if [ -n "$VE_ONLY" ] && ! printf '%s' ",${VE_ONLY}," | grep -q ",${id},"; then
      continue
    fi
    if [ "$VE_DRY" = 1 ]; then info "would install ${id} ${version}"; n=$((n+1)); continue; fi

    src="${VE_STAGE_DIR}/current/${rel}"
    tmp=""; arg=$src
    if ve_in_wsl && [ -z "${VSCODE_CMD:-}" ]; then
      tmp="$(ve_win_temp)/sneaker-$$-$(basename "$rel")" \
        || die "could not locate the Windows temp directory from WSL"
      cp "$src" "$tmp" || die "could not copy ${id} to the Windows side"
      arg=$(wslpath -w "$tmp")
    fi
    out=$(ve_code --install-extension "$arg" --force 2>&1); rc=$?
    [ -n "$tmp" ] && rm -f "$tmp"
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" | sed -e 's/^/    /' >&2
      die "code --install-extension refused ${id}"
    fi
    # Verified after being written. code reports success from states in
    # which nothing was installed, and a ui extension that is not actually on
    # the laptop is the one thing this domain exists to put there.
    ve_code --list-extensions 2>/dev/null | grep -qix "$id" \
      || die "${id}: code reported success but does not list it afterwards. \
If VS Code is running, quit it fully and re-run; see docs/first-run.md 7b."
    ok "${id} ${version}"
    ve_lock_append laptop "$id" "$version" "$(ve_client_platform)"
    n=$((n+1))
  done < <(ve_py extensions "${VE_STAGE_DIR}/current/MANIFEST.json" local "$(ve_client_platform)")
  [ "$n" -gt 0 ] || info "no local extensions staged"
}

ve_lock_append() {
  local target=$1 id=$2 version=$3 platform=$4 stamp row
  [ -n "${VE_LOCK_FILE:-}" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ ! -s "$VE_LOCK_FILE" ]; then
    printf '# utc\ttarget\tid\tversion\tplatform\tengine\textension-id\tpublisher-id\tvsix-sha256\n' \
      >> "$VE_LOCK_FILE"
  fi
  row=$(ve_py extensions "${VE_STAGE_DIR}/current/MANIFEST.json" \
        "$( [ "$target" = laptop ] && printf local || printf remote )" "$platform" \
        | awk -F'\t' -v id="$id" '$1==id{print $6"\t"$7"\t"$8"\t"$5}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$stamp" "$target" "$id" "$version" \
    "$platform" "$row" >> "$VE_LOCK_FILE"
}

ve_install() {
  ve_staged_or_die
  ve_require_code
  local staged
  staged=$(ve_py summary "${VE_STAGE_DIR}/current/MANIFEST.json" \
           | awk -F'\t' '$1=="vscode_commit"{print $2}')
  if [ "$staged" != "$VE_COMMIT" ]; then
    err "staged bundle is for commit ${staged} but VS Code is ${VE_COMMIT}"
    err "installing it would place a server Remote-SSH will not use"
    [ "$VE_FORCE" = 1 ] || die "refusing; re-run fetch, or pass --force"
    warn "--force given; continuing against a mismatched commit"
  fi
  ve_install_local
  local alias
  while IFS= read -r alias; do
    [ -n "$alias" ] && ve_install_host "$alias"
  done < <(ve_host_list)
}

ve_status() {
  ve_require_code
  hdr "laptop"
  info "VS Code ${VE_VERSION} (${VE_COMMIT:0:12}) $(ve_client_platform)"

  # Ids in extensions.txt, lowercased, so a remote inventory can be marked
  # against what has been reviewed. Anything unmarked is what `clean --all`
  # would drop and never put back.
  local listed=""
  [ -f "$VE_EXTENSIONS_FILE" ] && listed=$(grep -v '^#' "$VE_EXTENSIONS_FILE" \
    | awk 'NF{print $1}' | sed -e 's/@.*//' | tr 'A-Z' 'a-z')

  local alias dest line kind value
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    dest=$(ve_host_dest "$alias")
    hdr "$alias  (${dest})"
    ssh_master "$dest"
    while IFS=$'\t' read -r kind value; do
      case "$kind" in
        none)   info "no ${VE_SERVER_DIR}" ;;
        server) info "server     ${value}" ;;
        ext)
          if printf '%s\n' "$listed" | grep -qx "$(printf '%s' "$value" | tr 'A-Z' 'a-z')"; then
            info "extension  ${value}"
          else
            warn "extension  ${value}   not in extensions.txt"
          fi ;;
      esac
    done < <(sn_ssh "$dest" '
      d="$HOME/.vscode-server"
      [ -d "$d" ] || { printf "none\t\n"; exit 0; }
      for p in "$d"/cli/servers/Stable-* "$d"/bin/*; do
        [ -d "$p" ] || continue
        c=$(basename "$p"); c=${c#Stable-}
        if [ -f "$p/server/.sneaker-complete" ] || [ -f "$p/.sneaker-complete" ]; then
          printf "server\t%s  (placed by sneaker)\n" "$c"
        elif [ -f "$p/vscode-server.tar.gz" ] && [ ! -s "$p/vscode-server.tar.gz" ]; then
          printf "server\t%s  (Remote-SSH legacy self-install attempt: client reads LEGACY, set VE_LAYOUT=legacy)\n" "$c"
        else
          printf "server\t%s  (not placed by sneaker)\n" "$c"
        fi
      done
      # Directory names are publisher.name-version; strip from the version on.
      ls -1 "$d/extensions" 2>/dev/null | grep -v "^\." | grep -v "^extensions.json$" \
        | sed -E "s/-[0-9]+\.[0-9]+\.[0-9]+.*$//" | sort -u \
        | while read -r e; do printf "ext\t%s\n" "$e"; done' 2>/dev/null | tr -d '\r')
  done < <(ve_host_list)
}

ve_sync() { ve_fetch; ve_stage; ve_install; }

# ------------------------------------------------------------------------ clean
#
# Starting from a known state is sometimes the only honest move: a host that a
# previous tool set up, in a layout the current client no longer reads, with a
# hand-edited extensions.json on top, is not something to reason about. It is
# something to remove.
#
# Two tiers. The default removes every server tree in both layouts and the CLI
# - the parts Remote-SSH is confused by - and keeps extensions and their
# settings. --all removes ~/.vscode-server entirely. Both confirm per host by
# asking for the alias back, because 'y' is too easy to type at the wrong
# prompt; --yes skips that for a run you have already read the plan for.

ve_clean() {
  local alias dest reply
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    dest=$(ve_host_dest "$alias")
    hdr "$alias  (${dest})"
    if [ "$VE_ALL" = 1 ]; then
      info "removes ${VE_SERVER_DIR} entirely: every server, the CLI, all remote"
      info "extensions and their settings. Remote-SSH will rebuild from nothing."
    else
      info "removes every server tree (both layouts) and the CLI; keeps extensions"
    fi
    if [ "$VE_DRY" = 1 ]; then info "dry run, nothing removed"; continue; fi
    if [ "$VE_YES" != 1 ]; then
      printf 'type %s to confirm, anything else to skip: ' "$alias" >&2
      read -r reply </dev/tty || reply=""
      [ "$reply" = "$alias" ] || { warn "skipped ${alias}"; continue; }
    fi
    ssh_master "$dest"
    if [ "$VE_ALL" = 1 ]; then
      sn_ssh "$dest" "rm -rf \"\$HOME/${VE_SERVER_DIR#\$HOME/}\"" \
        || die "could not remove ${VE_SERVER_DIR} on ${dest}"
      ok "removed ${VE_SERVER_DIR} on ${alias}"
    else
      sn_ssh "$dest" "d=\"\$HOME/${VE_SERVER_DIR#\$HOME/}\"
        rm -rf \"\$d/cli/servers\" \"\$d/bin\" \"\$d\"/code-* \"\$d\"/.*.log \"\$d\"/.*.pid \"\$d\"/.*.token 2>/dev/null; true" \
        || die "could not remove server trees on ${dest}"
      ok "removed all server trees and the CLI on ${alias}; extensions kept"
    fi
  done < <(ve_host_list)
}

ve_search() {
  local term=${1:-}
  [ -n "$term" ] || die "usage: sneaker vscode-extensions search TERM"
  local cat="${VE_STAGE_DIR}/current/catalog/marketplace.tsv.gz"
  [ -f "$cat" ] || die "no catalogue staged; fetch without --no-catalog first"
  printf '%-42s %-12s %-9s %s\n' ID INSTALLS PUBLISHER NAME >&2
  gzip -dc "$cat" | grep -iv '^#' | grep -i -- "$term" | head -n "${VE_SEARCH_LIMIT}" \
    | awk -F'\t' '{printf "%-42s %-12s %-9s %s\n", $1, $2, $3, $6}'
}

# ----------------------------------------------------------------------- args

VE_HOSTS=(); VE_ONLY=""; VE_DRY=0; VE_FORCE=0; VE_YES=0; VE_ALL=0; VE_BUNDLE=""
VE_NO_HEDGE=""; VE_NO_CATALOG=""
declare -A _VE_HOME_DONE=()

ve_usage() {
  cat >&2 <<'USAGE'
sneaker vscode-extensions - VS Code extensions and server into an isolated network

usage: sneaker vscode-extensions <verb> [options]

verbs
  sync        fetch, stage and install
  fetch       run the bastion fetcher and carry the bundle down
  stage       verify and unpack a bundle; write nothing to a host
  install     place servers and install extensions
  probe       read each host's arch, libc and server layout
  status      what each host currently has
  clean       remove server trees on a host (--all: everything under ~/.vscode-server)
  drift       compare the installed VS Code against what is staged
  search TERM look an extension up in the staged catalogue

options
  --host ALIAS      target host; repeatable (default: DEFAULT_HOSTS)
  --only IDS        comma-separated extension ids
  --bundle FILE     stage this bundle rather than the newest
  --layout MODE     auto | modern | legacy   (default: auto)
  --no-hedge        stage only the installed commit's server
  --no-catalog      omit the Marketplace index
  --dry-run         print the plan, change nothing
  --force           install despite a commit mismatch
  --all             clean: remove ~/.vscode-server entirely, extensions included
  --yes             clean: skip the per-host confirmation
USAGE
}

ve_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)       VE_HOSTS+=("$2"); shift 2 ;;
      --host=*)     VE_HOSTS+=("${1#*=}"); shift ;;
      --only)       VE_ONLY=$2; shift 2 ;;
      --only=*)     VE_ONLY=${1#*=}; shift ;;
      --bundle)     VE_BUNDLE=$2; shift 2 ;;
      --bundle=*)   VE_BUNDLE=${1#*=}; shift ;;
      --layout)     VE_LAYOUT=$2; shift 2 ;;
      --layout=*)   VE_LAYOUT=${1#*=}; shift ;;
      --no-hedge)   VE_NO_HEDGE=1; shift ;;
      --no-catalog) VE_NO_CATALOG=1; shift ;;
      --dry-run)    VE_DRY=1; shift ;;
      --force)      VE_FORCE=1; shift ;;
      --all)        VE_ALL=1; shift ;;
      --yes|-y)     VE_YES=1; shift ;;
      -h|--help)    ve_usage; exit 0 ;;
      -*)           die "unknown option: $1" ;;
      *)            VE_ARGS+=("$1"); shift ;;
    esac
  done
  case "$VE_LAYOUT" in
    auto|modern|legacy) : ;;
    *) die "--layout must be auto, modern or legacy (got ${VE_LAYOUT})" ;;
  esac
}

ve_main() {
  local verb=${1:-}; shift || true
  [ -n "$verb" ] || { ve_usage; exit 1; }
  VE_ARGS=()
  ve_parse_args "$@"
  case "$verb" in
    fetch)   ve_fetch ;;
    stage)   ve_stage ;;
    install) ve_install ;;
    sync)    ve_sync ;;
    probe)   ve_probe ;;
    status)  ve_status ;;
    clean)   ve_clean ;;
    drift)   ve_drift ;;
    search)  ve_search ${VE_ARGS[0]+"${VE_ARGS[0]}"} ;;
    -h|--help|help) ve_usage ;;
    *) die "unknown verb: ${verb}" ;;
  esac
}
