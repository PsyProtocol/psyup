#!/usr/bin/env bash
# Smoke test for psyup. Verifies dispatcher wiring against fake psyc / psy-cli
# stubs and a local boilerplate tarball — no network, no real toolchain.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export PSY_HOME="$work/.psy"
export PATH="$work/bin:$PATH"
unset DARGO_STD_PATH RPC_CONFIG
mkdir -p "$work/bin" "$PSY_HOME"

# 1. dispatcher loads
"$repo_root/psyup" version | grep -q '^psyup '

# 2. help works without ~/.psy
"$repo_root/psyup" help | grep -q 'psyup <command>'

# Runtime commands fail early with an actionable source instruction when the
# install environment exists but has not been loaded into the current shell.
: > "$PSY_HOME/env"
env_out=$(PATH="/usr/bin:/bin" PSY_HOME="$PSY_HOME" PSYUP_LIB="$repo_root/lib" \
    "$repo_root/psyup" claim 2>&1) || true
echo "$env_out" | grep -Fq ". \"$PSY_HOME/env\"" \
    || { echo "FAIL: missing actionable shell-env error"; echo "$env_out"; exit 1; }

# A trailing slash on the PATH entry is equivalent and must not trigger the
# environment-not-loaded diagnostic.
mkdir -p "$PSY_HOME/bin"
env_out=$(PATH="$PSY_HOME/bin/:/usr/bin:/bin" PSY_HOME="$PSY_HOME" PSYUP_LIB="$repo_root/lib" \
    "$repo_root/psyup" claim 2>&1) || true
echo "$env_out" | grep -q 'environment is not loaded' \
    && { echo "FAIL: trailing slash in PSY_HOME/bin caused a false env warning"; echo "$env_out"; exit 1; } || true
rm -rf "$PSY_HOME/bin"
rm -f "$PSY_HOME/env"

# Every command library loaded by the dispatcher must be fetched by install.sh.
for f in cmd_install.sh cmd_new.sh cmd_build.sh cmd_deploy.sh cmd_claim_reward.sh cmd_init.sh cmd_worker.sh; do
    grep -q "$f" "$repo_root/install.sh" \
        || { echo "FAIL: install.sh does not fetch dispatcher library $f"; exit 1; }
done

# 3. install fake toolchain that the dispatcher can find (bin/ + lib/psy-std/)
mkdir -p "$PSY_HOME/toolchains/psy-0.0.0/bin" \
         "$PSY_HOME/toolchains/psy-0.0.0/lib/psy-std"
cat > "$PSY_HOME/toolchains/psy-0.0.0/bin/dargo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "compile" ]; then
    mkdir -p build && : > build/main.psyc
    echo "dargo: built build/main.psyc DARGO_STD_PATH=${DARGO_STD_PATH:-unset} args=$*"
    exit 0
fi
if [ "$1" = "generate-abi" ]; then
    contract="" abiname=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -c|--contract-name) shift; contract=${1:-} ;;
            -c=*|--contract-name=*) contract=${1#*=} ;;
            --abi-name) shift; abiname=${1:-} ;;
            --abi-name=*) abiname=${1#*=} ;;
        esac
        shift || true
    done
    # Real dargo writes target/<abi-name>.abi.json (abi-name defaults to the
    # contract type). Mimic that so build output remains covered independently
    # from deploy; current psy_user_cli reads ABI from the compilation artifact.
    out="${abiname:-$contract}"
    mkdir -p target && : > "target/${out}.abi.json"
    echo "dargo: generated ABI target/${out}.abi.json args=generate-abi -c $contract --abi-name $out"
    exit 0
fi
echo "dargo 0.0.0"
EOF
cat > "$PSY_HOME/toolchains/psy-0.0.0/bin/psy_user_cli" <<'EOF'
#!/usr/bin/env bash

# Top-level --help advertises structured-result support.
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: psy_user_cli [OPTIONS] <COMMAND>"
    [ -z "${PSY_USER_CLI_NO_RESULT_FILE_HELP:-}" ] && echo "      --result-file <RESULT_FILE>"
    echo "Commands: deploy-contract, wallet, get-user-id, register-user, claim-rewards"
    exit 0
fi

# Pull the global --result-file <path> out of argv so it isn't echoed back.
result_file=""
new=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --result-file) shift; result_file=${1:-} ;;
        --result-file=*) result_file=${1#--result-file=} ;;
        *) new+=("$1") ;;
    esac
    shift || true
done
set -- "${new[@]}"

