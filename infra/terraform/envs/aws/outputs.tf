# Output contract: identical names on every cloud, so the pipeline never
# branches on provider after `terraform apply`.

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

output "database_url" {
  value     = "postgresql+psycopg://${module.database.username}:${module.database.password}@${module.database.host}:${module.database.port}/${module.database.db_name}?sslmode=require"
  sensitive = true
}
