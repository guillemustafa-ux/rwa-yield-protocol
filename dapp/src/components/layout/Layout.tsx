import type { JSX } from 'react'
import { Outlet } from 'react-router-dom'
import { Header } from './Header'
import { Footer } from './Footer'
import { NetworkGuard } from './NetworkGuard'

export function Layout(): JSX.Element {
  return (
    <div className="flex min-h-screen flex-col bg-bg-void text-text-primary">
      <Header />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-10 sm:px-6">
        <NetworkGuard>
          <Outlet />
        </NetworkGuard>
      </main>
      <Footer />
    </div>
  )
}
