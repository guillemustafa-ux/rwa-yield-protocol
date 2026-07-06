import type { JSX } from 'react'
import { NavLink } from 'react-router-dom'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { cn } from '../../lib/cn'
import { Badge } from '../ui/Badge'

const navLinkClass = ({ isActive }: { isActive: boolean }): string =>
  cn(
    'rounded-md px-3 py-1.5 text-sm font-medium transition-colors',
    isActive ? 'bg-surface-2 text-text-primary' : 'text-text-secondary hover:text-text-primary',
  )

export function Header(): JSX.Element {
  return (
    <header className="sticky top-0 z-20 border-b border-border-subtle bg-bg-void/85 backdrop-blur">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-4 px-4 sm:px-6">
        <div className="flex items-center gap-3">
          <NavLink to="/" className="flex items-center gap-2 text-text-primary">
            <span className="flex h-7 w-7 items-center justify-center rounded-md border border-accent/40 bg-accent/10 text-xs font-semibold text-accent-strong">
              R
            </span>
            <span className="text-sm font-semibold tracking-tight sm:text-base">RWA Yield Protocol</span>
          </NavLink>
          <Badge tone="neutral" dot>
            Sepolia
          </Badge>
        </div>

        <nav className="hidden items-center gap-1 sm:flex">
          <NavLink to="/" end className={navLinkClass}>
            Overview
          </NavLink>
          <NavLink to="/vault" className={navLinkClass}>
            Vault
          </NavLink>
          <NavLink to="/admin" className={navLinkClass}>
            Admin
          </NavLink>
        </nav>

        <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
      </div>
    </header>
  )
}
