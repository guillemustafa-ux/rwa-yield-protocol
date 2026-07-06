import { useEffect, useState } from 'react'
import { useWaitForTransactionReceipt, useWriteContract } from 'wagmi'

export type TxStatus = 'idle' | 'pending' | 'confirming' | 'confirmed' | 'error'

/**
 * Extrae un mensaje legible de un error de viem/wagmi (revert, rechazo del
 * usuario, RPC, etc.). `shortMessage`/`message` llegan tal cual del SDK — no
 * están traducidos, esta dApp no controla ese texto.
 */
function toErrorMessage(err: unknown, fallback: string): string {
  if (err && typeof err === 'object') {
    const anyErr = err as { shortMessage?: unknown; message?: unknown }
    if (typeof anyErr.shortMessage === 'string' && anyErr.shortMessage.length > 0) return anyErr.shortMessage
    if (typeof anyErr.message === 'string' && anyErr.message.length > 0) return anyErr.message
  }
  return fallback
}

/**
 * Envoltorio de `useWriteContract` + `useWaitForTransactionReceipt` con una
 * máquina de estados simple (`idle → pending → confirming → confirmed|error`)
 * y mensaje de error ya normalizado. Portado de PULSO
 * (`apps/web/src/hooks/useTxAction.ts`) — un hook por acción (faucet,
 * approve, requestDeposit, claim, fulfill, updateNav…) así cada botón tiene
 * su propio spinner/estado independiente en vez de compartir uno global.
 */
export function useTxAction() {
  const { writeContractAsync, reset: resetWrite } = useWriteContract()
  const [hash, setHash] = useState<`0x${string}` | undefined>(undefined)
  const [status, setStatus] = useState<TxStatus>('idle')
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const receipt = useWaitForTransactionReceipt({ hash })

  useEffect(() => {
    if (!hash) return
    if (receipt.isSuccess) {
      // Gotcha de wagmi v2 (lección PULSO): isSuccess significa "la receipt
      // se obtuvo", NO que la tx haya tenido éxito — una tx revertida
      // on-chain también llega acá, con status 'reverted'. Sin este chequeo,
      // un revert se mostraría en verde como si hubiera confirmado bien.
      if (receipt.data.status === 'reverted') {
        setStatus('error')
        setErrorMessage('La transacción revirtió on-chain.')
      } else {
        setStatus('confirmed')
      }
    } else if (receipt.isError) {
      setStatus('error')
      setErrorMessage(toErrorMessage(receipt.error, 'Error inesperado esperando la confirmación.'))
    } else if (receipt.isLoading) {
      setStatus('confirming')
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hash, receipt.isSuccess, receipt.isError, receipt.isLoading, receipt.error, receipt.data])

  async function execute(params: Parameters<typeof writeContractAsync>[0]): Promise<void> {
    setStatus('pending')
    setErrorMessage(null)
    try {
      const txHash = await writeContractAsync(params)
      setHash(txHash)
    } catch (err) {
      setStatus('error')
      setErrorMessage(toErrorMessage(err, 'Error inesperado enviando la transacción.'))
    }
  }

  function reset(): void {
    setStatus('idle')
    setErrorMessage(null)
    setHash(undefined)
    resetWrite()
  }

  return { execute, status, hash, errorMessage, reset }
}
