import { zeroAddress, zeroHash } from 'viem'
import { useAccount, useReadContracts } from 'wagmi'
import { CONTRACT_ADDRESSES, VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { RwaNavFeedAbi } from '../../contracts/abis/RwaNavFeed'
import { TBillTokenAbi } from '../../contracts/abis/TBillToken'

const NAV_FEED_ADDRESS = CONTRACT_ADDRESSES.RwaNavFeed
const TBILL_ADDRESS = CONTRACT_ADDRESSES.TBillToken

function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
  return r && r.status === 'success' ? r.result : undefined
}

export type AdminRoles = {
  isLoading: boolean
  address: `0x${string}` | undefined
  isOperator: boolean | undefined
  isVaultAssetManager: boolean | undefined
  isPauser: boolean | undefined
  isNavUpdater: boolean | undefined
  isTBillAssetManager: boolean | undefined
  /** `undefined` mientras algún read todavía no resolvió y ninguno dio `true` todavía. */
  hasAnyRole: boolean | undefined
  roleHashes: {
    operator?: `0x${string}`
    vaultAssetManager?: `0x${string}`
    pauser?: `0x${string}`
    navUpdater?: `0x${string}`
    tBillAssetManager?: `0x${string}`
  }
  refetch: () => void
}

/**
 * Chequeo de roles ON-CHAIN (`hasRole`, nunca asumido por convención) para
 * gatear el panel de Admin — ARCHITECTURE.md §2/§3.3.
 *
 * OJO: `ASSET_MANAGER_ROLE` existe en DOS instancias de `AccessControl`
 * distintas — la del vault (gatea `investInTBill`/`divestFromTBill`) y la de
 * `TBillToken` (gatea `mint`/`burn` del sintético) — mismo identificador
 * keccak256, pero se otorgan y se consultan por separado (ver
 * `RwaVault.sol` NatSpec punto 4): una wallet puede tener uno sin el otro.
 */
export function useAdminRoles(): AdminRoles {
  const { address } = useAccount()

  const roleHashReads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'OPERATOR_ROLE' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'ASSET_MANAGER_ROLE' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'PAUSER_ROLE' },
      { address: NAV_FEED_ADDRESS, abi: RwaNavFeedAbi, functionName: 'NAV_UPDATER_ROLE' },
      { address: TBILL_ADDRESS, abi: TBillTokenAbi, functionName: 'ASSET_MANAGER_ROLE' },
    ],
  })
  const [operatorH, vaultAssetManagerH, pauserH, navUpdaterH, tBillAssetManagerH] = roleHashReads.data ?? []

  const operator = ok(operatorH)
  const vaultAssetManager = ok(vaultAssetManagerH)
  const pauser = ok(pauserH)
  const navUpdater = ok(navUpdaterH)
  const tBillAssetManager = ok(tBillAssetManagerH)

  const hashesReady =
    operator !== undefined &&
    vaultAssetManager !== undefined &&
    pauser !== undefined &&
    navUpdater !== undefined &&
    tBillAssetManager !== undefined

  const membershipReads = useReadContracts({
    contracts: [
      {
        address: VAULT_ADDRESS,
        abi: RwaVaultV2Abi,
        functionName: 'hasRole',
        args: [operator ?? zeroHash, address ?? zeroAddress],
      },
      {
        address: VAULT_ADDRESS,
        abi: RwaVaultV2Abi,
        functionName: 'hasRole',
        args: [vaultAssetManager ?? zeroHash, address ?? zeroAddress],
      },
      {
        address: VAULT_ADDRESS,
        abi: RwaVaultV2Abi,
        functionName: 'hasRole',
        args: [pauser ?? zeroHash, address ?? zeroAddress],
      },
      {
        address: NAV_FEED_ADDRESS,
        abi: RwaNavFeedAbi,
        functionName: 'hasRole',
        args: [navUpdater ?? zeroHash, address ?? zeroAddress],
      },
      {
        address: TBILL_ADDRESS,
        abi: TBillTokenAbi,
        functionName: 'hasRole',
        args: [tBillAssetManager ?? zeroHash, address ?? zeroAddress],
      },
    ],
    query: { enabled: address !== undefined && hashesReady, refetchInterval: 30_000 },
  })
  const [isOperatorR, isVaultAssetManagerR, isPauserR, isNavUpdaterR, isTBillAssetManagerR] =
    membershipReads.data ?? []

  const isOperator = ok(isOperatorR)
  const isVaultAssetManager = ok(isVaultAssetManagerR)
  const isPauser = ok(isPauserR)
  const isNavUpdater = ok(isNavUpdaterR)
  const isTBillAssetManager = ok(isTBillAssetManagerR)

  const flags = [isOperator, isVaultAssetManager, isPauser, isNavUpdater, isTBillAssetManager]
  const allResolved = flags.every((f) => f !== undefined)
  const hasAnyRole = address === undefined ? undefined : flags.some((f) => f === true) ? true : allResolved ? false : undefined

  return {
    isLoading: roleHashReads.isLoading || membershipReads.isLoading,
    address,
    isOperator,
    isVaultAssetManager,
    isPauser,
    isNavUpdater,
    isTBillAssetManager,
    hasAnyRole,
    roleHashes: {
      operator,
      vaultAssetManager,
      pauser,
      navUpdater,
      tBillAssetManager,
    },
    refetch: () => {
      void roleHashReads.refetch()
      void membershipReads.refetch()
    },
  }
}
