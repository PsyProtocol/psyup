# psyup claim — claim miner rewards via `psy_user_cli claim-rewards`
#
# Auto-fills (when not already set on CLI):
#   --rpc-config     ← PSY_CONFIG_PATH env, or $PSY_HOME/config.json
#   --jobs-file      ← ./worker.backup
#
# Wallet source (resolved in this order, any explicit user arg wins):
#   1. $KEYSTORE_PATH                          → forwarded as --keystore-path
#      (password read from $WALLET_PASSWORD or an interactive prompt); the
#      password is passed via env, never argv, and no private key is materialized.
#   2. $PRIVATE_KEY env var                     → read natively by psy_user_cli.
#
# Any explicit user arg overrides the corresponding auto-fill.

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

cmd_claim_reward() {
    command -v psy_user_cli >/dev/null 2>&1 \
        || die "psy_user_cli not found in PATH (run 'psyup install' first)"
    require_structured_results

    # --rpc-config / PSY_CONFIG_PATH (env passthrough)
    if [ -z "${PSY_CONFIG_PATH:-}" ] && [ -f "$PSY_HOME/config.json" ]; then
        export PSY_CONFIG_PATH="$PSY_HOME/config.json"
    fi

    # Wallet source resolution. claim-rewards takes the same WalletSourceArgs
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
        # claim-rewards binds WALLET_PASSWORD from env (clap), so export it
        # rather than exposing the password on the command line.
        credential_args+=(--keystore-path "$keystore_file")
        export WALLET_PASSWORD
    elif [ -n "${PRIVATE_KEY:-}" ]; then
        # psy_user_cli reads PRIVATE_KEY from env natively; nothing to forward.
        say "using PRIVATE_KEY for identity"
    else
        die "no wallet configured; set KEYSTORE_PATH (and WALLET_PASSWORD) or PRIVATE_KEY"
    fi

    # Match the worker's default completed-jobs log in the current directory.
    # Preserve the CLI's no-file behavior until the worker has created it.
    if ! has_flag --jobs-file "$@" && [ -f "./worker.backup" ]; then
        set -- --jobs-file "./worker.backup" "$@"
    fi

    # Run psy_user_cli; it streams human logs to the terminal and writes the
    # structured result to $res.
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
    psy_user_cli --result-file "$res" claim-rewards \
        ${credential_args[@]+"${credential_args[@]}"} "$@"
    local rc=$?
    set -e
    # Clear any exported wallet password now that claim-rewards has returned.
    unset WALLET_PASSWORD 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        if [ ! -s "$res" ]; then
            rm -f "$res"
            die "claim succeeded but psy_user_cli wrote no result file — toolchain output protocol incompatible"
        fi
        local status tx_hash
        status=$(result_get "$res" status)
        tx_hash=$(result_get "$res" tx_hash)
        rm -f "$res"
        if [ -n "$status" ]; then
            say "✓ status: $status"
        fi
        if [ -n "$tx_hash" ]; then
            say "✓ tx_hash: $tx_hash"
        fi
    else
        rm -f "$res"
    fi

    exit "$rc"
}
