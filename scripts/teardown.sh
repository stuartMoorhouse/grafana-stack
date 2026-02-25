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
# Confirmation prompt
# ---------------------------------------------------------------------------
echo -e "${YELLOW}WARNING: This will destroy all resources created by the Grafana Stack project.${NC}"
echo ""
echo "Resources that will be destroyed:"
echo "  - EKS cluster and managed node groups"
echo "  - VPC, subnets, NAT gateways, and security groups"
echo "  - All Helm releases (Grafana, Prometheus, Loki, Tempo, OTel Collector, Online Boutique)"
echo "  - Associated IAM roles and policies"
echo ""
read -rp "This will destroy all resources. Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Capture cluster info before destroy (best-effort)
# ---------------------------------------------------------------------------
CLUSTER_NAME=""
REGION=""
if [ -f "$PROJECT_ROOT/infra/terraform.tfstate" ] || [ -d "$PROJECT_ROOT/infra/.terraform" ]; then
  CLUSTER_NAME=$(terraform -chdir=infra output -raw cluster_name 2>/dev/null || true)
  REGION=$(terraform -chdir=infra output -raw region 2>/dev/null || true)
fi

# Fall back to variable defaults if outputs unavailable
if [ -z "$REGION" ]; then
  REGION="us-east-1"
fi
if [ -z "$CLUSTER_NAME" ]; then
  CLUSTER_NAME="grafana-demo-cluster"
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
# Clean up kubeconfig context
# ---------------------------------------------------------------------------
echo -e "\n${YELLOW}[3/4] Cleaning up kubeconfig context...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -n "$ACCOUNT_ID" ]; then
  CONTEXT_NAME="arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
else
  CONTEXT_NAME=""
fi

if kubectl config get-contexts "$CONTEXT_NAME" &>/dev/null; then
  kubectl config delete-context "$CONTEXT_NAME" 2>/dev/null && echo "  Removed context: $CONTEXT_NAME" || true
  kubectl config delete-cluster "$CONTEXT_NAME" 2>/dev/null && echo "  Removed cluster: $CONTEXT_NAME" || true
  # Remove the user entry as well
  kubectl config unset "users.${CONTEXT_NAME}" 2>/dev/null || true
  echo -e "${GREEN}  Kubeconfig cleaned.${NC}"
else
  # Try a broader match — the context may use a slightly different name
  matching_ctx=$(kubectl config get-contexts -o name 2>/dev/null | grep "${CLUSTER_NAME}" || true)
  if [ -n "$matching_ctx" ]; then
    while IFS= read -r ctx; do
      kubectl config delete-context "$ctx" 2>/dev/null && echo "  Removed context: $ctx" || true
    done <<< "$matching_ctx"
    echo -e "${GREEN}  Kubeconfig cleaned.${NC}"
  else
    echo "  No matching kubeconfig context found — nothing to clean."
  fi
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
echo "    - EKS cluster: ${CLUSTER_NAME}"
echo "    - Region: ${REGION}"
echo "    - All Helm releases and Kubernetes resources"
echo "    - VPC and networking resources"
echo "    - IAM roles and policies"
echo ""
echo "  Cleaned up:"
echo "    - Kubeconfig context for ${CLUSTER_NAME}"
echo "    - shared/env.json reset to defaults"
echo "    - Active port-forwards stopped"
echo ""
echo -e "${YELLOW}Note: Terraform state files in infra/ are still present for reference.${NC}"
