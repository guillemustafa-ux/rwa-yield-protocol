# Guion Loom — RWA Yield Protocol (4-5 min)

Guion para grabar en voz propia. Frases cortas, para hablar, no para leer en cámara.
Cada bloque trae `[MOSTRAR: ...]` con lo que tiene que estar en pantalla en ese
momento — dejalo armado en pestañas antes de arrancar a grabar.

**Antes de grabar, tené abierto en pestañas (en este orden):**
1. Etherscan en `0x48c78Ffe5A882069FC81Fb866510FAAE625109C4` (el proxy), pestaña "Contract" → "Read as Proxy" si Etherscan la detecta, o directamente la pestaña de eventos/txs.
2. `ARCHITECTURE.md` §3 (el diagrama de contratos), en un editor o preview de Markdown.
3. `contracts/test/invariants/RwaVault.invariants.t.sol`, scrolleado a `test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_RevertsAfterFix`.
4. La dApp corriendo local (`npm run dev` en `dapp/`) o el deploy si lo subiste, con MetaMask en Sepolia.
5. Una terminal con `cast` a mano, por si querés correr el comando en vivo en vez de solo mostrarlo pegado.

---

## 0. Hook — el upgrade en vivo (0:00–0:30)

[MOSTRAR: Etherscan, la tx del upgrade — `0xa42a4c94f41756ec0e84986c61160c0277e0538d57aeeb313642d7fef1844594`]

Hola. Esto es un protocolo DeFi que tokeniza un T-bill y le paga rendimiento a quien
deposita. Pero no vine a mostrar eso primero.

Vine a mostrar esto: esta transacción cambió el código detrás de este contrato. En
vivo. En Sepolia. Con plata de verdad adentro —bueno, plata de testnet, pero con
depósitos reales ya hechos, de antes del upgrade—.

La dirección del contrato no cambió. El código de atrás, sí. Y todo lo que había
adentro —los depósitos, los roles, el balance— sobrevivió.

Eso es un upgrade UUPS ejecutado de verdad, no una demo de pizarrón. Te muestro cómo
funciona.

---

## 1. Mapa de contratos (0:30–1:30)

[MOSTRAR: `ARCHITECTURE.md` §3, el diagrama ASCII de contratos]

Son 3 piezas que se hablan entre sí.

Primero, `TBillToken`. Un ERC-20 común. Representa el T-bill sintético. No tiene
lógica rara a propósito: el valor no vive en el token.

El valor vive en `RwaNavFeed`. Es un oráculo. Implementa la MISMA interfaz que un feed
de Chainlink —`AggregatorV3Interface`— así que el día que exista un feed real de
T-bills, se puede enchufar sin tocar una línea del vault. Alguien —un rol
autorizado— publica el NAV. Con dos guardas: no se puede mover más de un cinco por
ciento por update, y no se puede actualizar más de una vez por hora. Eso convierte un
typo o una key robada en un incidente que se puede frenar, no en un vaciado
instantáneo.

Y el corazón: `RwaVault`. Acá es donde pasa lo interesante. No es un vault común, tipo
ERC-4626, donde el precio de la share sale del balance del contrato. Acá el precio
sale del NAV. Nadie transfiere rendimiento adentro del vault — el NAV sube, y el
precio de la share sube solo. Es contable, no es una transferencia.

Y es asíncrono: depositás, alguien con el rol de operador liquida tu pedido al precio
del momento, y después reclamás. Tres pasos, no uno. Es el estándar ERC-7540, pensado
justo para activos que no tienen liquidez instantánea — como un T-bill.

---

## 2. El hallazgo (c) — la historia (1:30–3:00)

[MOSTRAR: `test/invariants/RwaVault.invariants.t.sol`, el test invertido]

Ahora la parte que más me importa mostrar, porque es la que prueba que esto se auditó
de verdad, no que se armó y ya.

