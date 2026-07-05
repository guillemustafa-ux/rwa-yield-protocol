export const meta = {
  name: 'rwa-dia-1',
  description: 'D1 flagship RWA: scaffold Foundry + TBillToken + RwaNavFeed con tests',
  phases: [
    { title: 'Scaffold', detail: 'forge init + OZ + config' },
    { title: 'Contratos', detail: 'TBillToken y RwaNavFeed en paralelo (archivos disjuntos)' },
    { title: 'Verificación', detail: 'forge build + test contra disco, no contra reportes' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol (flagship senior de Guille). Leé PRIMERO ${ROOT}/ARCHITECTURE.md — el diseño es ley, no lo cambies.
Gotchas Windows OBLIGATORIOS: forge/cast corren por Git Bash (PATH ~/.foundry/bin, usá la tool Bash, no PowerShell); en tests el timestamp local arranca en 1, warpeá en setUp (vm.warp(1_700_000_000)); NUNCA corras taskkill global. Solidity 0.8.24, estilo con NatSpec completo y custom errors (no strings).`

phase('Scaffold')
const scaffold = await agent(`${CTX}

Tarea: dejar el scaffold Foundry del protocolo en ${ROOT}/contracts:
1. forge init sin template extra (o estructura manual equivalente: src/, test/, script/, lib/).
2. forge install OpenZeppelin/openzeppelin-contracts y OpenZeppelin/openzeppelin-contracts-upgradeable (git requerido — ya está). remappings.txt con ambos.
3. foundry.toml: solc_version = "0.8.24", optimizer = true, optimizer_runs = 200, fuzz runs 512.
4. .gitignore raíz del repo (out/, cache/, broadcast/, .env, node_modules/) y contracts/.env.example con RPC_URL/PRIVATE_KEY/ETHERSCAN_API_KEY vacíos (JAMÁS valores reales).
5. Verificá con 'forge build' que compila vacío.
Devolvé SOLO JSON con lo hecho.`, {
  label: 'scaffold', phase: 'Scaffold', model: 'sonnet',
  schema: { type: 'object', properties: { estado: { type: 'string' }, forge_build_ok: { type: 'boolean' }, notas: { type: 'string' } }, required: ['estado', 'forge_build_ok'] },
}) || {}
log(`Scaffold: ${scaffold.estado || 'sin reporte'} (build ok: ${scaffold.forge_build_ok})`)

phase('Contratos')
const [token, feed] = await parallel([
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: solo tocás src/TBillToken.sol y test/TBillToken.t.sol. NO toques foundry.toml, remappings ni archivos de otro agente.

Tarea: implementar TBillToken según §3.1 de ARCHITECTURE.md:
- ERC-20 (OZ), 6 decimales, nombre "Synthetic T-Bill", símbolo "tBILL".
- mint/burn SOLO un rol ASSET_MANAGER_ROLE (AccessControl de OZ; DEFAULT_ADMIN_ROLE al deployer en constructor, que puede otorgar el rol).
- Custom errors, NatSpec completo explicando que es un RWA sintético y que el valor vive en el NAV feed.
- Tests: unit (mint/burn con rol, revert sin rol, decimales) + 1 fuzz de supply conservation. Corré 'forge test --match-path test/TBillToken.t.sol' y pegá el resultado REAL.
Devolvé SOLO JSON.`, {
    label: 'TBillToken', phase: 'Contratos', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: solo tocás src/RwaNavFeed.sol y test/RwaNavFeed.t.sol. NO toques foundry.toml, remappings ni archivos de otro agente.

Tarea: implementar RwaNavFeed según §3.2 de ARCHITECTURE.md:
- Implementa AggregatorV3Interface COMPLETA (definila local en src/interfaces/AggregatorV3Interface.sol idéntica a la de Chainlink): latestRoundData, getRoundData, decimals()=8, description(), version(). Guardar historial de rounds en mapping.
- updateNav(int256) solo NAV_UPDATER_ROLE (AccessControl): guardas NAV>0 (custom error), desviación máxima ±5% vs round anterior (constante MAX_DEVIATION_BPS=500, custom error NavDeviationTooHigh), frecuencia mínima 1 hora entre updates (custom error TooFrequent). Primer update sin guarda de desviación.
- NatSpec explicando el porqué de cada guarda (mitigación fat-finger / key comprometida).
- Tests: unit de cada guarda + fuzz de desviación (valores dentro/fuera de banda) + roundId monotónico. Acordate del vm.warp en setUp. Corré 'forge test --match-path test/RwaNavFeed.t.sol' y pegá el resultado REAL.
Devolvé SOLO JSON.`, {
    label: 'RwaNavFeed', phase: 'Contratos', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
])

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. NO confíes en reportes previos: verificá contra disco y salida real de comandos en ${ROOT}/contracts:
1. 'forge build' limpio (0 warnings graves).
2. 'forge test' completo: pegá el resumen real (X passed, Y failed).
3. Revisá que TBillToken y RwaNavFeed cumplen §3.1/§3.2 de ARCHITECTURE.md (roles correctos, guardas del feed, decimales) — leé el código, listá desvíos.
4. git status: listá archivos sin commitear; si todo está bien hacé UN commit atómico "feat: Día 1 — TBillToken + RwaNavFeed con tests (unit+fuzz)" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, tests_passed: { type: 'number' }, tests_failed: { type: 'number' }, desvios_arquitectura: { type: 'array', items: { type: 'string' } }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['build_ok', 'tests_passed', 'tests_failed', 'commit_hecho'] },
}) || {}

return {
  scaffold: scaffold.estado || 'sin reporte',
  token: token || 'agente caído',
  feed: feed || 'agente caído',
  verificacion: verif,
}
