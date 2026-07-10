# rook-gce-k3s

A k3s + Rook-Ceph + Cilium + Prometheus/Grafana/Sloth + Chaos Mesh test rig
for `thump` (an agentic SRE), running on plain GCE VMs. Fork of
[`ceph-lab`](../ceph-lab) (same stack, on Lima VMs) with the provisioning
layer replaced by OpenTofu + GCE — see [CLAUDE.md](CLAUDE.md) for the full
rationale and what changed.

Designed around one constraint ceph-lab's Lima setup can't meet: it needs to
run somewhere other than a laptop, while staying **zero cost when torn down,
cheap when up, and stable** for chaos experiments.

## Quick start

```bash
# 1. Set your IP allowlist and GitOps repo (gitignored)
cat > terraform.tfvars <<EOF
allowed_source_ranges = ["YOUR.IP.HERE/32"]
gitops_repo_url        = "git@github.com:YOUR_USERNAME/rook-gce-k3s.git"
EOF
# Deploy key needs WRITE access — see CLAUDE.md gotcha #6 for why.
# Put the private half at ./deploy_rook-gce-k3s (gitignored).

# 2. Stand up the cluster (~2-4 min: no GKE control plane, no regional
#    replication — just a handful of GCE VMs booting k3s)
just up

# 3. Watch ArgoCD sync the world
kubectl --context ceph-gce get applications -n argocd -w

# 4. Check Ceph health
kubectl --context ceph-gce exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# 5. Tear down — true zero cost, nothing left billing
just destroy
```

## Service directory

Once `just up` finishes, these resolve via the `/etc/hosts` entries
`just credentials` writes:

| Service | URL |
|---|---|
| ArgoCD | https://argocd.ceph-gce.lab |
| Grafana | https://grafana.ceph-gce.lab |
| Ceph Dashboard | https://dashboard.ceph-gce.lab |
| Hubble UI | https://hubble.ceph-gce.lab |
| Prometheus | https://prometheus.ceph-gce.lab |

## Chaos testing

Chaos Mesh is deployed at sync wave 40 (after Rook settles). Run an
experiment against a live OSD and watch Grafana/Prometheus reflect it:

```bash
kubectl --context ceph-gce apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-one-osd
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [rook-ceph]
    labelSelectors:
      app: rook-ceph-osd
EOF
```

See [CLAUDE.md](CLAUDE.md) for the full architecture, what's vendored from
ceph-lab unchanged, and every deliberate deviation from it.
