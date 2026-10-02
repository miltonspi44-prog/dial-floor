import { lazy, Suspense, useState } from 'react'

const Radar = lazy(() => import('./Radar'))
const Lists = lazy(() => import('./Lists'))
const Emails = lazy(() => import('./Emails'))

type Tab = 'radar' | 'lists' | 'emails'
const TABS: [Tab, string][] = [['radar', 'Radar'], ['lists', 'Lists'], ['emails', 'Emails']]

/** Item 43: one place for working the lead pool — the radar (with recycling and
 *  best-time inside it), the lists, and the email queue. */
export default function LeadsHub({ myName }: { myName: string }) {
  const [tab, setTab] = useState<Tab>('radar')
  return (
    <div>
      <div className="rangebar hubtabs" role="tablist" aria-label="Leads">
        {TABS.map(([k, label]) => (
          <button key={k} role="tab" aria-selected={tab === k}
            className={`rangebtn ${tab === k ? 'active' : ''}`} onClick={() => setTab(k)}>{label}</button>
        ))}
      </div>
      <Suspense fallback={<div className="page"><div className="emptystate">Loading…</div></div>}>
        {tab === 'radar' && <Radar />}
        {tab === 'lists' && <Lists />}
        {tab === 'emails' && <Emails myName={myName} />}
      </Suspense>
    </div>
  )
}
