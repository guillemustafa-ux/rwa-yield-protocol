export const meta = {
  name: 'rwa-dia-5',
  description: 'D5 flagship RWA: dApp wagmi/viem + README + DESIGN.md + guion Loom + CI',
  phases: [
    { title: 'Scaffold dApp', detail: 'Vite+React+wagmi v2 cableado a los contratos reales de Sepolia' },
    { title: 'Construcción', detail: 'flujos vault+admin en paralelo con docs (README/DESIGN/Loom) y CI' },
    { title: 'Verificación', detail: 'build + smoke real en browser + commit' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol, flagship senior de Guille. YA DESPLEGADO Y VERIFICADO en Sepolia con upgrade UUPS V1→V2 en vivo. Leé PRIMERO:
1. ${ROOT}/ARCHITECTURE.md (§3 diseño, §6 D5),
2. ${ROOT}/contracts/deployments/sepolia.json (direcciones/txs REALES — el proxy 0x48c78Ffe5A882069FC81Fb866510FAAE625109C4 es LA dirección; el vault corre la V2 con managementFeeBps=100),
3. Los ABIs canónicos están en ${ROOT}/contracts/out/RwaVaultV2.sol/RwaVaultV2.json, RwaNavFeed.json, TBillToken.json y el DemoUSDC dentro de out/Deploy.s.sol/.
REUSO OBLIGATORIO (lecciones PULSO, en C:/Users/Cript/pulso-exchange/apps/web/src/): el patrón useTxAction (hooks/useTxAction.ts — INCLUIDO el chequeo receipt.data.status === 'reverted', gotcha wagmi v2), el guard de red equivocada con useSwitchChain, y el manejo allowance undefined=cargando ≠ 0. Pinnear wagmi@^2.x + @tanstack/react-query@5 (wagmi v3 rompe RainbowKit — lección PULSO D1).
Gotchas Windows: PowerShell 5.1 sin && (usá la tool Bash); NUNCA taskkill global; Next.js PROHIBIDO (cuelga en Windows — Vite+React); WalletConnect projectId es opcional (MetaMask anda sin él, dejá la env VITE_WALLETCONNECT_PROJECT_ID vacía y documentada).
NO toques contracts/ ni subgraph/ ni archivos de otros agentes.`

phase('Scaffold dApp')
const scaffold = await agent(`${CTX}

OWNERSHIP: carpeta ${ROOT}/dapp entera (nueva) — solo el esqueleto compartido, NO las páginas de flujo (otra tarea).

Tarea: scaffold de la dApp en ${ROOT}/dapp:
1. Vite + React + TS + wagmi v2 + viem + RainbowKit, chain sepolia, tema oscuro sobrio (esto es un protocolo RWA institucional, NO neón: paleta slate/azul profundo con un acento, tipografía limpia).
2. src/contracts/: addresses.ts (desde deployments/sepolia.json, incluí CHAIN_ID=11155111) + ABIs generados con node desde contracts/out (RwaVaultV2 completo — el proxy corre V2 —, RwaNavFeed, TBillToken, DemoUSDC).
3. src/hooks/useTxAction.ts portado de PULSO (con el fix de 'reverted') + hook useVaultData (totalAssets, shares del usuario, NAV vigente + updatedAt del feed, pending/claimable del controller — usá multicall/useReadContracts).
4. Layout: header (logo texto "RWA Yield Protocol", ConnectButton, badge Sepolia), guard de red equivocada, footer con links a Etherscan de los 6 contratos (desde addresses.ts).
5. Rutas placeholder /vault y /admin (las llena otro agente) + home con hero corto: qué es el protocolo, el pitch del upgrade en vivo (link a la tx 0xa1fe2ef0ab9eab7820aecfe9f4d2eb2ce8e297eb0bea04e6bd4a17effca2bf1a) y stats vivas (totalAssets, NAV, share price) leyendo on-chain.
6. 'npm run build' limpio — pegá la salida real. Devolvé SOLO JSON.`, {
  label: 'scaffold-dapp', phase: 'Scaffold dApp', model: 'sonnet',
  schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, notas: { type: 'string' } }, required: ['build_ok'] },
}) || {}
log(`Scaffold dApp: build ${scaffold.build_ok ? 'OK' : 'FALLÓ'}`)

phase('Construcción')
const [flows, docs] = await parallel([
  () => agent(`${CTX}

OWNERSHIP: ${ROOT}/dapp/src/pages/Vault.tsx, Admin.tsx y componentes nuevos en dapp/src/components/ que ellas necesiten. NO toques el scaffold (config, hooks, layout) salvo registrar las rutas si falta.

Tarea: los dos flujos sobre el scaffold ya hecho (leelo primero):
1. /vault (usuario): faucet DemoUSDC (cap 10k, explicá que es asset demo) → approve (explicador del infinite-approve como PULSO) → requestDeposit → estado pending → (cuando el operador fulfilea) claimable → claim; y el espejo requestRedeem→claim. Panel lateral: NAV vigente + hace cuánto se actualizó (warning si >20h, staleness es 24h), share price, tus shares y su valor. CADA estado de tx con el patrón useTxAction + link a Etherscan.
2. /admin (solo si la wallet conectada tiene el rol — chequealo on-chain con hasRole): colas de pending por controller (input de address), fulfillDeposit/fulfillRedeem (con aviso del cap InsufficientLiquidity y el buffer libre visible), investInTBill/divestFromTBill + mint/burn de tBILL (flujo custodio demo), updateNav (con las bandas ±5%/1h explicadas y validación client-side), pause/unpause, accrueFees + fee config visible.
3. UX de errores: decodificá los custom errors del vault (InsufficientLiquidity, StaleNav, NavDeviationTooHigh, TooFrequent...) a mensajes humanos en español.
'npm run build' limpio al final — salida real. Devolvé SOLO JSON.`, {
    label: 'flows-vault-admin', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, paginas: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['build_ok'] },
  }),
  () => agent(`${CTX}

OWNERSHIP: ${ROOT}/README.md, ${ROOT}/DESIGN.md, ${ROOT}/LOOM-GUION.md, ${ROOT}/.github/workflows/ci.yml.

Tarea (leé también el git log completo — la historia de los hallazgos es el material):
1. README.md raíz: qué es (protocolo RWA multi-contrato: 7540 + NAV oracle + UUPS + roles + subgraph), tabla de direcciones verificadas (desde contracts/deployments/sepolia.json) con links a Etherscan, LA SECCIÓN ESTRELLA "El upgrade en vivo" (tx del upgrade + cómo verificar con cast que el estado sobrevivió — comandos copy-paste), cómo correr tests/dApp local, estructura del repo. Voz técnica sobria, sin hype, NADA de "thrilled/game-changer".
2. DESIGN.md: trade-offs con el porqué (NAV accounting vs balance, copia estructural V2 vs herencia por el __gap privado, ReentrancyGuard plano demostrado vía proxy, pausa parcial, rieles de tesorería y su trust boundary) + SELF-AUDIT: la tabla §4 de ARCHITECTURE.md mapeada a sus tests + LA HISTORIA de los 3 hallazgos ((a) transit window cuantificado, (b) guard vía proxy, (c) el que encontró la campaña de invariantes → fix InsufficientLiquidity con su commit) contados como post-mortem/proceso — es la narrativa senior del repo.
3. LOOM-GUION.md: guion de 4-5 min en español para que Guille grabe la arquitectura: hook (30s, el upgrade en vivo), mapa de contratos (1min), el hallazgo (c) como historia (1.5min), demo dApp (1min), cierre con números (30s). Frases cortas, habladas, con [MOSTRAR: ...] por sección.
4. .github/workflows/ci.yml: job contracts (foundry-toolchain, submodules recursive, forge build + forge test SIN invariants ni fork en CI — usá --no-match-path "test/{invariants,fork}/**" y explicá por qué en un comment; job aparte "slow-tests" con schedule semanal que sí los corre) + job dapp (node 24 — lección PULSO: el lock se genera con npm 11 —, npm ci + build).
Devolvé SOLO JSON.`, {
    label: 'docs-ci', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { archivos: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['archivos'] },
  }),
])

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. Contra disco y ejecución real:
1. ${ROOT}/dapp: 'npm run build' limpio (salida real).
2. Smoke REAL en browser: levantá 'npm run dev' en background (puerto que reporte), abrí con Playwright (las tools mcp__playwright__* via ToolSearch) http://localhost:<puerto>: home carga stats on-chain reales (totalAssets debe mostrar ~1000 dUSDC, NAV 100), /vault renderiza, 0 errores de consola (ignorá warnings de WalletConnect sin projectId). Matá SOLO el proceso del dev server que vos levantaste (por PID), JAMÁS taskkill global.
3. README: cada dirección coincide con deployments/sepolia.json; los comandos cast del "upgrade en vivo" corren de verdad (probalos, RPC público https://ethereum-sepolia-rpc.publicnode.com).
4. forge build sigue limpio en contracts/ (nadie debió tocarlo).
5. Si todo pasa: UN commit "feat: Día 5 — dApp wagmi/viem + README + DESIGN.md + guion Loom + CI. Flagship RWA completo" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>. Si algo falla, arreglalo solo si es tuyo (verificación), si es de otro agente reportalo sin commitear.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, smoke_browser_ok: { type: 'boolean' }, consola_errores: { type: 'number' }, readme_direcciones_ok: { type: 'boolean' }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['build_ok', 'smoke_browser_ok', 'commit_hecho'] },
}) || {}

return { scaffold, flows: flows || 'agente caído', docs: docs || 'agente caído', verificacion: verif }
