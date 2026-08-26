# shellcheck shell=bash
# sneaker / obsidian-plugins : stage, install, sync. Sourced by bin/sneaker.

OP_ONLY=""
OP_YES=0
OP_ENABLE=0
OP_DRY=0
OP_BUNDLE=""
OP_LOCAL_ONLY=0
OP_UPDATES_ONLY=0
declare -a OP_TARGETS=()

op_usage() {
  cat >&2 <<'USAGE'
usage: sneaker obsidian-plugins <verb> [options] [plugin-id ...]

verbs
  fetch      run the fetcher on the bastion, bring the bundle down, verify it
  stage      unpack and verify a bundle into the staging area, report the plan
  install    place staged plugins into one or more vaults
  sync       fetch, stage, then install  (the one you will actually type)
  status     show what each vault has versus what is staged

options
  --vault T          vault target: an alias, /local/path, or host:/remote/path
                     repeatable; defaults to DEFAULT_VAULTS from the config
  --bundle FILE      stage/install from this bundle instead of the newest
  --only-updates     skip plugins the vault does not already have
  --enable           add installed ids to the vault's enabled list
  --yes              do not prompt before writing to a vault
  --dry-run          show the plan, write nothing
  --config FILE      config file (default: ./sneaker.conf or ~/.config/sneaker/config)
USAGE
}

op_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --vault)         OP_TARGETS+=("$2"); shift 2 ;;
      --vault=*)       OP_TARGETS+=("${1#*=}"); shift ;;
      --bundle)        OP_BUNDLE=$2; shift 2 ;;
      --bundle=*)      OP_BUNDLE=${1#*=}; shift ;;
      --only-updates)  OP_UPDATES_ONLY=1; shift ;;
      --enable)        OP_ENABLE=1; shift ;;
      --yes|-y)        OP_YES=1; shift ;;
      --dry-run|-n)    OP_DRY=1; shift ;;
      --local-only)    OP_LOCAL_ONLY=1; shift ;;   # internal: remote re-entry
      --stage-dir)     STAGE_DIR=$2; shift 2 ;;    # internal
      --obsidian-version) OBSIDIAN_VERSION=$2; shift 2 ;;
      -h|--help)       op_usage; exit 0 ;;
      --*)             die "unknown option: $1" ;;
      *)               OP_ONLY="${OP_ONLY:+$OP_ONLY,}$1"; shift ;;
    esac
  done
}

