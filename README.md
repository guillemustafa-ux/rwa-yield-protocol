# RWA Yield Protocol

Protocolo multi-contrato que tokeniza un activo del mundo real que rinde (un T-bill
sintético) y lo distribuye vía un vault asíncrono ERC-7540 valuado por un oráculo de NAV.
Desplegado, verificado y **upgradeado en vivo (UUPS V1→V2)** en Sepolia — el proxy que
opera hoy es el mismo que se deployó el día 1.

No es un vault balance-based como un ERC-4626 estándar: el precio de la share sale de
un NAV feed compatible con Chainlink, no del balance propio del contrato. Nadie
transfiere yield adentro — el NAV subiendo *es* el yield.

**▶ Demo en vivo:** https://rwa-yield-protocol.vercel.app — dApp contra los contratos
en Sepolia (Overview · Vault · Cross-chain · Admin). Conectá una wallet en Sepolia para
operar; el resto es read-only.

## Qué hay acá

| Pieza | Qué hace |
|---|---|
| `TBillToken` | ERC-20 del RWA sintético (6 decimales). Mint/burn solo por `ASSET_MANAGER_ROLE`. Sin lógica propia — el valor vive en el feed, no en el token. |
| `RwaNavFeed` | Oráculo de NAV, implementa `AggregatorV3Interface` (Chainlink) completo. `updateNav` con banda de desviación ±5% y rate limit de 1 update/hora — mitiga fat-finger y compromiso de key. |
| `RwaVault` (V1) | ERC-7540 async vault: `requestDeposit/Redeem` → `fulfillDeposit/Redeem` (operador, precio fijado ahí) → `claim`. UUPS upgradeable, `AccessControl` con 4 roles separados, pausa parcial. |
| `RwaVaultV2` | Mismo vault + management fee (100 bps anual, devengada en shares). Es el código que corre HOY detrás del proxy — llegó ahí por un upgrade real, no por un redeploy. |
| Subgraph (The Graph Studio) | Indexa `DepositRequest`/`RedeemRequest`/`DepositFulfilled`/`RedeemFulfilled`/`NavUpdated`. Consumido por la dApp en la página **Actividad** (GraphQL, sin backend propio). |
| dApp (Vite + React + wagmi) | Flujo request → pending → claimable → claim, panel de NAV, página **Cross-chain** (CCIP + Automation, con la evidencia F3 en vivo), página **Actividad** (historial on-chain leído del subgraph) y panel admin. Deployada: [rwa-yield-protocol.vercel.app](https://rwa-yield-protocol.vercel.app). |

Diseño completo con el porqué de cada decisión: [`ARCHITECTURE.md`](./ARCHITECTURE.md).
Trade-offs, self-audit y la historia de los 3 hallazgos de la auditoría: [`DESIGN.md`](./DESIGN.md).

## Direcciones verificadas (Sepolia, chainId 11155111)

Fuente: [`contracts/deployments/sepolia.json`](./contracts/deployments/sepolia.json)
(deploy block `11217752`, deployer `0x40b282c45EE5667fB72b4D37a676A0110cEe36d5`).

| Contrato | Dirección | Etherscan |
|---|---|---|
| DemoUSDC (asset de demo, 6 dec) | `0x6E48f460b802F3777C5aC4339899EcA071Acd721` | [ver](https://sepolia.etherscan.io/address/0x6E48f460b802F3777C5aC4339899EcA071Acd721) |
| TBillToken | `0xa68C7381e4B0f539659f57b2a140B858828e2321` | [ver](https://sepolia.etherscan.io/address/0xa68C7381e4B0f539659f57b2a140B858828e2321) |
| RwaNavFeed | `0x8805250663BAE305b3891A11Ca888200EdB161d7` | [ver](https://sepolia.etherscan.io/address/0x8805250663BAE305b3891A11Ca888200EdB161d7) |
| **RwaVault proxy (ERC1967) — LA dirección del protocolo** | **`0x48c78Ffe5A882069FC81Fb866510FAAE625109C4`** | [ver](https://sepolia.etherscan.io/address/0x48c78Ffe5A882069FC81Fb866510FAAE625109C4) |
| RwaVault implementation V1 (histórica, no llamar directo) | `0xC5EF4730F4A50e0b5cfbBF9ECf3Bb7dD41A5971E` | [ver](https://sepolia.etherscan.io/address/0xC5EF4730F4A50e0b5cfbBF9ECf3Bb7dD41A5971E) |
| RwaVault implementation V2 (código que corre hoy detrás del proxy) | `0x9f19d8Ca2C42Cff754500227f677B8AD81Be2b23` | [ver](https://sepolia.etherscan.io/address/0x9f19d8Ca2C42Cff754500227f677B8AD81Be2b23) |
| Subgraph (The Graph Studio) | `rwa-yield-protocol` | [query endpoint](https://api.studio.thegraph.com/query/1756185/rwa-yield-protocol/v0.0.1) |

`RwaVaultImplementationV1` y `RwaVaultImplementationV2` no se llaman nunca directo desde
la dApp — están documentadas para verificar bytecode/diff de storage layout en Etherscan.
Todo lo que importa se hace contra el proxy.

## El upgrade en vivo

El 2026-07-06, con depósitos reales ya asentados en el proxy (seed lifecycle: faucet →
approve → requestDeposit → fulfillDeposit → claim, 5 txs status 1), se ejecutó:

```
upgradeToAndCall(RwaVaultV2_implementation, initializeV2(feeBps=100, feeRecipient=deployer))
```

sobre el proxy `0x48c78Ffe5A882069FC81Fb866510FAAE625109C4`, en dos transacciones
consecutivas del mismo broadcast (bloque `11217773`):

```
tx 1 (deploy de la implementación V2, contract creation):
  0xa1fe2ef0ab9eab7820aecfe9f4d2eb2ce8e297eb0bea04e6bd4a17effca2bf1a

tx 2 (la llamada upgradeToAndCall sobre el proxy — LA tx del upgrade):
  0xa42a4c94f41756ec0e84986c61160c0277e0538d57aeeb313642d7fef1844594
```

La tx 2 es la que importa: `to` es el proxy, no una creación de contrato, y sus 3 logs
son exactamente los que predice el diseño — `Upgraded(0x9f19...2b23)` (ERC1967),
`Initialized(2)` (el `reinitializer(2)` de `initializeV2`) y
`ManagementFeeInitialized(100, deployer)`. El proxy no cambió de dirección. Lo único
que cambió fue el slot de implementación (`V1 0xC5EF...971E` → `V2 0x9f19...2b23`), y
el estado — shares del seed (1e15), `totalAssets()` (1000e6 dUSDC), y los 4 roles
operativos — sobrevivió intacto. Eso es lo que hace a UUPS distinto de "redeployar de
nuevo": el contrato lógico cambió, la cuenta que todos usan no.

> Nota de verificación: `contracts/deployments/sepolia.json` trae estas dos tx hashes
> cruzadas entre los campos `liveUpgrade.txHash` y `RwaVaultV2_implementation.txHash`
> (ambas del mismo broadcast, un índice de diferencia). Los comandos de abajo usan la
> tx correcta para cada afirmación — verificado leyendo `to`/`contractAddress`/logs de
> cada receipt, no el campo del JSON.

### Cómo verificarlo vos mismo (copy-paste, requiere `cast` — Foundry)

```bash
export RPC=https://ethereum-sepolia-rpc.publicnode.com
export PROXY=0x48c78Ffe5A882069FC81Fb866510FAAE625109C4

# 1. Qué implementación corre HOY detrás del proxy (debe imprimir la V2:
#    0x9f19d8ca2c42cff754500227f677b8ad81be2b23) — lee el slot EIP-1967 estándar
cast implementation $PROXY --rpc-url $RPC

# 2. La tx del upgrade en sí: `to` debe ser el proxy (NO vacío/contract-creation) y
#    los logs deben incluir Upgraded/Initialized(2)/ManagementFeeInitialized
cast receipt 0xa42a4c94f41756ec0e84986c61160c0277e0538d57aeeb313642d7fef1844594 --rpc-url $RPC

# 3. El estado sobrevivió: totalAssets() y totalSupply() del vault, leídos HOY sobre el
#    proxy con el ABI de V2 (funciona porque el proxy delega en V2)
cast call $PROXY "totalAssets()(uint256)" --rpc-url $RPC   # esperado: 1000000000 (1000e6 dUSDC)
cast call $PROXY "totalSupply()(uint256)" --rpc-url $RPC   # esperado: 1000000000000000 (1e15)

# 4. Los roles operativos otorgados en el deploy (D4) siguen intactos post-upgrade
cast call $PROXY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "OPERATOR_ROLE") 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5 --rpc-url $RPC   # esperado: true

# 5. La feature nueva de V2 (management fee) está viva y en 100 bps
cast call $PROXY "managementFeeBps()(uint256)" --rpc-url $RPC   # esperado: 100
```

Los 5 comandos de arriba están corridos y verificados contra la RPC pública real al
escribir este README — no son teóricos. Si (1) devuelve la V2, (3) devuelve los
valores del seed, y (5) devuelve `100`, el upgrade pasó de verdad y el estado no se
perdió: no hace falta confiar en este README, la cadena lo dice.

## Estructura del repo

```
rwa-yield-protocol/
├── ARCHITECTURE.md          # diseño: mapa de contratos, decisiones de alcance, superficie de ataque
├── DESIGN.md                 # trade-offs + self-audit + la historia de los 3 hallazgos
├── LOOM-GUION.md              # guion para el video de arquitectura
├── contracts/                 # Foundry: TBillToken, RwaNavFeed, RwaVault, RwaVaultV2
│   ├── src/
│   ├── test/                  # unit + fuzz + invariants/ + fork/ + attacks/
│   ├── script/                 # Deploy.s.sol, UpgradeToV2.s.sol
│   ├── storage-layout/         # forge inspect storage-layout, V1 vs V2 (diff commiteado)
│   └── deployments/sepolia.json
├── dapp/                       # Vite + React + wagmi + viem
│   └── src/{pages,components,hooks,contracts}/
└── subgraph/                   # The Graph: schema, mappings AssemblyScript, manifest
```

## Correr los tests (contracts)

Requiere [Foundry](https://book.getfoundry.sh/) (`forge`/`cast`, vía `foundryup`).

```bash
cd contracts
forge build
forge test                              # todo, incluidos invariants (lento: ~3-4 min)
forge test --no-match-path "test/{invariants,fork}/**"   # rápido: unit+fuzz+attacks (~1s)
forge test --match-path "test/invariants/*" -vv          # solo la campaña de invariantes
forge test --match-path "test/fork/*"                    # requiere RPC real (Sepolia)
forge coverage
```

140 tests corren offline sin red (unit + fuzz + invariants + vectores de ataque);
8 tests adicionales en `test/fork/` necesitan un RPC de Sepolia real (consumen el feed
Chainlink ETH/USD en vivo) y se saltean limpio si no hay red.

## Correr la dApp local

Requiere Node 24 (ver `.github/workflows/ci.yml` — el `package-lock.json` de `dapp/` se
generó con npm 11; Node 22/npm 10 materializa distinto los peers opcionales y `npm ci`
falla).

```bash
cd dapp
npm install
cp .env.example .env    # VITE_WALLETCONNECT_PROJECT_ID es OPCIONAL — MetaMask conecta sin él
npm run dev
```

Con MetaMask (u otra wallet inyectada) en Sepolia, sin necesidad de configurar
WalletConnect. Para RPC propio (más estable que el público de viem), setear
`VITE_SEPOLIA_RPC_URL`.

```bash
npm run build     # tsc -b + vite build
```

## Stack

Solidity 0.8.24 + Foundry + OpenZeppelin Upgradeable (UUPS, AccessControl, Pausable) +
The Graph (AssemblyScript) + Vite + React + wagmi/viem + RainbowKit.
