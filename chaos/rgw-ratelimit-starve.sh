#!/bin/bash
# rook-gce-k3s — chaos/rgw-ratelimit-starve.sh
#
# Forces real RGW request failures (radosgw's "Aborted requests" perf
# counter, ceph_rgw_failed_req — the metric the ceph-rgw-availability
# Sloth SLO burns on) by throttling the traffic-generator's RGW user down
# to near-zero ops/min via `radosgw-admin ratelimit`, rather than by
# degrading the network or the backing pool.
#
# Why this exists: pg-num-starve.sh (starving the same RGW data pool down
# to pg_num=1) and chaos-mesh NetworkChaos (delay/loss on the RGW pod)
# were both tried first and both failed to move ceph_rgw_failed_req at
# all — confirmed live 2026-07-13. Both mechanisms only add *latency*;
# ops still eventually complete, so nothing ever "fails". RGW's own perf
# counter only increments on a request that's actually aborted, so the
# lever has to make ops fail outright, not just slow down. A rate limit
# does exactly that: RGW itself rejects requests over the cap, no
# network/pool trickery required.
#
# Usage (same ceph-gce kubeconfig-context assumption as pg-num-starve.sh):
#   chaos/rgw-ratelimit-starve.sh           # starve: 1 read-op/min, 1 write-op/min
#   chaos/rgw-ratelimit-starve.sh restore   # disable the ratelimit
#
# The zonegroup/zone flags below are NOT optional — radosgw-admin's
# default zonegroup lookup ("default") doesn't match this cluster's real
# zonegroup name ("ceph-objectstore") and every command fails with
# "ERROR: incorrect zonegroup" without them. Found this out the hard way.
set -euo pipefail

NAMESPACE="rook-ceph"
ZONEGROUP="ceph-objectstore"
ZONE="ceph-objectstore"
ACTION="${1:-starve}"

_toolbox() { kubectl exec -n "$NAMESPACE" deploy/rook-ceph-tools -- "$@" --rgw-zonegroup="$ZONEGROUP" --rgw-zone="$ZONE"; }

# The traffic generator's RGW user is OBC-provisioned (ObjectBucketClaim),
# so its uid carries a random UUID suffix that changes every time the
# bucket/OBC is recreated — look it up live by access key rather than
# hardcoding it.
ACCESS_KEY="$(kubectl -n default get secret traffic-generator-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
UID_LOOKUP="$(_toolbox radosgw-admin user info --access-key="$ACCESS_KEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user_id"])')"

case "$ACTION" in
  starve)
    echo "Rate-limiting RGW user ${UID_LOOKUP} to 1 read-op/min, 1 write-op/min..."
    _toolbox radosgw-admin ratelimit set --ratelimit-scope=user --uid="$UID_LOOKUP" \
      --max-read-ops=1 --max-write-ops=1
    _toolbox radosgw-admin ratelimit enable --ratelimit-scope=user --uid="$UID_LOOKUP"
    echo "--- after ---"
    _toolbox radosgw-admin ratelimit get --ratelimit-scope=user --uid="$UID_LOOKUP"
    ;;
  restore)
    echo "Disabling the ratelimit on ${UID_LOOKUP}..."
    _toolbox radosgw-admin ratelimit disable --ratelimit-scope=user --uid="$UID_LOOKUP"
    echo "--- after ---"
    _toolbox radosgw-admin ratelimit get --ratelimit-scope=user --uid="$UID_LOOKUP"
    ;;
  *)
    echo "Usage: $0 [starve|restore]" >&2
    exit 1
    ;;
esac