# Resolve aliases from the config into concrete targets.
op_resolve_targets() {
  local out=() t resolved
  if [ ${#OP_TARGETS[@]} -eq 0 ]; then
    if [ ${#DEFAULT_VAULTS[@]} -eq 0 ]; then
      die "no vault given and DEFAULT_VAULTS is empty; pass --vault"
    fi
    OP_TARGETS=("${DEFAULT_VAULTS[@]}")
  fi
  for t in "${OP_TARGETS[@]}"; do
    resolved="${VAULT_ALIAS[$t]:-$t}"
    if ! target_is_remote "$resolved"; then
      resolved=$(vault_normalize "$resolved") || exit 1
    fi
    out+=("$resolved")
  done
  OP_TARGETS=("${out[@]}")
}

op_py() { python3 "${SNEAKER_LIB}/vaultinfo.py" "$@"; }

# ---------------------------------------------------------------- vault state

# Installed-state TSV for one target, local or remote.
op_installed_tsv() {
  local target=$1 host path
  host=$(target_host "$target"); path=$(target_path "$target")
  if [ -z "$host" ]; then
    op_py installed "$path"
  else
    ssh_master "$host"
    op_bootstrap_remote "$host"
    sn_ssh "$host" "python3 ${REMOTE_CACHE}/lib/vaultinfo.py installed $(printf '%q' "$path")"
  fi
}

# Union across every target: a plugin is "current" only if every vault has it.
op_installed_union() {
  local target tmp all
  all=$(mktemp); tmp=$(mktemp)
  local first=1
  for target in "${OP_TARGETS[@]}"; do
    op_installed_tsv "$target" > "$tmp" || true
    if [ $first = 1 ]; then
      cp "$tmp" "$all"; first=0
    else
      # keep only entries present with an identical version everywhere
      awk -F'\t' 'NR==FNR{v[$1]=$2;next} ($1 in v) && v[$1]==$2' "$tmp" "$all" > "${all}.n"
      mv "${all}.n" "$all"
    fi
  done
  rm -f "$tmp"
  printf '%s' "$all"
}

# ------------------------------------------------------------------- bootstrap

REMOTE_CACHE='$HOME/.cache/sneaker'

op_bootstrap_remote() {
  local host=$1
  [ -n "${_SN_BOOTSTRAPPED[$host]:-}" ] && return 0
  info "pushing sneaker to ${host}"
  tar -C "$SNEAKER_ROOT" -czf - bin lib \
    | sn_ssh "$host" "rm -rf ${REMOTE_CACHE}/bin ${REMOTE_CACHE}/lib && mkdir -p ${REMOTE_CACHE} && tar -xzf - -C ${REMOTE_CACHE}" \
    || die "could not push sneaker to ${host}"
  _SN_BOOTSTRAPPED[$host]=1
}
declare -A _SN_BOOTSTRAPPED=()

# ----------------------------------------------------------------------- fetch

op_fetch() {
  [ -n "${BASTION:-}" ] || die "BASTION is not set in the config"
  need ssh scp tar sha256sum python3
  op_resolve_targets

  local installed req line rc bundle_remote digest size local_bundle got
  installed=$(op_installed_union)
  req=$(op_py request "$PLUGINS_FILE" "$installed" \
        ${OP_ONLY:+--only "$OP_ONLY"} \
        ${FETCH_SOURCE:+} ${FETCH_CATALOG:+}) || die "could not build the fetch request"
  rm -f "$installed"

  ssh_master "$BASTION"
  info "pushing fetcher to ${BASTION}"
  sn_ssh "$BASTION" "mkdir -p ${BASTION_WORKDIR} && cat > ${BASTION_WORKDIR}/fetch-obsidian-plugins.py" \
    < "${SNEAKER_ROOT}/bastion/fetch-obsidian-plugins.py" \
    || die "could not push the fetcher"

  hdr "fetching on ${BASTION}"
  # rc 2 means some plugins failed but a bundle was still produced; the failures
  # are reported above and recorded in MANIFEST.json.
  set +e
  line=$(printf '%s' "$req" \
    | sn_ssh "$BASTION" "python3 ${BASTION_WORKDIR}/fetch-obsidian-plugins.py --out ${BASTION_WORKDIR}/out --request -")
  rc=$?
  set -e
  if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
    die "the bastion fetcher failed (exit ${rc}); see the messages above"
  fi
  [ $rc -eq 2 ] && warn "some plugins failed to fetch; continuing with the rest"

  case "$line" in
    SNEAKER_EMPTY*) ok "every requested plugin is already current in every vault"; return 10 ;;
    SNEAKER_BUNDLE*) : ;;
    *) die "unexpected output from the fetcher: ${line:-<empty>}" ;;
  esac

  bundle_remote=$(printf '%s' "$line" | awk '{print $2}')
  digest=$(printf '%s' "$line" | awk '{print $3}')
  size=$(printf '%s' "$line" | awk '{print $4}')

  mkdir -p "$STAGE_DIR"
  local_bundle="${STAGE_DIR}/$(basename "$bundle_remote")"
  info "retrieving $(basename "$bundle_remote") (${size} bytes)"
  sn_scp "${BASTION}:${bundle_remote}" "$local_bundle" || die "scp failed"

  got=$(sha256_of "$local_bundle")
  if [ "$got" != "$digest" ]; then
    rm -f "$local_bundle"
    die "bundle hash mismatch after transfer (expected ${digest}, got ${got})"
  fi
  ok "bundle verified: $(basename "$local_bundle")"
  OP_BUNDLE=$local_bundle
  printf '%s\n' "$local_bundle"
}

# ----------------------------------------------------------------------- stage

op_newest_bundle() {
  ls -1t "${STAGE_DIR}"/obsidian-plugins-*.tar.gz 2>/dev/null | head -n1
}

# Refuse anything in the archive that could write outside the extraction root,
# or that is not one of the file kinds this format contains. The unpacker is
# the most exposed code here, so this is an allowlist, not a blocklist.
op_audit_tar() {
  local bundle=$1 bad=0 line kind name
  while IFS= read -r line; do
    kind=${line:0:1}
    name=$(printf '%s' "$line" | sed -e 's/^.* \([^ ]*\)$/\1/')
    case "$kind" in
      -) : ;;
      d) : ;;
      *) err "archive contains a non-regular member (${kind}): ${name}"; bad=1; continue ;;
    esac
    case "$name" in
      "${BUNDLE_ROOT}/"*) : ;;
      *) err "archive member outside ${BUNDLE_ROOT}/: ${name}"; bad=1; continue ;;
    esac
    case "$name" in
      /*|*..*) err "unsafe path in archive: ${name}"; bad=1 ;;
    esac
    case "${name#${BUNDLE_ROOT}/}" in
      MANIFEST.json|SHA256SUMS) : ;;
      catalog/community-plugins.json) : ;;
      source/*.tar.gz) : ;;
      plugins/*/main.js|plugins/*/manifest.json|plugins/*/styles.css) : ;;
      */) : ;;
      *) err "archive member not on the allowlist: ${name}"; bad=1 ;;
    esac
  done < <(tar -tvzf "$bundle")
  [ "$bad" = 0 ] || die "refusing this bundle"
}

