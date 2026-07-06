# DESIGN.md — trade-offs, self-audit, y la historia de 3 hallazgos

Este documento no repite lo que ya está en [`ARCHITECTURE.md`](./ARCHITECTURE.md) (el
diseño, decidido de antemano). Acá va lo que se decidió *bajo tensión* durante la
construcción: por qué se eligió una opción sabiendo el costo de la otra, qué encontró
la auditoría, y qué se hizo con cada hallazgo. Es el material que un revisor senior
pide cuando lee "protocolo auditado" y quiere saber si eso significa algo.

## 1. Trade-offs (con el porqué)

### 1.1 NAV accounting en vez de balance-based

Un ERC-4626 estándar valúa `totalAssets()` como el balance propio del contrato. Acá
`totalAssets()` es `tBILL.balanceOf(vault) × NAV(tBILL)` + buffer de asset libre — el
vault vale lo que dice el oráculo, no lo que tiene en el bolsillo.

**Por qué:** es la única forma de modelar el yield real de un RWA. El vault nunca tiene
"más USDC" cuando el T-bill rinde — tiene el mismo tBILL de siempre, valuado más caro.
Un accounting balance-based no tiene forma de representar eso sin que alguien
transfiera plata activamente (lo que YieldVault, la pieza anterior del portfolio, sí
hace con `distributeYield()` — acá se resolvió el problema de raíz en vez de
parchearlo).

**El costo que se acepta a cambio:** el vault ahora confía en un oráculo para saber
cuánto vale. Eso es una superficie de ataque nueva que un vault balance-based
simplemente no tiene (staleness, fat-finger, key comprometida — ver §2). Se decidió
que ese costo es correcto porque es el costo real de cualquier RWA vault que exista:
Centrifuge, Ondo, BUIDL todos dependen de un NAV publicado por alguien. Fingir que no
existe (quedarse balance-based) sería más simple pero no sería el problema que un RWA
vault real tiene que resolver.

### 1.2 `RwaVaultV2` como copia estructural, no herencia

La opción obvia para "V2 = V1 + una feature" es `contract RwaVaultV2 is RwaVault`.
Se rechazó por una razón concreta y no negociable: `RwaVault.__gap` es `private`.
Solidity fija los slots de un contrato base (sus campos Y su `__gap`) en el orden en
que se declaran; una subclase puede *agregar* slots después, pero no puede
reescribir ni angostar un gap `private` que no declaró ella misma. La única forma de
convertir 3 de esos 50 slots reservados en los campos nuevos de fee habría sido editar
`RwaVault.sol` — y el límite de ownership de esa tarea lo prohibía.

Con herencia, entonces, las dos opciones eran: (a) dejar los 50 slots del gap
permanentemente muertos y poner los campos nuevos después del slot 60 — seguro, pero
no "consume el gap" que pide §3.4 — o (b) ser estructuralmente incapaz de terminar con
un `uint256[47]` gap real. Ninguna cumple el criterio de aceptación del D4.

La copia estructural lo evita: los slots 0–10 de `RwaVaultV2` son, en el mismo orden y
tipo, los slots 0–10 de `RwaVault` (verificable con el diff commiteado en
`contracts/storage-layout/RwaVault.v1.txt` vs `RwaVault.v2.txt` — ver §3 abajo). Los
slots 11–13 son los 3 campos nuevos de fee — literalmente gastando 3 de los 50 slots
que `RwaVault` había reservado. El slot 14 abre un `uint256[47]` fresco, así que una
V3 hipotética hereda el mismo tipo de margen que V1 dejó, menos lo que V2 gastó.

**El costo que se acepta a cambio:** ~180 líneas de `RwaVault.sol` reproducidas
verbatim en `RwaVaultV2.sol` (mismo flujo request/fulfill/claim, mismo redondeo, mismos
guards). Si mañana aparece un bug en esa lógica compartida, hay que arreglarlo en dos
archivos, no en uno — el precio real de no tener una jerarquía de clases. Se acepta
porque es exactamente cómo evolucionan las releases de OpenZeppelin Upgradeable: cada
versión es un rewrite con un prefijo de storage compatible, no una cadena de subclases.
No es un atajo del proyecto — es la convención real del ecosistema.

### 1.3 `ReentrancyGuard` plano, demostrado seguro vía proxy

