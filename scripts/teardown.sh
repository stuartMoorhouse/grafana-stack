#!/bin/bash -e
# teardown.sh — Destroy all Grafana Stack infrastructure and clean up local state.

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
for cmd in terraform kubectl jq; do
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
# Confirmation prompt
# ---------------------------------------------------------------------------
echo -e "${YELLOW}WARNING: This will destroy all resources created by the Grafana Stack project.${NC}"
echo ""
echo "Resources that will be destroyed:"
echo "  - VKE cluster and node pools"
echo "  - All Helm releases (Grafana, Prometheus, Loki, Tempo, OTel Collector)"
echo "  - Online Boutique deployment"
echo "  - Associated Vultr Load Balancers"
echo ""
read -rp "This will destroy all resources. Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Capture cluster info before destroy (best-effort)
# ---------------------------------------------------------------------------
CLUSTER_ID=""
REGION=""
KUBECONFIG_PATH=""
if [ -f "$PROJECT_ROOT/infra/terraform.tfstate" ] || [ -d "$PROJECT_ROOT/infra/.terraform" ]; then
  CLUSTER_ID=$(terraform -chdir=infra output -raw cluster_id 2>/dev/null || true)
  REGION=$(terraform -chdir=infra output -raw region 2>/dev/null || true)
  KUBECONFIG_PATH=$(terraform -chdir=infra output -raw kubeconfig_path 2>/dev/null || true)
fi

if [ -z "$REGION" ]; then
  REGION="ewr"
fi

# ---------------------------------------------------------------------------
# Kill any active port-forwards for Grafana
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[1/4] Stopping any active port-forwards...${NC}"
pkill -f "kubectl port-forward.*grafana" 2>/dev/null && echo "  Stopped Grafana port-forward." || echo "  No active port-forwards found."

# ---------------------------------------------------------------------------
# Terraform destroy
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[2/4] Running terraform destroy...${NC}"
terraform -chdir=infra destroy -auto-approve

echo -e "${GREEN}  Terraform destroy completed.${NC}"

# ---------------------------------------------------------------------------
# Clean up kubeconfig
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Cleaning up kubeconfig...${NC}"

# Remove the Terraform-generated kubeconfig file
if [ -n "$KUBECONFIG_PATH" ] && [ -f "$KUBECONFIG_PATH" ]; then
  rm -f "$KUBECONFIG_PATH"
  echo "  Removed kubeconfig: $KUBECONFIG_PATH"
fi

# Also clean up any matching kubectl contexts
matching_ctx=$(kubectl config get-contexts -o name 2>/dev/null | grep -i "vultr\|vke\|grafana-demo" || true)
if [ -n "$matching_ctx" ]; then
  while IFS= read -r ctx; do
    kubectl config delete-context "$ctx" 2>/dev/null && echo "  Removed context: $ctx" || true
  done <<< "$matching_ctx"
  echo -e "${GREEN}  Kubeconfig cleaned.${NC}"
else
  echo "  No matching kubeconfig contexts found — nothing to clean."
fi

# ---------------------------------------------------------------------------
# Reset shared/env.json
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[4/4] Resetting shared/env.json...${NC}"
cat > "$PROJECT_ROOT/shared/env.json" <<'EOF'
{
  "grafana_url": "",
  "prometheus_url": "",
  "loki_url": "",
  "tempo_url": "",
  "infra_ready": false,
  "config_ready": false,
  "demo_executed": false
}
EOF
echo -e "${GREEN}  shared/env.json reset.${NC}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Teardown complete${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Destroyed:"
echo "    - VKE cluster: ${CLUSTER_ID:-unknown}"
echo "    - Region: ${REGION}"
echo "    - All Helm releases and Kubernetes resources"
echo "    - Vultr Load Balancers"
echo ""
echo "  Cleaned up:"
echo "    - Kubeconfig file"
echo "    - shared/env.json reset to defaults"
echo "    - Active port-forwards stopped"
echo ""
echo -e "${YELLOW}Note: Terraform state files in infra/ are still present for reference.${NC}"
