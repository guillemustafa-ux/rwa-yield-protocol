import type { JSX } from 'react'
import { keccak256, toBytes } from 'viem'
import { useAccount, useReadContracts } from 'wagmi'
import { useVaultData } from '../hooks/useVaultData'
import { StatCard } from '../components/ui/StatCard'
import { DepositFlow } from '../components/vault/DepositFlow'
import { RedeemFlow } from '../components/vault/RedeemFlow'
import { NavSidePanel } from '../components/vault/NavSidePanel'
import { ProtocolMechanicsPanel } from '../components/vault/ProtocolMechanicsPanel'
import { CONTRACT_ADDRESSES, F3, VAULT_ADDRESS } from '../contracts/addresses'
import { RwaVaultV2Abi } from '../contracts/abis/RwaVaultV2'
import { DemoUSDCAbi } from '../contracts/abis/DemoUSDC'
import { formatTokenAmount } from '../lib/format'

const ASSET_ADDRESS = CONTRACT_ADDRESSES.DemoUSDC
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const

/** `keccak256("OPERATOR_ROLE")` — el identificador del rol tal como lo define el contrato. */
const OPERATOR_ROLE = keccak256(toBytes('OPERATOR_ROLE'))

/** Devuelve el valor de un read de `useReadContracts` solo si resolvió OK — `undefined` si no. */
function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
  return r && r.status === 'success' ? r.result : undefined
}

/**
 * Flujo completo request → pending → claimable → claim (deposit y redeem,
 * ERC-7540) + panel lateral de NAV/share price/shares (ARCHITECTURE.md §3.3,
 * tarea D5 de la dApp). `useVaultData` (hooks/, no se toca) ya trae la mayor
 * parte de los reads; acá se completan los que esa página en particular
 * necesita y que el scaffold no anticipó (balance/allowance del usuario
 * sobre DemoUSDC, cap del faucet, MAX_STALENESS real, valor de las shares).
 */
