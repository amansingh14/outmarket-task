variable "name" { type = string }
variable "project_id" { type = string }
variable "location" {
  description = "A region (regional, HA control plane) or a zone (zonal, cheaper)."
  type        = string
}
variable "network_name" { type = string }
variable "subnetwork_name" { type = string }
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }
variable "machine_type" { type = string }
variable "node_min" { type = number }
variable "node_max" { type = number }
variable "node_desired" { type = number }
variable "spot" {
  type    = bool
  default = false
}
variable "master_cidr" {
  type    = string
  default = "172.16.0.0/28"
}
variable "deletion_protection" {
  type    = bool
  default = false
}
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the control plane; [\"0.0.0.0/0\"] disables the restriction (policy GKE-007)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "labels" {
  type    = map(string)
  default = {}
}

locals {
  restrict_api = !contains(var.api_allowed_cidrs, "0.0.0.0/0")
}

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = substr("${var.name}-nodes", 0, 30)
  display_name = "GKE nodes for ${var.name}"
}

# Least-privilege node identity (instead of the default compute SA with Editor).
resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name
  location = var.location

  network         = var.network_name
  subnetwork      = var.subnetwork_name
  networking_mode = "VPC_NATIVE"

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.deletion_protection

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  release_channel {
    channel = "REGULAR"
  }

  enable_shielded_nodes = true
  enable_legacy_abac    = false

  dynamic "master_authorized_networks_config" {
    for_each = local.restrict_api ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.api_allowed_cidrs
        content {
          cidr_block = cidr_blocks.value
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = var.labels
}

resource "google_container_node_pool" "default" {
  project            = var.project_id
  name               = "default"
  cluster            = google_container_cluster.this.id
  location           = var.location
  initial_node_count = var.node_desired

  autoscaling {
    min_node_count = var.node_min
    max_node_count = var.node_max
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_size_gb    = 30
    disk_type       = "pd-balanced"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded GKE nodes (policy GKE-006).
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

output "cluster_name" { value = google_container_cluster.this.name }
output "cluster_endpoint" { value = "https://${google_container_cluster.this.endpoint}" }
output "cluster_ca_certificate" { value = google_container_cluster.this.master_auth[0].cluster_ca_certificate }
