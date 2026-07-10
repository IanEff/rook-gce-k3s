output "control_plane_external_ip" {
  description = "Public IP of the control-plane node. Used by manage_hosts.py (DNS-equivalent /etc/hosts entries) and fetch_kubeconfig.py (kubeconfig server rewrite + SSH transport)."
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
  description = "Ready-to-run SSH command for the control-plane node. Uses OS Login via gcloud (tied to your gcloud identity/IAM) rather than a fixed username/injected keypair — the caller needs roles/compute.osLoginUser (or admin) on the project."
  value       = "gcloud compute ssh ${var.cluster_name}-control-plane --zone=${var.zone} --project=${var.project_id}"
}
