/**
 * Direcciones de contratos deployados en Sepolia.
 *
 * Hardcodeadas a propósito (mismo patrón que PULSO): el JSON de origen
 * (`contracts/deployments/sepolia.json`) vive fuera de `dapp/` y Vite solo
 * empaqueta lo que está dentro del root del proyecto. Si se re-deploya o
 * upgradea algún contrato, copiar los valores nuevos desde ese JSON acá.
 *
 * Fuente: contracts/deployments/sepolia.json (deployedAt 2026-07-06,
 * deployBlock 11217752).
 *
 * `RwaVaultProxy` es LA dirección del protocolo: sobrevivió el upgrade
 * UUPS V1→V2 sin cambiar (ERC1967Proxy). El código que corre detrás del
 * proxy hoy es `RwaVaultV2` — por eso el frontend usa el ABI de V2 contra
 * esta misma dirección. `RwaVaultImplementationV1` y
 * `RwaVaultImplementationV2` quedan documentadas para linkear a Etherscan
 * (verificación de bytecode / diff de storage layout), no se llaman nunca
 * directo desde la dApp.
 */
export const CHAIN_ID = 11_155_111

export const BLOCK_EXPLORER_URL = 'https://sepolia.etherscan.io'

export const CONTRACT_ADDRESSES = {
  DemoUSDC: '0x6E48f460b802F3777C5aC4339899EcA071Acd721',
  TBillToken: '0xa68C7381e4B0f539659f57b2a140B858828e2321',
  RwaNavFeed: '0x8805250663BAE305b3891A11Ca888200EdB161d7',
  RwaVaultImplementationV1: '0xC5EF4730F4A50e0b5cfbBF9ECf3Bb7dD41A5971E',
  RwaVaultProxy: '0x48c78Ffe5A882069FC81Fb866510FAAE625109C4',
  RwaVaultImplementationV2: '0x9f19d8Ca2C42Cff754500227f677B8AD81Be2b23',
} as const satisfies Record<string, `0x${string}`>

/** La dirección "viva" del vault — SIEMPRE el proxy, nunca una implementation. */
export const VAULT_ADDRESS = CONTRACT_ADDRESSES.RwaVaultProxy

/** Tx del upgrade UUPS V1→V2 ejecutado en vivo sobre el proxy (estado preservado). */
export const LIVE_UPGRADE_TX_HASH =
  '0xa1fe2ef0ab9eab7820aecfe9f4d2eb2ce8e297eb0bea04e6bd4a17effca2bf1a'

export const LIVE_UPGRADE_FEE_BPS = 100

/** Contratos a listar en el footer, en orden de lectura del mapa de arquitectura. */
export const FOOTER_CONTRACTS: Array<{ label: string; address: `0x${string}` }> = [
  { label: 'RWA Vault (proxy)', address: CONTRACT_ADDRESSES.RwaVaultProxy },
  { label: 'Vault implementation V2', address: CONTRACT_ADDRESSES.RwaVaultImplementationV2 },
  { label: 'Vault implementation V1', address: CONTRACT_ADDRESSES.RwaVaultImplementationV1 },
  { label: 'RWA NAV Feed', address: CONTRACT_ADDRESSES.RwaNavFeed },
  { label: 'tBILL Token', address: CONTRACT_ADDRESSES.TBillToken },
  { label: 'Demo USDC', address: CONTRACT_ADDRESSES.DemoUSDC },
]

/** Link a Etherscan (Sepolia) para una tx confirmada. */
export function etherscanTxUrl(hash: string): string {
  return `${BLOCK_EXPLORER_URL}/tx/${hash}`
}

/** Link a Etherscan (Sepolia) para una address (contrato o wallet). */
export function etherscanAddressUrl(address: string): string {
  return `${BLOCK_EXPLORER_URL}/address/${address}`
}

/**
 * F3 — activación en vivo de Chainlink Automation (log-trigger keeper) + CCIP
 * cross-chain deposit (2026-07-07). Todos los valores salen de
 * `contracts/deployments/sepolia.json` → `f3LiveActivation`. Hardcodeados por
 * el mismo motivo que el resto de este archivo (Vite solo empaqueta lo que vive
 * dentro de `dapp/`).
 *
 * El diseño es CCIP *messaging*, no un token bridge: el mensaje cross-chain
 * lleva solo `(controller, assets)`; el relay gasta su propio balance de dUSDC
 * pre-fondeado para llamar `requestDeposit` en el vault. Trade-off documentado
 * a propósito (ARCHITECTURE.md §7.2), no un bug.
 */
export const ARBISCAN_SEPOLIA_URL = 'https://sepolia.arbiscan.io'

export const F3 = {
  /** Keeper con OPERATOR_ROLE en el proxy (log-trigger Automation). Sepolia. */
  keeper: '0xA260e5614f85573baC7Ab83487Fa8425db007E25',
  /** Recibe el mensaje CCIP y dispara requestDeposit con su propio dUSDC. Sepolia. */
  relay: '0xDC5C24Ff3c0B474BB915133D18Cb5506d55554B6',
  /** Origina el mensaje CCIP. Vive en Arbitrum Sepolia (otra chain). */
  sender: '0xdC8530184b633Dca44A0e8C48C394Fb670Ac921f',
  /** Registrar de Automation 2.1.0 usado para dar de alta los upkeeps. Sepolia. */
  registrar: '0xb0E49c5D0d05cbc241d68c05BC5BA1d1B7B72976',
  /** IDs de los dos upkeeps log-trigger registrados, fondeados y auto-aprobados. */
  depositUpkeepId: '112595769480916896494387911308636691735539928830243869910881690145514775005662',
  redeemUpkeepId: '108129696599815390181158521457433630849823665853314984103586117881783981574404',
  /** El mensaje CCIP real: Arbitrum Sepolia → Sepolia, 50 dUSDC. */
  ccipMessageId: '0x760fcda38ac717d7a01960cf839bf36ca8a788358f9d45580067a36e90ea982c',
  ccipAssets: '50 dUSDC',
  ccipDeliveryTime: '~22 min',
  /** Cierre del ciclo: performUpkeep manual (permissionless) + claim de shares. */
  manualPerformUpkeepTx: '0xad71a503f9de153a1a0fdfee356db58d595be389dd309812567bb620b1cea20d',
  claimDepositTx: '0x2ffb764fb3bf8213672202107ed201bd84f20a8fd5b9ba7476bcc37eaf998831',
} as const

/** Link al explorador de CCIP para un messageId (traza el mensaje cross-chain end-to-end). */
export function ccipMessageUrl(messageId: string): string {
  return `https://ccip.chain.link/msg/${messageId}`
}

/** Link a Arbiscan (Arbitrum Sepolia) para una address — el sender vive en esa chain. */
export function arbiscanAddressUrl(address: string): string {
  return `${ARBISCAN_SEPOLIA_URL}/address/${address}`
}
