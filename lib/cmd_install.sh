# psyup install / update / uninstall
#
# Toolchain sources (all GitHub):
#   node      PsyProtocol/psy-node     psy_*_cli binaries + psy-mcp-server
#   compiler  PsyProtocol/psy-compiler dargo + lib/psy-std
#   config    PsyProtocol/psy-genesis  config.json (raw, branch mainnet-beta)

resolve_latest_version() {
    # resolve_latest_version <repo>
    need curl
    local repo=$1
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local tag
    tag=$(curl -fsSL "$api" 2>/dev/null | awk -F'"' '/"tag_name":/ {print $4; exit}') || tag=""
    [ -n "$tag" ] || return 1
    # strip leading v
    printf '%s\n' "${tag#v}"
}

current_version() {
    settings_get active
}

download_file() {
    local url=$1 out=$2
    if [ -t 2 ]; then
        curl -fL --progress-bar "$url" -o "$out"
    else
        curl -fsSL "$url" -o "$out"
    fi
}

# fetch <repo> <name-prefix> <version> <triple> <tmpdir>
# Downloads <name-prefix>-v<version>-<triple>.tar.gz plus the repo's
# SHA256SUMS, verifies the checksum, and echoes the tarball path.
fetch_verified_tarball() {
    local repo=$1 prefix=$2 version=$3 triple=$4 tmp=$5
    local base="https://github.com/${repo}/releases/download/v${version}"
    local tarball="${prefix}-v${version}-${triple}.tar.gz"
    local sums="SHA256SUMS"

    # stdout carries the tarball path (captured by the caller); log to stderr.
    say "downloading $tarball from $repo" >&2
    download_file "$base/$tarball" "$tmp/$tarball" \
        || die "failed to download $base/$tarball"
    curl -fsSL "$base/$sums" -o "$tmp/$sums" \
        || die "failed to download $base/$sums"

    local expected
    expected=$(awk -v f="$tarball" '$2 == f || $2 == "*"f {print $1; exit}' "$tmp/$sums")
    [ -n "$expected" ] || die "no checksum entry for $tarball in $repo $sums"
    sha256_verify "$tmp/$tarball" "$expected"

    printf '%s\n' "$tmp/$tarball"
}

