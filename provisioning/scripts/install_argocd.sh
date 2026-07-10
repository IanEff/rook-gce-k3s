#!/bin/bash
# rook-gce-k3s — install_argocd.sh
# Bootstraps ArgoCD and seeds the root Application that drives GitOps.
#
# Requires (from /etc/rook-gce-k3s.env, written by the Tofu-rendered bootstrap
# wrapper):
#   GITOPS_REPO_URL, GITOPS_REPO_TOKEN, GITOPS_SSH_KEY_PATH
#
# Ported from ceph-lab's version. The "wait for Gateway to acquire LB IP"
# step is gone — gatewayAPI.hostNetwork mode (see cilium/values.yaml) means
# there's no floating LB IP to wait on; the Gateway is reachable as soon as
# the Envoy hostNetwork pod is Running on the control-plane node.
set -euo pipefail

export KUBECONFIG=/root/.kube/config

set -a
[ -f /etc/rook-gce-k3s.env ] && source /etc/rook-gce-k3s.env
set +a

GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REPO_TOKEN="${GITOPS_REPO_TOKEN:-}"
GITOPS_SSH_KEY_PATH="${GITOPS_SSH_KEY_PATH:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

if [ -z "$GITOPS_REPO_URL" ]; then
    echo "ERROR: GITOPS_REPO_URL is not set. Set the gitops_repo_url Tofu variable before applying."
    exit 1
fi

echo "══════════════════════════════════════════"
echo "  rook-gce-k3s — ArgoCD bootstrap           "
echo "  Repo: ${GITOPS_REPO_URL}                 "
echo "══════════════════════════════════════════"

echo "[0] Pre-bootstrap Cilium Gateway resources"
CILIUM_APP=/ceph-lab/applications/infrastructure/cilium
bootstrap_ok=0
for attempt in $(seq 1 8); do
    echo "[0] Building and applying Cilium kustomization (attempt ${attempt}/8)..."
    output=$(kubectl kustomize "${CILIUM_APP}" --enable-helm \
        | kubectl apply --server-side --force-conflicts -f - 2>&1) || true
    echo "$output"
    if echo "$output" | grep -qE 'serverside-applied| configured$| created$| unchanged$'; then
        bootstrap_ok=1
        break
    fi
    echo "[0] Attempt ${attempt}/8 incomplete; retrying in 10s..."
    sleep 10
done
if [ "$bootstrap_ok" -eq 1 ]; then
    echo "[0] Cilium resources applied. Waiting for the Gateway's hostNetwork Envoy pod to settle..."
    kubectl rollout status daemonset/cilium -n kube-system --timeout=3m || true
    kubectl wait --for=condition=Programmed gateway/cilium-gateway -n kube-system --timeout=2m || true
else
    echo "[WARN] Pre-bootstrap may be incomplete; ArgoCD will reconcile."
fi

echo "[1] Install ArgoCD (${ARGOCD_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "[2] Apply local bootstrap patches (insecure mode, kustomize-helm, bcrypt password)"
kubectl apply --server-side -k /ceph-lab/cluster-bootstrap/argocd/

echo "[4] Configure repository access"
if [ -n "$GITOPS_SSH_KEY_PATH" ] && [ -f "${GITOPS_SSH_KEY_PATH}" ]; then
    echo "  Using SSH deploy key: ${GITOPS_SSH_KEY_PATH}"
    SSH_KEY_INDENTED=$(awk '{print "    " $0}' "${GITOPS_SSH_KEY_PATH}")
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rook-gce-k3s-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  insecureIgnoreHostKey: "true"
  sshPrivateKey: |
${SSH_KEY_INDENTED}
EOF
elif [ -n "$GITOPS_REPO_TOKEN" ]; then
    echo "  Using HTTPS token"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rook-gce-k3s-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  password: "${GITOPS_REPO_TOKEN}"
  username: "git"
EOF
else
    echo "  WARNING: No repo credentials configured."
    echo "  If ${GITOPS_REPO_URL} is public, ArgoCD will clone it without auth."
fi

echo "[5] Substitute GITOPS_REPO_URL placeholder across all manifests"
find /ceph-lab/applications/clusters /ceph-lab/cluster-bootstrap \
    -type f -name "*.yaml" \
    -exec sed -i "s|GITOPS_REPO_URL|${GITOPS_REPO_URL}|g" {} +

echo "[5b] Substitute CONTROL_PLANE_IP placeholder in gitops.env and cilium/kustomization.yaml"
# Same placeholder-substitution convention as GITOPS_REPO_URL above — see the
# comment in applications/config/gitops.env for why this can't be a static
# committed value.
sed -i "s|GCE_CONTROL_PLANE_IP_PLACEHOLDER|${CONTROL_PLANE_INTERNAL_IP}|g" \
    /ceph-lab/applications/config/gitops.env \
    /ceph-lab/applications/infrastructure/cilium/kustomization.yaml

echo "[5c] Commit and push the substituted values back so ArgoCD (reading from git) picks them up"
cd /ceph-lab
git config user.email "rook-gce-k3s-bootstrap@localhost"
git config user.name "rook-gce-k3s-bootstrap"
git add -A
git commit -m "bootstrap: substitute GITOPS_REPO_URL / CONTROL_PLANE_IP placeholders" --quiet || true
if [ -n "$GITOPS_SSH_KEY_PATH" ] && [ -f "${GITOPS_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="ssh -i ${GITOPS_SSH_KEY_PATH} -o StrictHostKeyChecking=no" git push || \
        echo "[WARN] push failed — push manually or ArgoCD will see stale placeholders until this succeeds."
else
    git push || echo "[WARN] push failed — push manually or ArgoCD will see stale placeholders until this succeeds."
fi

echo "[5d] Apply root Application (seeds entire GitOps tree)"
kubectl apply -f /ceph-lab/cluster-bootstrap/bootstrap/root-app.yaml

echo "[6] Install argocd CLI"
ARGOCD_CLI_VERSION=$(curl -sL \
    https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
ARCH=$(dpkg --print-architecture)
curl -fsSL -o /usr/local/bin/argocd \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}"
chmod +x /usr/local/bin/argocd

echo ""
echo "✓ ArgoCD is bootstrapped!"
echo ""
echo "  UI:       https://argocd.ceph-gce.lab  (after manage_hosts.py has run on the Mac)"
echo "  Login:    admin / password  (CHANGE IN PRODUCTION)"
echo ""
echo "  Watch sync progress:"
echo "    kubectl get applications -n argocd -w"
echo ""
echo "  Sync waves overview:"
echo "    -15: gateway-api CRDs"
echo "    -10: cilium (reconciled)"
echo "     -6: prometheus-operator-crds"
echo "     -5: grafana, prometheus, tempo"
echo "      0: otel-collector"
echo "      1: l7-policies (CiliumNetworkPolicies)"
echo "      5: topology-catalog, loki"
echo "      6: promtail"
echo "     10: argocd-ingress"
echo "     20: rook operator"
echo "     25: rook cluster (CephCluster CR)"
echo "     30: rook storage, ceph-latency-bridge"
echo "     31: rook dashboards"
echo "     35: rook gateway routes"
echo "     40: chaos-mesh, s3-traffic-generator"
