#!/usr/bin/env bash
#
# Emergency teardown of every gcloud resource this repo creates, bypassing
# OpenTofu entirely (`just destroy` needs a working `.terraform/` state --
# this doesn't, which is the point of a ripcord). Ported from rook-gke's
# scripts/ripcord.sh; the resource set here is much smaller and lower-risk
# by design, since this repo's OSD disks are ordinary Tofu-managed
# google_compute_disk resources (not CSI-provisioned PVCs) — there's no
# "orphaned PVC-backed disk" bug class here at all, only the ordinary case
# of a partial/interrupted apply leaving named resources behind.
#
# Deliberately itemized rather than a blanket "delete everything with this
# prefix" filter, so a resource type added later is easy to slot in and
# nothing sharing this project (other unrelated infra) is ever at risk.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PROJECT_ID=${PROJECT_ID:-"terraform-sandbox-430820"}
ZONE=${ZONE:-"us-central1-a"}
REGION=${REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"rook-gce-k3s"}

echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo "Cluster:  ${CLUSTER_NAME}"
echo

# --- 1. Instances (compute.tf: google_compute_instance.control_plane, .node) ---
echo "[1/6] Deleting instances..."
mapfile -t instances < <(gcloud compute instances list --project="${PROJECT_ID}" \
  --filter="name~'^${CLUSTER_NAME}-'" --format="value(name)" 2>/dev/null || true)
if [ "${#instances[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  gcloud compute instances delete "${instances[@]}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>&1 \
    || echo "  -> some deletes failed, check manually."
fi
echo

# --- 2. OSD disks (compute.tf: google_compute_disk.osd) ---
echo "[2/6] Deleting OSD disks..."
mapfile -t osd_disks < <(gcloud compute disks list --project="${PROJECT_ID}" \
  --filter="name~'^${CLUSTER_NAME}-osd-'" --format="value(name)" 2>/dev/null || true)
if [ "${#osd_disks[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  gcloud compute disks delete "${osd_disks[@]}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>&1 \
    || echo "  -> some deletes failed, check manually."
fi
echo

# --- 3. Static IPs (compute.tf: google_compute_address.control_plane_internal/_external) ---
echo "[3/6] Deleting static IPs..."
gcloud compute addresses delete "${CLUSTER_NAME}-control-plane-internal" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> internal address already deleted or not found."
gcloud compute addresses delete "${CLUSTER_NAME}-control-plane-external" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> external address already deleted or not found."
echo

# --- 4. Firewall rules (network.tf) ---
echo "[4/6] Deleting firewall rules..."
for fw in allow-ssh allow-k3s-api allow-gateway allow-internal; do
  gcloud compute firewall-rules delete "${CLUSTER_NAME}-${fw}" \
    --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> ${CLUSTER_NAME}-${fw} already deleted or not found."
done
echo

# --- 5. Subnetwork (network.tf: google_compute_subnetwork.main) ---
echo "[5/6] Deleting subnetwork..."
gcloud compute networks subnets delete "${CLUSTER_NAME}-subnet" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 6. VPC network (network.tf: google_compute_network.main) ---
echo "[6/6] Deleting VPC network..."
gcloud compute networks delete "${CLUSTER_NAME}-vpc" \
  --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- Verify: re-list every resource type independently rather than trusting
# delete exit codes (a delete can report failure on something already gone).
echo "Verifying teardown..."
status=0

check_gone() {
  local label="$1" list_cmd="$2"
  local left
  left=$(eval "$list_cmd" 2>/dev/null || true)
  if [ -n "$left" ]; then
    echo "  [FAIL] ${label} still present: $(echo "$left" | tr '\n' ' ')"
    status=1
  else
    echo "  [ok]   ${label} gone."
  fi
}

check_gone "Instances" \
  "gcloud compute instances list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-'\" --format='value(name)'"
check_gone "OSD disks" \
  "gcloud compute disks list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-osd-'\" --format='value(name)'"
check_gone "Static IPs" \
  "gcloud compute addresses list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-control-plane-'\" --format='value(name)'"
check_gone "Firewall rules" \
  "gcloud compute firewall-rules list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-allow-'\" --format='value(name)'"
check_gone "Subnetwork" \
  "gcloud compute networks subnets list --project '${PROJECT_ID}' --filter=\"name=${CLUSTER_NAME}-subnet\" --format='value(name)'"
check_gone "VPC network" \
  "gcloud compute networks list --project '${PROJECT_ID}' --filter=\"name=${CLUSTER_NAME}-vpc\" --format='value(name)'"

echo
if [ "$status" -eq 0 ]; then
  if [ -f terraform.tfstate ] || [ -f terraform.tfstate.backup ]; then
    rm -f terraform.tfstate terraform.tfstate.backup
    echo "Local terraform.tfstate cleared (was describing now-deleted resources)."
  fi
  echo "Ripcord complete -- all resources confirmed gone. Cost is zero from here."
else
  echo "Ripcord finished with leftovers -- see [FAIL] lines above. Investigate manually before re-applying."
  echo "Local terraform.tfstate left untouched since teardown was incomplete."
fi
exit "$status"