export function Vault(): JSX.Element {
  const { address } = useAccount()
  const vaultData = useVaultData()

  const staticReads = useReadContracts({
    contracts: [
      { address: ASSET_ADDRESS, abi: DemoUSDCAbi, functionName: 'FAUCET_CAP' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'MAX_STALENESS' },
    ],
  })
  const [faucetCapRead, maxStalenessRead] = staticReads.data ?? []

  const userAssetReads = useReadContracts({
    contracts: [
      { address: ASSET_ADDRESS, abi: DemoUSDCAbi, functionName: 'balanceOf', args: [address ?? ZERO_ADDRESS] },
      {
        address: ASSET_ADDRESS,
        abi: DemoUSDCAbi,
        functionName: 'allowance',
        args: [address ?? ZERO_ADDRESS, VAULT_ADDRESS],
      },
    ],
    query: { enabled: address !== undefined, refetchInterval: 15_000 },
  })
  const [userAssetBalanceRead, userAllowanceRead] = userAssetReads.data ?? []

  const shareValueReads = useReadContracts({
    contracts: [
      {
        address: VAULT_ADDRESS,
        abi: RwaVaultV2Abi,
        functionName: 'convertToAssets',
        args: [vaultData.userShares ?? 0n],
      },
    ],
    query: { enabled: vaultData.userShares !== undefined, refetchInterval: 20_000 },
  })
  const [userSharesValueRead] = shareValueReads.data ?? []

  // Mecánicas del protocolo que el flujo request→claim no muestra: fee V2 +
  // confirmación on-chain de que el keeper del F3 tiene OPERATOR_ROLE cableado.
  const mechanicsReads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'feeRecipient' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'lastFeeAccrual' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'MAX_FEE_BPS' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'hasRole', args: [OPERATOR_ROLE, F3.keeper] },
    ],
    query: { refetchInterval: 20_000 },
  })
  const [feeRecipientRead, lastFeeAccrualRead, maxFeeBpsRead, keeperHasRoleRead] = mechanicsReads.data ?? []

  function refetchAll(): void {
    vaultData.refetch()
    void staticReads.refetch()
    void userAssetReads.refetch()
    void shareValueReads.refetch()
    void mechanicsReads.refetch()
  }

  const isLoading = vaultData.isLoading

  return (
    <div className="flex flex-col gap-8">
      <div>
        <h1 className="text-2xl font-semibold text-text-primary">Vault</h1>
        <p className="mt-1 text-sm text-text-secondary">
          Depósito y rescate ERC-7540: request → fulfillment (operador) → claim. Ver panel lateral para el NAV
          vigente y el share price.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="Tus shares"
          isLoading={isLoading}
          value={
            vaultData.userShares !== undefined && vaultData.shareDecimals !== undefined
              ? formatTokenAmount(vaultData.userShares, vaultData.shareDecimals, 4)
              : '— (conectá tu wallet)'
          }
        />
        <StatCard
          label="Depósito pendiente"
          isLoading={isLoading}
          value={
            vaultData.userPendingDeposit !== undefined && vaultData.assetDecimals !== undefined
              ? `$${formatTokenAmount(vaultData.userPendingDeposit, vaultData.assetDecimals)}`
              : '—'
          }
        />
        <StatCard
          label="Redeem pendiente"
          isLoading={isLoading}
          value={
            vaultData.userPendingRedeem !== undefined && vaultData.shareDecimals !== undefined
              ? formatTokenAmount(vaultData.userPendingRedeem, vaultData.shareDecimals, 4)
              : '—'
          }
        />
        <StatCard
          label="Claimable"
          isLoading={isLoading}
          value={
            vaultData.userClaimableDepositAssets !== undefined &&
            vaultData.userClaimableRedeemAssets !== undefined &&
            vaultData.assetDecimals !== undefined
              ? `$${formatTokenAmount(
                  vaultData.userClaimableDepositAssets + vaultData.userClaimableRedeemAssets,
                  vaultData.assetDecimals,
                )}`
              : '—'
          }
          hint="depósito + redeem, en assets"
        />
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="flex flex-col gap-6">
          <DepositFlow
            address={address}
            faucetCap={ok(faucetCapRead)}
            assetDecimals={vaultData.assetDecimals}
            userAssetBalance={ok(userAssetBalanceRead)}
            userAllowance={ok(userAllowanceRead)}
            userPendingDeposit={vaultData.userPendingDeposit}
            userClaimableDepositAssets={vaultData.userClaimableDepositAssets}
            onChanged={refetchAll}
          />
          <RedeemFlow
            address={address}
            shareDecimals={vaultData.shareDecimals}
            assetDecimals={vaultData.assetDecimals}
            userShares={vaultData.userShares}
            userPendingRedeem={vaultData.userPendingRedeem}
            userClaimableRedeemShares={vaultData.userClaimableRedeemShares}
            userClaimableRedeemAssets={vaultData.userClaimableRedeemAssets}
            onChanged={refetchAll}
          />
        </div>

        <NavSidePanel
          isLoading={isLoading}
          navAnswer={vaultData.navAnswer}
          navDecimals={vaultData.navDecimals}
          navUpdatedAt={vaultData.navUpdatedAt}
          maxStalenessSeconds={ok(maxStalenessRead)}
          sharePrice={vaultData.sharePrice}
          assetDecimals={vaultData.assetDecimals}
          userShares={vaultData.userShares}
          shareDecimals={vaultData.shareDecimals}
          userSharesValueAssets={ok(userSharesValueRead)}
        />
      </div>

      <ProtocolMechanicsPanel
        managementFeeBps={vaultData.managementFeeBps}
        maxFeeBps={ok(maxFeeBpsRead)}
        feeRecipient={ok(feeRecipientRead)}
        lastFeeAccrual={ok(lastFeeAccrualRead)}
        totalAssets={vaultData.totalAssets}
        assetDecimals={vaultData.assetDecimals}
        keeperHasOperatorRole={ok(keeperHasRoleRead)}
        onAccrued={refetchAll}
      />
    </div>
  )
}
