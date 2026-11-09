variable "name" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "nodes_cidr" {
  type    = string
  default = "10.10.0.0/20"
}
variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "services_cidr" {
  type    = string
  default = "10.30.0.0/20"
}

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  project                  = var.project_id
  name                     = "${var.name}-nodes"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.nodes_cidr
  private_ip_google_access = true

  # VPC flow logs (policy GCP-NET-001).
  log_config {
    aggregation_interval = "INTERVAL_1_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Private nodes reach the internet (container registries) through Cloud NAT,
# the same role the NAT gateway plays in the AWS module.
resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  project                            = var.project_id
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Private Service Access lets Cloud SQL get a private IP inside this VPC,
# so the database is never exposed publicly (same as RDS in isolated subnets).
resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

output "network_id" { value = google_compute_network.this.id }
output "network_name" { value = google_compute_network.this.name }
output "subnetwork_name" { value = google_compute_subnetwork.nodes.name }
output "pods_range_name" { value = "pods" }
output "services_range_name" { value = "services" }
output "private_service_connection" { value = google_service_networking_connection.psa.id }
