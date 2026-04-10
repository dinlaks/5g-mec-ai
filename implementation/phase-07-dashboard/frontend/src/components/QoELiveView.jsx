import { Activity } from 'lucide-react'
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer } from 'recharts'

export default function QoELiveView({ qoeData }) {
  // Take last 20 data points for the chart
  const chartData = qoeData.slice(0, 20).reverse().map((d, i) => ({
    t:        i,
    qoe:      d.qoe_score ?? 70,
    buffering: d.buffering_rate_pct ?? 5,
  }))

  const latest = qoeData[0] ?? {}
  const qoe    = latest.qoe_score ?? 70
  const buf    = latest.buffering_rate_pct ?? 5
  const qoeColor = qoe >= 80 ? '#48bb78' : qoe >= 60 ? '#ecc94b' : '#fc8181'

  return (
    <>
      <div className="panel-header">
        <Activity /> QoE Live View
      </div>

      <div style={{ display: 'flex', gap: 20, marginBottom: 8 }}>
        <div className="metric">
          <div className="metric-label">QoE Score</div>
          <div className="metric-value" style={{ color: qoeColor }}>{qoe.toFixed(0)}/100</div>
        </div>
        <div className="metric">
          <div className="metric-label">Buffering Rate</div>
          <div className="metric-value" style={{ color: buf < 2 ? '#48bb78' : '#fc8181' }}>
            {buf.toFixed(1)}%
          </div>
        </div>
      </div>

      {chartData.length > 1 && (
        <ResponsiveContainer width="100%" height={80}>
          <LineChart data={chartData}>
            <XAxis dataKey="t" hide />
            <YAxis domain={[0, 100]} hide />
            <Tooltip
              contentStyle={{ background: '#1a1d27', border: '1px solid #2d3748', fontSize: 11 }}
              formatter={(v, name) => [v.toFixed(1), name === 'qoe' ? 'QoE' : 'Buffering%']}
            />
            <Line type="monotone" dataKey="qoe" stroke="#63b3ed" dot={false} strokeWidth={2} />
            <Line type="monotone" dataKey="buffering" stroke="#fc8181" dot={false} strokeWidth={1} />
          </LineChart>
        </ResponsiveContainer>
      )}
    </>
  )
}
