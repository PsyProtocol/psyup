# psyup deploy — wraps `psy_user_cli deploy-contract` for the current project.
#
# Auto-fills (when not already set on CLI):
#   --rpc-config     ← RPC_CONFIG env, or $PSY_HOME/config.json
#   --contract-path  ← ./target/<package>.json, ./<package>.json, or ./build/<package>.json
#   --is-deploy      always added
#
# Wallet source (resolved in this order, any explicit user arg wins):
#   1. $KEYSTORE_PATH                          → forwarded as --keystore-path
#      (password read from $WALLET_PASSWORD or an interactive prompt); the
#      password is passed via env, never argv, and no private key is materialized.
#   2. $PRIVATE_KEY env var                     → read natively by psy_user_cli.
#
# Any explicit user arg overrides the corresponding auto-fill.

# Read the top-level `name = "..."` field from Dargo.toml.
package_name_from_dargo() {
    awk '
        /^name[[:space:]]*=/ && !done {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print
            done=1
        }
    ' Dargo.toml 2>/dev/null
}

# Locate the compiled <package>.json. Prints the path or returns 1.
locate_contract_artifact() {
    local pkg=$1 p
    for p in "target/$pkg.json" "$pkg.json" "build/$pkg.json"; do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Detect which auto-fills are needed by scanning user args.
has_flag() {
    local needle=$1; shift
    for a in "$@"; do
        case "$a" in
            "$needle"|"$needle"=*) return 0 ;;
        esac
    done
    return 1
}

cmd_deploy() {
    [ -f Dargo.toml ] || die "no Dargo.toml in current directory"
    command -v psy_user_cli >/dev/null 2>&1 \
        || die "psy_user_cli not found in PATH (run 'psyup install' first)"
    require_structured_results

    # --rpc-config / RPC_CONFIG (env passthrough)
    if [ -z "${RPC_CONFIG:-}" ] && [ -f "$PSY_HOME/config.json" ]; then
        export RPC_CONFIG="$PSY_HOME/config.json"
    fi

    # Wallet source resolution. deploy-contract takes the same WalletSourceArgs
    # as the other wallet commands (--keystore-path + --wallet-password, or
    # --private-key), so the credential is forwarded straight through — no
    # private key is scraped or materialized. Preference order: keystore first,
    # then PRIVATE_KEY. An explicit --keystore-path / --private-key on the CLI
    # is passed through untouched.
    local keystore_file="${KEYSTORE_PATH:-}"
    local credential_args=()
    local using_keystore=0

    if has_flag --keystore-path "$@"; then
        using_keystore=1
    elif has_flag --private-key "$@"; then
        : # user supplied a private key; pass argv through unchanged
    elif [ -n "$keystore_file" ]; then
        [ -f "$keystore_file" ] || die "KEYSTORE_PATH does not point to a file: $keystore_file"
        using_keystore=1
        say "using keystore: $keystore_file"
        if [ -z "${WALLET_PASSWORD:-}" ]; then
            printf 'password: ' >&2
            IFS= read -rs WALLET_PASSWORD
            printf '\n' >&2
        fi
        # deploy-contract binds WALLET_PASSWORD from env (clap), so export it
        # rather than exposing the password on the command line.
        credential_args+=(--keystore-path "$keystore_file")
        export WALLET_PASSWORD
    elif [ -n "${PRIVATE_KEY:-}" ]; then
        # psy_user_cli reads PRIVATE_KEY from env natively; nothing to forward.
        say "using PRIVATE_KEY for identity"
    else
        die "no wallet configured; set KEYSTORE_PATH (and WALLET_PASSWORD) or PRIVATE_KEY"
    fi

    local pkg=""

    # --contract-path auto-fill from build output
    if ! has_flag --contract-path "$@"; then
        local artifact
        pkg=$(package_name_from_dargo)
        if [ -z "$pkg" ]; then
            warn "could not read package name from Dargo.toml; skipping --contract-path auto-fill"
        elif artifact=$(locate_contract_artifact "$pkg"); then
            say "using --contract-path=$artifact"
            set -- --contract-path "$artifact" "$@"
        else
            die "compiled artifact not found (looked for target/$pkg.json, $pkg.json, build/$pkg.json) — run 'psyup build' first"
        fi
    fi

    # Run psy_user_cli; it streams human logs to the terminal and writes the
    # structured DeployResult to $res. The contract uuid is read from the
    # result file (DeployResult.tx_hash == contract_uuid), never scraped from
    # the log text.
    local res
    res=$(mktemp)
    set +e
    # ${credential_args[@]+"..."} is the set -u-safe empty-array expansion
    # (bash 3.2 errors on a bare "${credential_args[@]}" when it is empty, i.e.
    # the PRIVATE_KEY-env path, where nothing is forwarded).
    if [ "$using_keystore" -eq 1 ]; then
        # clap treats an empty env variable as present, so remove it entirely.
        # This only affects the psyup process, never the caller's shell.
        unset PRIVATE_KEY
    fi
    psy_user_cli --result-file "$res" deploy-contract --is-deploy \
        ${credential_args[@]+"${credential_args[@]}"} "$@"
    local rc=$?
    set -e
    # Clear any exported wallet password now that deploy-contract has returned.
    unset WALLET_PASSWORD 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        if [ ! -s "$res" ]; then
            rm -f "$res"
            die "deploy succeeded but psy_user_cli wrote no result file — toolchain output protocol incompatible"
        fi
        local uuid
        uuid=$(result_get "$res" tx_hash)
        rm -f "$res"
        [ -n "$uuid" ] || die "psy_user_cli deploy result missing tx_hash — toolchain output protocol incompatible"
        say "✓ contract_uuid: $uuid"
        # lookup_contract_id always prints the URL on line 1, and the
        # numeric contract_id on line 2 if it succeeded (subshell vars
        # can't propagate back, so we communicate via stdout).
        local lookup_url="" cid=""
        # Both reads are tolerant: lookup_contract_id may exit early with
        # no output if config is missing.
        {
            read -r lookup_url || lookup_url=""
            read -r cid        || cid=""
        } < <(lookup_contract_id "$uuid")

        if [ -n "$cid" ]; then
            say "✓ contract_id:   $cid"
            printf '{"contract_uuid":"%s","contract_id":%s}\n' "$uuid" "$cid" > .psy-deploy
        else
            # Lookup failed/timed out — put the GET URL into contract_id
            # so the user can curl it manually later.
            printf '{"contract_uuid":"%s","contract_id":"%s"}\n' \
                "$uuid" "${lookup_url:-unknown}" > .psy-deploy
        fi
        say "  saved to .psy-deploy"
    else
        rm -f "$res"
    fi

    exit "$rc"
}

