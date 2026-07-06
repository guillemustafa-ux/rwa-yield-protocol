import type { JSX, ReactNode } from 'react'
import { useAccount, useSwitchChain } from 'wagmi'
import { CHAIN_ID } from '../../contracts/addresses'
import { Button } from '../ui/Button'

/**
 * Guard de red equivocada (patrón PULSO, `Staking.tsx`): si hay wallet
 * conectada pero a una chain distinta de Sepolia, reemplaza el contenido de
 * la página por un aviso + botón para cambiar de red en un solo click. Si no
 * hay wallet conectada todavía, no bloquea nada — eso lo resuelve el
 * `ConnectButton` del header, esta pantalla es solo para "conectado pero mal".
 */
export function NetworkGuard({ children }: { children: ReactNode }): JSX.Element {
  const { isConnected, chain } = useAccount()
  const { switchChain, isPending: switchPending } = useSwitchChain()

  const wrongNetwork = isConnected && chain !== undefined && chain.id !== CHAIN_ID

  if (!wrongNetwork) return <>{children}</>

  return (
    <div className="mx-auto flex max-w-lg flex-col items-center gap-4 rounded-xl border border-warning/30 bg-warning/5 px-6 py-10 text-center">
      <p className="text-sm text-text-primary">
        Tu wallet está conectada a <span className="font-medium text-warning">{chain?.name ?? 'otra red'}</span>.
      </p>
      <p className="max-w-md text-xs text-text-tertiary">
        El protocolo RWA Yield vive solo en Sepolia testnet (chainId {CHAIN_ID}). Cambiá de red para ver tus datos y
        operar.
      </p>
      <Button
        variant="primary"
        size="sm"
        disabled={switchPending}
        onClick={() => switchChain({ chainId: CHAIN_ID })}
      >
        {switchPending ? 'Cambiando…' : 'Cambiar a Sepolia'}
      </Button>
    </div>
  )
}
