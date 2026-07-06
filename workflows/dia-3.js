export const meta = {
  name: 'rwa-dia-3',
  description: 'D3 flagship RWA: suite adversarial — invariants multi-actor, fork test Sepolia, tests de ataque por vector',
  phases: [
    { title: 'Adversarial', detail: '3 frentes en paralelo: invariants / fork test / vectores de ataque' },
    { title: 'Verificación', detail: 'forge test completo + revisión de hallazgos contra §4' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol (flagship senior de Guille). Leé PRIMERO ${ROOT}/ARCHITECTURE.md (§3 diseño, §4 superficie de ataque, §5 vara) y DESPUÉS src/RwaVault.sol completo (646 líneas, el NatSpec documenta decisiones).
Gotchas OBLIGATORIOS: forge por Git Bash (PATH ~/.foundry/bin, tool Bash); vm.warp(1_700_000_000) en setUp; una lectura view entre vm.prank y la llamada CONSUME el prank (cachear role hashes antes — ya mordió 3 veces); deploy SIEMPRE vía ERC1967Proxy + initialize; NUNCA taskkill global. Solidity 0.8.24, custom errors, NatSpec.
NO toques src/ salvo bug demostrado con un test que falla (documentalo en notas). NO toques archivos de otros agentes.
HALLAZGOS de la auditoría Fable del D2 a cubrir donde corresponda:
(a) VENTANA ASSETS-IN-TRANSIT: investInTBill saca USDC y totalAssets() cae hasta que el manager mintea el tBILL equivalente — share price baja en esa ventana; fulfills en el medio dan shares de más / assets de menos a quien corresponde. Es rol confiable, pero hay que CUANTIFICARLO con un test con nombre explícito y documentar la mitigación operativa (fulfillear solo con transit=0) o proponer contador assetsInTransit.
(b) RwaVault usa ReentrancyGuard PLANO (no upgradeable) — el agente del D2 lo justificó (solo compara contra sentinel ENTERED, no depende del constructor); hay que DEMOSTRARLO con test (nonReentrant funciona vía proxy sin inicializar ese slot) y confirmar que _status figura en storage-layout/RwaVault.v1.txt.`

phase('Adversarial')
const [inv, fork, atk] = await parallel([
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: test/invariants/ (RwaVaultHandler.sol + RwaVault.invariants.t.sol).

Tarea: invariant testing multi-actor del vault completo:
- Handler con ≥3 actores + operator + assetManager + navUpdater: requestDeposit/requestRedeem/fulfill parciales/claims parciales/setOperator/investInTBill+mint tBILL equivalente/divest/updateNav dentro de banda/warp acotado (nunca > MAX_STALENESS para no bloquear el run).
- Invariantes mínimos (§5): (1) SOLVENCIA: balance de asset del vault >= totalPendingDepositAssets + totalClaimableRedeemAssets; (2) valor NAV de holdings + buffer libre >= pasivo con depositantes (shares outstanding valuadas); (3) conservación por actor: pending+claimable+claimed == solicitado; (4) shares nunca gratis: totalSupply crece solo vía fulfillDeposit; (5) el buffer reservado NUNCA baja por investInTBill.
- ghost variables en el handler para los agregados. 256+ runs, depth default.
Corré 'forge test --match-path "test/invariants/*"' y pegá el resumen REAL. Devolvé SOLO JSON.`, {
    label: 'invariants', phase: 'Adversarial', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, invariantes: { type: 'number' }, hallazgos: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['tests_pasan', 'invariantes'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: test/fork/RwaVault.fork.t.sol.

Tarea: fork test contra Sepolia REAL (§5): el vault consumiendo un AggregatorV3 verdadero de Chainlink.
- RPC: usá https://ethereum-sepolia-rpc.publicnode.com (público). vm.createSelectFork dentro del test; si el RPC falla, probá https://rpc.sepolia.org. Marcá los tests para que se salteen limpio (vm.skip o early return con log) si no hay red — el suite NUNCA debe romper offline.
- Feed real: ETH/USD Sepolia 0x694AA1769357215DE4FAC081bf1f309aDC325306. Deployá el vault en el fork apuntando navFeed a ESE feed real: verificá que _latestNav lo consume igual que a RwaNavFeed (misma interfaz — el claim central de §3.2), que decimals()==8, y el manejo de staleness con el updatedAt REAL del feed (si el feed real está stale >24h, el vault revierte — testeá ambos lados warpeando).
- Un test más: RwaNavFeed propio deployado en el fork responde byte-compatible (latestRoundData) vs el feed real.
Corré 'forge test --match-path "test/fork/*"' y pegá el resumen REAL. Devolvé SOLO JSON.`, {
    label: 'fork-sepolia', phase: 'Adversarial', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, rpc_uso: { type: 'string' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: test/attacks/RwaVault.attacks.t.sol.

Tarea: un test con nombre explícito por cada vector de la tabla §4 de ARCHITECTURE.md, más los 2 hallazgos Fable:
- test_Attack_StaleOracle_BlocksFulfills (feed muerto 24h+ → fulfills revierten, claims de buckets ya fijados siguen).
- test_Attack_NavFatFinger_BoundedByDeviation (update 10x revierte; el daño máximo por update es 5%).
- test_Attack_NavKeyCompromise_RateLimited (atacante con NAV_UPDATER: mover el NAV al máximo cada hora → cuantificar el drift máximo en 24h con asserts).
- test_Attack_DonationDoesNotInflateShares (donar USDC al vault: totalAssets sube (buffer) pero fulfillDeposit posterior no regala shares — cuantificar; donar tBILL: idem vía NAV).
- test_Attack_RoundingNeverFavorsUser_MicroAmounts (secuencias de 1 wei / montos primos en request/fulfill/claim).
- test_Attack_UninitializedImplementation (implementation sin proxy: initialize revierte, funciones críticas inoperantes).
- test_Attack_RoleEscalation_OperativeRolesCannotGrant (OPERATOR/PAUSER/ASSET_MANAGER no pueden grantRole ni upgradear).
- test_Attack_PauseIsNotExitDoS (pausado: TODO el camino de salida request-ya-hecho→fulfillRedeem→withdraw sigue vivo).
- test_Finding_AssetsInTransitWindow (hallazgo (a): cuantificar la caída de share price entre invest y mint del tBILL, y demostrar la mitigación operativa).
- test_Finding_ReentrancyGuardWorksViaProxy (hallazgo (b): nonReentrant activo vía proxy con _status jamás inicializado; incluí un mock reentrante que ataca claim y es bloqueado).
Corré 'forge test --match-path "test/attacks/*"' y pegá el resumen REAL. Devolvé SOLO JSON.`, {
    label: 'attack-vectors', phase: 'Adversarial', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, hallazgos: { type: 'array', items: { type: 'string' } }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
])

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. Contra disco y salida real en ${ROOT}/contracts:
1. 'forge test' COMPLETO (todas las suites, incluidas invariants; los fork tests pueden saltearse si no hay red — anotalo): pegá el resumen REAL.
2. Cada vector de §4 tiene su test con nombre explícito en test/attacks/ — listá el mapeo vector→test y cualquier vector SIN cubrir.
3. Los 2 hallazgos Fable (assets-in-transit y ReentrancyGuard vía proxy) tienen test y conclusión documentada.
4. Si un agente tocó src/, revisá el diff y validá que el test que lo justifica falla sin el fix.
5. Si todo pasa: UN commit "test: Día 3 — suite adversarial (invariants multi-actor, fork Sepolia, vectores de ataque §4)" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>. Si algo falla, NO commitees.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { tests_passed: { type: 'number' }, tests_failed: { type: 'number' }, vectores_sin_cubrir: { type: 'array', items: { type: 'string' } }, src_tocado: { type: 'boolean' }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_passed', 'tests_failed', 'commit_hecho'] },
}) || {}

return { invariants: inv || 'agente caído', fork: fork || 'agente caído', attacks: atk || 'agente caído', verificacion: verif }