# Resolve api_services_url from $RPC_CONFIG, then GET /v1/get/contract?contract_uuid=<uuid>
# and pull contract_id from the JSON response. Prints the id on stdout or
# nothing on failure (always returns 0 to keep deploy non-fatal).
lookup_contract_id() {
    local uuid=$1
    local cfg=${RPC_CONFIG:-$PSY_HOME/config.json}
    [ -f "$cfg" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    command -v curl >/dev/null 2>&1 || return 0

    local default_net
    default_net=$(python3 - "$cfg" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(cfg.get("defaultNetwork", ""))
except Exception:
    print("")
PY
)
    if [ -z "$default_net" ]; then
        default_net=$(settings_get default_network)
    fi

    # Returns "<status>\t<url>" so the caller can warn on silent fallback.
    local lookup_out status service_url
    lookup_out=$(python3 - "$cfg" "${default_net:-}" <<'PY' 2>/dev/null
import json, sys
cfg = json.load(open(sys.argv[1]))
nets = cfg.get("networks", {})
if not nets:
    sys.exit(0)
preferred = sys.argv[2]
net_name = None
if preferred and preferred in nets:
    net_name, net = preferred, nets[preferred]
    status = "matched"
else:
    net_name, net = next(iter(nets.items()))
    status = "fallback" if preferred else "default"
urls = net.get("api_services_url") or []
url = urls[0] if isinstance(urls, list) and urls else (urls if isinstance(urls, str) else "")
if url:
    print(f"{status}\t{net_name}\t{url}")
PY
)
    if [ -z "$lookup_out" ]; then
        printf 'psyup: warning: no api_services_url in %s\n' "$cfg" >&2
        return 0
    fi

    status=$(printf '%s' "$lookup_out" | cut -f1)
    local picked_net
    picked_net=$(printf '%s' "$lookup_out" | cut -f2)
    service_url=$(printf '%s' "$lookup_out" | cut -f3)

    if [ "$status" = "fallback" ]; then
        printf "psyup: warning: settings.toml default_network='%s' not found in %s\n" "$default_net" "$cfg" >&2
        printf "psyup:   falling back to network '%s' — update settings.toml to suppress this\n" "$picked_net" >&2
    fi

    local url="$service_url/api/v1/transaction/hash/$uuid"

    # ALWAYS print the URL first on stdout — the caller uses it on failure
    # to record the GET URL in .psy-deploy. cid (if any) goes on line 2.
    printf '%s\n' "$url"

    local attempts=30 cid="" resp i parse_err
    printf 'psyup:   polling %s\n' "$url" >&2
    printf 'psyup:   (up to %d attempts, 1s apart) ' "$attempts" >&2

    for i in $(seq 1 "$attempts"); do
        # Use -w "%{http_code}" so we can distinguish "no response" from "200
        # with unexpected payload". We capture both body and status.
        resp=$(curl -sL --max-time 5 "$url" 2>/dev/null) || resp=""
        if [ -n "$resp" ]; then
            cid=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
data = d.get("data") if isinstance(d, dict) else None
if not isinstance(data, dict):
    sys.exit(0)
if data.get("status") != "included":
    sys.exit(0)
result = data.get("result") or {}
cid = result.get("contract_id")
if cid is not None:
    print(cid)
' 2>/dev/null)
        fi
        if [ -n "$cid" ]; then
            printf ' ✓ (%d/%d)\n' "$i" "$attempts" >&2
            printf '%s\n' "$cid"
            return 0
        fi
        printf '.' >&2
        [ "$i" -lt "$attempts" ] && sleep 1
    done

    # Dump the last response so the user can see WHY parsing failed
    # (or why the server isn't returning status="included" yet).
    printf ' ✗ gave up after %d attempts\n' "$attempts" >&2
    if [ -n "$resp" ]; then
        printf 'psyup:   last response was:\n%s\n' "$resp" >&2
    else
        printf 'psyup:   no response received (network / server unreachable)\n' >&2
    fi
    return 0
}
