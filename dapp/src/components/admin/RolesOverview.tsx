import type { JSX } from 'react'
import { Badge } from '../ui/Badge'
import { truncateAddress } from '../../lib/format'
import type { AdminRoles } from './useAdminRoles'

/**
 * Tabla de transparencia: qué rol gatea qué acción, en qué contrato, y si la
 * wallet conectada lo tiene — todo leído on-chain vía `hasRole` (nunca
 * asumido). Se muestra siempre que hay wallet conectada, tenga o no roles.
 */
export function RolesOverview({ roles }: { roles: AdminRoles }): JSX.Element {
  const rows: Array<{ role: string; contract: string; gates: string; has: boolean | undefined }> = [
    { role: 'OPERATOR_ROLE', contract: 'Vault', gates: 'fulfillDeposit / fulfillRedeem', has: roles.isOperator },
    {
      role: 'ASSET_MANAGER_ROLE',
      contract: 'Vault',
      gates: 'investInTBill / divestFromTBill',
      has: roles.isVaultAssetManager,
    },
    {
      role: 'ASSET_MANAGER_ROLE',
      contract: 'TBillToken',
      gates: 'mint / burn de tBILL',
      has: roles.isTBillAssetManager,
    },
    { role: 'NAV_UPDATER_ROLE', contract: 'RwaNavFeed', gates: 'updateNav', has: roles.isNavUpdater },
    { role: 'PAUSER_ROLE', contract: 'Vault', gates: 'pause / unpause', has: roles.isPauser },
  ]

  if (!roles.address) {
    return (
      <div className="rounded-xl border border-dashed border-border-default bg-surface-1/50 p-8 text-center text-sm text-text-tertiary">
        Conectá tu wallet para ver qué roles operativos tenés en el protocolo.
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
          Roles de {truncateAddress(roles.address)}
        </h2>
        {roles.hasAnyRole === false && (
          <Badge tone="neutral" dot>
            Sin rol operativo
          </Badge>
        )}
      </div>

      <div className="overflow-x-auto">
        <table className="w-full min-w-[520px] text-left text-sm">
          <thead>
            <tr className="text-xs uppercase tracking-wide text-text-tertiary">
              <th className="pb-2 pr-4 font-medium">Rol</th>
              <th className="pb-2 pr-4 font-medium">Contrato</th>
              <th className="pb-2 pr-4 font-medium">Gatea</th>
              <th className="pb-2 font-medium">Tu wallet</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={`${row.role}-${row.contract}`} className="border-t border-border-subtle">
                <td className="py-2 pr-4 font-mono text-xs text-text-secondary">{row.role}</td>
                <td className="py-2 pr-4 text-text-secondary">{row.contract}</td>
                <td className="py-2 pr-4 text-text-tertiary">{row.gates}</td>
                <td className="py-2">
                  {row.has === undefined ? (
                    <span className="text-text-tertiary">…</span>
                  ) : row.has ? (
                    <Badge tone="positive">sí</Badge>
                  ) : (
                    <Badge tone="neutral">no</Badge>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {roles.hasAnyRole === false && (
        <p className="text-xs text-text-tertiary">
          Tu wallet no tiene ningún rol operativo — las secciones de acciones de abajo quedan ocultas. Pedile al
          admin (`DEFAULT_ADMIN_ROLE`) que te otorgue el rol correspondiente con `grantRole`.
        </p>
      )}
    </div>
  )
}
