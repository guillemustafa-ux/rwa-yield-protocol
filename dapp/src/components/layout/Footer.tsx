import type { JSX } from 'react'
import { FOOTER_CONTRACTS, LIVE_UPGRADE_TX_HASH, etherscanAddressUrl, etherscanTxUrl } from '../../contracts/addresses'
import { truncateAddress } from '../../lib/format'

export function Footer(): JSX.Element {
  return (
    <footer className="border-t border-border-subtle bg-bg-deep">
      <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6">
        <div className="grid gap-8 sm:grid-cols-2">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-text-tertiary">Contratos (Sepolia)</p>
            <ul className="mt-3 space-y-1.5">
              {FOOTER_CONTRACTS.map((c) => (
                <li key={c.address} className="flex items-center justify-between gap-3 text-sm">
                  <span className="text-text-secondary">{c.label}</span>
                  <a
                    href={etherscanAddressUrl(c.address)}
                    target="_blank"
                    rel="noreferrer"
                    className="font-mono text-xs text-accent-strong hover:underline"
                  >
                    {truncateAddress(c.address)}
                  </a>
                </li>
              ))}
            </ul>
          </div>

          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-text-tertiary">Upgrade en vivo</p>
            <p className="mt-3 text-sm text-text-secondary">
              El vault corrió un upgrade UUPS V1→V2 sobre el mismo proxy, en producción, con estado real preservado.
            </p>
            <a
              href={etherscanTxUrl(LIVE_UPGRADE_TX_HASH)}
              target="_blank"
              rel="noreferrer"
              className="mt-2 inline-block font-mono text-xs text-accent-strong hover:underline"
            >
              Ver tx del upgrade en Etherscan ↗
            </a>
          </div>
        </div>

        <p className="mt-8 text-xs text-text-muted">
          RWA Yield Protocol — demo de portfolio. tBILL es un T-bill sintético (mock), no un activo real; Sepolia
          testnet, sin valor monetario.
        </p>
      </div>
    </footer>
  )
}
