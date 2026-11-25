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
    PSY_CONFIG_PATH="$rpc_config" psy_user_cli --result-file "$res" get-user-id --pub-key "$public_key_hash" >/dev/null || rc=$?
    rc=${rc:-0}
    if [ "$rc" -eq 0 ]; then
        status=$(result_get "$res" status)
        user_id=$(result_get "$res" user_id)
    fi
    rm -f "$res"
    printf '%s\t%s\n' "${status:-}" "${user_id:-}"
    return "$rc"
}

# Find the active toolchain's bundled psy-std and export DARGO_STD_PATH so
# the compiler doesn't have to fall back to git. Duplicates ~/.psy/env so
# `psyup build` works even from a shell that hasn't sourced env.
ensure_dargo_std_path() {
    [ -n "${DARGO_STD_PATH:-}" ] && return 0

    local active std_path
    active=$(settings_get active_node)
    [ -n "$active" ] || active=$(settings_get active)
    [ -n "$active" ] || return 0

    std_path="$PSY_HOME/toolchains/psy-${active}/lib/psy-std/std.psy"
    if [ -f "$std_path" ]; then
        export DARGO_STD_PATH="$std_path"
    fi
}

# Package sources plus the std tree and path-dependency trees that dargo can
# read from outside this package. Git/URL dependencies and symlinks are refused
# so an automatic certificate cannot hide an untracked input. This is still not
# a compiler lockfile: it binds the files visible at build and deploy time.
compiler_input_paths() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - <<'PY'
import os, re, sys
root = os.getcwd()
std = os.environ.get("DARGO_STD_PATH", "")
if not std or os.path.islink(std) or not os.path.isfile(std):
    sys.exit(1)
std_dir = os.path.dirname(os.path.abspath(std))
if os.path.islink(std_dir) or not os.path.isdir(std_dir):
    sys.exit(1)
queue = [std_dir]
seen = set()
path_re = re.compile(r'\bpath\s*=\s*"([^"]*)"')
untracked_re = re.compile(r'\b(?:git|url|rev|branch)\s*=')

def manifest_text(path):
    if os.path.islink(path) or not os.path.isfile(path):
        sys.exit(1)
    try:
        return open(path, "r", encoding="utf-8").read()
    except OSError:
        sys.exit(1)

def add_manifest(path, base):
    if not os.path.exists(path):
        return
    for line in manifest_text(path).splitlines():
        code = line.split("#", 1)[0]
        if untracked_re.search(code):
            sys.exit(1)
        match = path_re.search(code)
        if match:
            raw = match.group(1)
            if raw == "" or "\n" in raw or "\r" in raw:
                sys.exit(1)
            queue.append(os.path.abspath(os.path.join(base, raw)))
        elif re.search(r'\bpath\s*=', code):
            sys.exit(1)

add_manifest(os.path.join(root, "Dargo.toml"), root)
lock = os.path.join(root, "Dargo.lock")
if os.path.exists(lock):
    add_manifest(lock, root)

emitted = [os.path.abspath(std)]
while queue:
    current = queue.pop(0)
    if current in seen:
        continue
    if len(seen) > 10000:
        sys.exit(1)
    seen.add(current)
    if os.path.islink(current) or not os.path.isdir(current):
        sys.exit(1)
    add_manifest(os.path.join(current, "Dargo.toml"), current)
    for dirpath, dirnames, filenames in os.walk(current, followlinks=False):
        for name in dirnames:
            if os.path.islink(os.path.join(dirpath, name)):
                sys.exit(1)
        for name in filenames:
            joined = os.path.join(dirpath, name)
            if name.endswith(".psy") or name in ("Dargo.toml", "Dargo.lock"):
                if os.path.islink(joined) or not os.path.isfile(joined):
                    sys.exit(1)
                emitted.append(os.path.abspath(joined))
for path in emitted:
    if "\n" in path or "\r" in path:
        sys.exit(1)
    sys.stdout.write(path + "\0")
PY
}

# Automatic deploy provenance binds this package, the resolved std tree, and
# local path dependencies. Keep this in common.sh, which is already installed
# with both commands.
project_source_snapshot() (
    local paths records path digest inputs
    ensure_dargo_std_path
    paths=$(mktemp) || exit 1
    records=$(mktemp) || { rm -f "$paths"; exit 1; }
    inputs=$(mktemp) || { rm -f "$paths" "$records"; exit 1; }
    trap 'rm -f "$paths" "$records" "$inputs"' EXIT
    find . \( -type d \( -name .git -o -name target -o -name build -o -name node_modules \) -prune \) -o \
        \( -type l -o -type f \( -name '*.psy' -o -name Dargo.toml -o -name Dargo.lock \) \) -print0 > "$paths" || exit 1
    while IFS= read -r -d '' path; do
        # Directory symlinks could hide untracked sources; don't certify them.
        [ ! -L "$path" ] || exit 1
        case "$path" in *$'\n'*|*$'\r'*) exit 1 ;; esac
        digest=$(build_file_digest "$path") || exit 1
        printf '%s  %s\n' "$digest" "$path" >> "$records" || exit 1
    done < "$paths"
    compiler_input_paths > "$inputs" || exit 1
    while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        [ ! -L "$path" ] || exit 1
        case "$path" in *$'\n'*|*$'\r'*) exit 1 ;; esac
        digest=$(build_file_digest "$path") || exit 1
        printf '%s  %s\n' "$digest" "$path" >> "$records" || exit 1
    done < "$inputs"
    printf 'psyup-package-sources-v1\n'
    LC_ALL=C sort -u "$records"
)

build_file_digest() {
    local digest
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 < "$1") || return 1
    else
        return 1
    fi
    printf '%s\n' "${digest%% *}"
}

automatic_build_manifest() {
    local artifact=$1 digest
    [ -f "$artifact" ] || return 1
    project_source_snapshot || return 1
    digest=$(build_file_digest "$artifact") || return 1
    printf 'artifact %s  %s\n' "$digest" "$artifact"
}

require_current_build_artifact() (
    local candidate
    [ -f .psy-build-manifest ] || exit 1
    candidate=$(mktemp) || exit 1
    trap 'rm -f "$candidate"' EXIT
    automatic_build_manifest "$1" > "$candidate" || exit 1
    cmp -s .psy-build-manifest "$candidate"
)

# Compare the manifest with a private byte copy of the artifact. The recorded
# path stays the project artifact; the digest comes from the copy that deploy
# will hand to the CLI, so a later rewrite of the live path is not selected.
require_pinned_build_artifact() (
    local pinned=$1 artifact=$2 candidate digest
    [ -f .psy-build-manifest ] && [ -f "$pinned" ] || exit 1
    candidate=$(mktemp) || exit 1
    trap 'rm -f "$candidate"' EXIT
    project_source_snapshot > "$candidate" || exit 1
    digest=$(build_file_digest "$pinned") || exit 1
    printf 'artifact %s  %s\n' "$digest" "$artifact" >> "$candidate" || exit 1
    cmp -s .psy-build-manifest "$candidate"
)
