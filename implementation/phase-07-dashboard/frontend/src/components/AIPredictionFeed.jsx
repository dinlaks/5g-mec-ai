import { Brain } from 'lucide-react'

export default function AIPredictionFeed({ predictions }) {
  return (
    <>
      <div className="panel-header">
        <Brain /> AI Prediction Feed
      </div>
      <div className="scrollable">
        {predictions.length === 0 ? (
          <p style={{ color: '#4a5568', fontSize: 12 }}>Waiting for demand predictions...</p>
        ) : (
          predictions.slice(0, 8).map((p, i) => {
            const conf = parseFloat(p.confidence ?? 0)
            const isHigh = conf >= 0.95
            return (
              <div key={i} className="prediction-item">
                <div>
                  <div style={{ fontWeight: 600, fontSize: 12 }}>{p.content_id ?? 'unknown'}</div>
                  <div style={{ color: '#718096', fontSize: 11 }}>
                    {(p.predicted_viewers ?? 0).toLocaleString()} viewers · {p.mec_site_id}
                  </div>
                  <div style={{ color: '#4a5568', fontSize: 10 }}>
                    Peak in {p.predicted_peak_in_minutes ?? '?'}min
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <span className={`confidence-badge ${isHigh ? 'confidence-high' : 'confidence-medium'}`}>
                    {(conf * 100).toFixed(0)}%
                  </span>
                  {isHigh && (
                    <div style={{ fontSize: 9, color: '#48bb78', marginTop: 3 }}>EDA auto-trigger</div>
                  )}
                </div>
              </div>
            )
          })
        )}
      </div>
    </>
  )
}