BUNDLE_ROOT="sneaker-obsidian-plugins"

op_stage() {
  need tar sha256sum python3
  local bundle=${OP_BUNDLE:-$(op_newest_bundle)}
  [ -n "$bundle" ] && [ -f "$bundle" ] || die "no bundle found in ${STAGE_DIR}; run fetch first"

  hdr "verifying $(basename "$bundle")"
  op_audit_tar "$bundle"
  ok "archive layout"

  local tmp; tmp=$(mktemp -d "${STAGE_DIR}/.unpack.XXXXXX")
  # No RETURN trap here: it runs after locals are torn down, which trips set -u.
  _op_unpack_fail() { rm -rf "$tmp"; die "$1"; }

  tar -xzf "$bundle" -C "$tmp" --no-same-owner --no-same-permissions \
    || _op_unpack_fail "extraction failed"

  ( cd "${tmp}/${BUNDLE_ROOT}" && sha256sum --quiet -c SHA256SUMS ) \
    || _op_unpack_fail "checksum mismatch inside the bundle"
  ok "every file matches SHA256SUMS"

  rm -rf "${STAGE_DIR}/current"
  mv "${tmp}/${BUNDLE_ROOT}" "${STAGE_DIR}/current" \
    || _op_unpack_fail "could not move the payload into place"
  rm -rf "$tmp"
  ok "staged to ${STAGE_DIR}/current"

  op_py summary "${STAGE_DIR}/current/MANIFEST.json" \
    | while IFS=$'\t' read -r key value; do
        case "$key" in
          created)    info "bundle created ${value} UTC" ;;
          content_id) info "content-id     ${value}" ;;
          warning)    warn "$value" ;;
          failure)    err  "$value" ;;
        esac
      done
  OP_BUNDLE=$bundle
}

# ----------------------------------------------------------------------- plan

op_print_plan() {
  local target=$1 planfile=$2 rows=0
  printf '\n%s%s%s\n' "$_c_bld" "$target" "$_c_off" >&2
  printf '  %-8s %-28s %-12s %-12s %s\n' ACTION PLUGIN FROM TO NOTE >&2
  while IFS=$'\t' read -r action id from to minapp _name; do
    local note=""
    if [ -n "$minapp" ] && [ -n "${OBSIDIAN_VERSION:-}" ]; then
      if ver_lt "$OBSIDIAN_VERSION" "$minapp"; then
        note="needs Obsidian >= ${minapp}, you have ${OBSIDIAN_VERSION}"
      fi
    fi
    [ "$action" = same ] && continue
    printf '  %-8s %-28s %-12s %-12s %s\n' "$action" "$id" "$from" "$to" "$note" >&2
    rows=$((rows+1))
  done < "$planfile"
  [ "$rows" = 0 ] && printf '  %s(nothing to do)%s\n' "$_c_dim" "$_c_off" >&2
  return 0
}

op_plan_for() {
  local target=$1 out=$2 installed
  installed=$(mktemp)
  op_installed_tsv "$target" > "$installed" || true
  op_py plan "${STAGE_DIR}/current/MANIFEST.json" "$installed" \
    ${OP_ONLY:+--only "$OP_ONLY"} > "$out"
  if [ "$OP_UPDATES_ONLY" = 1 ]; then
    awk -F'\t' '$1!="new"' "$out" > "${out}.f" && mv "${out}.f" "$out"
  fi
  rm -f "$installed"
}

