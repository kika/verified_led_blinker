# Tool versions

Nothing else pins these. Installed 2026-11-10 under `~/opt/veryfpga/` (and
`~/.elan/`). Put on `PATH` by `env.sh`.

## openXC7 toolchain

- Package: `openxc7-toolchain-linux-x86-64-20261109.tgz`, release `2026-11-09`
  (dated, not prerelease) of `github.com/cavearr/toolchain-openxc7-releases`.
- SHA-256 `a44631408ec4972186ddd47810c16b54cb81ebc0b08d0f7f71c1525da83f84e5`,
  verified against the release's `SHA256SUMS`.
- Install dir: `~/opt/veryfpga/openxc7`. Full metadata: `~/opt/veryfpga/openxc7/BUILD-INFO.json`.

| Component | Revision |
|---|---|
| nextpnr-xilinx | `a9cfec7606b449816893ac7e6728be32eb3730cf` |
| prjxray (`xc7frames2bit`, `bitread`, `xc7patch`) | `a5589d5187964aceeccd1650c37a405c5d0128d8` |
| prjxray-db | `a8b09269beb6e3d3c07e2a0901f845420df1c802` |
| fasm (`fasm2frames`) | `2f57ccb1727a120e8cacbb95c578f3c71bdcc95a` |
| chipdb | prebuilt, `chipdb-id` `00f725726e3fc150`; `chipdb-xc7s50.bin` covers `xc7s50ftgb196-1` |

The chip database is prebuilt, one per die, in
`share/nextpnr/himbaechel/xilinx/`. No local generation was needed.

## YosysHQ oss-cad-suite

- `oss-cad-suite-linux-x64-20261104.tgz`, release `2026-11-04`. This is the
  release the openXC7 package names as validated (`yosys-release-tag`).
- SHA-256 `8b4ee0a8071df1e20d3497c4fc11d66cc69991bd3e97903d56cc689c41fdea9a`,
  matches the GitHub release digest.
- Install dir: `~/opt/veryfpga/oss-cad-suite`.

| Tool | Version |
|---|---|
| yosys | 0.70+329 (git sha1 b8d84f823) |
| openFPGALoader | v1.2.0 |

## Lean

| Tool | Version |
|---|---|
| elan | 4.2.4 (227caca13 2026-08-25), installed with `--no-modify-path` by `elan-init.sh` from the elan repository's `master` branch (SHA-256 of the script used: `a620ff1641616222c8d37c54845492004bb84d6877cdbc944dd65c1aa685bf53`); the script installs the latest elan release, so a later install may get a newer elan |
| Lean toolchain | `leanprover/lean4:v4.35.0` (latest stable on 2026-11-10), pinned in `lean/lean-toolchain` |

## Smoke test (2026-11-10)

A 4-bit counter (clk G11, led E11) went through yosys `synth_xilinx`,
`nextpnr-xilinx --device xc7s50ftgb196-1` (1.9 s, 0.6 GB RAM), `fasm2frames`
and `xc7frames2bit`. The `.bit` header names `xc7s50ftgb196-1`. It was not
loaded onto the board.
