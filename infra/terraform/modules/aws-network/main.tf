variable "name" { type = string }
variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "az_count" {
  type    = number
  default = 3
}
variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap) instead of one per AZ (highly available)."
  type        = bool
  default     = true
}
variable "flow_log_retention_days" {
  type    = number
  default = 90
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  # /20 private subnets for nodes and pods, /24 public subnets for load balancers,
  # /24 isolated subnets for the database.
  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.cidr, 4, i)]
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, 48 + i)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, 56 + i)]

  create_database_subnet_group = true
  enable_nat_gateway           = true
  single_nat_gateway           = var.single_nat_gateway
  enable_dns_hostnames         = true
  enable_dns_support           = true

  # Lets the AWS cloud provider find subnets for Service type=LoadBalancer.
  # VPC flow logs to CloudWatch (policy AWS-NET-001).
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  tags = var.tags
}

output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr" { value = module.vpc.vpc_cidr_block }
output "private_subnet_ids" { value = module.vpc.private_subnets }
output "public_subnet_ids" { value = module.vpc.public_subnets }
output "database_subnet_group_name" { value = module.vpc.database_subnet_group_name }
