import type { JSX } from 'react'
import { useReadContract } from 'wagmi'
import { useVaultData } from '../hooks/useVaultData'
import { StatCard } from '../components/ui/StatCard'
import { CONTRACT_ADDRESSES, VAULT_ADDRESS } from '../contracts/addresses'
import { DemoUSDCAbi } from '../contracts/abis/DemoUSDC'
import { formatTokenAmount } from '../lib/format'
import { useAdminRoles } from '../components/admin/useAdminRoles'
import { RolesOverview } from '../components/admin/RolesOverview'
import { ControllerQueue } from '../components/admin/ControllerQueue'
import { CustodyPanel } from '../components/admin/CustodyPanel'
import { NavUpdatePanel } from '../components/admin/NavUpdatePanel'
import { PausePanel } from '../components/admin/PausePanel'
import { FeePanel } from '../components/admin/FeePanel'

const ASSET_ADDRESS = CONTRACT_ADDRESSES.DemoUSDC

/**
 * Panel operativo — cada sección se gatea con `hasRole` LEÍDO ON-CHAIN
 * (`useAdminRoles`), nunca por convención de UI. Sin ningún rol, la wallet
 * solo ve la tabla de roles (transparencia) y ninguna acción.
 */
export function Admin(): JSX.Element {
  const vaultData = useVaultData()
  const roles = useAdminRoles()

  // `_freeAssetBuffer()` (RwaVault.sol) es interna — se recalcula acá con
  // los mismos 3 públicos que usa el contrato: balance de dUSDC del vault
  // menos lo pendiente de depósito menos lo ya fulfilleado de redeem.
  const vaultAssetBalanceRead = useReadContract({
    address: ASSET_ADDRESS,
    abi: DemoUSDCAbi,
    functionName: 'balanceOf',
    args: [VAULT_ADDRESS],
    query: { refetchInterval: 15_000 },
  })
  const vaultAssetBalance = vaultAssetBalanceRead.data

  const freeAssetBuffer =
    vaultAssetBalance !== undefined &&
    vaultData.totalPendingDepositAssets !== undefined &&
    vaultData.totalClaimableRedeemAssets !== undefined
      ? (() => {
          const reserved = vaultData.totalPendingDepositAssets! + vaultData.totalClaimableRedeemAssets!
          return vaultAssetBalance > reserved ? vaultAssetBalance - reserved : 0n
        })()
      : undefined

  function refetchAll(): void {
    vaultData.refetch()
    roles.refetch()
    void vaultAssetBalanceRead.refetch()
  }

  return (
    <div className="flex flex-col gap-8">
      <div>
        <h1 className="text-2xl font-semibold text-text-primary">Admin</h1>
        <p className="mt-1 text-sm text-text-secondary">
          Panel operativo — cada acción requiere su rol on-chain (OPERATOR / ASSET_MANAGER / NAV_UPDATER / PAUSER).
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatCard
          label="Pending deposits (protocolo)"
          isLoading={vaultData.isLoading}
          value={
            vaultData.totalPendingDepositAssets !== undefined && vaultData.assetDecimals !== undefined
              ? `$${formatTokenAmount(vaultData.totalPendingDepositAssets, vaultData.assetDecimals)}`
              : '—'
          }
        />
        <StatCard
          label="Claimable redeems (protocolo)"
          isLoading={vaultData.isLoading}
          value={
            vaultData.totalClaimableRedeemAssets !== undefined && vaultData.assetDecimals !== undefined
              ? `$${formatTokenAmount(vaultData.totalClaimableRedeemAssets, vaultData.assetDecimals)}`
              : '—'
          }
        />
        <StatCard
          label="Buffer libre de USDC"
          isLoading={vaultData.isLoading}
          value={
            freeAssetBuffer !== undefined && vaultData.assetDecimals !== undefined
              ? `$${formatTokenAmount(freeAssetBuffer, vaultData.assetDecimals)}`
              : '—'
          }
          hint="disponible para investInTBill / respaldar fulfillRedeem"
        />
      </div>

      <RolesOverview roles={roles} />

      {roles.hasAnyRole && (
        <div className="flex flex-col gap-6">
          {roles.isOperator && (
            <ControllerQueue
              assetDecimals={vaultData.assetDecimals}
              shareDecimals={vaultData.shareDecimals}
              freeAssetBuffer={freeAssetBuffer}
              onChanged={refetchAll}
            />
          )}

          <CustodyPanel
            isVaultAssetManager={roles.isVaultAssetManager === true}
            isTBillAssetManager={roles.isTBillAssetManager === true}
            assetDecimals={vaultData.assetDecimals}
            freeAssetBuffer={freeAssetBuffer}
            onChanged={refetchAll}
          />

          {roles.isNavUpdater && (
            <NavUpdatePanel
              navAnswer={vaultData.navAnswer}
              navDecimals={vaultData.navDecimals}
              navUpdatedAt={vaultData.navUpdatedAt}
              onChanged={refetchAll}
            />
          )}

          {roles.isPauser && <PausePanel onChanged={refetchAll} />}

          <FeePanel managementFeeBps={vaultData.managementFeeBps} onChanged={refetchAll} />
        </div>
      )}
    </div>
  )
}
