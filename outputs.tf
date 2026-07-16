output "zone" {
  description = "Zone instances were actually provisioned in — the justfile reads this rather than hardcoding a zone, so SSH/tunnel/kubeconfig recipes stay correct across zone moves (stockouts, region migrations)."
  value       = var.zone
}

output "region" {
  description = "Region instances were actually provisioned in — see zone output for why the justfile derives this instead of hardcoding it."
  value       = var.region
}

output "control_plane_external_ip" {
  description = "Public IP of the control-plane node. Used by manage_hosts.py (DNS-equivalent /etc/hosts entries for the Cilium Gateway, still IP-reachable) — no longer used by fetch_kubeconfig.py, since SSH/the k3s API are IAP-tunnel-only now (see network.tf)."
  value       = google_compute_address.control_plane_external.address
}

output "control_plane_internal_ip" {
  description = "Internal VPC IP of the control-plane node (k3s advertise-address / node-ip)."
  value       = google_compute_address.control_plane_internal.address
}

output "node_external_ips" {
  description = "Public IPs of each worker node, for direct per-node SSH (just ssh node-<n>)."
  value       = { for i, inst in google_compute_instance.node : inst.name => inst.network_interface[0].access_config[0].nat_ip }
}

output "ssh_control_plane_command" {
  description = "Ready-to-run SSH command for the control-plane node. Uses OS Login via gcloud (tied to your gcloud identity/IAM) rather than a fixed username/injected keypair, tunneled through IAP since port 22 is IAP-only (see network.tf) — the caller needs both roles/compute.osLoginUser and roles/iap.tunnelResourceAccessor (or admin) on the project."
  value       = "gcloud compute ssh ${var.cluster_name}-control-plane --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

# thump's S3-compatible object store (storage.tf) — feeds the four
# S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY values thump's beats
# require in the broker path. The endpoint is a fixed GCS constant, not a
# per-bucket attribute — it's the same for every bucket in every project.
output "thump_s3_endpoint" {
  description = "GCS's S3-compatible XML/interop API endpoint — always this value, independent of bucket/region."
  value       = "https://storage.googleapis.com"
}

output "thump_s3_bucket" {
  description = "Name of the bucket thump's WAL shipper / S3Store write to."
  value       = google_storage_bucket.thump_wal.name
}

output "thump_s3_access_key" {
  description = "HMAC access ID for thump's dedicated storage service account — not secret on its own (paired with thump_s3_secret_key)."
  value       = google_storage_hmac_key.thump_storage.access_id
}

output "thump_s3_secret_key" {
  description = "HMAC secret for thump's dedicated storage service account. Sensitive — `tofu output -raw thump_s3_secret_key` to retrieve it for .env, never printed by a bare `tofu output`/`apply`."
  value       = google_storage_hmac_key.thump_storage.secret
  sensitive   = true
}
