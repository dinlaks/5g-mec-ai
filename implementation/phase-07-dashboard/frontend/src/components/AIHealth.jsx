import { useEffect, useState } from 'react'
import { BarChart2, ExternalLink } from 'lucide-react'

export default function AIHealth({ backendUrl }) {
  const [data, setData]       = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const fetch_ = async () => {
      try {
        const res = await fetch(`${backendUrl}/langfuse/traces`)
        setData(await res.json())
      } catch {
        setData(null)
      } finally {
        setLoading(false)
      }
    }
    fetch_()
    const iv = setInterval(fetch_, 30000)
    return () => clearInterval(iv)
  }, [backendUrl])

  const traces = data?.traces ?? []
  const avgLatency = traces.length > 0
    ? (traces.reduce((s, t) => s + (t.latency ?? 0), 0) / traces.length / 1000).toFixed(1)
    : '—'

  return (
    <>
      <div className="panel-header">
        <BarChart2 /> AI Health (Langfuse)
      </div>

      {loading ? (
        <p style={{ color: '#4a5568', fontSize: 12 }}>Loading Langfuse data...</p>
      ) : !data || data.error ? (
        <p style={{ color: '#fc8181', fontSize: 12 }}>
          Langfuse unavailable — {data?.error ?? 'check connection'}
        </p>
      ) : (
        <>
          <div style={{ display: 'flex', gap: 16, marginBottom: 10 }}>
            <div className="metric">
              <div className="metric-label">Traces (recent)</div>
              <div className="metric-value blue">{traces.length}</div>
            </div>
            <div className="metric">
              <div className="metric-label">Avg latency</div>
              <div className="metric-value yellow">{avgLatency}s</div>
            </div>
          </div>

          <div className="scrollable">
            {traces.slice(0, 6).map((t, i) => (
              <div key={i} style={{ display: 'flex', justifyContent: 'space-between',
                fontSize: 11, padding: '4px 0', borderBottom: '1px solid #2d3748' }}>
                <span style={{ color: '#a0aec0', maxWidth: 120, overflow: 'hidden',
                  textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {t.name ?? t.id?.slice(0, 8) ?? '—'}
                </span>
                <span style={{ color: '#4a5568' }}>
                  {t.latency ? `${(t.latency / 1000).toFixed(1)}s` : '—'}
                </span>
              </div>
            ))}
          </div>

          {data.langfuse_url && (
            <a href={data.langfuse_url} target="_blank" rel="noreferrer"
              style={{ display: 'flex', alignItems: 'center', gap: 4,
                fontSize: 11, color: '#63b3ed', marginTop: 10, textDecoration: 'none' }}>
              <ExternalLink size={11} /> Open Langfuse
            </a>
          )}
        </>
      )}
    </>
  )
}
