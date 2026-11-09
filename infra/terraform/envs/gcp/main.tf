terraform {
  required_version = ">= 1.10"

  # Partial config: bucket/prefix supplied with -backend-config (see scripts/tf.sh).
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "project_id" {
  description = "GCP only: the project to deploy into."
  type        = string
}

locals {
  cloud = "gcp"
  name  = "${var.project_name}-${var.environment}"
  labels = merge({
    project     = var.project_name
    environment = var.environment
    managed-by  = "terraform"
  }, var.extra_tags)
  # Zonal = one control plane in zone "a" (cheaper); regional = HA across zones.
  gke_location = var.zonal_control_plane ? "${var.region}-a" : var.region
}

provider "google" {
  project        = var.project_id
  region         = var.region
  default_labels = local.labels
}

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "sizing" {
  source    = "../../modules/sizing"
  cloud     = local.cloud
  node_size = var.node_size
  db_size   = var.db_size
}

module "network" {
  source     = "../../modules/gcp-network"
  name       = local.name
  project_id = var.project_id
  region     = var.region
  depends_on = [google_project_service.apis]
}

module "cluster" {
  source              = "../../modules/gcp-gke"
  name                = local.name
  project_id          = var.project_id
  location            = local.gke_location
  network_name        = module.network.network_name
  subnetwork_name     = module.network.subnetwork_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  machine_type        = module.sizing.node_instance_type
  node_min            = var.node_min
  node_max            = var.node_max
  node_desired        = var.node_desired
  spot                = var.spot_nodes
  deletion_protection = var.deletion_protection
  api_allowed_cidrs   = var.api_allowed_cidrs
  labels              = local.labels
}

module "database" {
  source              = "../../modules/gcp-cloudsql"
  name                = local.name
  project_id          = var.project_id
  region              = var.region
  network_id          = module.network.network_id
  tier                = module.sizing.db_instance_class
  storage_gb          = var.db_storage_gb
  high_availability   = var.db_high_availability
  deletion_protection = var.deletion_protection
  labels              = local.labels

  # Cloud SQL private IP requires the peering connection to exist first.
  depends_on = [module.network]
}
