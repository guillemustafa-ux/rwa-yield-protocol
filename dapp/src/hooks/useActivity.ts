import { useQuery } from '@tanstack/react-query'
import { querySubgraph } from '../lib/subgraph'

/**
 * Historial on-chain del vault leído del subgraph. Una sola query trae las cinco
 * colecciones (últimos N eventos de cada una, más nuevos primero), y react-query
 * se encarga del caché/refetch. Los montos vienen como strings decimales (BigInt
 * serializado) — la UI los pasa a `BigInt(...)` y los formatea con los decimales
 * del contrato.
 *
 * Nombres de colección = plural camelCase de la entidad del schema:
 * depositRequests / redeemRequests / depositFulfilleds / redeemFulfilleds /
 * navUpdates.
 */

export interface DepositRequestRow {
  id: string
  owner: string
  sender: string
  assets: string
  blockTimestamp: string
  transactionHash: string
}

export interface RedeemRequestRow {
  id: string
  owner: string
  sender: string
  shares: string
  blockTimestamp: string
  transactionHash: string
}

export interface DepositFulfilledRow {
  id: string
  controller: string
  assets: string
  shares: string
  blockTimestamp: string
  transactionHash: string
}

export interface RedeemFulfilledRow {
  id: string
  controller: string
  shares: string
  assets: string
  blockTimestamp: string
  transactionHash: string
}

export interface NavUpdateRow {
  id: string
  roundId: string
  nav: string
  updatedAt: string
  blockTimestamp: string
  transactionHash: string
}

export interface ActivityData {
  depositRequests: DepositRequestRow[]
  redeemRequests: RedeemRequestRow[]
  depositFulfilleds: DepositFulfilledRow[]
  redeemFulfilleds: RedeemFulfilledRow[]
  navUpdates: NavUpdateRow[]
}

const ACTIVITY_QUERY = /* GraphQL */ `
  query Activity($first: Int!) {
    depositRequests(first: $first, orderBy: blockTimestamp, orderDirection: desc) {
      id
      owner
      sender
      assets
      blockTimestamp
      transactionHash
    }
    redeemRequests(first: $first, orderBy: blockTimestamp, orderDirection: desc) {
      id
      owner
      sender
      shares
      blockTimestamp
      transactionHash
    }
    depositFulfilleds(first: $first, orderBy: blockTimestamp, orderDirection: desc) {
      id
      controller
      assets
      shares
      blockTimestamp
      transactionHash
    }
    redeemFulfilleds(first: $first, orderBy: blockTimestamp, orderDirection: desc) {
      id
      controller
      shares
      assets
      blockTimestamp
      transactionHash
    }
    navUpdates(first: $first, orderBy: blockTimestamp, orderDirection: desc) {
      id
      roundId
      nav
      updatedAt
      blockTimestamp
      transactionHash
    }
  }
`

export function useActivity(first = 25) {
  return useQuery({
    queryKey: ['activity', first],
    queryFn: () => querySubgraph<ActivityData>(ACTIVITY_QUERY, { first }),
    // El subgraph indexa con unos bloques de retraso; no tiene sentido machacarlo.
    refetchInterval: 30_000,
    staleTime: 15_000,
  })
}
