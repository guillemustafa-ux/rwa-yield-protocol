# RWA Yield Protocol — Subgraph

**Live and indexing** (deployed 2026-07-06, synced from block 11217752, zero indexing
errors): https://thegraph.com/studio/subgraph/rwa-yield-protocol

Query endpoint: `https://api.studio.thegraph.com/query/1756185/rwa-yield-protocol/v0.0.1`

Indexes the two on-chain data sources described in `ARCHITECTURE.md` §6 (D4):

- **RwaVault** (`contracts/src/RwaVault.sol`) — `DepositRequest`, `RedeemRequest`,
  `DepositFulfilled`, `RedeemFulfilled`.
- **RwaNavFeed** (`contracts/src/RwaNavFeed.sol`) — `NavUpdated`.

See `schema.graphql` for entity definitions (including a note on why a derived
`VaultDailySnapshot` of `totalAssets()` was left out — it needs data this
subgraph's two sources don't emit) and `src/rwa-vault.ts` / `src/rwa-nav-feed.ts`
for the mappings.

## Layout

```
subgraph/
├── schema.graphql       # entities
├── subgraph.yaml         # manifest (network sepolia, addresses = placeholder 0x0)
├── abis/                 # ABIs extracted from contracts/out/*.json (forge build output)
├── src/                  # AssemblyScript mappings
├── package.json
└── build/, generated/    # gitignored — produced by codegen/build below
```

## Before publishing (post-deploy checklist)

`subgraph.yaml` ships with `address: "0x0000000000000000000000000000000000000000"`
and `startBlock: 0` for both data sources — placeholders on purpose (this task's
scope). Once D4's deploy script runs, fill in for **each** `dataSources[].source`:

- `address`: the deployed `RwaVault` proxy address / the deployed `RwaNavFeed` address.
- `startBlock`: the block number of that deployment tx (avoids a full-chain backfill).

## Local build (offline, no Studio account needed)

```bash
npm install
npx graph codegen
npx graph build
```

Both commands were run against this exact manifest — see the parent task's report
for the real CLI output (`Types generated successfully` / `Build completed: build\subgraph.yaml`).

## Publish to The Graph Studio

1. Create the subgraph in [Studio](https://thegraph.com/studio/) (or reuse
   Guille's existing slug) to get its deploy key, then authenticate once:

   ```bash
   npx graph auth <DEPLOY_KEY>
   ```

2. Deploy (bumps the version label each time; addresses/startBlock in
   `subgraph.yaml` must be the real post-deploy values before this step):

   ```bash
   npx graph deploy rwa-yield-protocol
   ```

   (`rwa-yield-protocol` above must match the exact subgraph slug created in
   Studio; `package.json`'s `deploy` script already points at it, so
   `npm run deploy` also works once real addresses are in place.)
