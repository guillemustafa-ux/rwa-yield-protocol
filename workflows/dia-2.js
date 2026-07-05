export const meta = {
  name: 'rwa-dia-2',
  description: 'D2 flagship RWA: RwaVault ERC-7540 UUPS con NAV accounting + roles + pausa parcial',
  phases: [
    { title: 'Vault', detail: 'RwaVault UUPS: initializer, roles, request/fulfill/claim, totalAssets por NAV' },
    { title: 'Tests', detail: 'unit + fuzz del vault, storage layout commiteado' },
    { title: 'Verificación', detail: 'forge build/test real + revisión contra ARCHITECTURE.md §3.3' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol (flagship senior de Guille). Leé PRIMERO ${ROOT}/ARCHITECTURE.md — el diseño es ley, en especial §3.3 (RwaVault) y §4 (superficie de ataque).
Referencia de la mecánica 7540: C:/Users/Cript/yield-vault/src/AsyncVault.sol (NO lo copies a ciegas: acá es upgradeable y el accounting es por NAV, re-derivá cada función).
Gotchas Windows OBLIGATORIOS: forge/cast por Git Bash (PATH ~/.foundry/bin, usá la tool Bash, no PowerShell); en tests warpeá en setUp (vm.warp(1_700_000_000)) porque el timestamp local arranca en 1; OJO en Foundry una lectura view entre vm.prank y la llamada consume el prank (cachear role hashes ANTES del prank — bug ya visto 2 veces en D1); NUNCA taskkill global. Solidity 0.8.24, NatSpec completo, custom errors.
Hallazgos de la auditoría Fable del D1 que APLICAN a tu trabajo:
1. RwaNavFeed no valida admin != address(0) en el constructor — en RwaVault el initializer DEBE validar zero-address en todos los parámetros de dirección.
2. La separación de roles real (quien opera != quien actualiza NAV != quien upgradea) se demuestra en este contrato: roles distintos, sin atajos.`

phase('Vault')
const vault = await agent(`${CTX}

OWNERSHIP EXCLUSIVO: src/RwaVault.sol (podés crear src/interfaces/ adicionales si hace falta). NO toques TBillToken, RwaNavFeed ni config compartida.

Tarea: implementar RwaVault según §3.3 de ARCHITECTURE.md:
- ERC-7540 async vault UUPS upgradeable (OZ upgradeable: ERC4626Upgradeable como base contable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable).
- constructor con _disableInitializers(); initialize(asset USDC-like, tBillToken, navFeed, admin) con zero-checks en TODAS las direcciones; roles: ASSET_MANAGER_ROLE, OPERATOR_ROLE, PAUSER_ROLE, UPGRADER_ROLE (admin NO recibe los operativos por defecto — separación real).
- Flujo 7540: requestDeposit/requestRedeem (pending), fulfillDeposit/fulfillRedeem (solo OPERATOR_ROLE, shares se fijan acá al NAV vigente, redondeo SIEMPRE a favor del vault), claim vía deposit/mint/redeem/withdraw con controller, modelo operator (setOperator), previews deshabilitados (revert PreviewDisabled) — como manda 7540.
- NAV accounting: totalAssets() = (tBILL.balanceOf(vault) * NAV del feed, normalizando decimales 6/8/decimals del asset) + buffer de asset apartado para claims. Lectura del feed con staleness check: revert StaleNav() si updatedAt + MAX_STALENESS (constante, 24 hours) < block.timestamp; revert si answer <= 0.
- Pausa PARCIAL: whenNotPaused SOLO en requestDeposit/requestRedeem; fulfillRedeem y todos los claim* NUNCA se pausan (§4: pausa como DoS).
- _authorizeUpgrade solo UPGRADER_ROLE. Storage gap (uint256[50] __gap) al final.
- NatSpec completo explicando cada decisión (en especial el porqué del redondeo y de la pausa parcial).
Verificá que compila con forge build y devolvé SOLO JSON.`, {
  label: 'RwaVault', phase: 'Vault', model: 'sonnet',
  schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, funciones_clave: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['build_ok'] },
}) || {}
log(`Vault: build ${vault.build_ok ? 'OK' : 'FALLÓ'}`)

phase('Tests')
const tests = await agent(`${CTX}

OWNERSHIP EXCLUSIVO: test/RwaVault.t.sol (y helpers en test/utils/ si hace falta, ej. mock de USDC de 6 decimales). NO toques src/ salvo bug demostrado con test que falla (si tocás src, explicá exactamente qué y por qué en las notas).

Tarea: suite del RwaVault recién implementado en src/RwaVault.sol (leelo primero):
- Deploy en tests SIEMPRE vía proxy (ERC1967Proxy + initialize), nunca la implementation directa.
- Unit: initialize (zero-checks, no re-init, implementation con initializers deshabilitados), roles (cada función con su rol, revert sin rol), flujo feliz completo requestDeposit→fulfill→claim y requestRedeem→fulfill→claim con NAV real del feed, totalAssets con NAV (subir el NAV → share price sube sin transferencias), staleness (warp más allá de MAX_STALENESS → revert), pausa parcial (requests bloqueados, claims y fulfillRedeem siguen), previews revierten.
- Fuzz (512 runs): montos de deposit/redeem con fulfills parciales — conservación: pending + claimable + claimed == solicitado; redondeo nunca a favor del usuario (property: sum de assets entregados <= sum aportado al NAV correspondiente).
- Corré 'forge test' COMPLETO y pegá el resumen real en las notas.
- Además: 'forge inspect src/RwaVault.sol:RwaVault storage-layout' > storage-layout/RwaVault.v1.txt (crear carpeta contracts/storage-layout/) — es la línea de base para el diff del upgrade en D4.
Devolvé SOLO JSON.`, {
  label: 'tests-vault', phase: 'Tests', model: 'sonnet',
  schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, storage_layout_ok: { type: 'boolean' }, toco_src: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests', 'storage_layout_ok', 'toco_src'] },
}) || {}
log(`Tests vault: ${tests.cantidad_tests || 0} (pasan: ${tests.tests_pasan})`)

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. NO confíes en reportes previos: verificá contra disco y salida real en ${ROOT}/contracts:
1. 'forge build' y 'forge test' completos: pegá el resumen REAL (X passed, Y failed).
2. Leé src/RwaVault.sol contra §3.3 y §4 de ARCHITECTURE.md. Chequeos específicos que NO podés saltear:
   - la pausa NO alcanza a fulfillRedeem ni a ningún claim,
   - shares se fijan en fulfill (no en request) y el redondeo favorece al vault,
   - staleness check presente en TODA lectura del feed,
   - initializer con zero-checks y _disableInitializers() en el constructor,
   - _authorizeUpgrade gated por UPGRADER_ROLE, __gap presente,
   - roles operativos NO otorgados al admin por defecto.
3. storage-layout/RwaVault.v1.txt existe y no está vacío.
4. git status: si todo pasa, UN commit atómico "feat: Día 2 — RwaVault ERC-7540 UUPS con NAV accounting, roles y pausa parcial" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>. Si algo falla, NO commitees y reportalo.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { build_ok: { type: 'boolean' }, tests_passed: { type: 'number' }, tests_failed: { type: 'number' }, chequeos_criticos_ok: { type: 'boolean' }, desvios: { type: 'array', items: { type: 'string' } }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['build_ok', 'tests_passed', 'tests_failed', 'chequeos_criticos_ok', 'commit_hecho'] },
}) || {}

return { vault, tests, verificacion: verif }
