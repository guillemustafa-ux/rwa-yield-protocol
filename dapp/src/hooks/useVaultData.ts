import { useAccount, useReadContracts } from 'wagmi'
import { CONTRACT_ADDRESSES, VAULT_ADDRESS } from '../contracts/addresses'
import { RwaVaultV2Abi } from '../contracts/abis/RwaVaultV2'
import { RwaNavFeedAbi } from '../contracts/abis/RwaNavFeed'
import { DemoUSDCAbi } from '../contracts/abis/DemoUSDC'

const NAV_FEED_ADDRESS = CONTRACT_ADDRESSES.RwaNavFeed
const ASSET_ADDRESS = CONTRACT_ADDRESSES.DemoUSDC

/**
 * Snapshot on-chain del vault vía multicall (3 tandas, cada una su propio
 * `useReadContracts`):
 *
 *  A. Datos "estáticos" del protocolo — no dependen de nada más y siempre se
 *     piden, haya o no wallet conectada (son los que alimentan el hero de
 *     stats vivas en Home).
 *  B. `sharePrice` — depende de `shareDecimals` (tanda A), así que se pide
 *     recién cuando esa lectura llegó (evita hardcodear la fórmula de
 *     conversión de shares del ERC-4626/7540: se le pregunta al contrato).
 *  C. Datos del usuario conectado (`controller` = su address) — SOLO se
 *     piden si hay wallet conectada (`enabled`). Importante: cuando no hay
 *     wallet, estos campos quedan `undefined` (no `0n`) — igual que la
 *     lección de `allowance` en PULSO, "no leído todavía" y "leyó cero" son
 *     estados distintos y la UI no debe confundirlos.
 */
export function useVaultData() {
  const { address } = useAccount()

  const protocolReads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'totalAssets' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'totalSupply' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'decimals' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'managementFeeBps' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'totalPendingDepositAssets' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'totalClaimableRedeemAssets' },
      { address: ASSET_ADDRESS, abi: DemoUSDCAbi, functionName: 'decimals' },
      { address: NAV_FEED_ADDRESS, abi: RwaNavFeedAbi, functionName: 'latestRoundData' },
      { address: NAV_FEED_ADDRESS, abi: RwaNavFeedAbi, functionName: 'decimals' },
    ],
    query: { refetchInterval: 20_000 },
  })

  const [
    totalAssetsRead,
    totalSupplyRead,
    shareDecimalsRead,
    managementFeeBpsRead,
    totalPendingDepositAssetsRead,
    totalClaimableRedeemAssetsRead,
    assetDecimalsRead,
    latestRoundDataRead,
    navDecimalsRead,
  ] = protocolReads.data ?? []

  const shareDecimals = shareDecimalsRead?.status === 'success' ? shareDecimalsRead.result : undefined

  const sharePriceReads = useReadContracts({
    contracts: [
      {
        address: VAULT_ADDRESS,
        abi: RwaVaultV2Abi,
        functionName: 'convertToAssets',
        args: [10n ** BigInt(shareDecimals ?? 0)],
      },
    ],
    query: { enabled: shareDecimals !== undefined, refetchInterval: 20_000 },
  })
  const [sharePriceRead] = sharePriceReads.data ?? []

  const userReads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'balanceOf', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'pendingDeposit', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'pendingRedeem', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'claimableDepositAssets', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'claimableDepositShares', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'claimableRedeemAssets', args: [address!] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'claimableRedeemShares', args: [address!] },
    ],
    query: { enabled: address !== undefined, refetchInterval: 20_000 },
  })
  const [
    userSharesRead,
    userPendingDepositRead,
    userPendingRedeemRead,
    userClaimableDepositAssetsRead,
    userClaimableDepositSharesRead,
    userClaimableRedeemAssetsRead,
    userClaimableRedeemSharesRead,
  ] = userReads.data ?? []

  /** Helper: solo devuelve el valor si el read efectivamente resolvió; si no, `undefined` ("todavía no sé", no "es cero"). */
  function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
    return r && r.status === 'success' ? r.result : undefined
  }

  const navRoundData = ok(latestRoundDataRead) as
    | readonly [bigint, bigint, bigint, bigint, bigint]
    | undefined

  return {
    isLoading: protocolReads.isLoading,
    isError: protocolReads.isError,
    refetch: () => {
      void protocolReads.refetch()
      void sharePriceReads.refetch()
      void userReads.refetch()
    },

    // decimales (para formatear todo lo demás)
    assetDecimals: ok(assetDecimalsRead),
    shareDecimals,
    navDecimals: ok(navDecimalsRead),

    // protocolo
    totalAssets: ok(totalAssetsRead),
    totalSupply: ok(totalSupplyRead),
    sharePrice: ok(sharePriceRead),
    managementFeeBps: ok(managementFeeBpsRead),
    totalPendingDepositAssets: ok(totalPendingDepositAssetsRead),
    totalClaimableRedeemAssets: ok(totalClaimableRedeemAssetsRead),

    // NAV vigente del oráculo (RwaNavFeed, interfaz AggregatorV3 estilo Chainlink)
    navAnswer: navRoundData?.[1],
    navUpdatedAt: navRoundData?.[3],

    // datos del usuario conectado — `undefined` si no hay wallet, NUNCA `0n` por default
    userShares: ok(userSharesRead),
    userPendingDeposit: ok(userPendingDepositRead),
    userPendingRedeem: ok(userPendingRedeemRead),
    userClaimableDepositAssets: ok(userClaimableDepositAssetsRead),
    userClaimableDepositShares: ok(userClaimableDepositSharesRead),
    userClaimableRedeemAssets: ok(userClaimableRedeemAssetsRead),
    userClaimableRedeemShares: ok(userClaimableRedeemSharesRead),
  }
}
