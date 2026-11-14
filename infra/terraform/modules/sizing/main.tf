# Cloud-neutral size classes -> provider-specific SKUs.
#
# Everything upstream of Terraform (developers, the AI stack-profile generator,
# the pipeline) speaks in "small / medium / large". Only this module knows that
# "medium" means t3.large on AWS and e2-standard-2 on GCP. Adding a third cloud
# means adding one column here, not touching any caller.

variable "cloud" {
  type = string
  validation {
    condition     = contains(["aws", "gcp"], var.cloud)
    error_message = "cloud must be aws or gcp."
  }
}

variable "node_size" {
  type = string
  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be small, medium or large."
  }
}

variable "db_size" {
  type = string
  validation {
    condition     = contains(["small", "medium", "large"], var.db_size)
    error_message = "db_size must be small, medium or large."
  }
}

locals {
  #           ~vCPU / RAM       AWS              GCP
  node_types = {
    small  = { aws = "t3.medium", gcp = "e2-medium" }      # 2 / 4 GiB (burstable)
    medium = { aws = "t3.large", gcp = "e2-standard-2" }   # 2 / 8 GiB
    large  = { aws = "m6i.xlarge", gcp = "e2-standard-4" } # 4 / 16 GiB
  }
  db_tiers = {
    small  = { aws = "db.t4g.micro", gcp = "db-f1-micro" }       # dev / preview
    medium = { aws = "db.t4g.medium", gcp = "db-custom-2-4096" } # staging
    large  = { aws = "db.m6g.large", gcp = "db-custom-2-8192" }  # production
  }
}

output "node_instance_type" {
  value = local.node_types[var.node_size][var.cloud]
}

output "db_instance_class" {
  value = local.db_tiers[var.db_size][var.cloud]
}
