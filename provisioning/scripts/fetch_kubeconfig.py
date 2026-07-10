#!/usr/bin/env python3
"""Fetch and merge kubeconfig for the rook-gce-k3s cluster.

Ported from ceph-lab's manage_k8s_config.py: the transport becomes
`gcloud compute ssh ... --command` (OS Login) instead of `limactl shell`, and
the fetched kubeconfig's server URL is rewritten from the control-plane's
INTERNAL static IP (what control-plane.sh's own kubeconfig already uses
internally) to its EXTERNAL static IP, since that's the address reachable
from your Mac. No TLS-verify skip is needed for this rewrite — k3s's
tls-san list (control-plane.sh) already includes both IPs, so the existing
CA still validates against the external address.

Usage:
    python3 fetch_kubeconfig.py add    (requires: tofu output values below)
    python3 fetch_kubeconfig.py remove
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

KUBE_CONFIG_PATH = Path.home() / ".kube" / "config"

NEW_CONTEXT_NAME = "ceph-gce"
NEW_USER_NAME = "ceph-gce-admin"
NEW_CLUSTER_NAME = "ceph-gce-cluster"


def tofu_output(name: str) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", name],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"tofu output -raw {name} failed: {result.stderr.strip()}", file=sys.stderr)
        print("Run this from the repo root after `tofu apply`.", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def backup_file(path: Path) -> None:
    if path.exists():
        import time
        backup_path = path.with_suffix(f".bak.{int(time.time())}")
        shutil.copy2(path, backup_path)
        print(f"Backed up {path.name} to {backup_path.name}")


def add() -> None:
    project_id = os.environ.get("PROJECT_ID") or tofu_output_or_default()
    zone = os.environ.get("ZONE", "us-central1-a")
    cluster_name = os.environ.get("CLUSTER_NAME", "rook-gce-k3s")
    external_ip = tofu_output("control_plane_external_ip")
    internal_ip = tofu_output("control_plane_internal_ip")

    instance = f"{cluster_name}-control-plane"
    print(f"Fetching kubeconfig from {instance} via gcloud compute ssh...")
    cmd = [
        "gcloud", "compute", "ssh", instance,
        f"--zone={zone}", f"--project={project_id}",
        "--command=sudo cat /root/.kube/config",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Failed to fetch kubeconfig: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)

    tmpdir = Path(tempfile.mkdtemp(prefix="rook_gce_k3s_"))
    temp_conf = tmpdir / "k3s.yaml"
    merged_conf = tmpdir / "kubeconfig.merged"
    try:
        content = result.stdout
        # Rewrite server URL: internal IP (what control-plane.sh set) -> external
        # IP (reachable from the Mac). tls-san already covers both, so no
        # insecure-skip-tls-verify is needed.
        content = content.replace(internal_ip, external_ip)
        content = content.replace("current-context: default", f"current-context: {NEW_CONTEXT_NAME}")
        import re
        content = re.sub(r"\bcluster: default\b", f"cluster: {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"\buser: default\b", f"user: {NEW_USER_NAME}", content)
        content = re.sub(r"(- context:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CONTEXT_NAME}", content)
        content = re.sub(r"(- cluster:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"(?m)^- name:\s+default$", f"- name: {NEW_USER_NAME}", content)
        temp_conf.write_text(content, encoding="utf-8")

        print("Merging kubeconfig...")
        env = os.environ.copy()
        env["KUBECONFIG"] = f"{temp_conf}:{KUBE_CONFIG_PATH}" if KUBE_CONFIG_PATH.exists() else str(temp_conf)
        with open(merged_conf, "w") as f:
            merge = subprocess.run(["kubectl", "config", "view", "--flatten"], env=env, stdout=f)
        if merge.returncode != 0:
            print("Failed to merge kubeconfig.", file=sys.stderr)
            sys.exit(1)

        backup_file(KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(merged_conf), KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.chmod(0o600)
        print(f"Kubeconfig updated. Context '{NEW_CONTEXT_NAME}' is now current.")
        print(f"  Server: https://{external_ip}:6443")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def tofu_output_or_default() -> str:
    # project_id isn't a Tofu output today; fall back to gcloud's configured
    # default project rather than adding an output just for this.
    result = subprocess.run(["gcloud", "config", "get-value", "project"], capture_output=True, text=True)
    return result.stdout.strip()


def remove() -> None:
    print("Removing rook-gce-k3s Kubernetes configuration...")
    cmds = [
        ["kubectl", "config", "delete-context", NEW_CONTEXT_NAME],
        ["kubectl", "config", "delete-cluster", NEW_CLUSTER_NAME],
        ["kubectl", "config", "delete-user", NEW_USER_NAME],
    ]
    for cmd in cmds:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("Kubeconfig cleaned up (best effort).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["add", "remove"])
    args = parser.parse_args()
    add() if args.action == "add" else remove()


if __name__ == "__main__":
    main()
