# RWA Yield Protocol — Arquitectura (diseño Fable, 2026-07-05)

> **Pieza #6 del roadmap a senior** (F2 flagship). El salto de "estándares sueltos" a
> **un protocolo multi-contrato cohesivo que parece producto**. Integra todo lo ya
> shippeado: el ERC-7540 de yield-vault como corazón, los patrones wagmi/viem de PULSO
> en el frontend, la disciplina F0 (fuzz+invariants+CI) como vara mínima.
>
> Lema: hito (portfolio senior) + suceso (protocolo desplegado y UPGRADEADO en vivo
> en Sepolia) + aprendizaje (UUPS, oráculos, roles, NAV accounting, The Graph).

---

## 1. Qué es (pitch de una línea)

Protocolo que tokeniza un activo del mundo real que rinde (T-bill sintético) y lo
distribuye vía un vault asíncrono ERC-7540 **valuado por oráculo (NAV)**, con roles
operativos reales, upgradeable por UUPS, indexado con The Graph.

**Por qué RWA:** es la narrativa institucional dominante (Centrifuge, Ondo, BlackRock
BUIDL); ERC-7540 existe *por* RWA (liquidez no instantánea → request/fulfill/claim);
y Guille ya tiene el estándar implementado a mano — acá se lo convierte en producto.

## 2. Decisiones de alcance (tomadas, con motivo)

| Decisión | Elección | Por qué |
|---|---|---|
| Activo subyacente | **tBILL sintético** (mock de T-bill tokenizado, NAV creciente) | Un RWA real requiere custodio/legal; el mock con NAV feed reproduce exactamente la mecánica técnica que se evalúa en un dev |
| Oráculo | **Consumir `AggregatorV3Interface` de Chainlink**: feed real de Sepolia para el par de referencia + `RwaNavFeed` propio (misma interfaz) para el NAV del tBILL | Señal senior = consumir la interfaz estándar con chequeos de staleness/decimales, no "usé el precio y ya". En Sepolia no existe feed de T-bills → se publica uno propio compatible |
| Accounting | **NAV-based**: `totalAssets()` = holdings × precio del oráculo, NO balance del vault | Este es el salto conceptual vs YieldVault (balance-based). Es como valúan los vaults RWA reales |
| Upgradeability | **UUPS** (OZ upgradeable), y el plan incluye **ejecutar un upgrade V1→V2 en vivo en Sepolia** | Demostrar el ciclo completo (deploy proxy → upgrade real on-chain verificable) vale más que "sé qué es un proxy" |
| Roles | `AccessControl`: `ASSET_MANAGER_ROLE`, `OPERATOR_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE`, admin = multisig-ready | Separación operativa real: quien cumple requests no es quien actualiza el NAV ni quien upgradea |
| Indexing | **The Graph** (Studio, Sepolia) — subgraph de requests/fulfills/NAV | Dimensión "Integraciones" del gap senior; los jobs full-stack lo piden |
| Frontend | **wagmi + viem + Vite/React** reusando patrones PULSO (`useTxAction`, guard de red, i18n opcional) | Ya probado; migración ethers→wagmi era objetivo explícito del roadmap |
| Chain | Sepolia (deployer existente `0x40b2...36d5`, ~0.007 ETH — alcanza justo; pedir faucet si D4 lo requiere) | Continuidad con las otras 5 piezas |
| Repo | Nuevo repo público `rwa-yield-protocol` (NO tocar yield-vault) | yield-vault queda como pieza didáctica; el flagship es producto aparte que la referencia |

## 3. Mapa de contratos

```
                        ┌──────────────────────┐
                        │  Chainlink Sepolia    │  feed real (USDC/USD)
                        │  AggregatorV3         │  → sanity del asset de depósito
                        └──────────┬───────────┘
                                   │
┌──────────────┐        ┌──────────▼───────────┐        ┌──────────────────┐
│ RwaNavFeed   │───────▶│   RwaVault (UUPS)     │◀───────│ Depositante      │
│ (Aggregator  │  NAV   │   ERC-7540 async      │  USDC  │ requestDeposit → │
│  V3 propio,  │        │   NAV accounting      │        │ claim shares     │
│  updater =   │        │   AccessControl       │        └──────────────────┘
│  ASSET_MGR)  │        │   Pausable            │
└──────────────┘        └──────────┬───────────┘
                                   │ compra/vende (fulfill)
                        ┌──────────▼───────────┐
                        │  TBillToken (tBILL)   │  ERC-20 del RWA sintético
                        │  mint/burn solo       │  1 tBILL = 1 T-bill unit
                        │  ASSET_MANAGER        │  valor = RwaNavFeed
                        └──────────────────────┘

Subgraph (The Graph) indexa: DepositRequest / RedeemRequest / Fulfilled / NavUpdated
dApp (wagmi+viem): flujo request → pending → claimable → claim + panel de NAV
```

