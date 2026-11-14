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
variable "password_version" {
  description = "Bump to rotate the admin password (write-only values are only re-sent when this changes)."
  type        = number
  default     = 1
}

# The admin password never touches Terraform state or plan files (policy GCP-SQL-007):
# an *ephemeral* random value is sent through *write-only* arguments to Cloud SQL and to
# Secret Manager, where the pipeline reads it (clouds/gcp/db-admin-url.sh).
ephemeral "random_password" "db" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "db_admin" {
  project   = var.project_id
  secret_id = "${var.name}-db-admin"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_admin" {
  secret                 = google_secret_manager_secret.db_admin.id
  secret_data_wo         = ephemeral.random_password.db.result
  secret_data_wo_version = var.password_version
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
  project             = var.project_id
  name                = var.username
  instance            = google_sql_database_instance.this.name
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = var.password_version
}

output "host" { value = google_sql_database_instance.this.private_ip_address }
output "port" { value = 5432 }
output "db_name" { value = var.db_name }
output "username" { value = var.username }
output "admin_secret" {
  description = "Secret Manager secret id holding the admin password."
  value       = google_secret_manager_secret.db_admin.secret_id
}
