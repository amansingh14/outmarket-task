terraform {
  required_version = ">= 1.10"

  # Partial config: bucket/key/region are supplied with -backend-config by the
  # pipeline (see scripts/tf.sh), so one root serves every environment.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "admin_principal_arns" {
  description = "AWS only: extra IAM principals granted cluster-admin."
  type        = list(string)
  default     = []
}

locals {
  cloud = "aws"
  name  = "${var.project_name}-${var.environment}"
  tags = merge({
    project     = var.project_name
    environment = var.environment
    managed-by  = "terraform"
  }, var.extra_tags)
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

module "sizing" {
  source    = "../../modules/sizing"
  cloud     = local.cloud
  node_size = var.node_size
  db_size   = var.db_size
}

module "network" {
  source             = "../../modules/aws-network"
  name               = local.name
  single_nat_gateway = !var.db_high_availability
}

module "cluster" {
  source               = "../../modules/aws-eks"
  name                 = local.name
  kubernetes_version   = var.kubernetes_version
  vpc_id               = module.network.vpc_id
  subnet_ids           = module.network.private_subnet_ids
  instance_type        = module.sizing.node_instance_type
  node_min             = var.node_min
  node_max             = var.node_max
  node_desired         = var.node_desired
  spot                 = var.spot_nodes
  admin_principal_arns = var.admin_principal_arns
  api_allowed_cidrs    = var.api_allowed_cidrs
}

module "database" {
  source                     = "../../modules/aws-rds"
  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_group_name          = module.network.database_subnet_group_name
  allowed_security_group_ids = module.cluster.workload_security_group_ids
  instance_class             = module.sizing.db_instance_class
  storage_gb                 = var.db_storage_gb
  high_availability          = var.db_high_availability
  deletion_protection        = var.deletion_protection
}
