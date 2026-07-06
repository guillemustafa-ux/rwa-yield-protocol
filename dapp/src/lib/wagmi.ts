import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { http } from 'viem'
import { sepolia } from 'wagmi/chains'

/**
 * Project id de WalletConnect Cloud (https://cloud.reown.com) — identifica la
 * app ante wallets que se conectan vía WalletConnect (QR/mobile). Es
 * OPCIONAL: si `VITE_WALLETCONNECT_PROJECT_ID` no está seteada, cae a un
 * placeholder y RainbowKit funciona igual con conectores inyectados
 * (MetaMask, Rabby, etc.) — solo el flujo WalletConnect/QR queda deshabilitado.
 */
const projectId: string = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || 'rwa-yield-protocol-demo'

/** RPC propio opcional (Alchemy/Infura/QuickNode); si no está, viem usa el default público de Sepolia. */
const rpcUrl = import.meta.env.VITE_SEPOLIA_RPC_URL

/**
 * Config de wagmi/RainbowKit. Sepolia es la única chain habilitada: el
 * protocolo corre exclusivamente contra los contratos deployados ahí (ver
 * `src/contracts/addresses.ts`) — no tiene sentido ofrecer mainnet u otra
 * L2 todavía (es un mock de T-bill, no custodia activos reales).
 */
export const wagmiConfig = getDefaultConfig({
  appName: 'RWA Yield Protocol',
  appDescription:
    'Protocolo RWA (T-bill sintético) — vault ERC-7540 valuado por oráculo NAV, upgradeable UUPS. Sepolia testnet.',
  projectId,
  chains: [sepolia],
  transports: rpcUrl ? { [sepolia.id]: http(rpcUrl) } : undefined,
})
