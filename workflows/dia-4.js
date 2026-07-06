export const meta = {
  name: 'rwa-dia-4',
  description: 'D4 flagship RWA: RwaVaultV2 + scripts de deploy (solo simulación) + subgraph',
  phases: [
    { title: 'Construcción', detail: '3 frentes: V2+layout diff / scripts deploy+upgrade / subgraph' },
    { title: 'Verificación', detail: 'suite completa + simulaciones con gas + layout diff' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol (flagship senior de Guille). Leé PRIMERO ${ROOT}/ARCHITECTURE.md (§3.4 RwaVaultV2, §4, §6 D4) y src/RwaVault.sol (el NatSpec documenta todo, incluido el cap InsufficientLiquidity del hallazgo (c)).
Gotchas OBLIGATORIOS: forge por Git Bash (PATH ~/.foundry/bin, tool Bash); vm.warp(1_700_000_000) en setUp; lectura view entre vm.prank y la llamada CONSUME el prank (cachear antes); deploy en tests vía ERC1967Proxy; NUNCA taskkill global; Solidity 0.8.24, custom errors, NatSpec.
SEGURIDAD: contracts/.env existe con PRIVATE_KEY real — JAMÁS lo leas, imprimas o copies. Para simulaciones usá --sender 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5 SIN clave. PROHIBIDO --broadcast: el broadcast lo hace la sesión principal tras revisión.
NO toques src/RwaVault.sol ni archivos de otros agentes.`

phase('Construcción')
const [v2, scripts, subgraph] = await parallel([
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: src/RwaVaultV2.sol, test/RwaVaultV2.t.sol, storage-layout/RwaVault.v2.txt.

Tarea (§3.4): RwaVaultV2 = V1 + management fee, con upgrade seguro:
- Hereda de RwaVault (o copia estructural si la herencia complica el layout — decidí y justificá). Storage NUEVO append-only: managementFeeBps (cap MAX_FEE_BPS=200), feeRecipient, lastFeeAccrual — consumiendo espacio del __gap correctamente (si V1 tiene uint256[50] __gap, V2 debe declarar sus 3 vars nuevas y reducir a uint256[47]).
- initializeV2(feeBps, feeRecipient) con reinitializer(2) + zero-checks; fee devengada en cada fulfill (dilución: mint de shares al feeRecipient pro-rata del tiempo transcurrido, anual sobre totalAssets — documentá la fórmula exacta en NatSpec) + accrueFees() pública.
- Tests (proxy SIEMPRE): upgrade V1→V2 con estado vivo (depósito pendiente + claimable + shares en V1 sobreviven byte a byte), initializeV2 no re-ejecutable, fee math determinista + fuzz (nunca supera el cap anualizado, no se devenga dos veces el mismo segundo), roles intactos post-upgrade, upgradeToAndCall solo UPGRADER_ROLE.
- 'forge inspect src/RwaVaultV2.sol:RwaVaultV2 storage-layout' > storage-layout/RwaVault.v2.txt y COMPARÁ contra RwaVault.v1.txt: cada slot de V1 idéntico en V2 (mismo offset/tipo), lo nuevo solo al final. Pegá el veredicto del diff en las notas. Corré 'forge test --match-path test/RwaVaultV2.t.sol' y pegá el resumen REAL.
Devolvé SOLO JSON.`, {
    label: 'RwaVaultV2', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, layout_compatible: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests', 'layout_compatible'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: script/Deploy.s.sol y script/UpgradeToV2.s.sol. NOTA: src/RwaVaultV2.sol lo está escribiendo OTRO agente en paralelo — escribí UpgradeToV2.s.sol contra la interfaz esperada (initializeV2(uint16 feeBps, address feeRecipient), reinitializer(2)) y si al final no compila porque V2 aún no existe, reportalo sin bloquear (la sesión principal re-simula después).

Tarea:
1. script/Deploy.s.sol — secuencia EXACTA (§6 D4): deploy TBillToken(deployer) → RwaNavFeed(deployer, "tBILL / USD NAV") → feed.updateNav(100e8) → deploy RwaVault implementation → ERC1967Proxy(impl, abi.encodeCall(initialize, (USDC_MOCK?, tBill, feed, deployer))) → grant OPERATOR/ASSET_MANAGER/PAUSER/UPGRADER al deployer (demo single-operator, comentá que producción = cuentas distintas) → grant ASSET_MANAGER de TBillToken al proxy? NO — revisá quién mintea tBILL según el diseño y dejalo bien cableado y documentado. OJO: el vault necesita un asset ERC-20 (USDC): NO hay USDC canónico en Sepolia para esto — deployá también un MockUSDC de 6 decimales con faucet público acotado (mint máx 10_000e6 por llamada) como parte del script, documentado como demo asset. Consola: log de CADA dirección.
2. script/UpgradeToV2.s.sol — lee la address del proxy de una env var PROXY_ADDRESS (vm.envAddress), deploya RwaVaultV2 impl y hace upgradeToAndCall(abi.encodeCall(initializeV2, (100, deployer))) — 1% anual demo.
3. SIMULACIÓN (sin clave, sin broadcast): 'forge script script/Deploy.s.sol --rpc-url <RPC_URL leída de contracts/.env SOLO la URL, con grep de esa línea, sin tocar las demás> --sender 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5' — pegá el gas total estimado REAL en las notas. Simulá también el estilo de UpgradeToV2 si V2 ya compila.
Devolvé SOLO JSON.`, {
    label: 'deploy-scripts', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { simulacion_ok: { type: 'boolean' }, gas_total_estimado: { type: 'string' }, notas: { type: 'string' } }, required: ['simulacion_ok'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: carpeta ${ROOT}/subgraph/ entera (nueva).

Tarea: subgraph de The Graph para el protocolo (§6 D4), listo para publicar en Studio:
- schema.graphql: entidades DepositRequest, RedeemRequest, DepositFulfilled, RedeemFulfilled, NavUpdate (del feed), VaultDailySnapshot (totalAssets si es derivable de eventos — si no, documentá la limitación y omitilo).
- Mappings AssemblyScript sobre los eventos REALES de src/RwaVault.sol y src/RwaNavFeed.sol (leé las firmas exactas de los eventos, generá los ABIs desde contracts/out con node si hace falta).
- subgraph.yaml: network sepolia, dataSources vault+feed con address "0x0000000000000000000000000000000000000000" placeholder y startBlock 0 (la sesión principal los completa post-deploy).
- package.json con graph-cli como devDependency; DEBE compilar offline: 'npx graph codegen && npx graph build' (Git Bash) — pegá la salida REAL. README.md corto del subgraph con los 2 comandos de publicación en Studio (graph auth + graph deploy).
Devolvé SOLO JSON.`, {
    label: 'subgraph', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, entidades: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['build_ok'] },
  }),
])

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. Contra disco y salida real:
1. 'forge test' COMPLETO en ${ROOT}/contracts (los fork tests necesitan red; las suites de invariants tardan ~4 min — esperalas): resumen REAL.
2. Diff storage-layout v1 vs v2 verificado por VOS (no por el reporte del agente): slots de V1 intactos, nuevas vars al final, __gap reducido en la cantidad exacta.
3. Re-simulá 'forge script script/Deploy.s.sol' y (si V2 compila) el flujo de UpgradeToV2 con --sender 0x40b2...36d5 sin clave: gas totales reales en notas. PROHIBIDO --broadcast.
4. 'npx graph build' en ${ROOT}/subgraph: exit code real.
5. Si TODO pasa: UN commit "feat: Día 4 — RwaVaultV2 (management fee) + scripts de deploy/upgrade + subgraph (pre-broadcast)" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>. Si algo falla, NO commitees y detallá qué.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { tests_passed: { type: 'number' }, tests_failed: { type: 'number' }, layout_diff_ok: { type: 'boolean' }, simulacion_gas: { type: 'string' }, subgraph_build_ok: { type: 'boolean' }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_passed', 'tests_failed', 'layout_diff_ok', 'commit_hecho'] },
}) || {}

return { v2: v2 || 'agente caído', scripts: scripts || 'agente caído', subgraph: subgraph || 'agente caído', verificacion: verif }