La versión instalada de OpenZeppelin Upgradeable (5.6.1) no incluye
`ReentrancyGuardUpgradeable`. La alternativa obvia — escribir un guard propio con
`__ReentrancyGuard_init()` — se descartó a favor del `ReentrancyGuard` plano
(`openzeppelin-contracts`, no la línea `-upgradeable`), por una razón estructural: esa
versión de OZ mueve `_status` a un slot namespaced ERC-7201 y, más importante,
`_nonReentrantBefore`/`_nonReentrantAfter` comparan el slot *solo* contra el valor
`ENTERED` — nunca contra `NOT_ENTERED` — así que un slot en cero (nunca inicializado,
porque el constructor de un contrato nunca corre en contexto delegatecall) se comporta
exactamente igual que uno inicializado. Los propios mocks de OZ (`ReentrancyMockUpgradeable`)
heredan este mismo contrato por esa razón.

**Por qué esto es un trade-off y no un hallazgo:** confiar en esa propiedad sin
demostrarla en código sería "leí la documentación de OZ y confío". El proyecto no se
quedó ahí: `test_Finding_ReentrancyGuardWorksViaProxy` y
`test_ReentrancyGuard_UninitializedProxySlot_StillBlocksReentrantCall` cargan el slot
crudo con `vm.load` ANTES de cualquier llamada (confirmando que arranca en cero, nunca
inicializado), y después arman un ERC-20 malicioso cuyo `transfer`/`transferFrom`
reentra `redeem`/`requestDeposit` a mitad de una llamada real — y confirman que
revierte con `ReentrancyGuardReentrantCall`. La garantía no descansa en "el diseño es
correcto en teoría"; descansa en un ataque real, ejecutado, bloqueado.

### 1.4 Pausa parcial, no total

`whenNotPaused` se aplica únicamente a `requestDeposit`/`requestRedeem`.
`fulfillDeposit`, `fulfillRedeem`, los 4 entry points de claim, `investInTBill`/
`divestFromTBill` y `setOperator` ignoran `paused()` por completo.

**Por qué:** una pausa total convierte a `PAUSER_ROLE` en un vector de DoS — un pauser
comprometido (o simplemente de mal juicio en un incidente) podría trabar dinero que ya
es del depositante. La regla del diseño es que pausa solo puede frenar *exposición
nueva*, nunca atrapar lo que ya está comprometido con alguien.

**El costo que se acepta a cambio:** un pause real (feed comprometido, bug descubierto
en producción) no protege contra un `fulfillRedeem` malicioso ejecutado por un
`OPERATOR_ROLE` comprometido DURANTE la pausa — esa vía sigue abierta a propósito. La
mitigación de ese escenario no vive en la pausa: vive en que `OPERATOR_ROLE` y
`PAUSER_ROLE` son llaves distintas (separación de roles, ARCHITECTURE.md §2), y —
después del hallazgo (c) — en que `fulfillRedeem` ya no puede prometer un claim sin
respaldo líquido incluso si el operador quisiera. `test_Attack_PauseIsNotExitDoS`
prueba el camino de salida completo (request antes de pausar → fulfillRedeem con la
pausa activa → claim) de punta a punta con la pausa nunca levantada.

### 1.5 Los rieles de tesorería y su trust boundary

`investInTBill`/`divestFromTBill` mueven el *asset* (USDC) hacia/desde
`ASSET_MANAGER_ROLE`, pero el vault **nunca llama `TBillToken.mint`/`burn`** — esa
autoridad vive enteramente en la instancia de `AccessControl` propia de `TBillToken`
(un `ASSET_MANAGER_ROLE` distinto, aunque el identificador hashee igual). El vault
simplemente confía, de solo lectura, en `tBillToken.balanceOf(vault)`.

**Por qué separar así:** mantiene a `RwaVault.sol` totalmente desacoplado de los
internals de `TBillToken` — la frontera de ownership entre ambos contratos queda
limpia, y el vault no necesita saber cómo se compra o vende un T-bill fuera de la
cadena, solo cuánto tBILL terminó teniendo.

