#!/usr/bin/env bash
# Build a fake two-repo PSY toolchain release for smoke tests.
#
# Mirrors the release layout psyup install consumes:
#   psy-node-v<version>-<triple>.tar.gz      binaries flat at archive root
#   psy-compiler-v<version>-<triple>.tar.gz  bin/dargo + lib/psy-std/
#   SHA256SUMS                               both tarballs
#
# Usage:
#     packaging/make-fake-toolchain.sh <version>
#
# Environment:
#     PSYUP_FAKE_TOOLCHAIN_DIR   Output directory. Defaults to a new tmp dir.
#     PSY_TOOLCHAIN_TRIPLE       Override inferred platform triple.
#
# The script prints the release directory path on stdout. It intentionally does
# not write to repo-root dist/.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version_input=${1:-0.1.0}
version_no_v=${version_input#v}
version="v${version_no_v}"

infer_triple() {
    local arch os
    arch=$(uname -m)
    os=$(uname -s)

    case "$arch" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64) arch=x86_64 ;;
        *) echo "unsupported architecture: $arch" >&2; return 1 ;;
    esac

    case "$os" in
        Darwin) echo "${arch}-apple-darwin" ;;
        Linux) echo "${arch}-unknown-linux-gnu" ;;
        *) echo "unsupported OS: $os" >&2; return 1 ;;
    esac
}

write_checksum() {
    local dir=$1 name=$2

    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$dir" && sha256sum "$name" ) >> "$dir/SHA256SUMS"
    else
        ( cd "$dir" && shasum -a 256 "$name" ) >> "$dir/SHA256SUMS"
    fi
}

triple=${PSY_TOOLCHAIN_TRIPLE:-$(infer_triple)}
release_dir=${PSYUP_FAKE_TOOLCHAIN_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/psyup-fake-release.XXXXXX")}

# --- psy-node: binaries flat at the archive root ---
node_stage="$release_dir/psy-node-${version}-${triple}"
rm -rf "$node_stage"
mkdir -p "$node_stage"

for bin in psy_user_cli psy_worker_cli psy_node_cli psy_dev_cli psy_relayer_cli psy-mcp-server; do
    cat > "$node_stage/$bin" <<EOF
#!/usr/bin/env bash
echo "$bin ${version_no_v}"
EOF
    chmod +x "$node_stage/$bin"
done

node_tarball="psy-node-${version}-${triple}.tar.gz"
rm -f "$release_dir/$node_tarball"
# Real psy-node tarballs ship binaries flat at the archive root.
( cd "$node_stage" && COPYFILE_DISABLE=1 tar -czf "$release_dir/$node_tarball" . )

# --- psy-compiler: bin/dargo + lib/psy-std/ ---
compiler_stage="$release_dir/psy-compiler-${version}-${triple}"
rm -rf "$compiler_stage"
mkdir -p "$compiler_stage/bin" "$compiler_stage/lib/psy-std"

cat > "$compiler_stage/bin/dargo" <<EOF
#!/usr/bin/env bash
echo "dargo ${version_no_v}"
EOF
chmod +x "$compiler_stage/bin/dargo"

cat > "$compiler_stage/lib/psy-std/std.psy" <<'EOF'
// fake psy std
EOF
cat > "$compiler_stage/lib/psy-std/prelude.psy" <<'EOF'
// fake psy prelude
EOF

compiler_tarball="psy-compiler-${version}-${triple}.tar.gz"
rm -f "$release_dir/$compiler_tarball"
# Real psy-compiler tarballs ship bin/ and lib/ at the archive root.
( cd "$compiler_stage" && COPYFILE_DISABLE=1 tar -czf "$release_dir/$compiler_tarball" bin lib )

# --- checksums for both ---
: > "$release_dir/SHA256SUMS"
write_checksum "$release_dir" "$node_tarball"
write_checksum "$release_dir" "$compiler_tarball"

# --- config.json stand-in for the psy-genesis raw file ---
if [ -f "$repo_root/config.json" ]; then
    cp "$repo_root/config.json" "$release_dir/config.json"
else
    cat > "$release_dir/config.json" <<'EOF'
{
  "defaultNetwork": "localhost"
}
EOF
fi

printf '%s\n' "$release_dir"
