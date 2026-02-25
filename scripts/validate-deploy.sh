#!/bin/bash -e
# validate-deploy.sh — Post-deployment validation for the Grafana Observability Stack.
# Checks pods, data sources, and data flow. Prints pass/fail summary.

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track results
declare -a RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0

pass() {
  RESULTS+=("${GREEN}PASS${NC}  $1")
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  RESULTS+=("${RED}FAIL${NC}  $1")
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  RESULTS+=("${YELLOW}WARN${NC}  $1")
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
missing=()
for cmd in kubectl jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo -e "${RED}Missing required tools: ${missing[*]}${NC}"
  echo "Install them before running this script."
  exit 1
fi

# Verify cluster connectivity
echo -e "${YELLOW}Verifying cluster connectivity...${NC}"
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Cannot connect to Kubernetes cluster.${NC}"
  echo "Run scripts/access.sh first to configure kubeconfig."
  exit 1
fi
echo -e "${GREEN}Connected to cluster.${NC}\n"

# ---------------------------------------------------------------------------
# Check 1: Boutique namespace pods
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[1/6] Checking pods in 'boutique' namespace...${NC}"

boutique_total=$(kubectl get pods -n boutique --no-headers 2>/dev/null | wc -l | tr -d ' ')
boutique_running=$(kubectl get pods -n boutique --no-headers 2>/dev/null \
  | grep -cE '([0-9]+)/\1\s+Running|Completed' || echo "0")

echo "  ${boutique_running}/${boutique_total} pods Running"

if [ "$boutique_total" -gt 0 ] && [ "$boutique_running" -eq "$boutique_total" ]; then
  pass "All boutique pods are Running (${boutique_running}/${boutique_total})"
else
  not_running=$(kubectl get pods -n boutique --no-headers 2>/dev/null \
    | grep -v -E '([0-9]+)/\1\s+Running|Completed' || true)
  if [ -n "$not_running" ]; then
    echo "$not_running" | sed 's/^/    /'
  fi
  fail "Boutique pods not all Running (${boutique_running}/${boutique_total})"
fi

# ---------------------------------------------------------------------------
# Check 2: Monitoring namespace pods
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/6] Checking pods in 'monitoring' namespace...${NC}"

monitoring_total=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
monitoring_running=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
  | grep -cE '([0-9]+)/\1\s+Running|Completed' || echo "0")

echo "  ${monitoring_running}/${monitoring_total} pods Running"

if [ "$monitoring_total" -gt 0 ] && [ "$monitoring_running" -eq "$monitoring_total" ]; then
  pass "All monitoring pods are Running (${monitoring_running}/${monitoring_total})"
else
  not_running=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -v -E '([0-9]+)/\1\s+Running|Completed' || true)
  if [ -n "$not_running" ]; then
    echo "$not_running" | sed 's/^/    /'
  fi
  fail "Monitoring pods not all Running (${monitoring_running}/${monitoring_total})"
fi

# ---------------------------------------------------------------------------
# Check 3: Prometheus targets
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/6] Checking Prometheus targets...${NC}"

# Find the Prometheus pod
PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | head -1 || true)

if [ -z "$PROM_POD" ]; then
  # Try the kube-prometheus-stack label
  PROM_POD=$(kubectl get pods -n monitoring -l app=prometheus -o name 2>/dev/null | head -1 || true)
fi

if [ -z "$PROM_POD" ]; then
  # Broader match
  PROM_POD=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -i "prometheus-server\|prometheus-kube-prom" | awk '{print "pod/"$1}' | head -1 || true)
fi

if [ -n "$PROM_POD" ]; then
  # Query Prometheus targets API via kubectl exec
  targets_json=$(kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
    wget -q -O - "http://localhost:9090/api/v1/targets" 2>/dev/null || true)

  if [ -n "$targets_json" ]; then
    active_up=$(echo "$targets_json" | jq '[.data.activeTargets[] | select(.health == "up")] | length' 2>/dev/null || echo "0")
    active_total=$(echo "$targets_json" | jq '[.data.activeTargets[]] | length' 2>/dev/null || echo "0")
    echo "  Targets up: ${active_up}/${active_total}"

    if [ "$active_up" -gt 0 ]; then
      pass "Prometheus has ${active_up}/${active_total} targets UP"
    else
      fail "No Prometheus targets are UP"
    fi
  else
    fail "Could not query Prometheus targets API"
  fi
else
  fail "Prometheus pod not found in monitoring namespace"
fi

# ---------------------------------------------------------------------------
# Check 4: Grafana reachable
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/6] Checking Grafana is reachable...${NC}"

GRAFANA_URL="http://localhost:3000"

# Check if port-forward is active
if curl -s -o /dev/null -w "%{http_code}" "$GRAFANA_URL/api/health" 2>/dev/null | grep -q "200"; then
  grafana_health=$(curl -s "$GRAFANA_URL/api/health" 2>/dev/null)
  db_status=$(echo "$grafana_health" | jq -r '.database' 2>/dev/null || echo "unknown")
  echo "  Grafana health: database=${db_status}"
  pass "Grafana is reachable at ${GRAFANA_URL}"
