export const meta = {
  name: 'rwa-f3',
  description: 'F3 flagship RWA: Chainlink Automation (log-trigger) + CCIP cross-chain deposit',
  phases: [
    { title: 'Construcción', detail: '2 frentes: keeper de Automation / sender+receiver CCIP' },
    { title: 'Verificación', detail: 'suite completa offline + simulaciones de registro/envío' },
  ],
}

const ROOT = 'C:/Users/Cript/rwa-yield-protocol'
const CTX = `Proyecto: RWA Yield Protocol (flagship senior de Guille). Leé PRIMERO ${ROOT}/ARCHITECTURE.md §7 (F3, diseño completo ya decidido — no lo re-diseñes) y src/RwaVault.sol (getters públicos reales: pendingDepositRequest, pendingRedeemRequest, totalPendingDepositAssets, totalClaimableRedeemAssets, asset(), OPERATOR_ROLE, eventos DepositRequest/RedeemRequest con la firma exacta que ya está en el .sol).
Gotchas OBLIGATORIOS: forge por Git Bash (PATH ~/.foundry/bin, tool Bash); vm.warp(1_700_000_000) en setUp; lectura view entre vm.prank y la llamada CONSUME el prank (cachear antes — ya mordió 3 veces); NUNCA taskkill global; Solidity 0.8.24, custom errors, NatSpec.
SEGURIDAD: contracts/.env tiene PRIVATE_KEY real — JAMÁS lo leas/imprimas/copies. Para cualquier simulación usá --sender 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5 SIN clave. PROHIBIDO --broadcast: todo broadcast real (registro de upkeep, envío CCIP) lo hace la sesión principal después, y requiere LINK que hoy el deployer no tiene — no bloqueado por eso, pero no lo intentes en vivo.
NO toques src/RwaVault.sol, src/RwaVaultV2.sol ni archivos de otros agentes. Instalá deps de Chainlink con forge install (git ya configurado) si hacen falta: smartcontractkit/chainlink-brownie-contracts o smartcontractkit/chainlink-local (para CCIPLocalSimulator en tests) — dejá el remappings.txt prolijo.`