Durante la construcción corrí una campaña de invariantes. Esto es: en vez de escribir
"probá que pase esto, después esto otro" — que es lo que hace un test normal — le doy
a un fuzzer un conjunto de acciones válidas del protocolo, y le pido que las combine
al azar, miles de veces, con varios usuarios actuando en paralelo. Y después de cada
combinación, chequeo una propiedad que SIEMPRE tiene que ser cierta. Acá la propiedad
era simple: el vault siempre tiene que tener suficiente plata líquida para cubrir lo
que le debe a la gente.

Y en la primera corrida, esa propiedad se rompió.

El fuzzer encontró una secuencia — nadie la escribió a mano, la generó solo — donde el
operador liquidaba un pedido de redención, el contrato calculaba cuánto le debía a esa
persona usando el NAV... y ese cálculo no chequeaba si había plata de verdad
disponible. El holding estaba, pero en T-bill, no en efectivo. El contrato prometía
algo que no podía pagar en el momento. Y cuando la persona iba a reclamar, la
transacción revertía. Una promesa sin respaldo, en la cara del usuario.

Esto no estaba en la lista de vectores de ataque que había escrito antes de
auditar. Lo encontró la máquina, combinando acciones que por separado eran normales.

Y ahí tuve que decidir: ¿esto se resuelve con un procedimiento operativo — "che,
liquidá redenciones solo después de vender el T-bill" — o se resuelve en el contrato?

Decidí en el contrato. Porque acá la víctima es un usuario, no el protocolo. Un
procedimiento se puede olvidar. Un `require` no.

[MOSTRAR: `RwaVault.sol`, el error `InsufficientLiquidity` y el chequeo en `fulfillRedeem`]

Así que ahora `fulfillRedeem` calcula cuánta plata líquida hay disponible de verdad, y
si lo que le debería prometer a esa persona supera eso, revierte ahí mismo, con un
error explícito. La regla que antes era "acordate de hacerlo en este orden" ahora es
una regla que el contrato hace cumplir solo.

Y el test que antes demostraba el bug se dio vuelta a propósito: ahora prueba que ESE
mismo escenario, el que antes rompía la promesa, hoy revierte limpio.

Esto para mí es la auditoría de verdad: no es "no encontramos nada". Es "encontramos
algo que ni estaba en la lista, y elegimos arreglarlo en el lugar correcto".

---

## 3. Demo de la dApp (3:00–4:00)

[MOSTRAR: la dApp, wallet conectada en Sepolia]

Esto es el flujo completo, desde el lado del usuario.

[MOSTRAR: pantalla de depósito, requestDeposit]

Deposito USDC de prueba. El pedido queda pendiente — todavía no tengo shares.

[MOSTRAR: panel de admin o estado pendiente → claimable]

El operador liquida el pedido al NAV del momento. Ahí mi depósito pasa de pendiente a
reclamable.

[MOSTRAR: botón de claim, transacción confirmada]

Reclamo, y ahí sí tengo shares del vault en mi wallet.

[MOSTRAR: panel de NAV / valor de las shares]

Y acá el panel de NAV: si el operador sube el valor del T-bill, mis shares valen más,
sin que nadie me transfiera nada. Eso es todo el mecanismo de rendimiento del
protocolo, visible en una sola pantalla.

---

## 4. Cierre con números (4:00–4:30)

[MOSTRAR: README.md, tabla de direcciones, o Etherscan de nuevo]

Para cerrar, en números: 3 contratos, desplegados y verificados en Sepolia. Un upgrade
UUPS real, con estado preservado, verificable con `cast` en cinco comandos —están
todos en el README, copiables. 148 tests: unit, fuzz, invariantes multi-actor, y fork
test contra un feed real de Chainlink. Y 3 hallazgos de auditoría documentados con su
proceso completo, no solo el resultado.

Esto es lo que quería mostrar: no un contrato que compila. Un protocolo que se
auditó, se atacó a propósito, y sobrevivió un upgrade real con plata adentro.

Gracias por ver.