echo "psy_user_cli invoked: $* RPC_CONFIG=${RPC_CONFIG:-unset} PRIVATE_KEY_ENV=${PRIVATE_KEY:-unset}"

# Write the structured result (--result-file), unless the caller asked us to
# simulate a toolchain that doesn't write one (protocol-error test).
if [ -n "$result_file" ] && [ -z "${PSY_USER_CLI_NO_RESULT:-}" ]; then
    case "$1" in
        deploy-contract)
            printf '{"contract_id":null,"tx_hash":"44684652986c3dc870aa15812544b2b1701a0c16cc2b97281ae6cc9aa4b729de","network":"test","status":"submitted"}\n' > "$result_file" ;;
        wallet)
            printf '{"public_key_hash":"0d47fda4480f045506b085ba6921fc86d8cc6feb1b533292db4b1a3af8f89eab","keystore_path":null}\n' > "$result_file" ;;
        get-user-id)
            printf '{"public_key_hash":"0d47fda4480f045506b085ba6921fc86d8cc6feb1b533292db4b1a3af8f89eab","user_id":%s,"status":"%s"}\n' \
                "${PSY_USER_CLI_USER_ID:-42}" "${PSY_USER_CLI_REG_STATUS:-registered}" > "$result_file" ;;
        register-user)
            printf '{"public_key_hash":"0d47fda4480f045506b085ba6921fc86d8cc6feb1b533292db4b1a3af8f89eab","user_id":%s,"transaction_hash":"abc","status":"%s"}\n' \
                "${PSY_USER_CLI_USER_ID:-42}" "${PSY_USER_CLI_REG_STATUS:-registered}" > "$result_file" ;;
        claim-rewards)
            printf '{"status":"claimed","tx_hash":"claimtx123"}\n' > "$result_file" ;;
    esac
fi
exit 0
EOF
# The other four binaries just exist to verify install symlinks them all.
for b in psy_worker_cli psy_node_cli psy_dev_cli psy_relayer_cli; do
    printf '#!/usr/bin/env bash\necho "%s stub"\n' "$b" \
        > "$PSY_HOME/toolchains/psy-0.0.0/bin/$b"
done
echo "// fake std" > "$PSY_HOME/toolchains/psy-0.0.0/lib/psy-std/std.psy"
chmod +x "$PSY_HOME/toolchains/psy-0.0.0/bin/"*

mkdir -p "$PSY_HOME/bin"
for b in dargo psy_user_cli psy_worker_cli psy_node_cli psy_dev_cli psy_relayer_cli; do
    ln -sf "$PSY_HOME/toolchains/psy-0.0.0/bin/$b" "$PSY_HOME/bin/$b"
done
# Isolate PATH so the smoke test doesn't pick up real `dargo` from cargo bin.
export PATH="$PSY_HOME/bin:/usr/bin:/bin"

cat > "$PSY_HOME/settings.toml" <<EOF
active_node = "0.0.0"
active_compiler = "0.0.0"
default_network = "localhost"
EOF
echo '{}' > "$PSY_HOME/config.json"

# 4. build a local fake multi-template tarball (mirrors PsyProtocol/psy-template
#    layout: top-level dirs are templates), serve via file:// URL.
boiler="$work/boiler/psy-template-main"
mkdir -p "$boiler/dapp/contract/src" "$boiler/contract/src"

# dapp/ template — has both package.json and contract/Dargo.toml
cat > "$boiler/dapp/package.json" <<'EOF'
{ "name": "psy-dapp-template", "version": "0.1.0" }
EOF
cat > "$boiler/dapp/contract/Dargo.toml" <<'EOF'
[package]
name = "token"
type = "bin"
EOF
cat > "$boiler/dapp/contract/src/main.psy" <<'EOF'
use std::prelude::*;

#[contract]
#[derive(Storage)]
pub struct PsyTokenContract {
    pub balance: Felt,
}
EOF

# contract/ template — contract-only
cat > "$boiler/contract/Dargo.toml" <<'EOF'
[package]
name = "hello"
type = "bin"
EOF
echo "// hello psy" > "$boiler/contract/src/main.psy"

( cd "$work/boiler" && tar -czf "$work/boiler.tar.gz" psy-template-main )

# 5a. URL + #subdir extracts only the requested template
cd "$work"
"$repo_root/psyup" new demo --template "file://$work/boiler.tar.gz#dapp"

