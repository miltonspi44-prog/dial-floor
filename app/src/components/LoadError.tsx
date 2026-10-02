/** Item 40: a failed load says so, instead of dressing up as good news. */
export default function LoadError({ what, error, onRetry }: { what: string; error: string; onRetry?: () => void }) {
  return (
    <div className="card" role="alert" style={{ borderColor: 'var(--bad)', color: 'var(--bad)' }}>
      <b>Couldn't load {what}.</b> <span className="small">{error}</span>
      {onRetry && <button className="btn ghost small" style={{ marginLeft: 10 }} onClick={onRetry}>Try again</button>}
    </div>
  )
}
