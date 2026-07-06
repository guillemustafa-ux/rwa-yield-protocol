/**
 * Decodificador de errores de tx a mensajes humanos en español.
 *
 * `useTxAction` (hooks/useTxAction.ts, NO se toca) ya normaliza el error de
 * viem/wagmi a un string (`shortMessage` o `message`). Ese string, cuando la
 * ABI se pasó al `writeContractAsync` (siempre es el caso acá), incluye el
 * NOMBRE del custom error revertido — viem lo decodifica contra la ABI antes
 * de armar el mensaje. Lo que NO se puede asumir es que incluya los valores
 * de los argumentos como texto (viem solo garantiza el nombre/firma, los
 * valores viven en `err.data.args`, no llegan hasta acá) — por eso esta
 * traducción es best-effort sobre el NOMBRE del error, sin depender de
 * parsear números del string.
 *
 * Cubre los custom errors de las 4 ABIs que esta dApp llama:
 * RwaVaultV2, RwaNavFeed, TBillToken, DemoUSDC (ARCHITECTURE.md §3, §4).
 */

type ErrorRule = {
  /** Nombre exacto del custom error tal como aparece en el ABI/Solidity. */
  name: string
  message: string
}

const RULES: ErrorRule[] = [
  // --- RwaVaultV2 ---
  {
    name: 'AccessControlUnauthorizedAccount',
    message: 'Tu wallet no tiene el rol on-chain necesario para esta acción.',
  },
  { name: 'AccessControlBadConfirmation', message: 'Confirmación de rol inválida.' },
  {
    name: 'ERC20InsufficientAllowance',
    message: 'No autorizaste (approve) fondos suficientes para esta operación.',
  },
  { name: 'ERC20InsufficientBalance', message: 'No tenés balance suficiente para esta operación.' },
  { name: 'ERC20InvalidApprover', message: 'Dirección inválida como approver del token.' },
  { name: 'ERC20InvalidReceiver', message: 'Dirección inválida como receptor del token.' },
  { name: 'ERC20InvalidSender', message: 'Dirección inválida como emisor del token.' },
  { name: 'ERC20InvalidSpender', message: 'Dirección inválida como spender del token.' },
  {
    name: 'ERC4626ExceededMaxDeposit',
    message: 'Estás pidiendo depositar/reclamar más de lo máximo permitido ahora mismo.',
  },
  { name: 'ERC4626ExceededMaxMint', message: 'Estás pidiendo mintear más shares de las máximas permitidas.' },
  { name: 'ERC4626ExceededMaxRedeem', message: 'Estás pidiendo redimir más shares de las que tenés claimable.' },
  { name: 'ERC4626ExceededMaxWithdraw', message: 'Estás pidiendo retirar más assets de los que tenés claimable.' },
  {
    name: 'EnforcedPause',
    message:
      'El vault está pausado — no se pueden crear nuevos requests de depósito/rescate ahora. Los claims y fulfills de redeem siguen abiertos.',
  },
  { name: 'ExpectedPause', message: 'Esta acción requiere que el vault esté pausado primero.' },
  { name: 'ExceedsClaimable', message: 'Estás pidiendo reclamar más de lo que tenés disponible (claimable).' },
  {
    name: 'ExceedsPending',
    message: 'Estás pidiendo fulfillear más de lo que hay pendiente para ese controller.',
  },
  { name: 'FeeTooHigh', message: 'La management fee pedida supera el máximo permitido por el contrato.' },
  {
    name: 'InsufficientFreeBuffer',
    message:
      'No hay buffer libre de USDC suficiente — ese USDC ya está comprometido con depositantes pendientes o redeems fulfilleados.',
  },
  {
    name: 'InsufficientLiquidity',
    message:
      'El vault no tiene liquidez líquida suficiente para cubrir este fulfillRedeem. Hay que devolver USDC con divestFromTBill antes de fulfillear (todo claim queda 100% respaldado por asset líquido).',
  },
  { name: 'InvalidNavAnswer', message: 'El oráculo de NAV devolvió un valor inválido (≤0).' },
  {
    name: 'StaleNav',
    message:
      'El NAV del oráculo está desactualizado (más de 24hs desde el último update) — hay que actualizarlo con updateNav antes de poder operar.',
  },
  {
    name: 'NotAuthorized',
    message: 'No estás autorizado a operar en nombre de esta cuenta (revisá controller/owner/operator).',
  },
  {
    name: 'PreviewDisabled',
    message: 'Los previews están deshabilitados en este vault (ERC-7540): el precio se fija recién en el fulfill.',
  },
  { name: 'ReentrancyGuardReentrantCall', message: 'Llamada reentrante bloqueada por el contrato.' },
  { name: 'SafeERC20FailedOperation', message: 'Falló la transferencia del token (revisá balance/allowance).' },
  { name: 'ZeroAddress', message: 'Dirección inválida (address cero).' },
  { name: 'ZeroAmount', message: 'El monto no puede ser cero.' },

  // --- RwaNavFeed ---
  { name: 'InvalidNav', message: 'El NAV debe ser mayor a cero.' },
  {
    name: 'NavDeviationTooHigh',
    message:
      'Ese NAV se desvía más del ±5% permitido por update respecto al valor anterior — hacelo en pasos más chicos.',
  },
  {
    name: 'TooFrequent',
    message: 'Todavía no pasó 1 hora desde el último update de NAV (rate-limit anti fat-finger).',
  },
  { name: 'NoDataPresent', message: 'El oráculo todavía no tiene ningún NAV publicado.' },
  { name: 'RoundNotFound', message: 'Ese round del oráculo no existe.' },

  // --- TBillToken ---
  { name: 'InsufficientBalance', message: 'No hay balance de tBILL suficiente para quemar esa cantidad.' },

  // --- DemoUSDC ---
  { name: 'FaucetCapExceeded', message: 'El faucet de DemoUSDC está capado a 10,000 dUSDC por llamada.' },
]

/**
 * Traduce el string de error ya normalizado por `useTxAction` a un mensaje
 * humano en español. Si detecta un patrón de wallet conocido (usuario
 * rechazó, sin ETH para gas) lo prioriza; si no, busca el nombre de un
 * custom error conocido en el texto; si nada matchea, devuelve el mensaje
 * original (mejor mostrar algo en inglés que nada).
 */
export function humanizeTxError(raw: string): string {
  const lower = raw.toLowerCase()

  if (lower.includes('user rejected') || lower.includes('user denied')) {
    return 'Rechazaste la transacción en tu wallet.'
  }
  if (lower.includes('insufficient funds')) {
    return 'Tu wallet no tiene ETH suficiente para pagar el gas.'
  }

  for (const rule of RULES) {
    if (raw.includes(`${rule.name}(`)) {
      return `${rule.message} (${rule.name})`
    }
  }

  return raw
}