# Like fetch_verified_tarball but for a local override base URL (file://,
# https://, ...). SHA256SUMS is downloaded from the same base and verified,
# exactly like the GitHub path.
fetch_local_tarball() {
    local base=$1 prefix=$2 version=$3 triple=$4 tmp=$5
    local tarball="${prefix}-v${version}-${triple}.tar.gz"

    # stdout carries the tarball path (captured by the caller); log to stderr.
    say "downloading $tarball from $base" >&2
    download_file "$base/$tarball" "$tmp/$tarball" \
        || die "failed to download $base/$tarball"
    download_file "$base/SHA256SUMS" "$tmp/SHA256SUMS" \
        || die "failed to download $base/SHA256SUMS"

    local expected
    expected=$(awk -v f="$tarball" '$2 == f || $2 == "*"f {print $1; exit}' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "no checksum entry for $tarball in $base/SHA256SUMS"
    sha256_verify "$tmp/$tarball" "$expected"

    printf '%s\n' "$tmp/$tarball"
}

install_toolchain() {
    local node_version=$1 compiler_version=$2 triple default_network
    triple=$(detect_triple)
    default_network=${PSYUP_DEFAULT_NETWORK:-$(settings_get default_network)}
    [ -n "$default_network" ] || default_network=localhost
    local dest="$PSY_HOME/toolchains/psy-${node_version}"
    local tmp
    tmp=$(mktemp -d)

    # PSYUP_RELEASE_URL_* overrides point the downloads at any URL base curl
    # supports (https://, file://, ...). Useful for local dist/ testing.
    local node_base="${PSYUP_RELEASE_URL_NODE:-}"
    local compiler_base="${PSYUP_RELEASE_URL_COMPILER:-}"
    local config_url="${PSYUP_RELEASE_URL_CONFIG:-}"

    local node_tarball compiler_tarball
    if [ -n "$node_base" ]; then
        node_tarball=$(fetch_local_tarball "$node_base" psy-node "$node_version" "$triple" "$tmp")
    else
        node_tarball=$(fetch_verified_tarball "$PSY_NODE_REPO" psy-node "$node_version" "$triple" "$tmp")
    fi

    if [ -n "$compiler_base" ]; then
        compiler_tarball=$(fetch_local_tarball "$compiler_base" psy-compiler "$compiler_version" "$triple" "$tmp")
    else
        compiler_tarball=$(fetch_verified_tarball "$PSY_COMPILER_REPO" psy-compiler "$compiler_version" "$triple" "$tmp")
    fi

    rm -rf "$dest"
    mkdir -p "$dest/bin" "$dest/lib"

    # Node tarball ships binaries flat at the archive root; the compiler
    # tarball ships bin/ and lib/ at the archive root.
    tar -xzf "$node_tarball" -C "$dest/bin" \
        || die "failed to extract $(basename "$node_tarball")"
    tar -xzf "$compiler_tarball" -C "$dest" \
        || die "failed to extract $(basename "$compiler_tarball")"

    [ -x "$dest/bin/dargo" ] || die "dargo missing from compiler tarball"
    [ -f "$dest/lib/psy-std/std.psy" ] || die "psy-std/std.psy missing from compiler tarball"

    # Symlink executables into ~/.psy/bin (skip stray files like LICENSE)
    mkdir -p "$PSY_HOME/bin"
    local b
    for b in "$dest"/bin/*; do
        [ -f "$b" ] && [ -x "$b" ] || continue
        ln -sf "$b" "$PSY_HOME/bin/$(basename "$b")"
    done

    update_settings "$node_version" "$compiler_version" "$default_network"

    rm -rf "$tmp"

    write_env_paths "$dest" "$default_network" "$config_url"

    say "installed PSY toolchain (node $node_version, compiler $compiler_version)"
}

# Rewrite managed lines in ~/.psy/env to point at files installed from the
# active toolchain.
write_env_paths() {
    local dest=$1
    local default_network=$2
    local config_url=${3:-}
    local std_path="$dest/lib/psy-std/std.psy"
    local rpc_config="$PSY_HOME/config.json"
    local env_file="$PSY_HOME/env"
    local fish_env_file="$PSY_HOME/env.fish"
    local have_rpc_config=0

    [ -f "$env_file" ] || return 0

    # Runtime config at ~/.psy/config.json is authoritative once present.
    # Do not overwrite it on install/update: a packaged copy can regress
    # network names/endpoints (e.g. reintroduce legacy 'staging').
    if [ ! -f "$rpc_config" ]; then
        local genesis_url="${config_url:-https://raw.githubusercontent.com/${PSY_GENESIS_REPO}/${PSY_GENESIS_BRANCH}/config.json}"
        if download_file "$genesis_url" "$rpc_config"; then
            say "fetched config.json from $PSY_GENESIS_REPO ($PSY_GENESIS_BRANCH)"
        else
            warn "failed to fetch config.json from $genesis_url"
            warn "  deploy will require --rpc-config or RPC_CONFIG"
        fi
    fi
    if [ -f "$rpc_config" ]; then
        validate_network_in_config "$rpc_config" "$default_network"
        set_config_default_network "$rpc_config" "$default_network"
        have_rpc_config=1
    fi

    local tmpf
    tmpf=$(mktemp)
    awk -v std="$std_path" -v rpc="$rpc_config" -v have_rpc="$have_rpc_config" '
        /^# DARGO_STD_PATH=__PSYUP_MANAGED__/ { seen_std=1; print "export DARGO_STD_PATH=\"" std "\""; next }
        /^export DARGO_STD_PATH=/ { seen_std=1; print "export DARGO_STD_PATH=\"" std "\""; next }
        /^# RPC_CONFIG=__PSYUP_MANAGED__/ {
            seen_rpc=1
            if (have_rpc == 1) print "export RPC_CONFIG=\"" rpc "\""
            else print
            next
        }
        /^export RPC_CONFIG=/ {
            seen_rpc=1
            if (have_rpc == 1) print "export RPC_CONFIG=\"" rpc "\""
            else print
            next
        }
        { print }
        END {
            if (seen_std != 1) print "export DARGO_STD_PATH=\"" std "\""
            if (have_rpc == 1 && seen_rpc != 1) print "export RPC_CONFIG=\"" rpc "\""
        }
    ' "$env_file" > "$tmpf" && mv "$tmpf" "$env_file"

    say "DARGO_STD_PATH -> $std_path"
    if [ "$have_rpc_config" -eq 1 ]; then
        say "RPC_CONFIG -> $rpc_config"
    fi

    {
        printf '# psyup shell integration for fish.\n'
        printf 'fish_add_path -a "%s/bin"\n' "$PSY_HOME"
        printf 'set -gx DARGO_STD_PATH "%s"\n' "$std_path"
        if [ "$have_rpc_config" -eq 1 ]; then
            printf 'set -gx RPC_CONFIG "%s"\n' "$rpc_config"
        fi
    } > "$fish_env_file"
}

update_settings() {
    local node_version=$1 compiler_version=$2 default_network=$3 settings="$PSY_HOME/settings.toml"
    local tmpf

    if [ ! -f "$settings" ]; then
        cat > "$settings" <<EOF
# psyup user settings
active_node = "$node_version"
active_compiler = "$compiler_version"
default_network = "$default_network"
EOF
        return 0
    fi

    tmpf=$(mktemp)
    awk -v nv="$node_version" -v cv="$compiler_version" -v n="$default_network" '
        /^active_node[[:space:]]*=/ {
            print "active_node = \"" nv "\""
            seen_node=1
            next
        }
        /^active_compiler[[:space:]]*=/ {
            print "active_compiler = \"" cv "\""
            seen_compiler=1
            next
        }
        /^active[[:space:]]*=/ {
            # migrate legacy single-version setting: replace or drop it
            if (seen_node != 1) {
                print "active_node = \"" nv "\""
                seen_node=1
            }
            next
        }
        /^default_network[[:space:]]*=/ {
            print "default_network = \"" n "\""
            seen_network=1
            next
        }
        { print }
        END {
            if (seen_node != 1) print "active_node = \"" nv "\""
            if (seen_compiler != 1) print "active_compiler = \"" cv "\""
            if (seen_network != 1) print "default_network = \"" n "\""
        }
    ' "$settings" > "$tmpf" && mv "$tmpf" "$settings"
}

set_config_default_network() {
    local config=$1 default_network=$2 tmpf
    tmpf=$(mktemp)
    awk -v n="$default_network" '
        function count_char(s, c,    i, total) {
            total = 0
            for (i = 1; i <= length(s); i++) {
                if (substr(s, i, 1) == c) total++
            }
            return total
        }
        function flush_prev() {
            if (prev != "") {
                print prev
                prev = ""
            }
        }
        /^[[:space:]]*"defaultNetwork"[[:space:]]*:/ {
            comma = ($0 ~ /,[[:space:]]*$/) ? "," : ""
            indent = $0
            sub(/"defaultNetwork".*$/, "", indent)
            flush_prev()
            print indent "\"defaultNetwork\": \"" n "\"" comma
            seen=1
            next
        }
        /^[[:space:]]*}[[:space:]]*$/ && seen != 1 && depth == 1 {
            if (prev != "" && prev !~ /,[[:space:]]*$/) prev = prev ","
            flush_prev()
            print "  \"defaultNetwork\": \"" n "\""
            seen=1
        }
        {
            flush_prev()
            prev = $0
            depth += count_char($0, "{") - count_char($0, "}")
        }
        END { flush_prev() }
    ' "$config" > "$tmpf" && mv "$tmpf" "$config"
}

resolve_versions() {
    # Fills NODE_VERSION / COMPILER_VERSION. A pinned value from settings.toml
    # wins; otherwise resolve latest from each repo's releases.
    NODE_VERSION=$(resolve_latest_version "$PSY_NODE_REPO") || {
        warn "failed to resolve latest ${PSY_NODE_REPO} version; falling back to ${PSYUP_DEFAULT_VERSION:-0.1.0}"
        NODE_VERSION="${PSYUP_DEFAULT_VERSION:-0.1.0}"
    }
    COMPILER_VERSION=$(resolve_latest_version "$PSY_COMPILER_REPO") || {
        warn "failed to resolve latest ${PSY_COMPILER_REPO} version; falling back to ${NODE_VERSION}"
        COMPILER_VERSION="$NODE_VERSION"
    }
}

cmd_install() {
    local version=${1:-}
    if [ -z "$version" ] || [ "$version" = "latest" ]; then
        resolve_versions
    else
        # Single argument pins both components to the same version.
        NODE_VERSION=$version
        COMPILER_VERSION=$version
    fi
    install_toolchain "$NODE_VERSION" "$COMPILER_VERSION"
}

cmd_update() {
    resolve_versions
    local current_node current_compiler
    current_node=$(settings_get active_node)
    [ -n "$current_node" ] || current_node=$(settings_get active)
    current_compiler=$(settings_get active_compiler)
    [ -n "$current_compiler" ] || current_compiler="$current_node"
    if [ "$current_node" = "$NODE_VERSION" ] && [ "$current_compiler" = "$COMPILER_VERSION" ]; then
        say "already up to date (node $current_node, compiler $current_compiler)"
        return 0
    fi
    say "updating node $current_node -> $NODE_VERSION, compiler $current_compiler -> $COMPILER_VERSION"
    install_toolchain "$NODE_VERSION" "$COMPILER_VERSION"
}

cmd_uninstall() {
    printf 'psyup: this will remove psyup binaries, libs, toolchains, templates, config, and settings under %s, but preserve %s/keystore. continue? [y/N] ' "$PSY_HOME" "$PSY_HOME"
    local reply
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) say "aborted"; return 0 ;;
    esac

    local preserved_keystore=0
    if [ -d "$PSY_HOME/keystore" ]; then
        preserved_keystore=1
    fi

    rm -rf \
        "$PSY_HOME/bin" \
        "$PSY_HOME/lib" \
        "$PSY_HOME/toolchains" \
        "$PSY_HOME/templates" \
        "$PSY_HOME/env" \
        "$PSY_HOME/env.fish" \
        "$PSY_HOME/config.json" \
        "$PSY_HOME/settings.toml"

    # Remove the root dir only if nothing preserved remains.
    if [ "$preserved_keystore" -ne 1 ]; then
        rmdir "$PSY_HOME" 2>/dev/null || true
        say "removed $PSY_HOME"
    else
        say "removed psyup files under $PSY_HOME"
        say "preserved keystore at $PSY_HOME/keystore"
    fi
    say "note: you may want to remove the PATH line added by install.sh from your shell rc/config"
}
