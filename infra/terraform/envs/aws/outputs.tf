# Output contract: identical names on every cloud, so the pipeline never branches on provider
# after `terraform apply`. No output contains a secret: database credentials are fetched from the
# cloud's secret store by clouds/<cloud>/db-admin-url.sh.

output "cloud" {
  value = local.cloud
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name}"
}

output "node_instance_type" {
  value = module.sizing.node_instance_type
}

output "db_instance_class" {
  value = module.sizing.db_instance_class
}

output "database_host" {
  value = module.database.host
}

output "database_port" {
  value = module.database.port
}

output "database_name" {
  value = module.database.db_name
}

output "database_admin_username" {
  value = module.database.username
}

output "database_admin_secret" {
  description = "Where the admin password lives in the cloud's secret store (never in state)."
  value       = module.database.admin_secret
}
