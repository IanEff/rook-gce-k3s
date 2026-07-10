resource "google_compute_network" "main" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Single subnet, no secondary ranges. Unlike GKE (rook-gke's vpc.tf), Cilium
# brings its own pod/service IPAM (POD_CIDR/SERVICE_CIDR in gitops.env) — the
# VPC subnet only needs to cover the VM's own addresses.
resource "google_compute_subnetwork" "main" {
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

resource "google_compute_firewall" "allow_ssh" {
  name          = "${var.cluster_name}-allow-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = var.allowed_source_ranges
  target_tags   = ["${var.cluster_name}-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_k3s_api" {
  name          = "${var.cluster_name}-allow-k3s-api"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = var.allowed_source_ranges
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

# Cilium Gateway (gatewayAPI.hostNetwork mode, pinned to the control-plane
# node — see applications/infrastructure/cilium/values.yaml). 4245 is the
# cleartext Hubble relay listener on the same Gateway.
resource "google_compute_firewall" "allow_gateway" {
  name          = "${var.cluster_name}-allow-gateway"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = var.allowed_source_ranges
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "4245"]
  }
}

# Full mesh within the subnet — cluster traffic (k3s, Cilium overlay/BGP-free
# native routing, Ceph mon/osd/mgr msgr2, NFS/iSCSI for CSI). Mirrors what
# Lima's flat host-only network gave ceph-lab for free.
resource "google_compute_firewall" "allow_internal" {
  name          = "${var.cluster_name}-allow-internal"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
