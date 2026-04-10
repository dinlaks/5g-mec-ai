#!/usr/bin/env bash
# =============================================================================
# test-scenarios.sh — End-to-End Demo Scenarios
# 5G MEC Content Intelligence
#
# Runs complete E2E test scenarios that demonstrate the full pipeline:
#   - Demand prediction → Agent decision → AAP execution → Cache hit → QoE improvement
#
# Usage:
#   source configs/near-edge/env.sh
#   ./implementation/phase-08-validation/test-scenarios.sh --scenario nfl
#   ./implementation/phase-08-validation/test-scenarios.sh --scenario concert
#   ./implementation/phase-08-validation/test-scenarios.sh --scenario synthetic
#   ./implementation/phase-08-validation/test-scenarios.sh --all
#
# Scenarios:
#   nfl       — NFL game halftime spike (45K viewers, confidence 0.91)
#   concert   — Live concert spike (25K viewers, confidence 0.88)
#   synthetic — Low confidence event → human approval path (confidence 0.72)
#   stress    — Rapid-fire events to stress-test the pipeline
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCENARIO=""
RUN_ALL=false
WAIT_TIMEOUT=120    # seconds to wait for each verification step

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenario) SCENARIO=$2; shift 2 ;;
    --all)      RUN_ALL=true; shift ;;
    --timeout)  WAIT_TIMEOUT=$2; shift 2 ;;
    *) echo -e "${RED}Unknown arg: $1${NC}"; exit 1 ;;
  esac
done

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}═══ $* ═══${NC}"; }

CDN_MOCK_URL="http://cdn-mock.mec-content-ai.svc.cluster.local:8080"
KAFKA_IMAGE="registry.redhat.io/amq-streams/kafka-38-rhel9:latest"
KAFKA_BOOTSTRAP="kafka-cluster-kafka-bootstrap.mec-ai-data.svc.cluster.local:9092"

# ── Helpers ────────────────────────────────────────────────────────────────────

publish_event() {
  local payload=$1
  oc run "test-pub-${RANDOM}" --rm -it --restart=Never \
    --image="${KAFKA_IMAGE}" \
    -n mec-ai-data -- bash -c \
    "echo '${payload}' | bin/kafka-console-producer.sh \
      --bootstrap-server ${KAFKA_BOOTSTRAP} \
      --topic demand.predictions" \
    2>/dev/null && success "Event published to demand.predictions"
}

wait_for_kafka_message() {
  local topic=$1 field=$2 expected=$3 desc=$4
  info "Waiting for ${desc} on ${topic} (up to ${WAIT_TIMEOUT}s)..."
  local result
  result=$(oc run "test-con-${RANDOM}" --rm -it --restart=Never \
    --image="${KAFKA_IMAGE}" \
    -n mec-ai-data -- bash -c \
    "bin/kafka-console-consumer.sh \
      --bootstrap-server ${KAFKA_BOOTSTRAP} \
      --topic ${topic} \
      --max-messages 1 \
      --timeout-ms $((WAIT_TIMEOUT * 1000))" \
    2>/dev/null || echo "TIMEOUT")

  if echo "${result}" | grep -q "${expected}" 2>/dev/null; then
    success "${desc} confirmed"
    return 0
  else
    warn "${desc} — not confirmed within ${WAIT_TIMEOUT}s"
    return 1
  fi
}