# --------------------------------------------------------------------- install

obsidian_running() {
  pgrep -x obsidian  >/dev/null 2>&1 && return 0
  pgrep -x Obsidian  >/dev/null 2>&1 && return 0
  if command -v tasklist.exe >/dev/null 2>&1; then
    tasklist.exe /FI "IMAGENAME eq Obsidian.exe" /NH 2>/dev/null \
      | grep -qi 'Obsidian.exe' && return 0
  fi
  return 1
}

op_install_local() {
  local vault=$1 planfile=$2 class plugins_dir id action from to minapp
  local staged src dst want existing enabled=() failed=0 done_n=0

  plugins_dir="${vault}/.obsidian/plugins"
  [ -d "$vault" ] || die "vault does not exist: ${vault}"
  [ -d "${vault}/.obsidian" ] || die "not an Obsidian vault (no .obsidian): ${vault}"

  class=$(fs_class_of "$vault")
  fs_advise "$vault" "$class"
  mkdir -p "$plugins_dir"

  while IFS=$'\t' read -r action id from to minapp _name; do
    [ "$action" = same ] && continue
    staged="${STAGE_DIR}/current/plugins/${id}"
    [ -d "$staged" ] || { err "${id}: not in the staged bundle"; failed=1; continue; }

    if [ -n "$minapp" ] && [ -n "${OBSIDIAN_VERSION:-}" ] \
       && ver_lt "$OBSIDIAN_VERSION" "$minapp"; then
      warn "${id} ${to} needs Obsidian >= ${minapp} (you have ${OBSIDIAN_VERSION}); it will not load"
    fi

    existing=$(plugin_dir_name "$plugins_dir" "$id")
    dst="${plugins_dir}/${existing:-$id}"
    mkdir -p "$dst"

    local file_failed=0
    for src in "$staged"/*; do
      [ -f "$src" ] || continue
      want=$(sha256_of "$src")
      if ! copy_verified "$src" "${dst}/$(basename "$src")" "$want" "$class"; then
        file_failed=1; break
      fi
    done
    if [ "$file_failed" = 1 ]; then
      err "${id}: install aborted"; failed=1; continue
    fi

    ok "${id} ${to}${from:+ (was ${from})}"
    enabled+=("$id")
    done_n=$((done_n+1))
    op_lock_append "$vault" "$id" "$to"
  done < "$planfile"

  if [ "$OP_ENABLE" = 1 ] && [ ${#enabled[@]} -gt 0 ]; then
    if obsidian_running; then
      warn "Obsidian is running; not editing the enabled list (it would be overwritten)"
      warn "enable these in Settings > Community plugins: ${enabled[*]}"
    else
      op_py enable "$vault" "${enabled[@]}" >/dev/null \
        && ok "enabled: ${enabled[*]}" \
        || warn "could not update the enabled list"
    fi
  elif [ ${#enabled[@]} -gt 0 ]; then
    info "installed but not enabled; toggle in Settings > Community plugins"
  fi

  [ "$failed" = 0 ] || return 1
  return 0
}

# The record of what crossed the boundary and when. Append-only, text, and the
# one artifact from this process that belongs in version control.
op_lock_append() {
  local vault=$1 id=$2 version=$3 rec stamp
  [ -n "${LOCK_FILE:-}" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rec=$(op_py record "${STAGE_DIR}/current/MANIFEST.json" "$id" 2>/dev/null) || rec=""
  if [ ! -s "$LOCK_FILE" ] 2>/dev/null; then
    printf '# utc\tvault\tid\tversion\trepo\ttag\tmain.js-sha256\n' >> "$LOCK_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$stamp" "$vault" "$id" "$version" \
    "$(printf '%s' "$rec" | awk -F'\t' '{print $1"\t"$2"\t"$4}')" >> "$LOCK_FILE"
}

op_install_remote() {
  local target=$1 host path
  host=$(target_host "$target"); path=$(target_path "$target")
  ssh_master "$host"
  op_bootstrap_remote "$host"
  info "pushing staged payload to ${host}"
  tar -C "$STAGE_DIR" -czf - current \
    | sn_ssh "$host" "rm -rf ${REMOTE_CACHE}/stage && mkdir -p ${REMOTE_CACHE}/stage && tar -xzf - -C ${REMOTE_CACHE}/stage" \
    || die "could not push the staged payload to ${host}"
  sn_ssh "$host" "${REMOTE_CACHE}/bin/sneaker obsidian-plugins install --local-only \
      --stage-dir ${REMOTE_CACHE}/stage \
      --vault $(printf '%q' "$path") \
      --obsidian-version $(printf '%q' "${OBSIDIAN_VERSION:-}") \
      $( [ "$OP_ENABLE" = 1 ] && printf %s --enable ) \
      $( [ "$OP_DRY" = 1 ] && printf %s --dry-run ) --yes \
      $(printf '%s' "${OP_ONLY//,/ }")"
}

op_install() {
  need sha256sum python3
  [ -d "${STAGE_DIR}/current" ] || die "nothing staged; run stage or sync first"
  op_resolve_targets

  local target planfile any=0 rc=0
  declare -a plans=()
  for target in "${OP_TARGETS[@]}"; do
    planfile=$(mktemp); plans+=("$planfile")
    op_plan_for "$target" "$planfile"
    op_print_plan "$target" "$planfile"
    awk -F'\t' '$1!="same"' "$planfile" | grep -q . && any=1
  done

  if [ "$any" = 0 ]; then
    log ""; ok "every vault is already current"
    rm -f "${plans[@]}"; return 0
  fi
  if [ "$OP_DRY" = 1 ]; then
    log ""; info "dry run: nothing written"
    rm -f "${plans[@]}"; return 0
  fi
  if [ "$OP_YES" != 1 ]; then
    log ""
    local reply=""
    read -r -p "apply this plan? [y/N] " reply < /dev/tty || reply=""
    case "$reply" in y|Y|yes|YES) : ;; *) info "aborted"; rm -f "${plans[@]}"; return 1 ;; esac
  fi

  local i=0
  for target in "${OP_TARGETS[@]}"; do
    hdr "installing into ${target}"
    if target_is_remote "$target" && [ "$OP_LOCAL_ONLY" != 1 ]; then
      op_install_remote "$target" || { err "${target}: failed"; rc=1; }
    else
      op_install_local "$(target_path "$target")" "${plans[$i]}" || { err "${target}: failed"; rc=1; }
    fi
    i=$((i+1))
  done
  rm -f "${plans[@]}"
  return $rc
}

# ------------------------------------------------------------------ sync/status

op_sync() {
  local out rc
  out=$(op_fetch); rc=$?
  if [ $rc = 10 ]; then return 0; fi
  [ $rc = 0 ] || return $rc
  OP_BUNDLE=$(printf '%s' "$out" | tail -n1)
  op_stage
  op_install
}

op_status() {
  op_resolve_targets
  local target installed
  for target in "${OP_TARGETS[@]}"; do
    hdr "$target"
    installed=$(op_installed_tsv "$target" || true)
    if [ -z "$installed" ]; then
      info "  no plugins installed"
    else
      printf '%s\n' "$installed" \
        | awk -F'\t' '{printf "  %-30s %-12s %s\n", $1, $2, ($3?"minApp "$3:"")}' >&2
    fi
  done
  if [ -d "${STAGE_DIR}/current" ]; then
    hdr "staged"
    op_py summary "${STAGE_DIR}/current/MANIFEST.json" \
      | awk -F'\t' '{printf "  %-12s %s\n", $1, $2}' >&2
  fi
}

op_main() {
  local verb=${1:-}; shift || true
  [ -n "$verb" ] || { op_usage; exit 1; }
  op_parse_args "$@"
  case "$verb" in
    fetch)   op_fetch >/dev/null ;;
    stage)   op_stage; op_resolve_targets
             local t p; for t in "${OP_TARGETS[@]}"; do
               p=$(mktemp); op_plan_for "$t" "$p"; op_print_plan "$t" "$p"; rm -f "$p"
             done ;;
    install) op_install ;;
    sync)    op_sync ;;
    status)  op_status ;;
    -h|--help|help) op_usage ;;
    *) die "unknown verb: ${verb}" ;;
  esac
}