[ -f demo/package.json ]              || { echo "FAIL: demo/package.json missing"; exit 1; }
[ -f demo/contract/Dargo.toml ]       || { echo "FAIL: demo/contract/Dargo.toml missing"; exit 1; }
[ ! -e demo/contract/src/main.psy ]   && { echo "FAIL: contract sources missing"; exit 1; }
# The other template (contract/) should NOT have come along.
[ ! -d demo/contract/src ] && { echo "FAIL: nested contract dir missing"; exit 1; }
[ ! -f demo/Dargo.toml ]   || { echo "FAIL: extracted the wrong template (got contract/, want dapp/)"; exit 1; }

grep -q '"name": "demo"' demo/package.json \
    || { echo "FAIL: package.json name not rewritten"; cat demo/package.json; exit 1; }
grep -q 'name = "demo"' demo/contract/Dargo.toml \
    || { echo "FAIL: contract/Dargo.toml name not rewritten"; cat demo/contract/Dargo.toml; exit 1; }

# 5b. URL with no subdir → whole archive copied (legacy single-template behavior)
"$repo_root/psyup" new demo2 --template "file://$work/boiler.tar.gz"
[ -d demo2/dapp ] && [ -d demo2/contract ] \
    || { echo "FAIL: bare URL should copy the whole archive"; ls demo2; exit 1; }

# 5c. #contract picks the other subdir
"$repo_root/psyup" new demo3 --template "file://$work/boiler.tar.gz#contract"
[ -f demo3/Dargo.toml ] || { echo "FAIL: #contract should yield a flat contract project"; exit 1; }
grep -q 'name = "demo3"' demo3/Dargo.toml \
    || { echo "FAIL: top-level Dargo.toml name not rewritten"; exit 1; }

# 5d. project names with `-` are sanitized to `_` for Dargo.toml (dargo
#     rejects '-' in CrateName), but kept as-is in package.json (npm allows it).
"$repo_root/psyup" new my-app --template "file://$work/boiler.tar.gz#dapp"
grep -q 'name = "my_app"' my-app/contract/Dargo.toml \
    || { echo "FAIL: hyphen not sanitized in Dargo.toml"; cat my-app/contract/Dargo.toml; exit 1; }
grep -q '"name": "my-app"' my-app/package.json \
    || { echo "FAIL: hyphen should be preserved in package.json"; cat my-app/package.json; exit 1; }

# 6. build — also asserts DARGO_STD_PATH gets auto-exported and
#    --contract-name is auto-detected from #[contract] in main.psy.
cd "$work/demo/contract"
build_out=$("$repo_root/psyup" build)
echo "$build_out" | grep -q 'dargo: built'
echo "$build_out" | grep -q "DARGO_STD_PATH=$PSY_HOME/toolchains/psy-0.0.0/lib/psy-std/std.psy" \
    || { echo "FAIL: DARGO_STD_PATH not exported by cmd_build"; echo "$build_out"; exit 1; }
echo "$build_out" | grep -q 'detected contract: PsyTokenContractRef' \
    || { echo "FAIL: auto-detect of --contract-name"; echo "$build_out"; exit 1; }
echo "$build_out" | grep -q -- '--contract-name=PsyTokenContractRef' \
    || { echo "FAIL: --contract-name not passed to dargo"; echo "$build_out"; exit 1; }
echo "$build_out" | grep -q 'dargo: generated ABI target/demo.abi.json' \
    || { echo "FAIL: ABI generation did not run"; echo "$build_out"; exit 1; }
[ -f build/main.psyc ] || { echo "FAIL: build artifact missing"; exit 1; }
[ -f target/demo.abi.json ] || { echo "FAIL: ABI artifact missing"; exit 1; }

# 6b. user-supplied --contract-name overrides auto-detection
override_out=$("$repo_root/psyup" build --contract-name=CustomRef)
echo "$override_out" | grep -q -- '--contract-name=CustomRef' \
    || { echo "FAIL: user override of --contract-name"; echo "$override_out"; exit 1; }
echo "$override_out" | grep -q 'dargo: generated ABI target/demo.abi.json' \
    || { echo "FAIL: ABI generation did not use package ABI name"; echo "$override_out"; exit 1; }
echo "$override_out" | grep -q 'detected contract:' \
    && { echo "FAIL: should not auto-detect when user passed --contract-name"; exit 1; } || true

# 7a. deploy passes through to psy_user_cli with user-supplied args.
# No keystore present here, so identity comes from PRIVATE_KEY env (see 7h for
# the keystore path); the forwarded artifact contains both circuits and ABI.
out=$(PRIVATE_KEY=0xdead "$repo_root/psyup" deploy --contract-path build/main.psyc 2>&1)
echo "$out" | grep -q 'psy_user_cli invoked: deploy-contract --is-deploy' \
    || { echo "FAIL: deploy didn't invoke psy_user_cli correctly"; echo "$out"; exit 1; }
