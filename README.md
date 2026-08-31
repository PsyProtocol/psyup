# psyup

One-shot installer + project scaffolder for the PSY smart-contract toolchain.
Inspired by `rustup` / `foundryup`.

## End-to-end quickstart

```sh
# 1. Install psyup itself (pins the network to sepolia).
curl -fsSL https://raw.githubusercontent.com/PsyProtocol/psyup/mainnet-beta/install.sh \
  | PSYUP_DEFAULT_NETWORK=sepolia sh
# (no need to source — install.sh auto-writes your shell rc)

# 2. Pull the PSY toolchain (dargo + psy_user_cli + ...) for your platform.
psyup install

# 3. Scaffold a new project from the dapp template.
psyup new token-app

# 4. Compile the contract.
cd token-app/contract && psyup build

# 5. Deploy.
export PRIVATE_KEY=<your-hex-key>
psyup deploy
# → ✓ contract_uuid: …  ✓ contract_id: 7
# (written to ./.psy-deploy)

# 6. Launch the dApp frontend.
cd ../                                  # back to token-app/
pnpm install                            # or npm install
echo "VITE_PSY_CONTRACT_ID=$(jq -r .contract_id contract/.psy-deploy)" > .env.local
pnpm dev                                # http://localhost:5173
```

Open the page, [psy-wallet](https://app-stg.psy-protocol.xyz/wallet) (browser extension),
connect, then mint / transfer / claim. No manual cloning, no source builds,
no chasing dependencies.

## Commands

| Command | What it does |
|---|---|
| `psyup install [version]` | Download the PSY toolchain release for your platform, verify SHA256, symlink into `~/.psy/bin`. Defaults to `latest`. |
| `psyup update` | Re-resolve `latest` and reinstall if newer. |
| `psyup uninstall` | Remove `~/.psy` (asks first). |
| `psyup new <name> [--template <key\|owner/repo\|url>[#subdir]]` | Download a template tarball, rewrite project name in `Dargo.toml` / `package.json`, `git init`. Default template = `dapp`. |
| `psyup build [args...]` | `dargo compile` plus `dargo generate-abi -c <package>.abi`; auto-detects `--contract-name` from `#[contract]` struct for compilation. |
| `psyup deploy [args...]` | `psy_user_cli deploy-contract --is-deploy`. Auto-fills `--rpc-config` and `--contract-path`; the compilation artifact contains the ABI used by `psy_user_cli`. Polls service for numeric `contract_id` and saves to `.psy-deploy`. |
| `psyup init` | Create the default wallet at `~/.psy/keystore/default`, register it, and print the `KEYSTORE_PATH` export needed by wallet commands. |
| `psyup worker [args...]` | Run the proof miner. Uses `KEYSTORE_PATH` when set, otherwise `PRIVATE_KEY`; writes completed jobs to `./worker.backup` by default. |
| `psyup claim [args...]` | Claim miner rewards. Defaults `--jobs-file` to `./worker.backup` (the worker's default output). |

Wallet commands select credentials from the environment. `KEYSTORE_PATH` takes
priority over `PRIVATE_KEY`; if it is set, it must point to an existing file.
After creating the default wallet, configure the current shell with:

```sh
psyup init
export KEYSTORE_PATH="$HOME/.psy/keystore/default"
```

To use a raw private key instead, leave `KEYSTORE_PATH` unset:

```sh
unset KEYSTORE_PATH
export PRIVATE_KEY=<your-hex-key>
```

## Layout

```
~/.psy/
├── bin/            # psyup + symlinks to active toolchain
├── toolchains/     # versioned by node release: psy-<node-ver>/{bin/, lib/psy-std/}
├── lib/            # psyup's own bash modules (installed by install.sh)
├── templates/      # cache (reserved, not used yet)
├── env             # POSIX shell env: PATH + DARGO_STD_PATH + RPC_CONFIG
├── env.fish        # fish shell env: PATH + DARGO_STD_PATH + RPC_CONFIG
├── config.json     # RPC network config consumed by psy_user_cli (--rpc-config)
└── settings.toml   # active node/compiler versions, default network
```

## Repository contract

### Toolchain releases

The toolchain is assembled from two GitHub release sources, downloaded and
checksum-verified by `psyup install`:

| component | repo | contents |
|---|---|---|
| node binaries | `PsyProtocol/psy-node` | `psy_user_cli`, `psy_worker_cli`, `psy_node_cli`, `psy_dev_cli`, `psy_relayer_cli`, `psy-mcp-server` |
| compiler | `PsyProtocol/psy-compiler` | `bin/dargo`, `lib/psy-std/` stdlib |

Each repo tags `vX.Y.Z` and ships four per-platform tarballs plus a checksum
file:

```
psy-node-vX.Y.Z-<triple>.tar.gz      # binaries flat at the archive root
psy-compiler-vX.Y.Z-<triple>.tar.gz  # bin/dargo + lib/psy-std/
SHA256SUMS                           # one line per tarball
```

where `<triple>` is one of `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`.

Override the source repos with `PSY_NODE_REPO` / `PSY_COMPILER_REPO` if you
need to point at forks.

The two tarballs are merged into one toolchain dir:

```
~/.psy/toolchains/psy-<node-ver>/
├── bin/                  # all node binaries + dargo, symlinked into ~/.psy/bin
└── lib/
    └── psy-std/          # bundled stdlib (std.psy, prelude.psy, ...)
```

`psyup install` symlinks every file in `bin/` into `~/.psy/bin/`, so all
binaries are on PATH after install. A single version argument
(`psyup install 0.1.1`) pins both components to that version; `latest`
resolves each repo's latest release independently.

After `psyup install`, `~/.psy/env` is rewritten to export
`DARGO_STD_PATH=<toolchain-root>/lib/psy-std/std.psy` so the compiler can find
the stdlib without falling back to a git clone. `~/.psy/env.fish` is rewritten
with the equivalent fish shell exports. The shell installer sources the matching
env file from your shell rc. It also exports
`RPC_CONFIG=~/.psy/config.json` for `psy_user_cli`. Runtime config at
`~/.psy/config.json` is authoritative once present: `install.sh` installs it
and `psyup install/update` never overwrites it. `psyup build` also sets
`DARGO_STD_PATH` defensively in case the shell didn't source `~/.psy/env`.
Set `PSYUP_DEFAULT_NETWORK=<name>` before running `install.sh` or
`psyup install` to choose the default network; otherwise it defaults to
`localhost`.

### `PsyProtocol/psy-genesis`

`config.json` (the RPC network config consumed by `psy_user_cli`) is fetched
raw from the `mainnet-beta` branch of `PsyProtocol/psy-genesis`:

```
https://raw.githubusercontent.com/PsyProtocol/psy-genesis/mainnet-beta/config.json
```

Override with `PSY_GENESIS_REPO` / `PSY_GENESIS_BRANCH` (install.sh and
`psyup install` both honor them). If the fetch fails and no local copy exists,
`psyup install` continues without it; deploy then requires `--rpc-config` or
`RPC_CONFIG`.

### `PsyProtocol/psy-template`

Multi-template repo — each top-level directory is one named template.
`psyup new` downloads the repo's `main` tarball and extracts the requested
subdir. Currently only `dapp/` exists; new templates are added by dropping a
new directory at the repo root.

```
psy-template/
└── dapp/                           # default — React + contract starter
    ├── package.json                # top-level frontend manifest
    ├── index.html
    ├── tsconfig.json
    ├── vite.config.ts
    ├── src/                        # React app
    │   ├── App.tsx
    │   ├── main.tsx
    │   ├── components/{ConnectBar,TokenPanel,TxLog}.tsx
    │   ├── hooks/usePsy.ts
    │   ├── lib/{psy,token}.ts
    │   └── config.ts
    └── contract/                   # PSY contract sub-package
        ├── Dargo.toml
        └── src/main.psy
```

Selection:

| invocation | result |
|---|---|
| `psyup new my-app` | default subdir = `$PSYUP_DEFAULT_TEMPLATE` (currently `dapp`) |
| `psyup new my-app --template <key>` | `<key>/` subdir of `PsyProtocol/psy-template` |
| `psyup new my-app --template owner/repo` | that repo's whole `main` archive |
| `psyup new my-app --template owner/repo#sub` | `sub/` subdir of that repo |
| `psyup new my-app --template https://...tar.gz[#sub]` | direct tarball URL (with optional subdir) |

After extraction, `psyup new` rewrites the project name in (where present):
`Dargo.toml`, `contract/Dargo.toml`, and the top-level `package.json`.

## Development

```sh
# run dispatcher from a checkout (no need to install globally)
./psyup help

# end-to-end smoke test — uses fake psyc/psy-cli stubs and a local tarball,
# no network, no real toolchain required
bash test/smoke.sh
```

## Out of scope (v0.1)

- Windows (only macOS + Linux for now)
- Local test chain / anvil-equivalent
- Wallet & key management (bring your own keyfile)
- `psyup self update` (just re-run `install.sh`)
