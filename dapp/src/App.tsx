import type { JSX } from 'react'
import { Route, Routes } from 'react-router-dom'
import { Layout } from './components/layout/Layout'
import { Home } from './pages/Home'
import { Vault } from './pages/Vault'
import { Admin } from './pages/Admin'
import { CrossChain } from './pages/CrossChain'
import { Activity } from './pages/Activity'
import { Analytics } from './pages/Analytics'

/**
 * Rutas de la dApp. `/cross-chain` cuenta la historia F3 (CCIP + Automation)
 * con la evidencia en vivo del deploy.
 */
export default function App(): JSX.Element {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="vault" element={<Vault />} />
        <Route path="cross-chain" element={<CrossChain />} />
        <Route path="activity" element={<Activity />} />
        <Route path="analytics" element={<Analytics />} />
        <Route path="admin" element={<Admin />} />
      </Route>
    </Routes>
  )
}
