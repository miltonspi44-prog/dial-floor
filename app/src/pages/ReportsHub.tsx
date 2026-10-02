import { lazy, Suspense, useState } from 'react'
import type { Profile } from '../lib/types'

const Funnel = lazy(() => import('./Funnel'))
const Coaching = lazy(() => import('./Coaching'))
const Ledger = lazy(() => import('./Ledger'))

type Tab = 'funnel' | 'coaching' | 'handoffs'
const TABS: [Tab, string][] = [['funnel', 'Funnel'], ['coaching', 'Coaching'], ['handoffs', 'Handoffs']]

/** Item 43: the reading room — funnel, coaching, and the handoff ledger. */
export default function ReportsHub({ profile }: { profile: Profile | null }) {
  const [tab, setTab] = useState<Tab>('funnel')
  return (
    <div>
      <div className="rangebar hubtabs" role="tablist" aria-label="Reports">
        {TABS.map(([k, label]) => (
          <button key={k} role="tab" aria-selected={tab === k}
            className={`rangebtn ${tab === k ? 'active' : ''}`} onClick={() => setTab(k)}>{label}</button>
        ))}
      </div>
      <Suspense fallback={<div className="page"><div className="emptystate">Loading…</div></div>}>
        {tab === 'funnel' && <Funnel />}
        {tab === 'coaching' && <Coaching profile={profile} />}
        {tab === 'handoffs' && <Ledger />}
      </Suspense>
    </div>
  )
}
