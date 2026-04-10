import { useEffect, useRef, useState, useCallback } from 'react'
import MecSiteMap       from './components/MecSiteMap.jsx'
import AIPredictionFeed from './components/AIPredictionFeed.jsx'
import AgentDecisionCenter from './components/AgentDecisionCenter.jsx'
import CacheIntelligence from './components/CacheIntelligence.jsx'
import QoELiveView      from './components/QoELiveView.jsx'
import BusinessKPIs     from './components/BusinessKPIs.jsx'
import AIHealth         from './components/AIHealth.jsx'

const BACKEND_WS  = import.meta.env.VITE_BACKEND_WS  || `ws://${window.location.host}/ws`
const BACKEND_URL = import.meta.env.VITE_BACKEND_URL  || '/api'

export default function App() {
  const ws = useRef(null)
  const [connected, setConnected] = useState(false)

  // Per-panel state updated by WebSocket messages
  const [siteData,        setSiteData]       = useState({})
  const [predictions,     setPredictions]    = useState([])
  const [agentRuns,       setAgentRuns]      = useState({})
  const [pendingApprovals,setPendingApprovals] = useState([])
  const [cacheData,       setCacheData]      = useState({})
  const [qoeData,         setQoeData]        = useState([])
  const [outcomes,        setOutcomes]       = useState([])
  const [agentDecisions,  setAgentDecisions] = useState([])

  // Human approval handler (Panel C → backend → agent API)
  const handleApproval = useCallback(async (runId, decision, approver = 'dashboard') => {
    try {
      await fetch(`${BACKEND_URL}/agent/resume/${runId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ decision, approver }),
      })
      setPendingApprovals(prev => prev.filter(r => r.run_id !== runId))
    } catch (e) {
      console.error('Approval failed:', e)
    }
  }, [])

  // WebSocket message dispatcher
  const handleMessage = useCallback((msg) => {
    const { type, panel, topic, data } = msg

    if (type === 'human-approval') {
      setPendingApprovals(prev => prev.filter(r => r.run_id !== msg.run_id))
      return
    }

    if (type === 'kafka') {
      const siteId = data?.mec_site_id

      switch (panel) {
        case 'site-map':
          if (siteId) {
            setSiteData(prev => ({
              ...prev,
              [siteId]: { ...(prev[siteId] || {}), ...data },
            }))
          }
          break

        case 'prediction-feed':
          if (data?.confidence >= 0.75) {
            setPredictions(prev => [data, ...prev].slice(0, 20))
          }
          break

        case 'cache-intelligence':
          if (siteId) {
            setCacheData(prev => ({
              ...prev,
              [siteId]: { ...(prev[siteId] || {}), ...data },
            }))
          }
          break

        case 'qoe-live':
          setQoeData(prev => [data, ...prev].slice(0, 60))
          break

        case 'business-kpis':
          setOutcomes(prev => [data, ...prev].slice(0, 50))
          break

        case 'agent-decisions':
          setAgentDecisions(prev => [data, ...prev].slice(0, 20))
          // Check for human approval required
          if (data?.action === 'alert-noc' && data?.alert_type === 'human_required') {
            setPendingApprovals(prev => {
              const exists = prev.find(r => r.run_id === data.run_id)
              return exists ? prev : [data, ...prev]
            })
          }
          break
      }
    }

    // Agent run state updates (polled separately via REST, not WebSocket)
    if (type === 'agent-run') {
      setAgentRuns(prev => ({ ...prev, [msg.run_id]: msg }))
    }
  }, [])

  // WebSocket connection
  useEffect(() => {
    const connect = () => {
      const socket = new WebSocket(BACKEND_WS)

      socket.onopen = () => {
        setConnected(true)
        console.log('WebSocket connected')
      }

      socket.onmessage = (e) => {
        try {
          handleMessage(JSON.parse(e.data))
        } catch { /* ignore parse errors */ }
      }

      socket.onclose = () => {
        setConnected(false)
        console.log('WebSocket disconnected — reconnecting in 3s')
        setTimeout(connect, 3000)
      }

      socket.onerror = () => socket.close()

      // Keepalive ping every 30s
      const ping = setInterval(() => {
        if (socket.readyState === WebSocket.OPEN) socket.send('ping')
      }, 30000)

      ws.current = socket
      return () => { clearInterval(ping); socket.close() }
    }

    return connect()
  }, [handleMessage])

  // Poll agent runs every 10s
  useEffect(() => {
    const poll = async () => {
      try {
        const res = await fetch(`${BACKEND_URL}/agent/runs`)
        const runs = await res.json()
        setAgentRuns(runs)
      } catch { /* ignore */ }
    }
    poll()
    const interval = setInterval(poll, 10000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="dashboard">
      {/* Top bar */}
      <div className="topbar">
        <div className="topbar-title">
          <div className="status-dot" />
          EdgeStream IQ — <span>5G MEC Content Intelligence</span>
        </div>
        <div className="conn-status">
          <div className={`conn-dot ${connected ? 'connected' : 'disconnected'}`} />
          {connected ? 'Live' : 'Reconnecting...'}
        </div>
      </div>

      {/* Panel A — MEC Site Map */}
      <div className="panel panel-site-map">
        <MecSiteMap siteData={siteData} />
      </div>

      {/* Panel B — AI Prediction Feed */}
      <div className="panel panel-predictions">
        <AIPredictionFeed predictions={predictions} />
      </div>

      {/* Panel C — Agent Decision Center */}
      <div className="panel panel-agent">
        <AgentDecisionCenter
          agentRuns={agentRuns}
          pendingApprovals={pendingApprovals}
          agentDecisions={agentDecisions}
          onApproval={handleApproval}
          backendUrl={BACKEND_URL}
        />
      </div>

      {/* Panel D — Cache Intelligence */}
      <div className="panel panel-cache">
        <CacheIntelligence cacheData={cacheData} />
      </div>

      {/* Panel E — QoE Live View */}
      <div className="panel panel-qoe">
        <QoELiveView qoeData={qoeData} />
      </div>

      {/* Panel F — Business KPIs */}
      <div className="panel panel-kpis">
        <BusinessKPIs outcomes={outcomes} />
      </div>

      {/* Panel G — AI Health */}
      <div className="panel panel-ai-health">
        <AIHealth backendUrl={BACKEND_URL} />
      </div>
    </div>
  )
}
