import { HardDrive, TrendingUp } from 'lucide-react'

export default function CacheIntelligence({ cacheData }) {
  const sites = Object.values(cacheData)

  const avgHitRate = sites.length > 0
    ? sites.reduce((s, d) => s + (d.cache_hit_rate_pct ?? 12), 0) / sites.length
    : 12

  const hitColor = avgHitRate > 70 ? '#48bb78' : avgHitRate > 30 ? '#ecc94b' : '#fc8181'

  return (
    <>
      <div className="panel-header">
        <HardDrive /> Cache Intelligence
      </div>

      <div style={{ display: 'flex', gap: 20, marginBottom: 10 }}>
        <div className="metric">
          <div className="metric-label">Avg cache hit rate</div>
          <div className="metric-value" style={{ color: hitColor, fontSize: 28 }}>
            {avgHitRate.toFixed(1)}%
          </div>
        </div>
        <div className="metric">
          <div className="metric-label">Active sites</div>
          <div className="metric-value blue">{sites.length}</div>
        </div>
      </div>

      <div className="progress-bar" style={{ height: 8 }}>
        <div className="progress-bar-fill" style={{ width: `${avgHitRate}%`, background: hitColor }} />
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: '#4a5568', marginTop: 3 }}>
        <span>0%</span><span>Baseline ~12%</span><span>Target 80%+</span>
      </div>

      <div style={{ marginTop: 10 }}>
        {sites.map(site => (
          <div key={site.mec_site_id} style={{ display: 'flex', justifyContent: 'space-between',
            fontSize: 11, padding: '4px 0', borderBottom: '1px solid #2d3748' }}>
            <span style={{ color: '#a0aec0' }}>{site.mec_site_id}</span>
            <span style={{ color: hitColor }}>{(site.cache_hit_rate_pct ?? 12).toFixed(1)}%</span>
            <span style={{ color: '#4a5568' }}>{(site.used_gb ?? 0).toFixed(1)} GB used</span>
          </div>
        ))}
      </div>
    </>
  )
}