**El costo que se acepta a cambio — el trust boundary real:** hay una ventana entre
"el USDC salió del vault" (`investInTBill`) y "el NAV ya refleja el tBILL comprado"
(`tBillToken.mint`, una tx separada, ejecutada por el mismo rol). Esa ventana es una
asunción de confianza aceptada y documentada sobre `ASSET_MANAGER_ROLE` — simétrica a
la que ya existe sobre `NAV_UPDATER_ROLE` en `RwaNavFeed`. No se resolvió con más
código: se resolvió con una regla operativa (`fulfillear solo con transit == 0`) y con
un test que la cuantifica en dólares. Es exactamente el hallazgo (a) de la sección 3.

## 2. Self-audit — tabla §4 de ARCHITECTURE.md mapeada a sus tests

| Vector (ARCHITECTURE.md §4) | Mitigación | Test(s) que lo prueban |
|---|---|---|
| Oracle staleness / feed muerto | `MAX_STALENESS` (24h) en el único call site de lectura (`_latestNav`); revert `StaleNav` explícito | `test_Attack_StaleOracle_BlocksFulfills`, `test_Attack_StaleOracle_AlreadyFixedBucketsStillClaim`, `test_RevertWhen_FulfillDeposit_StaleNav`, `test_RevertWhen_FulfillRedeem_StaleNav`, `test_RevertWhen_TotalAssets_StaleNav` |
| Manipulación/fat-finger del NAV | banda ±5% (`MAX_DEVIATION_BPS`) + rate limit 1h (`MIN_UPDATE_INTERVAL`) en `RwaNavFeed.updateNav` | `test_Attack_NavFatFinger_BoundedByDeviation` (un typo 10x revierte, el daño máximo aprobado es exactamente ±5%), `test_Attack_NavKeyCompromise_RateLimited` (24h de updates al límite componen ~3.24x, no un drenaje atómico) |
| Rounding 7540 (request vs fulfill) | shares se fijan en `fulfill`, no en `request`; `Math.Rounding.Floor` en ambas direcciones, ceil solo en el lado "consumido" de un claim parcial | `test_Attack_RoundingNeverFavorsUser_MicroAmounts` (1 wei, montos primos, en las 4 direcciones de claim), fuzz de 512 runs en `RwaVault.t.sol` |
| Donation/inflation attack | decimals offset (`_decimalsOffset() == 6`) + `totalAssets()` por NAV ignora transferencias directas | `test_Attack_DonationDoesNotInflateShares` (dona 1,000,000 USDC directo al vault: infla el buffer pero el donante recibe 0 shares; una donación de tBILL vía `mint` sin `investInTBill` matching, ídem) |
| Uninitialized proxy | `_disableInitializers()` en el constructor de la implementation | `test_Attack_UninitializedImplementation`, `test_RevertWhen_Implementation_InitializedDirectly` |
| Storage collision en upgrade | storage gaps + `forge inspect storage-layout` diff V1↔V2 commiteado | `contracts/storage-layout/RwaVault.v1.txt` / `RwaVault.v2.txt` (slots 0–10 idénticos, 11–13 nuevos, gap 50→47) + `test_UpgradeV1ToV2_PreservesLiveState_AcrossAllBuckets`, `test_Upgrade_SucceedsWithUpgraderRole_PreservesState` |
| Role escalation | admin separado de los roles operativos; ninguno de los 3 roles operativos puede `grantRole` ni upgradear | `test_Attack_RoleEscalation_OperativeRolesCannotGrant` |
| Pausa como DoS | pausa solo bloquea `request*`; `fulfillRedeem` y los 4 `claim*` nunca se pausan | `test_Attack_PauseIsNotExitDoS` |
| Reentrancy en claim | CEI + `nonReentrant` (guard plano, ver §1.3) en todo flujo con transferencia | `test_Finding_ReentrancyGuardWorksViaProxy`, `test_ReentrancyGuard_UninitializedProxySlot_StillBlocksReentrantCall` |
| Fulfill de redeem sin liquidez (hallazgo (c)) | `fulfillRedeem` capea por `_freeAssetBuffer()`, revert `InsufficientLiquidity` | `test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_RevertsAfterFix`, `test_RedeemLiquidityGap_MitigatedByDivestingBeforeFulfilling` |

A esto se suma la campaña de invariantes multi-actor (`test/invariants/`,
`RwaVaultHandler.sol` con 4 actores + operator + assetManager + navUpdater, 256 runs
por defecto de `foundry.toml`), que corre 5 propiedades sobre CUALQUIER secuencia
válida de acciones, no sobre un escenario elegido a mano:

- `invariant_Solvency` — balance de asset del vault ≥ pending deposits + claimable redeems reservados.
- `invariant_NavBackedValueCoversShareLiability` — valor NAV de holdings + buffer libre ≥ pasivo con depositantes.
- `invariant_PerActorConservation` — pending + claimable + claimed == solicitado, por actor, en ambos lados del ciclo.
- `invariant_SharesOnlyMintedViaFulfillDeposit` — `totalSupply()` nunca se mueve por ningún otro call site.
- `invariant_ReservedBufferNeverDecreasesViaInvest` — `investInTBill` nunca toca el buffer reservado.

Y el fork test (`test/fork/`, 8 tests) contra Sepolia real: el vault consumiendo el
feed `AggregatorV3` real de Chainlink (ETH/USD) en vez de `RwaNavFeed` propio, probando
byte-compatibilidad y el manejo de staleness con un `updatedAt` real, no simulado.

140 tests corren offline (unit + fuzz + invariants + attacks); 8 fork tests adicionales
requieren RPC real. `forge test` completo: 148 passing, 0 failing.

## 3. La historia de 3 hallazgos

Esta es la parte que un self-audit de verdad tiene que mostrar: no "no encontramos
nada" (una auditoría que no encuentra nada suele significar que no miró suficiente),
sino qué se encontró, cómo se decidió qué hacer con cada cosa, y por qué esa decisión
—no otra— fue la correcta para cada caso.

### (a) La ventana de assets-in-transit — cuantificada, no parcheada

**Qué es.** `investInTBill` saca USDC del vault para financiar una compra fuera de la
cadena. El `tBillToken.mint` que representa esa compra llega en una transacción
separada, ejecutada por el mismo `ASSET_MANAGER_ROLE`. Entre esas dos transacciones,
`totalAssets()` está momentáneamente hundido: el USDC ya no es buffer, el tBILL
todavía no existe. Si un `fulfillDeposit` cae justo en esa ventana, el nuevo
depositante se fija contra un pool que parece mucho más chico de lo que realmente vale
— se lleva de más, a costa de los depositantes existentes.

**Cómo se encontró.** Auditoría de diseño (Fable, D2), antes de escribir un solo test
adversarial — leyendo `investInTBill`/`divestFromTBill` contra la definición de
`totalAssets()` y notando que ninguna de las dos transacciones es atómica con la otra.

**Qué se hizo.** Se decidió NO resolverlo en código. `ASSET_MANAGER_ROLE` es un rol
confiable por diseño (igual que `NAV_UPDATER_ROLE`) — esto no es un exploit
permissionless, es una ventana operativa de un actor que ya tiene otras formas de
hacer daño si es malicioso. La solución fue una regla operativa —*"fulfillear solo con
transit == 0"*— documentada en el contrato y **demostrada, no solo enunciada**:
`test_Finding_AssetsInTransitWindow` cuantifica el daño exacto (Bob se lleva ~1.67x las
shares justas si se lo fulfillea durante la ventana; Alice queda diluida a menos de 1
USDC de su depósito de 1,000 en el caso límite de
`test_AssetsInTransitWindow_FulfillDuringGap_DilutesExistingDepositor`), y
`test_AssetsInTransitWindow_MitigatedByFulfillingOnlyAfterMintCompletes` prueba que
cerrar la ventana ANTES de fulfillear (sin ningún cambio de código) restaura precios
justos casi exactos (±0.01%). El runbook es la mitigación; el test es la prueba de que
el runbook alcanza.

### (b) `ReentrancyGuard` plano vía proxy — verificado, no asumido

**Qué es.** `RwaVault` usa el `ReentrancyGuard` no-upgradeable de OpenZeppelin en vez
de una versión propia con inicializador, apoyado en que esa versión de OZ solo compara
el slot contra `ENTERED` (nunca contra `NOT_ENTERED`), así que un slot en cero se
comporta como uno inicializado.

**Cómo se encontró (bueno, cómo se marcó para revisar).** Auditoría de diseño (Fable,
D2): la elección técnica era correcta sobre el papel, pero "es correcta sobre el
papel" no es un estándar aceptable para algo que protege cada `redeem`/`withdraw` del
protocolo. Se pidió una prueba activa, no una relectura de la documentación de OZ.

