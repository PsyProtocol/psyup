# psyup worker — run the proof miner with auto-resolved user identity

has_flag() {
    local needle=$1; shift
    for a in "$@"; do
        case "$a" in
            "$needle"|"$needle"=*) return 0 ;;
        esac
    done
    return 1
}

get_worker_api_urls() {
    local config_file=$1
    python3 - "$config_file" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
networks = cfg.get("networks", {})
name = cfg.get("defaultNetwork")
if not name or name not in networks:
    sys.exit(0)
net = networks[name]
for entry in net.get("coordinator_configs", []):
    urls = entry.get("rpc_url") or []
    if isinstance(urls, str):
        urls = [urls]
    for url in urls:
        if url:
            print(f"C\t{url}")
for entry in net.get("realm_configs", []):
    urls = entry.get("rpc_url") or []
    if isinstance(urls, str):
        urls = [urls]
    for url in urls:
        if url:
            print(f"R\t{url}")
PY
}

cmd_worker() {
    require_structured_results

    # --rpc-config / PSY_CONFIG_PATH (env passthrough)
    if [ -z "${PSY_CONFIG_PATH:-}" ] && [ -f "$PSY_HOME/config.json" ]; then
        export PSY_CONFIG_PATH="$PSY_HOME/config.json"
    fi

    local keystore_file="${KEYSTORE_PATH:-}"
    local rpc_config="${PSY_CONFIG_PATH:-$PSY_HOME/config.json}"
    local user_id=""
    local has_keystore=0
    local has_private_key=0
    local private_key=""

    if [ -n "$keystore_file" ]; then
        [ -f "$keystore_file" ] || die "KEYSTORE_PATH does not point to a file: $keystore_file"
        has_keystore=1
    fi

    private_key="${PRIVATE_KEY:-}"
    if [ -n "$private_key" ]; then
        has_private_key=1
    fi

    if [ "$has_keystore" -eq 0 ] && [ "$has_private_key" -eq 0 ]; then
        die "no wallet configured; set KEYSTORE_PATH (and WALLET_PASSWORD) or PRIVATE_KEY"
    fi

    local public_key_hash=""
    # Credential args forwarded straight to psy_worker_cli. For a keystore we
    # pass --keystore-path and the password via env (never a private key).
    local credential_args=()

    if [ "$has_keystore" -eq 0 ] && [ "$has_private_key" -eq 1 ]; then
        say "using PRIVATE_KEY for identity"
        local res rc
        res=$(mktemp)
        # Discard stdout (human logs incl. the private_key line); read the key from $res.
        psy_user_cli --result-file "$res" wallet info --private-key "$private_key" >/dev/null || rc=$?
        if [ "${rc:-0}" -ne 0 ]; then
            rm -f "$res"
            die "failed to derive public key from PRIVATE_KEY"
        fi
        public_key_hash=$(result_get "$res" public_key_hash)
        rm -f "$res"
        [ -n "$public_key_hash" ] || die "wallet info did not contain public_key (private key invalid?)"
        credential_args+=(--private-key "$private_key")
    else
        if [ -z "${WALLET_PASSWORD:-}" ]; then
            printf 'Enter keystore password: ' >&2
            IFS= read -rs WALLET_PASSWORD
            printf '\n' >&2
        fi
        local wallet_password="$WALLET_PASSWORD"
        unset WALLET_PASSWORD

        local res rc
        res=$(mktemp)
        psy_user_cli --result-file "$res" wallet info \
            --keystore-path "$keystore_file" --wallet-password "$wallet_password" >/dev/null || rc=$?
        if [ "${rc:-0}" -ne 0 ]; then
            rm -f "$res"
            die "failed to read wallet info; check keystore password"
        fi
        public_key_hash=$(result_get "$res" public_key_hash)
        rm -f "$res"
        [ -n "$public_key_hash" ] || die "wallet info did not contain public_key (corrupt keystore?)"

        # Forward the keystore straight to psy_worker_cli (no private key ever
        # passes through psyup). The worker binds WALLET_PASSWORD from env, so
        # export it rather than exposing it on the command line.
        credential_args+=(--keystore-path "$keystore_file")
        export WALLET_PASSWORD="$wallet_password"
        wallet_password=""
    fi

    say "resolving user_id..."
    local line qrc=0 status
    line=$(query_user_id "$rpc_config" "$public_key_hash") || qrc=$?
    if [ "$qrc" -ne 0 ]; then
        unset WALLET_PASSWORD 2>/dev/null || true
        die "get-user-id failed; is RPC reachable? (network: $(get_current_network))"
    fi
    status=${line%%$'\t'*}
    user_id=${line#*$'\t'}
    if [ "$status" != "registered" ] || [ -z "$user_id" ]; then
        unset WALLET_PASSWORD 2>/dev/null || true
        die "no user_id found for this wallet on $(get_current_network); run 'psyup init' to register"
    fi

    say "✅ user_id: $user_id (network: $(get_current_network))"
    say ""
    say "starting worker..."
    say ""

    local worker_args=()
    worker_args+=("${credential_args[@]}")
    worker_args+=("--user" "$user_id")

    # Worker network enum is fixed for this workflow and is independent of
    # ~/.psy/config.json defaultNetwork, which selects coordinator/realm URLs.
    if ! has_flag --network "$@"; then
        worker_args+=("--network" "local-devnet")
    fi

    # Map shared ~/.psy/config.json network config into worker-specific API URL args
    # unless the user already passed their own explicit worker API URLs.
    local mapped_urls="" kind="" url="" have_coord=0 have_realm=0
    if ! has_flag --coordinator-api-url "$@" || ! has_flag --realm-api-url "$@"; then
        mapped_urls=$(get_worker_api_urls "$rpc_config" 2>/dev/null) || mapped_urls=""
        while IFS=$'\t' read -r kind url; do
            [ -n "$kind" ] || continue
            case "$kind" in
                C)
                    if ! has_flag --coordinator-api-url "$@"; then
                        worker_args+=("--coordinator-api-url" "$url")
                        have_coord=1
                    fi
                    ;;
                R)
                    if ! has_flag --realm-api-url "$@"; then
                        worker_args+=("--realm-api-url" "$url")
                        have_realm=1
                    fi
                    ;;
            esac
        done <<EOF
$mapped_urls
EOF
    fi

    if ! has_flag --coordinator-api-url "$@" && [ "$have_coord" -ne 1 ]; then
        warn "no coordinator API URLs found in $rpc_config for network $(get_current_network)"
    fi
    if ! has_flag --realm-api-url "$@" && [ "$have_realm" -ne 1 ]; then
        warn "no realm API URLs found in $rpc_config for network $(get_current_network)"
    fi

    # Keep completed jobs in the directory where the worker was started unless
    # the caller explicitly chooses another log file.
    if ! has_flag --completed-jobs-log-file "$@"; then
        worker_args+=("--completed-jobs-log-file" "./worker.backup")
    fi

    worker_args+=("$@")

    local worker_rc=0
    if [ "$has_keystore" -eq 1 ]; then
        # clap treats an empty env variable as present, so remove it entirely.
        # This only affects the psyup process, never the caller's shell.
        unset PRIVATE_KEY
    fi
    psy_worker_cli worker "${worker_args[@]}" || worker_rc=$?

    # Clear any exported wallet password now that the worker has exited.
    unset WALLET_PASSWORD 2>/dev/null || true
    return "$worker_rc"
}
