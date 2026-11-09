variable "name" { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "instance_type" { type = string }
variable "node_min" { type = number }
variable "node_max" { type = number }
variable "node_desired" { type = number }
variable "spot" {
  type    = bool
  default = false
}
variable "admin_principal_arns" {
  description = "Extra IAM roles/users granted cluster-admin (the identity running Terraform is always admin)."
  type        = list(string)
  default     = []
}
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint (policy AWS-EKS-003)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "tags" {
  type    = map(string)
  default = {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name                             = var.name
  cluster_version                          = var.kubernetes_version
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.api_allowed_cidrs
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  # Explicit rather than relying on module defaults, so the policies can see them (AWS-EKS-001/002).
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cluster_encryption_config = { resources = ["secrets"] }

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.instance_type]
      capacity_type  = var.spot ? "SPOT" : "ON_DEMAND"
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_desired

      # `disk_size` is ignored when the module uses its custom launch template (the default),
      # so the root volume is declared explicitly, encrypted (AWS-EKS-005).
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 only; hop limit 2 so pods using IRSA/pod identity still work (AWS-EKS-004).
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
    }
  }

  access_entries = {
    for arn in var.admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = var.tags
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_ca_certificate" { value = module.eks.cluster_certificate_authority_data }
output "workload_security_group_ids" {
  description = "Security groups attached to nodes/pods; the database allows ingress from these."
  value       = [module.eks.node_security_group_id, module.eks.cluster_primary_security_group_id]
}
