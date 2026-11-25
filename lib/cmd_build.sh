# psyup build — wraps `dargo compile` and `dargo generate-abi` in the current project.

# Read `entry = "..."` from Dargo.toml, falling back to src/main.psy.
contract_entry_file() {
    local entry
    entry=$(awk -F'=' '
        $1 ~ /^[[:space:]]*entry[[:space:]]*$/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^"|"$|[[:space:]]+$/, "")
            print
            exit
        }
    ' Dargo.toml 2>/dev/null)
    if [ -n "$entry" ]; then
        printf '%s\n' "$entry"
    else
        printf 'src/main.psy\n'
    fi
}

# Find the #[contract]-annotated struct in the entry file and return
# <name>Ref. Empty output means nothing detected; caller should fall through.
detect_contract_name() {
    local entry=$1
    [ -f "$entry" ] || return 0
    # Skip blank/comment/derive/attribute lines after #[contract]; the next
    # struct's name (with optional `pub`) is our target.
    awk '
        /#\[contract\]/ { in_contract=1; next }
        in_contract && /^[[:space:]]*$/ { next }
        in_contract && /^[[:space:]]*\/\// { next }
        in_contract && /^[[:space:]]*#\[/ { next }
        in_contract && /^[[:space:]]*(pub[[:space:]]+)?struct[[:space:]]/ {
            sub(/^[[:space:]]*(pub[[:space:]]+)?struct[[:space:]]+/, "")
            sub(/[[:space:]<{].*$/, "")
            print $0 "Ref"
            exit
        }
    ' "$entry"
}

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

arg_value() {
    local needle=$1
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            "$needle")
                shift
                [ "$#" -gt 0 ] && printf '%s\n' "$1"
                return 0
                ;;
            "$needle"=*)
                printf '%s\n' "${1#*=}"
                return 0
                ;;
        esac
        shift
    done

    return 1
}

cmd_build() {
    [ -f Dargo.toml ] \
        || die "no Dargo.toml in current directory (run 'psyup new <name>' first)"

    # A failed/retried build must never retain a previous success certificate.
    rm -f .psy-build-manifest || die "cannot invalidate previous build manifest"

    command -v dargo >/dev/null 2>&1 \
        || die "dargo not found in PATH (run 'psyup install' first)"

    ensure_dargo_std_path

    # Auto-fill --contract-name unless the user passed one.
    local has_contract_name=0 arg entry_path target_dir package_name
    for arg in "$@"; do
        case "$arg" in
            --contract-name|--contract-name=*) has_contract_name=1; break ;;
        esac
    done

    if [ "$has_contract_name" -eq 0 ]; then
        local entry name
        entry=$(contract_entry_file)
        name=$(detect_contract_name "$entry")
        if [ -n "$name" ]; then
            say "detected contract: $name (from $entry)"
            set -- --contract-name="$name" "$@"
        fi
    fi

    local source_before="" source_after="" automatic_build=1 manifest_tmp artifact digest
    for arg in "$@"; do
        case "$arg" in
            --entry-path|--entry-path=*|--target-dir|--target-dir=*|--program-dir|--program-dir=*|--debug|--debug=*) automatic_build=0 ;;
        esac
    done
    # An entry outside this package is not covered by the package snapshot.
    case "/$(contract_entry_file)/" in
        *'/../'*|//*) automatic_build=0 ;;
    esac
    source_before=$(project_source_snapshot) || automatic_build=0

    entry_path=$(arg_value --entry-path "$@" || true)
    target_dir=$(arg_value --target-dir "$@" || true)

    dargo compile "$@"

    package_name=$(package_name_from_dargo)
    if [ -z "$package_name" ]; then
        warn "could not read package name from Dargo.toml; skipping ABI generation"
        return 0
    fi

    # generate-abi's -c/--contract-name wants the contract TYPE name (e.g.
    # PsyTokenContractRef), not the package name. Reuse the --contract-name
    # passed to compile (user-supplied or auto-detected from #[contract]);
    # --abi-name keeps the output file at target/<package>.abi.json.
    local contract_ref
    contract_ref=$(arg_value --contract-name "$@" || true)
    if [ -z "$contract_ref" ]; then
        warn "could not detect contract name (#[contract]); skipping ABI generation"
        return 0
    fi

    local -a abi_args
    abi_args=(-c "$contract_ref" --abi-name "$package_name")
    if [ -n "$entry_path" ]; then
        abi_args+=(--entry-path "$entry_path")
    fi
    if [ -n "$target_dir" ]; then
        abi_args+=(--target-dir "$target_dir")
    fi

    dargo generate-abi "${abi_args[@]}"

    artifact="target/$package_name.json"
    source_after=$(project_source_snapshot) || automatic_build=0
    if [ "$automatic_build" -eq 1 ] && [ -f "$artifact" ] && \
        [ "$source_before" = "$source_after" ]; then
        manifest_tmp=$(mktemp .psy-build-manifest.XXXXXX) || die "cannot create build manifest"
        # Reuse the checked snapshot; recapturing here could certify an edit
        # made after the before/after comparison against the old artifact.
        if digest=$(build_file_digest "$artifact") && \
            printf '%s\nartifact %s  %s\n' "$source_after" "$digest" "$artifact" > "$manifest_tmp"; then
            mv -f "$manifest_tmp" .psy-build-manifest || die "cannot save build manifest"
        else
            rm -f "$manifest_tmp"
            warn "build freshness could not be recorded; automatic deploy requires another 'psyup build'"
        fi
    else
        warn "automatic deploy freshness not recorded (changed sources, custom paths/debug, or missing artifact); rebuild normally or explicitly select --contract-path"
    fi
}