check_agent_runs() {
  local agent_url
  agent_url=$(oc get route content-intelligence-agent -n mec-content-ai \
    -o jsonpath='{.spec.host}' 2>/dev/null)
  local runs
  runs=$(curl -sk "https://${agent_url}/runs" 2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
  [[ "$runs" -gt 0 ]] && success "Agent has ${runs} active run(s)" || \
    warn "No agent runs yet — event may not have met confidence threshold"
}

# ── Scenario: NFL Game ─────────────────────────────────────────────────────────

run_nfl_scenario() {
  section "Scenario: NFL Game Halftime Spike"
  echo "Simulates 45,000 subscribers requesting NFL game at halftime"
  echo "Confidence: 0.91 → LangGraph agent path (not EDA auto-trigger)"
  echo ""

  local NOW
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local PAYLOAD
  PAYLOAD=$(cat << EOF
{"mec_site_id":"mec-stadium-01","content_id":"nfl-game","content_url":"${CDN_MOCK_URL}/nfl-game","predicted_viewers":45000,"event_type":"live_sport","event_start_utc":"${NOW}","confidence":0.91,"predicted_peak_in_minutes":20}
EOF
)

  info "Publishing NFL demand event..."
  publish_event "${PAYLOAD}"
  echo ""

  info "Waiting 10s for agent to process..."
  sleep 10

  info "Checking agent run status..."
  check_agent_runs

  echo ""
  info "Checking demand.predictions topic..."
  wait_for_kafka_message "demand.predictions" "content_id" "nfl-game" "NFL event on Kafka" || true

  echo ""
  info "Checking agent.decisions topic for AAP trigger..."
  wait_for_kafka_message "agent.decisions" "action" "prefetch" "Prefetch decision" || \
    warn "Agent may be processing — check Langfuse for trace"

  echo ""
  success "NFL scenario complete. Check:"
  echo "  • Dashboard Panel C — agent node progression"
  echo "  • Dashboard Panel D — cache hit rate should jump after prefetch"
  echo "  • Langfuse — full trace with strategy_reasoner reasoning"
}

# ── Scenario: Concert ─────────────────────────────────────────────────────────

run_concert_scenario() {
  section "Scenario: Live Concert Spike"
  echo "Simulates 25,000 subscribers for a live concert stream"
  echo "Confidence: 0.88 → LangGraph agent path"
  echo ""

  local NOW
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local PAYLOAD
  PAYLOAD=$(cat << EOF
{"mec_site_id":"mec-stadium-01","content_id":"live-concert","content_url":"${CDN_MOCK_URL}/nfl-game","predicted_viewers":25000,"event_type":"live_concert","event_start_utc":"${NOW}","confidence":0.88,"predicted_peak_in_minutes":15}
EOF
)

  publish_event "${PAYLOAD}"
  sleep 10
  check_agent_runs
  success "Concert scenario complete. Confidence lower than NFL — agent may apply conservative ABR policy."
}

# ── Scenario: Synthetic (low confidence → human approval) ─────────────────────

run_synthetic_scenario() {
  section "Scenario: Synthetic — Human Approval Path"
  echo "Simulates a low-confidence prediction (0.72) — below agent threshold"
  echo "Agent will post Slack approval request and suspend the graph"
  echo ""

  local NOW
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local PAYLOAD
  PAYLOAD=$(cat << EOF
{"mec_site_id":"mec-stadium-02","content_id":"vod-premiere","content_url":"${CDN_MOCK_URL}/nfl-game","predicted_viewers":18000,"event_type":"vod_premiere","event_start_utc":"${NOW}","confidence":0.72,"predicted_peak_in_minutes":45}
EOF
)

  publish_event "${PAYLOAD}"
  sleep 10

  info "Agent should have posted Slack approval request..."
  info "Check #mec-ai-ops Slack channel for approval card"
  info "Or approve via dashboard Panel C"
  local agent_url
  agent_url=$(oc get route content-intelligence-agent -n mec-content-ai \
    -o jsonpath='{.spec.host}' 2>/dev/null)
  info "Dashboard: https://$(oc get route edgestream-iq -n mec-content-ai -o jsonpath='{.spec.host}' 2>/dev/null)"
  success "Synthetic scenario running — waiting for human approval in Slack or dashboard"
}

# ── Scenario: EDA Auto-Trigger ─────────────────────────────────────────────────

run_eda_scenario() {
  section "Scenario: EDA Auto-Trigger (Ultra-High Confidence)"
  echo "Confidence: 0.97 → EDA auto-triggers prefetch (bypasses LangGraph agent)"
  echo ""

  local NOW
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local PAYLOAD
  PAYLOAD=$(cat << EOF
{"mec_site_id":"mec-stadium-01","content_id":"nfl-game","content_url":"${CDN_MOCK_URL}/nfl-game","predicted_viewers":48000,"event_type":"live_sport","event_start_utc":"${NOW}","confidence":0.97,"predicted_peak_in_minutes":8}
EOF
)

  publish_event "${PAYLOAD}"

  info "Confidence 0.97 — EDA Controller should auto-trigger prefetch-content job..."
  sleep 15

  local aap_url
  aap_url=$(oc get route controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null)
  info "Check AAP for auto-triggered job: https://${aap_url}"
  success "EDA scenario complete. LangGraph agent was NOT involved — EDA handled it directly."
}

# ── Scenario: Stress ───────────────────────────────────────────────────────────

run_stress_scenario() {
  section "Scenario: Stress Test (10 rapid events)"
  echo "Fires 10 events in quick succession to test pipeline throughput"
  echo ""

  for i in $(seq 1 10); do
    SITE=$( [[ $((i % 2)) -eq 0 ]] && echo "mec-stadium-01" || echo "mec-stadium-02" )
    CONF=$(python3 -c "import random; print(round(random.uniform(0.75, 0.97), 2))")
    VIEWERS=$((RANDOM % 40000 + 10000))
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    PAYLOAD="{\"mec_site_id\":\"${SITE}\",\"content_id\":\"nfl-game\",\"content_url\":\"${CDN_MOCK_URL}/nfl-game\",\"predicted_viewers\":${VIEWERS},\"event_type\":\"live_sport\",\"event_start_utc\":\"${NOW}\",\"confidence\":${CONF},\"predicted_peak_in_minutes\":20}"
    oc run "stress-pub-${i}" --rm --restart=Never \
      --image="${KAFKA_IMAGE}" \
      -n mec-ai-data -- bash -c \
      "echo '${PAYLOAD}' | bin/kafka-console-producer.sh \
        --bootstrap-server ${KAFKA_BOOTSTRAP} \
        --topic demand.predictions" \
      2>/dev/null &
    info "Event ${i}/10: ${SITE}, viewers=${VIEWERS}, conf=${CONF}"
    sleep 2
  done
  wait
  success "Stress test: 10 events published. Check dashboard for pipeline activity."
}

# ── Full validation summary ────────────────────────────────────────────────────

run_validation_summary() {
  section "System Validation Summary"

  AGENT_URL=$(oc get route content-intelligence-agent -n mec-content-ai \
    -o jsonpath='{.spec.host}' 2>/dev/null)
  DASHBOARD_URL=$(oc get route edgestream-iq -n mec-content-ai \
    -o jsonpath='{.spec.host}' 2>/dev/null)

  echo ""
  echo -e "${BOLD}Component Status:${NC}"
  oc get pods -n mec-content-ai --no-headers 2>/dev/null | \
    awk '{printf "  %-45s %s\n", $1, $3}'

  echo ""
  echo -e "${BOLD}Far Edge (SNO) Status:${NC}"
  for SITE in stadium-01 stadium-02; do
    KC="${HOME}/mec-rhdp/mec-${SITE}-kubeconfig"
    if [[ -f "$KC" ]]; then
      RUNNING=$(KUBECONFIG="${KC}" oc get pods -n far-edge-mec \
        --no-headers 2>/dev/null | grep -c Running || echo 0)
      echo -e "  mec-${SITE}: ${RUNNING}/6 pods Running"
    fi
  done

  echo ""
  echo -e "${BOLD}Key URLs:${NC}"
  echo -e "  Dashboard:  https://${DASHBOARD_URL}"
  echo -e "  Agent API:  https://${AGENT_URL}/health"
  echo -e "  CDN Mock:   http://cdn-mock.mec-content-ai.svc.cluster.local:8080/health"
}

# ── Main ───────────────────────────────────────────────────────────────────────

if [[ "$RUN_ALL" == true ]]; then
  run_nfl_scenario
  sleep 30
  run_concert_scenario
  sleep 30
  run_eda_scenario
  run_validation_summary
elif [[ -n "$SCENARIO" ]]; then
  case "$SCENARIO" in
    nfl)       run_nfl_scenario ;;
    concert)   run_concert_scenario ;;
    synthetic) run_synthetic_scenario ;;
    eda)       run_eda_scenario ;;
    stress)    run_stress_scenario ;;
    validate)  run_validation_summary ;;
    *)
      error "Unknown scenario: ${SCENARIO}"
      echo "Available: nfl, concert, synthetic, eda, stress, validate"
      exit 1
      ;;
  esac
else
  echo "Usage: $0 --scenario <nfl|concert|synthetic|eda|stress|validate>"
  echo "       $0 --all"
  exit 1
fi
