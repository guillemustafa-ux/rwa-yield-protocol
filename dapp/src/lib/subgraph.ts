/**
 * Cliente mínimo del subgraph (The Graph Studio) por `fetch`.
 *
 * La dApp ya trae `@tanstack/react-query` para orquestar el fetching/caché, así
 * que NO sumamos apollo/urql/graphql-codegen: alcanza con un POST a mano y el
 * `data` tipado del lado del hook. El endpoint es público (query key ya en la
 * URL de Studio), no requiere API key.
 *
 * El subgraph indexa el ciclo de vida ERC-7540 del vault en Sepolia:
 * DepositRequest / RedeemRequest / DepositFulfilled / RedeemFulfilled y las
 * publicaciones de NAV (RwaNavFeed.NavUpdated). Ver `subgraph/schema.graphql`.
 */
export const SUBGRAPH_URL =
  'https://api.studio.thegraph.com/query/1756185/rwa-yield-protocol/v0.0.1'

interface GraphQLResponse<T> {
  data?: T
  errors?: Array<{ message: string }>
}

/**
 * Ejecuta una query GraphQL contra el subgraph y devuelve `data` tipado.
 * Lanza si el transporte falla (lo agarra react-query como `isError`) o si el
 * subgraph responde con `errors` (query inválida / entidad inexistente).
 */
export async function querySubgraph<T>(
  query: string,
  variables?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  })

  if (!res.ok) {
    throw new Error(`Subgraph HTTP ${res.status}`)
  }

  const json = (await res.json()) as GraphQLResponse<T>
  if (json.errors?.length) {
    throw new Error(json.errors.map((e) => e.message).join('; '))
  }
  if (!json.data) {
    throw new Error('Subgraph devolvió una respuesta vacía')
  }
  return json.data
}
