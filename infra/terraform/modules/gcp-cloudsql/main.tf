variable "name" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "network_id" { type = string }
variable "tier" { type = string }
variable "storage_gb" {
  type    = number
  default = 20
}
variable "high_availability" {
  type    = bool
  default = false
}
variable "deletion_protection" {
  type    = bool
  default = false
}
variable "db_name" {
  type    = string
  default = "ideas"
}
variable "username" {
  type    = string
  default = "ideas"
}
variable "labels" {
  type    = map(string)
  default = {}
}

resource "random_password" "db" {
  length  = 32
  special = false
}

# Cloud SQL instance names are reserved for ~1 week after deletion,
# so a random suffix keeps destroy/recreate cycles working.
resource "random_id" "suffix" {
  byte_length = 3
}

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = "${var.name}-${random_id.suffix.hex}"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.storage_gb
    disk_autoresize   = true
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false # private IP only, never on the internet
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.high_availability
    }

    # CIS GCP Cloud SQL for PostgreSQL logging flags (policy GCP-SQL-006).
    dynamic "database_flags" {
      for_each = {
        "log_checkpoints"            = "on"
        "log_connections"            = "on"
        "log_disconnections"         = "on"
        "log_lock_waits"             = "on"
        "log_min_duration_statement" = "-1"
        "log_statement"              = "ddl"
        "cloudsql.enable_pgaudit"    = "on"
      }
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
  }
}

resource "google_sql_database" "this" {
  project  = var.project_id
  name     = var.db_name
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "this" {
  project  = var.project_id
  name     = var.username
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}

output "host" { value = google_sql_database_instance.this.private_ip_address }
output "port" { value = 5432 }
output "db_name" { value = var.db_name }
output "username" { value = var.username }
output "password" {
  value     = random_password.db.result
  sensitive = true
}