phase('Construcción')
const [keeper, ccip] = await parallel([
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: src/RwaVaultKeeper.sol, test/RwaVaultKeeper.t.sol, script/RegisterUpkeep.s.sol.

Tarea (§7.1): RwaVaultKeeper, log-trigger Automation:
- Implementá la interfaz oficial de Chainlink Automation para log-triggers (ILogAutomation: checkLog(Log calldata, bytes memory) returns (bool,bytes), performUpkeep(bytes calldata)). Instalá el paquete oficial (forge install smartcontractkit/chainlink-brownie-contracts o similar) para importar el struct Log y la interfaz reales — NO los reescribas a mano si el paquete los tiene.
- checkLog decodifica el log (topics/data) de DepositRequest o RedeemRequest (las firmas EXACTAS están en RwaVault.sol — leelas, no las inventes), y verifica de forma independiente contra el vault (getters públicos, sin modificar nada) si el request sigue pendiente y si hay buffer libre suficiente (recalculá _freeAssetBuffer equivalente desde afuera: asset().balanceOf(vault) - totalPendingDepositAssets - totalClaimableRedeemAssets — todo público). Si es seguro liquidar, upkeepNeeded=true, performData=(esAcciónDeposit, controller, monto).
- performUpkeep RE-VERIFICA lo mismo (no confíes en performData ciegamente) y recién ahí llama fulfillDeposit/fulfillRedeem. Si ya no es seguro (cambió el estado), no-op silencioso (no revert que rompa el upkeep) — documentá esta decisión en NatSpec.
- Tests: mockeá el struct Log de Chainlink (constructilo a mano con los topics/data reales de un DepositRequest emitido en un test, usando vm.recordLogs()/vm.getRecordedLogs() para capturar el log real y pasarlo a checkLog — así el test usa datos genuinos, no inventados). Escenarios: checkLog dice upkeepNeeded=true cuando corresponde y false cuando el request ya se liquidó o no hay buffer; performUpkeep liquida de verdad (fulfillDeposit real) y el usuario puede claimear después; performUpkeep no-opea (no revierte) si el estado cambió entre check y perform (ej. otro fulfill ya lo procesó, o el buffer se secó) — simulá ambos casos; el keeper necesita OPERATOR_ROLE para funcionar, test de revert si no lo tiene.
- script/RegisterUpkeep.s.sol: registro del log-trigger upkeep contra el AutomationRegistrar real de Sepolia (0xb0E49c5D0d05cbc241d68c05BC5BA1D1B7B72976) — arma el triggerConfig (filtro por dirección del vault + topic0 de DepositRequest y RedeemRequest) según la interfaz real del registrar (leé la interfaz del paquete instalado). SOLO simulación (--sender, sin --broadcast, sin clave) — necesita LINK que hoy no hay, documentá eso en un comentario al final del script. Corré 'forge test --match-path test/RwaVaultKeeper.t.sol' y pegá el resultado REAL.
Devolvé SOLO JSON.`, {
    label: 'keeper', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
  () => agent(`${CTX}

OWNERSHIP EXCLUSIVO: src/CrossChainDepositSender.sol, src/CrossChainDepositRelay.sol, test/CrossChainDeposit.t.sol, script/SendCrossChainDeposit.s.sol.

Tarea (§7.2): depósito disparado desde Arbitrum Sepolia vía CCIP (mensajería, NO token bridge real — documentado como trade-off explícito en NatSpec, ya decidido en ARCHITECTURE.md §7.2, no lo cuestiones):
- Instalá smartcontractkit/chainlink-local (trae CCIPLocalSimulator para tests offline) y/o smartcontractkit/ccip para las interfaces IRouterClient/CCIPReceiver reales — NO reescribas las interfaces a mano.
- CrossChainDepositSender.sol (pensado para deployarse en Arbitrum Sepolia): sendDeposit(address relay, uint64 destChainSelector, uint256 assets) arma un mensaje CCIP (msg.sender, assets) hacia 'relay' en la chain destino, paga fee en LINK (IRouterClient.getFee + ccipSend), revert explícito si el fee excede el LINK aprobado/disponible.
- CrossChainDepositRelay.sol (CCIPReceiver, pensado para Sepolia): _ccipReceive decodifica (controller, assets), exige que sourceChainSelector+sender estén en un allowlist (mapping owner-configurable, revert explícito si no), y ejecuta requestDeposit(assets, controller, address(this)) contra el vault usando SU PROPIO balance de DemoUSDC (necesita approve previo al vault) — si el relay no tiene balance suficiente, revert explícito y claro, no un revert genérico de ERC20.
- Tests con CCIPLocalSimulator (2 routers simulados, misma chain de test): mensaje válido → el relay termina con un requestDeposit real y verificable contra el vault (pendingDepositRequest del controller creció); mensaje de un sender NO allowlisteado → revert; relay sin balance suficiente de DemoUSDC → revert explícito; happy path completo hasta fulfillDeposit+claim usando el flujo normal del vault después de que el mensaje cruzó.
- script/SendCrossChainDeposit.s.sol: arma el envío real (Arbitrum Sepolia router 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165, LINK de Arbitrum Sepolia 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E — verificalos con cast code antes de asumirlos válidos, si no coinciden con el que devuelve el router real de Chainlink docs, buscá el correcto en el paquete instalado y USALO, no el que te doy acá si difiere). SOLO simulación, sin --broadcast, sin clave — necesita LINK en ambas chains, documentá eso. Corré 'forge test --match-path test/CrossChainDeposit.t.sol' y pegá el resultado REAL.
Devolvé SOLO JSON.`, {
    label: 'ccip', phase: 'Construcción', model: 'sonnet',
    schema: { type: 'object', properties: { tests_pasan: { type: 'boolean' }, cantidad_tests: { type: 'number' }, direcciones_verificadas: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_pasan', 'cantidad_tests'] },
  }),
])

phase('Verificación')
const verif = await agent(`${CTX}

Sos el verificador. Contra disco y salida real en ${ROOT}/contracts:
1. 'forge test' COMPLETO (todas las suites, incluidas las nuevas de keeper y CCIP): resumen REAL, X passed/Y failed.
2. Leé RwaVaultKeeper.sol: confirmá que performUpkeep RE-VERIFICA antes de actuar (no confía ciegamente en performData) y que necesita OPERATOR_ROLE real.
3. Leé CrossChainDepositRelay.sol: confirmá el allowlist de sender+chain y que un balance insuficiente da revert explícito, no genérico.
4. Verificá con 'cast code' contra el RPC de Sepolia (y si hay RPC de Arbitrum Sepolia a mano, contra esa también) que las direcciones de Chainlink usadas en los scripts tienen bytecode real — si algún agente usó una dirección inventada o de otra red, marcalo como desvío.
5. Si TODO pasa: UN commit "feat: F3 — Chainlink Automation (log-trigger keeper) + CCIP cross-chain deposit (pre-broadcast, requiere LINK)" con Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>. Si algo falla, NO commitees y detallá qué.
Devolvé SOLO JSON.`, {
  label: 'verificador', phase: 'Verificación', model: 'sonnet',
  schema: { type: 'object', properties: { tests_passed: { type: 'number' }, tests_failed: { type: 'number' }, direcciones_ok: { type: 'boolean' }, desvios: { type: 'array', items: { type: 'string' } }, commit_hecho: { type: 'boolean' }, notas: { type: 'string' } }, required: ['tests_passed', 'tests_failed', 'commit_hecho'] },
}) || {}

return { keeper: keeper || 'agente caído', ccip: ccip || 'agente caído', verificacion: verif }
