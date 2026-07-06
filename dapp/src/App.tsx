import type { JSX } from 'react'
import { Route, Routes } from 'react-router-dom'
import { Layout } from './components/layout/Layout'
import { Home } from './pages/Home'
import { Vault } from './pages/Vault'
import { Admin } from './pages/Admin'

/**
 * Rutas de la dApp. `Vault` y `Admin` son placeholders de este scaffold —
 * los llena otro agente (flujo request→claim y panel operativo de roles).
 */
export default function App(): JSX.Element {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="vault" element={<Vault />} />
        <Route path="admin" element={<Admin />} />
      </Route>
    </Routes>
  )
}
