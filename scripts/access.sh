#!/bin/bash -e
# access.sh — Set up local access to the Grafana Stack after deployment.
# Configures kubeconfig, waits for pods, port-forwards Grafana, and prints credentials.

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
missing=()
for cmd in terraform aws kubectl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo -e "${RED}Missing required tools: ${missing[*]}${NC}"
  echo "Install them before running this script."
  exit 1
fi

# ---------------------------------------------------------------------------
# Read Terraform outputs
# ---------------------------------------------------------------------------
echo -e "${YELLOW}[1/5] Reading Terraform outputs...${NC}"

CLUSTER_NAME=$(terraform -chdir=infra output -raw cluster_name 2>/dev/null || true)
REGION=$(terraform -chdir=infra output -raw region 2>/dev/null || true)
if [ -z "$CLUSTER_NAME" ]; then
  echo -e "${RED}  Could not read cluster_name from Terraform outputs.${NC}"
  echo "  Ensure 'terraform apply' has completed successfully in infra/."
  exit 1
fi

if [ -z "$REGION" ]; then
  REGION="us-east-1"
  echo -e "${YELLOW}  Region not in outputs, defaulting to ${REGION}.${NC}"
fi

echo -e "${GREEN}  Cluster: ${CLUSTER_NAME}  Region: ${REGION}${NC}"

# ---------------------------------------------------------------------------
# Update kubeconfig
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/5] Updating kubeconfig...${NC}"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
echo -e "${GREEN}  Kubeconfig updated.${NC}"

# ---------------------------------------------------------------------------
# Wait for boutique pods
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/5] Waiting for pods in 'boutique' namespace to be Ready...${NC}"

TIMEOUT=300
INTERVAL=10
elapsed=0

while true; do
  not_ready=$(kubectl get pods -n boutique --no-headers 2>/dev/null \
    | grep -v -E '([0-9]+)/\1\s+Running|Completed' || true)

  total=$(kubectl get pods -n boutique --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready_count=$(kubectl get pods -n boutique --no-headers 2>/dev/null \
    | grep -cE '([0-9]+)/\1\s+Running|Completed' || echo "0")

  echo "  ${ready_count}/${total} pods ready (${elapsed}s elapsed)"

  if [ "$total" -gt 0 ] && [ -z "$not_ready" ]; then
    echo -e "${GREEN}  All boutique pods are Ready.${NC}"
    break
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo -e "${RED}  Timeout waiting for boutique pods after ${TIMEOUT}s.${NC}"
    echo "  Not-ready pods:"
    echo "$not_ready" | sed 's/^/    /'
    echo -e "${YELLOW}  Continuing anyway — Grafana may still be accessible.${NC}"
    break
  fi

  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

# ---------------------------------------------------------------------------
# Wait for monitoring pods
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/5] Waiting for pods in 'monitoring' namespace to be Ready...${NC}"

elapsed=0

while true; do
  not_ready=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -v -E '([0-9]+)/\1\s+Running|Completed' || true)

  total=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready_count=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -cE '([0-9]+)/\1\s+Running|Completed' || echo "0")

  echo "  ${ready_count}/${total} pods ready (${elapsed}s elapsed)"

  if [ "$total" -gt 0 ] && [ -z "$not_ready" ]; then
    echo -e "${GREEN}  All monitoring pods are Ready.${NC}"
    break
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo -e "${RED}  Timeout waiting for monitoring pods after ${TIMEOUT}s.${NC}"
    echo "  Not-ready pods:"
    echo "$not_ready" | sed 's/^/    /'
    echo -e "${YELLOW}  Continuing anyway — some services may not be ready yet.${NC}"
    break
  fi

  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

# ---------------------------------------------------------------------------
# Port-forward Grafana
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[5/5] Setting up Grafana port-forward...${NC}"

# Kill any existing Grafana port-forward
pkill -f "kubectl port-forward.*grafana.*3000" 2>/dev/null || true
sleep 1

# Find the Grafana service name
GRAFANA_SVC=$(kubectl get svc -n monitoring -o name 2>/dev/null | grep grafana | grep -v alertmanager | head -1 || true)
if [ -z "$GRAFANA_SVC" ]; then
  echo -e "${RED}  Could not find Grafana service in monitoring namespace.${NC}"
  echo "  Check that the kube-prometheus-stack Helm release deployed successfully."
  exit 1
fi

kubectl port-forward "$GRAFANA_SVC" 3000:80 -n monitoring &>/dev/null &
PF_PID=$!
sleep 2

# Verify the port-forward is running
if kill -0 "$PF_PID" 2>/dev/null; then
  echo -e "${GREEN}  Grafana port-forward active (PID: ${PF_PID}).${NC}"
else
  echo -e "${RED}  Port-forward failed to start. Try manually:${NC}"
  echo "  kubectl port-forward ${GRAFANA_SVC} 3000:80 -n monitoring"
  exit 1
fi

# ---------------------------------------------------------------------------
# Update shared/env.json
# ---------------------------------------------------------------------------
GRAFANA_URL="http://localhost:3000"

jq --arg grafana_url "$GRAFANA_URL" \
   --arg prom_url "http://localhost:9090" \
   --arg loki_url "http://localhost:3100" \
   --arg tempo_url "http://localhost:3200" \
   '. + {
     grafana_url: $grafana_url,
     prometheus_url: $prom_url,
     loki_url: $loki_url,
     tempo_url: $tempo_url,
     infra_ready: true,
     config_ready: true
   }' "$PROJECT_ROOT/shared/env.json" > "$PROJECT_ROOT/shared/env.json.tmp" \
  && mv "$PROJECT_ROOT/shared/env.json.tmp" "$PROJECT_ROOT/shared/env.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Access ready${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Grafana:"
echo "    URL:      ${GRAFANA_URL}"
echo "    Username: admin"
echo "    Password: (retrieve via: terraform -chdir=infra output -raw grafana_admin_password)"
echo ""
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Region:     ${REGION}"
echo ""
echo "  Port-forward PID: ${PF_PID}"
echo "  To stop:    kill ${PF_PID}"
echo ""
echo -e "${YELLOW}Tip: Run scripts/validate-deploy.sh to verify the full stack.${NC}"
