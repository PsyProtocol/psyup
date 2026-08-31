# Shared helpers for psyup. Sourced, not executed.

PSY_HOME="${PSY_HOME:-$HOME/.psy}"
PSY_NODE_REPO="${PSY_NODE_REPO:-PsyProtocol/psy-node}"
PSY_COMPILER_REPO="${PSY_COMPILER_REPO:-PsyProtocol/psy-compiler}"
PSY_GENESIS_REPO="${PSY_GENESIS_REPO:-PsyProtocol/psy-genesis}"
PSY_GENESIS_BRANCH="${PSY_GENESIS_BRANCH:-mainnet-beta}"
PSYUP_BOILERPLATE_REPO="${PSYUP_BOILERPLATE_REPO:-PsyProtocol/psy-template}"
PSYUP_DEFAULT_TEMPLATE="${PSYUP_DEFAULT_TEMPLATE:-dapp}"

say()  { printf 'psyup: %s\n' "$*"; }
warn() { printf 'psyup: warning: %s\n' "$*" >&2; }
die()  { printf 'psyup: error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

detect_triple() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Darwin) os=apple-darwin ;;
        Linux)  os=unknown-linux-gnu ;;
        *) die "unsupported OS: $os" ;;
    esac
    case "$arch" in
        x86_64|amd64) arch=x86_64 ;;
        arm64|aarch64) arch=aarch64 ;;
        *) die "unsupported arch: $arch" ;;
    esac
    printf '%s-%s\n' "$arch" "$os"
}

sha256_verify() {
    # sha256_verify <file> <expected-hex>
    local file=$1 expected=$2 actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        die "neither sha256sum nor shasum found"
    fi
    [ "$actual" = "$expected" ] || die "checksum mismatch for $file (got $actual, expected $expected)"
}

# Read a simple top-level `key = "value"` from a TOML-ish file. Not a real parser.
settings_get() {
    local key=$1 file="$PSY_HOME/settings.toml"
    [ -f "$file" ] || { echo ""; return 0; }
    awk -v k="$key" '
        $1 == k && $2 == "=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$file"
}

# Read the current default network from config.json.
# Uses PSYUP_CONFIG env var if set, otherwise falls back to $PSY_HOME/config.json.
get_current_network() {
    local config_file="${PSYUP_CONFIG:-$PSY_HOME/config.json}"
    if [ -f "$config_file" ]; then
        python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(cfg.get('defaultNetwork', 'unknown'))
except Exception:
    print('unknown')
" "$config_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

validate_network_in_config() {
    local config_file=$1 network=$2
    [ -f "$config_file" ] || die "config file not found: $config_file"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to validate network config"
    python3 - "$config_file" "$network" <<'PY' >/dev/null
import json, sys
cfg = json.load(open(sys.argv[1]))
network = sys.argv[2]
nets = cfg.get("networks", {})
if network not in nets:
    available = ", ".join(sorted(nets.keys())) if isinstance(nets, dict) and nets else "<none>"
    print(f"invalid network '{network}' (available: {available})", file=sys.stderr)
    sys.exit(1)
PY
    [ $? -eq 0 ] || die "invalid default network '$network' for $config_file"
}

# --- Structured psy_user_cli result protocol (--result-file) ---------------
#
# psy_user_cli accepts a global `--result-file <path>` and writes exactly one
# typed CommandResult as pretty JSON there (stdout/stderr stay human logs and
# are NOT parsed). These helpers read those result files. See
# structured_cli_protocol.plan.md.

# Ensure the installed toolchain can speak the result protocol, and that we can
# parse its output. Dies with an actionable upgrade message instead of silently
# falling back to log scraping (spec §15).
require_structured_results() {
    need jq
    psy_user_cli --help 2>&1 | grep -q -- '--result-file' \
        || die "installed psy_user_cli is too old (no --result-file support); run 'psyup update'"
}

# Read one top-level field from a result file. Prints empty for null/missing.
result_get() {  # result_get <file> <key>
    jq -r --arg k "$2" '.[$k] // empty' "$1"
}

# Read one top-level field that must be non-empty, else treat it as a protocol
# incompatibility (the toolchain produced a result we don't understand).
result_require() {  # result_require <file> <key> <label>
    local v
    v=$(result_get "$1" "$2")
    [ -n "$v" ] || die "psy_user_cli result missing/empty '$2' ($3) — toolchain output protocol incompatible"
    printf '%s\n' "$v"
}

# Resolve a wallet's on-chain registration via `get-user-id`. Prints
# "<status>\t<user_id>" (user_id empty unless registered) and returns the
# psy_user_cli exit status. A non-zero return is a real RPC/transport failure;
# "not_registered" is a normal business result returned with exit 0.
query_user_id() {  # query_user_id <rpc_config> <public_key_hash>
    local rpc_config=$1 public_key_hash=$2 res rc status user_id
    res=$(mktemp)
    # The result is read from $res; discard psy_user_cli's stdout (human logs,
    # incl. the private_key line) so it can't pollute this helper's return value.
    RPC_CONFIG="$rpc_config" psy_user_cli --result-file "$res" get-user-id --pub-key "$public_key_hash" >/dev/null || rc=$?
    rc=${rc:-0}
    if [ "$rc" -eq 0 ]; then
        status=$(result_get "$res" status)
        user_id=$(result_get "$res" user_id)
    fi
    rm -f "$res"
    printf '%s\t%s\n' "${status:-}" "${user_id:-}"
    return "$rc"
}
