import { useEffect, useState } from 'react'
import { Bot, CheckCircle, Clock, AlertCircle } from 'lucide-react'

// LangGraph 8 nodes in order
const NODES = [
  'demand_reader',
  'context_enricher',
  'strategy_reasoner',
  'confidence_gate',
  'aap_executor',
  'human_approver',
  'outcome_verifier',
  'kubeflow_trigger',
]

function NodeGraph({ nodeHistory = [] }) {
  return (
    <div className="node-graph">
      {NODES.map((node) => {
        const idx        = nodeHistory.indexOf(node)
        const isActive   = nodeHistory.length > 0 && nodeHistory[nodeHistory.length - 1] === node
        const isDone     = idx >= 0 && !isActive
        const status     = isActive ? 'active' : isDone ? 'done' : 'pending'
        const Icon       = isDone ? CheckCircle : isActive ? Clock : AlertCircle
        return (
          <div key={node} className={`agent-node ${status}`}>
            <Icon size={12} />
            <span>{node}</span>
          </div>
        )
      })}
    </div>
  )
}

export default function AgentDecisionCenter({ agentRuns, pendingApprovals, agentDecisions, onApproval, backendUrl }) {
  const [selectedRun, setSelectedRun] = useState(null)
  const [runState,    setRunState]    = useState(null)

  // Auto-select the most recent run
  useEffect(() => {
    const ids = Object.keys(agentRuns || {})
    if (ids.length > 0 && !selectedRun) {
      setSelectedRun(ids[ids.length - 1])
    }
  }, [agentRuns, selectedRun])

  // Fetch detailed state for selected run
  useEffect(() => {
    if (!selectedRun) return
    const fetchState = async () => {
      try {
        const res = await fetch(`${backendUrl}/agent/state/${selectedRun}`)
        setRunState(await res.json())
      } catch { /* ignore */ }
    }
    fetchState()
    const iv = setInterval(fetchState, 3000)
    return () => clearInterval(iv)
  }, [selectedRun, backendUrl])

  return (
    <>
      <div className="panel-header">
        <Bot /> Agent Decision Center
      </div>

      {/* LangGraph node flow */}
      <div style={{ marginBottom: 12 }}>
        <div style={{ fontSize: 11, color: '#718096', marginBottom: 6 }}>
          Run: {selectedRun ? selectedRun.slice(0, 8) + '...' : 'none'}
          {runState?.confidence && (
            <span style={{ marginLeft: 8, color: '#63b3ed' }}>
              conf: {(runState.confidence * 100).toFixed(0)}%
            </span>
          )}
        </div>
        <NodeGraph nodeHistory={runState?.node_history ?? []} />
      </div>

      {/* Human approval queue */}
      {pendingApprovals.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 11, color: '#fc8181', fontWeight: 600, marginBottom: 6 }}>
            ⚠ Approval Required
          </div>
          {pendingApprovals.slice(0, 2).map((r, i) => (
            <div key={i} className="approval-card">
              <div style={{ fontSize: 12, fontWeight: 600 }}>{r.mec_site_id}</div>
              <div style={{ fontSize: 11, color: '#a0aec0' }}>
                Action: {r.action} · Conf: {((r.confidence ?? 0) * 100).toFixed(0)}%
              </div>
              <div className="approval-actions">
                <button className="btn btn-approve" onClick={() => onApproval(r.run_id, 'approved')}>
                  ✓ Approve
                </button>
                <button className="btn btn-reject" onClick={() => onApproval(r.run_id, 'rejected')}>
                  ✗ Reject
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Recent agent decisions */}
      <div style={{ fontSize: 11, color: '#718096', marginBottom: 4 }}>Recent actions</div>
      <div className="scrollable">
        {agentDecisions.slice(0, 6).map((d, i) => (
          <div key={i} style={{ display: 'flex', justifyContent: 'space-between',
            fontSize: 11, padding: '4px 0', borderBottom: '1px solid #2d3748' }}>
            <span style={{ color: '#a0aec0' }}>{d.action ?? d.alert_type ?? 'decision'}</span>
            <span style={{ color: '#4a5568' }}>{d.mec_site_id ?? ''}</span>
          </div>
        ))}
        {agentDecisions.length === 0 && (
          <p style={{ color: '#4a5568', fontSize: 11 }}>No agent actions yet</p>
        )}
      </div>
    </>
  )
}
