import { DollarSign, TrendingDown, Zap } from 'lucide-react'

// Rough cost: $1/GB backhaul at peak
const COST_PER_MBPS_PER_EVENT = 0.05

export default function BusinessKPIs({ outcomes }) {
  const successful = outcomes.filter(o => o.verdict === 'success' || o.verdict === 'partial')
  const totalEvents  = outcomes.length
  const autoHandled  = outcomes.filter(o => !o.human_involved).length
  const totalBWSaved = outcomes.reduce((s, o) => s + (o.cache_hit_rate_delta ?? 0) * 20, 0)
  const estSaved     = (totalBWSaved * COST_PER_MBPS_PER_EVENT).toFixed(0)

  return (
    <>
      <div className="panel-header">
        <DollarSign /> Business KPIs
      </div>

      <div className="kpi-grid">
        <div className="metric">
          <div className="metric-label"><Zap size={10} style={{display:'inline'}}/> Events handled</div>
          <div className="metric-value green">{totalEvents}</div>
        </div>
        <div className="metric">
          <div className="metric-label">Autonomous</div>
          <div className="metric-value blue">
            {totalEvents > 0 ? ((autoHandled / totalEvents) * 100).toFixed(0) : 0}%
          </div>
        </div>
        <div className="metric">
          <div className="metric-label"><TrendingDown size={10} style={{display:'inline'}}/> BW saved</div>
          <div className="metric-value yellow">{totalBWSaved.toFixed(0)} Mbps·h</div>
        </div>
        <div className="metric">
          <div className="metric-label">$ saved (est.)</div>
          <div className="metric-value green">${estSaved}</div>
        </div>
      </div>

      <div style={{ marginTop: 10 }}>
        {outcomes.slice(0, 4).map((o, i) => (
          <div key={i} style={{ display: 'flex', justifyContent: 'space-between',
            fontSize: 11, padding: '3px 0', borderBottom: '1px solid #2d3748' }}>
            <span style={{ color: '#a0aec0' }}>{o.mec_site_id ?? o.content_id ?? '—'}</span>
            <span style={{
              color: o.verdict === 'success' ? '#48bb78' : o.verdict === 'failure' ? '#fc8181' : '#ecc94b'
            }}>{o.verdict ?? '—'}</span>
            <span style={{ color: '#4a5568' }}>
              Δ{(o.cache_hit_rate_delta ?? 0) > 0 ? '+' : ''}{(o.cache_hit_rate_delta ?? 0).toFixed(0)}%
            </span>
          </div>
        ))}
      </div>
    </>
  )
}