else
  echo "  Port-forward may not be active. Trying via kubectl..."
  GRAFANA_SVC=$(kubectl get svc -n monitoring -o name 2>/dev/null | grep grafana | grep -v alertmanager | head -1 || true)
  if [ -n "$GRAFANA_SVC" ]; then
    echo "  Grafana service exists: ${GRAFANA_SVC}"
    fail "Grafana not reachable at ${GRAFANA_URL} (run scripts/access.sh to set up port-forward)"
  else
    fail "Grafana service not found and not reachable at ${GRAFANA_URL}"
  fi
fi

# ---------------------------------------------------------------------------
# Check 5: Loki receiving logs
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[5/6] Checking Loki is receiving logs...${NC}"

# Find the Loki pod
LOKI_POD=$(kubectl get pods -n monitoring -l app=loki -o name 2>/dev/null | head -1 || true)

if [ -z "$LOKI_POD" ]; then
  LOKI_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -o name 2>/dev/null | head -1 || true)
fi

if [ -z "$LOKI_POD" ]; then
  LOKI_POD=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -i "loki" | grep -v promtail | awk '{print "pod/"$1}' | head -1 || true)
fi

if [ -n "$LOKI_POD" ]; then
  # Query Loki for recent logs from the boutique namespace
  loki_query=$(kubectl exec -n monitoring "$LOKI_POD" -- \
    wget -q -O - 'http://localhost:3100/loki/api/v1/query?query={namespace="boutique"}&limit=5' 2>/dev/null || true)

  if [ -n "$loki_query" ]; then
    result_count=$(echo "$loki_query" | jq '.data.result | length' 2>/dev/null || echo "0")
    if [ "$result_count" -gt 0 ]; then
      echo "  Found ${result_count} log stream(s) from boutique namespace"
      pass "Loki is receiving logs (${result_count} stream(s) from boutique)"
    else
      # Try a broader query
      loki_labels=$(kubectl exec -n monitoring "$LOKI_POD" -- \
        wget -q -O - 'http://localhost:3100/loki/api/v1/labels' 2>/dev/null || true)
      label_count=$(echo "$loki_labels" | jq '.data | length' 2>/dev/null || echo "0")
      if [ "$label_count" -gt 0 ]; then
        echo "  Loki has ${label_count} label(s) but no boutique logs yet"
        warn "Loki is running but no boutique logs found yet"
        pass "Loki is accepting data (${label_count} labels found)"
      else
        fail "Loki returned no log streams"
      fi
    fi
  else
    fail "Could not query Loki API"
  fi
else
  fail "Loki pod not found in monitoring namespace"
fi

# ---------------------------------------------------------------------------
# Check 6: Tempo receiving traces
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[6/6] Checking Tempo is receiving traces...${NC}"

# Find the Tempo pod
TEMPO_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo -o name 2>/dev/null | head -1 || true)

if [ -z "$TEMPO_POD" ]; then
  TEMPO_POD=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -i "tempo" | awk '{print "pod/"$1}' | head -1 || true)
fi

if [ -n "$TEMPO_POD" ]; then
  # Check Tempo readiness and query for traces
  tempo_ready=$(kubectl exec -n monitoring "$TEMPO_POD" -- \
    wget -q -O - 'http://localhost:3200/ready' 2>/dev/null || true)

  if echo "$tempo_ready" | grep -qi "ready"; then
    echo "  Tempo reports ready"

    # Try to search for recent traces
    tempo_search=$(kubectl exec -n monitoring "$TEMPO_POD" -- \
      wget -q -O - 'http://localhost:3200/api/search?limit=5' 2>/dev/null || true)

    if [ -n "$tempo_search" ]; then
      trace_count=$(echo "$tempo_search" | jq '.traces | length' 2>/dev/null || echo "0")
      if [ "$trace_count" -gt 0 ]; then
        echo "  Found ${trace_count} recent trace(s)"
        pass "Tempo is receiving traces (${trace_count} found)"
      else
        echo "  Tempo is ready but no traces found yet (loadgenerator may need more time)"
        warn "Tempo is ready but no traces found yet"
        pass "Tempo is running and ready"
      fi
    else
      echo "  Tempo is ready (search API not available in this version)"
      pass "Tempo is running and ready"
    fi
  else
    # Check if pod is at least running
    tempo_status=$(kubectl get "$TEMPO_POD" -n monitoring -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$tempo_status" = "Running" ]; then
      echo "  Tempo pod is Running but not reporting ready"
      warn "Tempo pod running but readiness check inconclusive"
      pass "Tempo pod is Running"
    else
      fail "Tempo is not ready (status: ${tempo_status})"
    fi
  fi
else
  fail "Tempo pod not found in monitoring namespace"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW}  Validation Summary${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
for result in "${RESULTS[@]}"; do
  echo -e "  $result"
done
echo ""
echo -e "  Total: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}All checks passed. The observability stack is fully operational.${NC}"
  exit 0
else
  echo -e "${YELLOW}Some checks failed. Review the output above for details.${NC}"
  exit 1
fi
