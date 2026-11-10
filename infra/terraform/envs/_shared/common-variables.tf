# ---------------------------------------------------------------------------
# THE CLOUD-NEUTRAL CONTRACT
#
# This file is symlinked into every envs/<cloud>/ root, so every cloud accepts
# exactly the same inputs. The values are produced (and validated) by
# `devops-ai stack-profile`, written to <stack>.<cloud>.auto.tfvars.json, and are
# identical no matter which cloud they target.
# ---------------------------------------------------------------------------

variable "project_name" {
  type    = string
  default = "idea-board"
}

variable "stack" {
  description = "Infrastructure stack name (config/stacks/<stack>.yaml), e.g. nonprod, preprod, production."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.stack))
    error_message = "stack must be lowercase alphanumeric/dashes, 2-15 chars."
  }
}

variable "region" {
  type = string
}

variable "kubernetes_version" {
  description = "Used on AWS; GKE follows its release channel. Raise one minor version at a time on a live cluster."
  type        = string
  default     = "1.34"
}

variable "node_size" {
  description = "small | medium | large, mapped to SKUs by modules/sizing."
  type        = string
  default     = "small"
}

variable "node_min" {
  type    = number
  default = 1
}

variable "node_max" {
  type    = number
  default = 3
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "spot_nodes" {
  description = "Use spot/preemptible capacity (cheap, can be reclaimed)."
  type        = bool
  default     = false
}

variable "db_size" {
  type    = string
  default = "small"
}

variable "db_storage_gb" {
  type    = number
  default = 20
}

variable "db_high_availability" {
  description = "Multi-AZ RDS / REGIONAL Cloud SQL."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the database (and GKE cluster) from accidental destroy."
  type        = bool
  default     = false
}

variable "zonal_control_plane" {
  description = "GKE only: zonal cluster (cheaper) instead of regional. Ignored on AWS."
  type        = bool
  default     = true
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API. ["0.0.0.0/0"] = unrestricted (reported as a warning
    by policies AWS-EKS-003 / GKE-007). Restricting it requires the deploy runners to have fixed
    egress IPs (self-hosted runners or GitHub larger runners with static IPs).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
