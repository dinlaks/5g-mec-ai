import { MapPin, Wifi, HardDrive } from 'lucide-react'

export default function MecSiteMap({ siteData }) {
  const sites = Object.values(siteData)

  return (
    <>
      <div className="panel-header">
        <MapPin /> MEC Site Map
      </div>
      {sites.length === 0 ? (
        <p style={{ color: '#4a5568', fontSize: 12 }}>Waiting for telemetry...</p>
      ) : (
        sites.map(site => {
          const cacheHit   = site.cache_hit_rate_pct ?? 12
          const ues        = site.active_ues ?? 0
          const backhaul   = site.backhaul_utilization_pct ?? 50
          const healthy    = site.far_edge_healthy !== false
          const hitColor   = cacheHit > 70 ? '#48bb78' : cacheHit > 30 ? '#ecc94b' : '#fc8181'

          return (
            <div key={site.mec_site_id} style={{ marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <span style={{ fontWeight: 600, fontSize: 13 }}>{site.mec_site_id}</span>
                <span style={{ fontSize: 10, padding: '2px 8px', borderRadius: 10,
                  background: healthy ? '#1c4532' : '#4a1a1a',
                  color: healthy ? '#48bb78' : '#fc8181' }}>
                  {healthy ? '● Online' : '● Offline'}
                </span>
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                <div className="metric">
                  <div className="metric-label"><Wifi size={10} style={{display:'inline'}}/> Active UEs</div>
                  <div className="metric-value blue">{ues.toLocaleString()}</div>
                </div>
                <div className="metric">
                  <div className="metric-label"><HardDrive size={10} style={{display:'inline'}}/> Cache Hit Rate</div>
                  <div className="metric-value" style={{ color: hitColor }}>{cacheHit.toFixed(1)}%</div>
                </div>
              </div>

              <div className="metric-label" style={{ marginTop: 6 }}>Backhaul utilisation</div>
              <div className="progress-bar">
                <div className="progress-bar-fill" style={{
                  width: `${backhaul}%`,
                  background: backhaul > 80 ? '#fc8181' : backhaul > 60 ? '#ecc94b' : '#48bb78'
                }} />
              </div>
              <div style={{ fontSize: 10, color: '#718096', marginTop: 2 }}>{backhaul.toFixed(0)}%</div>
            </div>
          )
        })
      )}
    </>
  )
}