echo "$out" | grep -q "RPC_CONFIG=$PSY_HOME/config.json" \
    || { echo "FAIL: deploy didn't export RPC_CONFIG"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--contract-path build/main.psyc" \
    || { echo "FAIL: --contract-path passthrough lost"; exit 1; }
echo "$out" | grep -q -- "--abi-path" \
    && { echo "FAIL: deploy must not pass removed --abi-path option"; echo "$out"; exit 1; } || true

# 7b. auto-fill --contract-path from target/<pkg>.json; PRIVATE_KEY just env-forwarded
mkdir -p target
echo '{}' > target/token.json
echo '{}' > target/token.abi.json
cat > Dargo.toml <<'EOF'
[package]
name = "token"
type = "bin"
EOF
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy 2>&1)
echo "$out" | grep -q -- "--contract-path target/token.json" \
    || { echo "FAIL: --contract-path not auto-filled from target/"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--abi-path" \
    && { echo "FAIL: deploy must use ABI embedded in target/token.json"; echo "$out"; exit 1; } || true
# PRIVATE_KEY is read natively by psy_user_cli via clap env — psyup should NOT
# rewrite it into a --private-key flag.
echo "$out" | grep -q -- "--private-key" \
    && { echo "FAIL: psyup should leave PRIVATE_KEY env alone, not synthesize --private-key"; exit 1; } || true

# 7c. user-supplied --contract-path overrides auto-fill
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy --contract-path other.json 2>&1)
echo "$out" | grep -q -- "--contract-path other.json" \
    || { echo "FAIL: user-supplied --contract-path lost"; exit 1; }
echo "$out" | grep -q "using --contract-path=target/token.json" \
    && { echo "FAIL: should not auto-fill --contract-path when user passes it"; exit 1; } || true

# 7d. successful deploy reads tx_hash from the result file and writes .psy-deploy
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy 2>&1)
echo "$out" | grep -q '✓ contract_uuid: 44684652986c3dc870aa15812544b2b1701a0c16cc2b97281ae6cc9aa4b729de' \
    || { echo "FAIL: contract_uuid not extracted"; echo "$out"; exit 1; }
[ -f .psy-deploy ] || { echo "FAIL: .psy-deploy not written"; exit 1; }
grep -q '"contract_uuid":"44684652986c3dc870aa15812544b2b1701a0c16cc2b97281ae6cc9aa4b729de"' .psy-deploy \
    || { echo "FAIL: .psy-deploy content wrong"; cat .psy-deploy; exit 1; }
rm -f .psy-deploy

# 7e. missing artifact errors out (no target/, no <pkg>.json, no build/<pkg>.json)
rm -rf target build
rm -f token.json
if "$repo_root/psyup" deploy 2>/dev/null; then
    echo "FAIL: deploy should error when no compiled artifact exists"
    exit 1
fi

# 7f. old psy_user_cli without --result-file support → explicit upgrade error,
#     not a silent fallback to log scraping. (deploy is expected to fail here,
#     so neutralize set -e around the capture.)
out=$(PSY_USER_CLI_NO_RESULT_FILE_HELP=1 PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy --contract-path other.json 2>&1) || true
echo "$out" | grep -q "too old (no --result-file support)" \
    || { echo "FAIL: missing upgrade error for old psy_user_cli"; echo "$out"; exit 1; }

# 7g. psy_user_cli exits 0 but writes no result file → protocol-incompatible error.
out=$(PSY_USER_CLI_NO_RESULT=1 PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy --contract-path other.json 2>&1) || true
echo "$out" | grep -q "protocol incompatible" \
    || { echo "FAIL: missing protocol-incompatible error"; echo "$out"; exit 1; }

# 7h. KEYSTORE_PATH takes priority over PRIVATE_KEY: deploy forwards
#     --keystore-path (password via WALLET_PASSWORD env) and hides PRIVATE_KEY.
mkdir -p "$PSY_HOME/keystore"
: > "$PSY_HOME/keystore/default"
out=$(KEYSTORE_PATH="$PSY_HOME/keystore/default" PRIVATE_KEY=0xbeef WALLET_PASSWORD=pass \
    "$repo_root/psyup" deploy --contract-path other.json 2>&1)