### 3.1 `TBillToken.sol` — el RWA sintético
- ERC-20 estándar, 6 decimales (como los T-bill tokens reales), `mint`/`burn` solo
  `ASSET_MANAGER_ROLE` del protocolo (simula compra/venta del subyacente por el custodio).
- Sin lógica exótica a propósito: el valor NO está en el token, está en el feed.

### 3.2 `RwaNavFeed.sol` — oráculo de NAV compatible Chainlink
- Implementa `AggregatorV3Interface` completo (`latestRoundData`, `decimals=8`, rounds).
- `updateNav(int256 newNav)` solo `NAV_UPDATER_ROLE`; guardas: NAV > 0, **desviación
  máxima por update** (p. ej. ±5%) y **frecuencia mínima** — mitiga fat-finger y
  compromiso de la key del updater.
- El vault lo consume EXACTAMENTE igual que a un feed de Chainlink → swap-in real
  posible el día que exista feed oficial. Esa simetría es el argumento del diseño.

### 3.3 `RwaVault.sol` — el corazón (evolución del AsyncVault)
Base: el `AsyncVault.sol` de yield-vault (request/fulfill/claim, operator model,
previews deshabilitados por 7540). Cambios estructurales:

| Dimensión | AsyncVault (pieza #4) | RwaVault (flagship) |
|---|---|---|
| Ownership | `Ownable` single owner | `AccessControlUpgradeable` 4 roles |
| Deploy | contrato plano | **proxy UUPS** + initializer + storage gaps |
| totalAssets | balance del vault + yield manual | `tBILL holdings × NAV` del feed + buffer USDC |
| Yield | `distributeYield()` (transferencia) | el NAV sube → share price sube solo (accrual real) |
| Pausa | no tiene | `PausableUpgradeable` (solo requests nuevos; claim NUNCA se pausa) |
| Oráculo | — | staleness check (`updatedAt + MAX_STALENESS`), revert `StaleNav()` |

Flujo económico:
1. Usuario `requestDeposit(USDC)` → USDC queda en el vault (pending).
2. `OPERATOR_ROLE` corre `fulfillDeposit`: el vault registra shares al NAV vigente
   y el ASSET_MANAGER convierte el USDC en tBILL (mint del sintético).
3. El NAV del tBILL sube con el tiempo (rendimiento del T-bill) → `totalAssets()`
   crece → las shares valen más. **Nadie transfiere yield: es contable.**
4. `requestRedeem` → fulfill (burn tBILL, aparta USDC al NAV vigente) → claim.

Invariante central (la que probará el invariant test):
`USDC apartado para claims + valor NAV de tBILL holdings ≥ pasivo total con depositantes`.

### 3.4 `RwaVaultV2.sol` — el upgrade en vivo (D4)
V2 agrega una feature visible y acotada: **management fee** (bps anuales sobre
totalAssets, devengada en `fulfill`, cobrada en shares al `feeRecipient`).
- Demuestra: storage layout compatible (append-only), `reinitializer(2)`,
  `_authorizeUpgrade` gated por `UPGRADER_ROLE`, y el upgrade REAL en Sepolia con
  el proxy manteniendo estado (los depósitos de V1 sobreviven — verificable on-chain).

## 4. Superficie de ataque / self-audit (se escribe en DESIGN.md al final)

| Vector | Mitigación en el diseño |
|---|---|
| Oracle staleness / feed muerto | `MAX_STALENESS` en cada lectura; revert explícito, nunca precio viejo silencioso |
| Manipulación/fat-finger del NAV | banda de desviación ±5% por update + rate limit en `RwaNavFeed` |
| Rounding 7540 (request vs fulfill) | shares se fijan en fulfill (no en request); redondeo SIEMPRE a favor del vault; fuzz dirigido |
| Donation/inflation attack | decimals offset (ya resuelto en pieza #2) + totalAssets por NAV ignora donaciones de USDC |
| Uninitialized proxy | `_disableInitializers()` en constructor del implementation |
| Storage collision en upgrade | storage gaps + `forge inspect storage-layout` diff V1 vs V2 commiteado en CI |
| Role escalation | admin separado de roles operativos; `DEFAULT_ADMIN_ROLE` con transferencia en 2 pasos documentada |
| Pausa como DoS | pausa solo bloquea requests nuevos; `claim*` y `fulfillRedeem` quedan siempre abiertos |
| Reentrancy en claim | CEI + `nonReentrant` en flujos con transferencia (lección BotPass F0) |

## 5. Vara de calidad (no negociable, es la firma de la casa)

- Unit + **fuzz** (montos, secuencias request/fulfill parciales) + **invariant**
  (handler multi-actor con warp, mínimo: solvencia NAV, conservación de pending,
  shares nunca gratis) — la lección PULSO: el invariant de solvencia fue el que
  hubiera atrapado el bug C1.
- **Fork test** contra Sepolia real leyendo el feed Chainlink USDC/USD (staleness
  handling con datos reales).
- `forge coverage` + `forge snapshot` (gas) + storage-layout diff en CI (GitHub Actions).
- NatSpec completo; DESIGN.md con trade-offs + self-audit; README con arquitectura
  y "cómo verificar cada claim" (direcciones + comandos cast).

## 6. Plan de construcción (5 días, modalidad sandwich PULSO)

Fable diseña/audita; workflows Sonnet ejecutan por día; verificación contra disco y
chain, nunca contra el reporte del agente.

| Día | Entrega | Aceptación |
|---|---|---|
| **D1** | Scaffold Foundry + `TBillToken` + `RwaNavFeed` completos con tests | tests verdes; feed responde `latestRoundData` como Chainlink; bandas de desviación probadas con fuzz |
| **D2** | `RwaVault` UUPS: initializer, roles, 7540 request/fulfill/claim con NAV accounting | unit+fuzz verdes; `forge inspect` del storage layout commiteado; pausa parcial probada |
| **D3** | Suite adversarial: invariants multi-actor, fork test Sepolia, ataques de la tabla §4 | invariants corren ≥256 runs limpios; cada vector de §4 tiene SU test con nombre explícito |
| **D4** | Deploy Sepolia (proxy+impl+feed+token) verificado + **upgrade V1→V2 en vivo** + subgraph | direcciones en deployments/; estado pre/post upgrade verificado con cast; subgraph sincronizado en Studio |
| **D5** | dApp wagmi/viem (request→claim + panel NAV + admin) + README + DESIGN.md + guion Loom | build limpio; flujo completo probado en browser real con wallet; CI verde en GitHub |

## 7. Qué reusa (cohesión con el portfolio)

- **yield-vault**: AsyncVault como referencia de la mecánica 7540 (se reescribe
  upgradeable, no se copia a ciegas — el post-mortem de PULSO manda re-derivar).
- **PULSO**: `useTxAction` (con el fix de `receipt.status === 'reverted'`), guard de
  red, patrón de estados de tx con link a Etherscan, estética de design system propio.
- **aa-smart-wallet**: pipeline de CI y patrón de scripts de deploy con verificación.
- **BotPass F0**: SafeERC20, CEI, disciplina de invariants.

## 8. Tu parte (Guille) — corre en paralelo, no bloquea

1. **F1 seguridad es tuyo**: Damn Vulnerable DeFi + Solodit son tu aprendizaje — el
   protocolo te da el contexto perfecto (varios challenges son exactamente vaults y
   oráculos como estos). No lo automatizo porque el hito es que VOS puedas hablarlo.
2. **Nombre del protocolo**: "RWA Yield Protocol" es nombre de trabajo. Si querés
   marca propia (estilo PULSO), decidila antes del D5 (dApp + README).
3. **Loom de arquitectura** (cierre F2): guion me lo pedís hecho, la voz es tuya.
4. ~0.007 ETH en el deployer: si D4 se queda corto, faucet de Sepolia antes del deploy.

## 9. Gotchas Windows (heredados, para los workflows)

- forge/cast por **Git Bash** (PATH `~/.foundry/bin`); PowerShell 5.1 sin `&&`.
- `vm.warp` base: timestamp local arranca en 1 → warpear en setUp.
- Node para reemplazos de strings en archivos (sed/heredoc rompen quoting).
- Prohibido `taskkill /F /IM node.exe` global en agentes (mata procesos ajenos).
