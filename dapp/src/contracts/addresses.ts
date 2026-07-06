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