echo "$out" | grep -q 'using keystore:' \
    || { echo "FAIL: deploy should report keystore use"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--keystore-path" \
    || { echo "FAIL: deploy should forward --keystore-path when keystore present"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--private-key" \
    && { echo "FAIL: deploy must not forward --private-key in keystore mode"; echo "$out"; exit 1; } || true
echo "$out" | grep -q -- "PRIVATE_KEY_ENV=unset" \
    || { echo "FAIL: deploy must hide PRIVATE_KEY env in keystore mode"; echo "$out"; exit 1; }

# A file at the conventional path alone must not select keystore mode.
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" deploy --contract-path other.json 2>&1)
echo "$out" | grep -q 'using PRIVATE_KEY for identity' \
    || { echo "FAIL: deploy should use PRIVATE_KEY when KEYSTORE_PATH is unset"; echo "$out"; exit 1; }
rm -rf "$PSY_HOME/keystore"

# 7i. claim auto-fills --jobs-file from ./worker.backup and reads
#     status/tx_hash from the result file.
: > worker.backup
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" claim 2>&1)
echo "$out" | grep -q 'psy_user_cli invoked: claim-rewards' \
    || { echo "FAIL: claim didn't invoke psy_user_cli correctly"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--jobs-file ./worker.backup" \
    || { echo "FAIL: claim didn't auto-fill --jobs-file"; echo "$out"; exit 1; }
echo "$out" | grep -q '✓ status: claimed' \
    || { echo "FAIL: claim status not extracted"; echo "$out"; exit 1; }
echo "$out" | grep -q '✓ tx_hash: claimtx123' \
    || { echo "FAIL: claim tx_hash not extracted"; echo "$out"; exit 1; }
rm -f worker.backup

# 7j. A missing default backup is not passed to claim-rewards.
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" claim 2>&1)
echo "$out" | grep -q -- "--jobs-file" \
    && { echo "FAIL: claim should not auto-fill a missing jobs file"; echo "$out"; exit 1; } || true

# 7j2. user-supplied --jobs-file overrides auto-fill.
: > worker.backup
out=$(PRIVATE_KEY=0xbeef "$repo_root/psyup" claim --jobs-file custom.json 2>&1)
echo "$out" | grep -q -- "--jobs-file custom.json" \
    || { echo "FAIL: user-supplied --jobs-file lost"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--jobs-file ./worker.backup" \
    && { echo "FAIL: claim should not auto-fill --jobs-file when user passes it"; echo "$out"; exit 1; } || true
rm -f worker.backup

# 7k. KEYSTORE_PATH takes priority over PRIVATE_KEY for claim: forwards
#     --keystore-path and hides the PRIVATE_KEY environment variable.
mkdir -p "$PSY_HOME/keystore"
: > "$PSY_HOME/keystore/default"
out=$(KEYSTORE_PATH="$PSY_HOME/keystore/default" PRIVATE_KEY=0xbeef WALLET_PASSWORD=pass \
    "$repo_root/psyup" claim --jobs-file other.json 2>&1)
echo "$out" | grep -q 'using keystore:' \
    || { echo "FAIL: claim should report keystore use"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--keystore-path" \
    || { echo "FAIL: claim should forward --keystore-path when keystore present"; echo "$out"; exit 1; }
echo "$out" | grep -q -- "--private-key" \
    && { echo "FAIL: claim must not forward --private-key in keystore mode"; echo "$out"; exit 1; } || true
echo "$out" | grep -q -- "PRIVATE_KEY_ENV=unset" \
    || { echo "FAIL: claim must hide PRIVATE_KEY env in keystore mode"; echo "$out"; exit 1; }
rm -rf "$PSY_HOME/keystore"

# 8. build error when no manifest
cd "$work"
if "$repo_root/psyup" build 2>/dev/null; then
    echo "FAIL: build should error without Dargo.toml"
    exit 1
fi

# 9. Full `psyup install` flow against fake release tarballs in tmp.
echo "--- section 9: install via dist/ tarballs ---"
fake_release="$work/fake-release"
PSYUP_FAKE_TOOLCHAIN_DIR="$fake_release" bash "$repo_root/packaging/make-fake-toolchain.sh" 0.9.9 >/dev/null
[ -f "$fake_release/SHA256SUMS" ] || { echo "FAIL: make-fake-toolchain.sh did not produce SHA256SUMS"; exit 1; }

# Use a fresh PSY_HOME so we exercise install from a clean slate.
install_home="$work/.psy-install"
rm -rf "$install_home"
# Note: deliberately no $install_home/lib — the dispatcher falls back to
# repo lib/ when PSY_HOME/lib doesn't exist, which is what we want here.
mkdir -p "$install_home/bin" "$install_home/toolchains"

# Seed env + settings.toml as install.sh would have done.
cat > "$install_home/env" <<'EOF'
export PATH="$HOME/.psy/bin:$PATH"
# DARGO_STD_PATH=__PSYUP_MANAGED__
EOF
cat > "$install_home/settings.toml" <<EOF
active = ""
default_network = "localhost"
EOF
# legacy single-`active` setting: install must migrate it to active_node/compiler

PSY_HOME="$install_home" \
PSYUP_DEFAULT_NETWORK="sepolia" \
PSYUP_RELEASE_URL_NODE="file://$fake_release" \
PSYUP_RELEASE_URL_COMPILER="file://$fake_release" \
PSYUP_RELEASE_URL_CONFIG="file://$fake_release/config.json" \
    "$repo_root/psyup" install 0.9.9

# Verify the install landed:
[ -d "$install_home/toolchains/psy-0.9.9/bin" ] \
    || { echo "FAIL: toolchain bin/ not extracted"; ls -R "$install_home" 2>&1 | head; exit 1; }
[ -x "$install_home/toolchains/psy-0.9.9/bin/dargo" ] \
    || { echo "FAIL: dargo stub not present / not executable"; exit 1; }
[ -f "$install_home/toolchains/psy-0.9.9/lib/psy-std/std.psy" ] \
    || { echo "FAIL: psy-std not bundled"; exit 1; }
[ -f "$install_home/config.json" ] \
    || { echo "FAIL: config.json not installed into PSY_HOME"; exit 1; }
for b in dargo psy_user_cli psy_worker_cli psy_node_cli psy_dev_cli psy_relayer_cli; do
    [ -L "$install_home/bin/$b" ] || { echo "FAIL: $b not symlinked into ~/.psy/bin"; exit 1; }
done

# Sanity: an installed stub responds.
"$install_home/bin/dargo" --version | grep -q '0.9.9' \
    || { echo "FAIL: installed dargo stub didn't report 0.9.9"; exit 1; }

# settings.toml should now have active_node = active_compiler = "0.9.9"
grep -q 'active_node = "0.9.9"' "$install_home/settings.toml" \
    || { echo "FAIL: settings.toml active_node not updated"; cat "$install_home/settings.toml"; exit 1; }
grep -q 'active_compiler = "0.9.9"' "$install_home/settings.toml" \
    || { echo "FAIL: settings.toml active_compiler not updated"; cat "$install_home/settings.toml"; exit 1; }
grep -q 'default_network = "sepolia"' "$install_home/settings.toml" \
    || { echo "FAIL: settings.toml default_network not updated"; cat "$install_home/settings.toml"; exit 1; }
grep -q 'rpc_config' "$install_home/settings.toml" \
    && { echo "FAIL: settings.toml should not contain rpc_config"; cat "$install_home/settings.toml"; exit 1; } || true
grep -q '"defaultNetwork": "sepolia"' "$install_home/config.json" \
    || { echo "FAIL: config.json defaultNetwork not updated"; cat "$install_home/config.json"; exit 1; }

# env file should have DARGO_STD_PATH pointing at the installed std
grep -q "DARGO_STD_PATH=.*psy-0.9.9/lib/psy-std/std.psy" "$install_home/env" \
    || { echo "FAIL: ~/.psy/env DARGO_STD_PATH not rewritten"; cat "$install_home/env"; exit 1; }
grep -q "RPC_CONFIG=\"$install_home/config.json\"" "$install_home/env" \
    || { echo "FAIL: ~/.psy/env RPC_CONFIG not rewritten"; cat "$install_home/env"; exit 1; }
grep -q "DARGO_STD_PATH \"$install_home/toolchains/psy-0.9.9/lib/psy-std/std.psy\"" "$install_home/env.fish" \
    || { echo "FAIL: ~/.psy/env.fish DARGO_STD_PATH not rewritten"; cat "$install_home/env.fish"; exit 1; }
grep -q "RPC_CONFIG \"$install_home/config.json\"" "$install_home/env.fish" \
    || { echo "FAIL: ~/.psy/env.fish RPC_CONFIG not rewritten"; cat "$install_home/env.fish"; exit 1; }

# 9b. Latest resolution follows the public GitHub redirect and does not touch the rate-limited API.
PSYUP_FAKE_TOOLCHAIN_DIR="$fake_release" bash "$repo_root/packaging/make-fake-toolchain.sh" 0.1.0 >/dev/null
fallback_home="$work/.psy-fallback"
fake_path="$work/fake-path"
mkdir -p "$fallback_home/bin" "$fallback_home/toolchains" "$fake_path"
cat > "$fallback_home/env" <<'EOF'
export PATH="$HOME/.psy/bin:$PATH"
# DARGO_STD_PATH=__PSYUP_MANAGED__
EOF
cat > "$fallback_home/settings.toml" <<EOF
active = ""
default_network = "localhost"
EOF
cat > "$fake_path/curl" <<'EOF'
#!/usr/bin/env bash
format=
output=
follow=0
previous=
for arg in "$@"; do
    if [ "$previous" = -w ]; then format=$arg; fi
    if [ "$previous" = -o ]; then output=$arg; fi
    case "$arg" in
        -*L*) follow=1 ;;
        https://api.github.com/*)
        echo 'FAIL: GitHub API must not be used to resolve latest' >&2
        exit 99
        ;;
        https://github.com/*/releases/latest)
        [ "$format" = '%{redirect_url}' ] && [ "$output" = /dev/null ] && [ "$follow" = 0 ] || {
            echo 'FAIL: latest resolver must read redirect_url without following it' >&2
            exit 98
        }
        repo=${arg#https://github.com/}
        repo=${repo%/releases/latest}
        printf 'https://github.com/%s/releases/tag/v0.1.0' "$repo"
        exit 0
        ;;
    esac
    previous=$arg
done
exec /usr/bin/curl "$@"
EOF
chmod +x "$fake_path/curl"
fallback_out=$(
    PATH="$fake_path:/usr/bin:/bin" \
    PSY_HOME="$fallback_home" \
    PSYUP_RELEASE_URL_NODE="file://$fake_release" \
    PSYUP_RELEASE_URL_COMPILER="file://$fake_release" \
    PSYUP_RELEASE_URL_CONFIG="file://$fake_release/config.json" \
        "$repo_root/psyup" install latest 2>&1
)
echo "$fallback_out" | grep -q 'falling back' \
    && { echo "FAIL: latest resolution hit fallback instead of redirect"; echo "$fallback_out"; exit 1; }
grep -q 'active_node = "0.1.0"' "$fallback_home/settings.toml" \
    || { echo "FAIL: redirect-based latest resolution did not install 0.1.0"; cat "$fallback_home/settings.toml"; exit 1; }

# 9c. A failed public redirect still falls back to PSYUP_DEFAULT_VERSION.
PSYUP_FAKE_TOOLCHAIN_DIR="$fake_release" bash "$repo_root/packaging/make-fake-toolchain.sh" 0.1.0 >/dev/null
fallback_failed_home="$work/.psy-fallback-failed"
fake_failed_path="$work/fake-failed-path"
mkdir -p "$fallback_failed_home/bin" "$fallback_failed_home/toolchains" "$fake_failed_path"
cat > "$fallback_failed_home/env" <<'EOF'
export PATH="$HOME/.psy/bin:$PATH"
# DARGO_STD_PATH=__PSYUP_MANAGED__
EOF
cat > "$fallback_failed_home/settings.toml" <<EOF
active = ""
default_network = "localhost"
EOF
cat > "$fake_failed_path/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        https://api.github.com/*) exit 22 ;;
        https://github.com/*/releases/latest) exit 22 ;;
    esac
done
exec /usr/bin/curl "$@"
EOF
chmod +x "$fake_failed_path/curl"
fallback_failed_out=$(
    PATH="$fake_failed_path:/usr/bin:/bin" \
    PSY_HOME="$fallback_failed_home" \
    PSYUP_DEFAULT_VERSION=0.1.0 \
    PSYUP_RELEASE_URL_NODE="file://$fake_release" \
    PSYUP_RELEASE_URL_COMPILER="file://$fake_release" \
    PSYUP_RELEASE_URL_CONFIG="file://$fake_release/config.json" \
        "$repo_root/psyup" install latest 2>&1
)
echo "$fallback_failed_out" | grep -q 'falling back to 0.1.0' \
    || { echo "FAIL: latest resolution failure did not report fallback"; echo "$fallback_failed_out"; exit 1; }
grep -q 'active_node = "0.1.0"' "$fallback_failed_home/settings.toml" \
    || { echo "FAIL: latest resolution failure did not install fallback"; cat "$fallback_failed_home/settings.toml"; exit 1; }

# 10. init (offline, stubbed): create wallet → already-registered fast path,
#     reading wallet / get-user-id results via --result-file (no log scraping).
init_home="$work/.psy-init"
mkdir -p "$init_home/bin" "$init_home/toolchains/psy-0.0.0/bin"
cp "$PSY_HOME/toolchains/psy-0.0.0/bin/psy_user_cli" "$init_home/toolchains/psy-0.0.0/bin/psy_user_cli"
chmod +x "$init_home/toolchains/psy-0.0.0/bin/psy_user_cli"
ln -sf "$init_home/toolchains/psy-0.0.0/bin/psy_user_cli" "$init_home/bin/psy_user_cli"
printf '{"defaultNetwork":"test","networks":{"test":{}}}\n' > "$init_home/config.json"
# No keystore present → Case 2 (create). Feed the new-wallet password on stdin;
# get-user-id stub defaults to registered + user_id 42.
init_out=$(printf 'pass\n' | PSY_HOME="$init_home" PATH="$init_home/bin:/usr/bin:/bin" \
    "$repo_root/psyup" init 2>&1) || true
echo "$init_out" | grep -q 'user already registered (user_id: 42)' \
    || { echo "FAIL: init did not reach already-registered path"; echo "$init_out"; exit 1; }
echo "$init_out" | grep -q "export KEYSTORE_PATH=\"$init_home/keystore/default\"" \
    || { echo "FAIL: init did not print KEYSTORE_PATH setup hint"; echo "$init_out"; exit 1; }

# 11. worker (offline, stubbed): keystore path forwards --keystore-path and the
#     password via env to psy_worker_cli; no --private-key is exported by psyup.
worker_home="$work/.psy-worker"
mkdir -p "$worker_home/bin" "$worker_home/keystore" "$worker_home/toolchains/psy-0.0.0/bin"
cp "$PSY_HOME/toolchains/psy-0.0.0/bin/psy_user_cli" "$worker_home/toolchains/psy-0.0.0/bin/psy_user_cli"
cat > "$worker_home/toolchains/psy-0.0.0/bin/psy_worker_cli" <<'EOF'
#!/usr/bin/env bash
echo "psy_worker_cli invoked: $* PRIVATE_KEY_ENV=${PRIVATE_KEY:-unset}"
EOF
chmod +x "$worker_home/toolchains/psy-0.0.0/bin/"*
ln -sf "$worker_home/toolchains/psy-0.0.0/bin/psy_user_cli"   "$worker_home/bin/psy_user_cli"
ln -sf "$worker_home/toolchains/psy-0.0.0/bin/psy_worker_cli" "$worker_home/bin/psy_worker_cli"
: > "$worker_home/keystore/default"
printf '{"defaultNetwork":"test","networks":{"test":{}}}\n' > "$worker_home/config.json"
worker_out=$(KEYSTORE_PATH="$worker_home/keystore/default" PRIVATE_KEY=0xbeef WALLET_PASSWORD=pass \
    PSY_HOME="$worker_home" PATH="$worker_home/bin:/usr/bin:/bin" \
    "$repo_root/psyup" worker 2>&1) || true
echo "$worker_out" | grep -q -- "--keystore-path" \
    || { echo "FAIL: worker should forward --keystore-path"; echo "$worker_out"; exit 1; }
echo "$worker_out" | grep -q -- "--user 42" \
    || { echo "FAIL: worker should pass --user 42"; echo "$worker_out"; exit 1; }
echo "$worker_out" | grep -q -- "--completed-jobs-log-file ./worker.backup" \
    || { echo "FAIL: worker should default completed jobs log to ./worker.backup"; echo "$worker_out"; exit 1; }
echo "$worker_out" | grep -q -- "--private-key" \
    && { echo "FAIL: worker must not forward --private-key in keystore mode"; echo "$worker_out"; exit 1; } || true
echo "$worker_out" | grep -q -- "PRIVATE_KEY_ENV=unset" \
    || { echo "FAIL: worker must hide PRIVATE_KEY env in keystore mode"; echo "$worker_out"; exit 1; }

# An explicit completed-jobs log path overrides the default.
worker_out=$(KEYSTORE_PATH="$worker_home/keystore/default" PRIVATE_KEY= WALLET_PASSWORD=pass \
    PSY_HOME="$worker_home" PATH="$worker_home/bin:/usr/bin:/bin" \
    "$repo_root/psyup" worker --completed-jobs-log-file custom.backup 2>&1) || true
echo "$worker_out" | grep -q -- "--completed-jobs-log-file custom.backup" \
    || { echo "FAIL: worker should preserve explicit completed jobs log path"; echo "$worker_out"; exit 1; }
echo "$worker_out" | grep -q -- "--completed-jobs-log-file ./worker.backup" \
    && { echo "FAIL: worker should not add default completed jobs log when explicitly set"; echo "$worker_out"; exit 1; } || true

echo "OK: all smoke checks passed"