**Qué se hizo.** `test_Finding_ReentrancyGuardWorksViaProxy` (en
`test/attacks/RwaVault.attacks.t.sol`) y
`test_ReentrancyGuard_UninitializedProxySlot_StillBlocksReentrantCall` (en
`test/invariants/RwaVault.invariants.t.sol`) leen el slot crudo vía `vm.load` antes de
cualquier interacción (confirmando cero, nunca escrito), ejecutan una llamada normal
para confirmar que el slot en cero no rompe nada, y después arman un ERC-20 malicioso
cuyo `transfer` (uno) y `transferFrom` (el otro) intentan reentrar `redeem` /
`requestDeposit` a mitad de la propia llamada — y confirman `revert
ReentrancyGuardReentrantCall`. No fue un hallazgo que exigiera un cambio: fue una
afirmación de diseño que se convirtió en una garantía demostrada.

### (c) El gap de liquidez en `fulfillRedeem` — encontrado por la campaña de invariantes, arreglado on-chain

**Qué es.** `fulfillRedeem` fijaba un claim valuado por NAV (`convertToAssets(shares)`)
contra los holdings de tBILL — sin chequear si el vault tenía USDC líquido para
cubrirlo. Si el operador fulfilleaba un redeem después de que el `ASSET_MANAGER` había
invertido todo el buffer libre en tBILL, el claim se registraba igual, y el `redeem()`
posterior del usuario revertía por `ERC20InsufficientBalance` — una promesa on-chain
sin respaldo, en la cara de la persona equivocada.

**Cómo se encontró.** Esta es la diferencia real con (a) y (b): nadie lo pidió en la
auditoría de diseño ni estaba en la tabla §4 original. Lo encontró la propia campaña
de invariantes multi-actor del D3, en su primera corrida: `invariant_Solvency` falló —
el handler, ejecutando una secuencia aleatoria válida de deposit/invest/redeem/fulfill
entre 4 actores, llegó a un estado donde el vault le debía a los claimants más asset
líquido del que tenía. Es exactamente para esto que se corre una campaña de
invariantes en vez de conformarse con la lista de vectores conocidos: el fuzzer no
tiene el sesgo de "qué se me ocurrió pensar" que tiene un humano escribiendo tests a
mano.

**Qué se hizo — y por qué distinto de (a).** (a) es una ventana sobre un rol confiable:
la víctima potencial, en el peor caso, es el pool compartido, y el actor que puede
causarlo es el mismo que ya controla el treasury. Acá la víctima es un **usuario**
con un claim que el contrato le prometió y no puede cumplir — ese es el estándar más
alto, y ahí sí se decidió el fix on-chain en vez de un runbook: `fulfillRedeem` ahora
calcula `_freeAssetBuffer()` (el mismo buffer que ya usa `investInTBill`, que descuenta
depósitos pendientes y claims de redeem previos) y revierte con
`InsufficientLiquidity(requested, available)` si el claim pedido lo excede. La regla
operativa real de los vaults RWA — *"divest primero, fulfill después"* — dejó de ser
un procedimiento a seguir y pasó a ser una regla que el contrato hace cumplir.

El test que originalmente demostraba el bug (`fulfillRedeem` aceptando un claim de
1,000 USDC contra un vault con 0 USDC líquido) se invirtió a propósito después del fix
para fijar el comportamiento nuevo:
`test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_RevertsAfterFix` ahora confirma que
ESE MISMO escenario revierte con `InsufficientLiquidity(1_000e6, 0)`, y
`test_RedeemLiquidityGap_MitigatedByDivestingBeforeFulfilling` confirma que divestear
antes de fulfillear (la regla operativa, ahora forzada) deja al claim 100% respaldado.
Commit: `77a01b5` — `fix!: hallazgo (c) de la campaña de invariantes — fulfillRedeem
capea por liquidez`. 126/126 tests en el momento del fix (140/140 hoy, con los
agregados posteriores del D4/D5).

**La lección que deja, en una frase:** una tabla de vectores conocidos (§4) es
necesaria pero no alcanza — el vector que terminó siendo un fix real (no una nota de
runbook) fue el que ni siquiera estaba en la lista antes de que el fuzzer lo
encontrara.
