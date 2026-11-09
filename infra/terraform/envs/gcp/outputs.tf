# Output contract: identical names on every cloud (see envs/aws/outputs.tf).

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
  value = "gcloud container clusters get-credentials ${module.cluster.cluster_name} --location ${local.gke_location} --project ${var.project_id}"
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

# libpq-format URL for the master user, used in-cluster by the Helm db-init hook to create
# per-environment databases on the shared non-prod instance. The pipeline masks it.
output "database_admin_url" {
  value     = "postgresql://${module.database.username}:${module.database.password}@${module.database.host}:${module.database.port}/${module.database.db_name}?sslmode=require"
  sensitive = true
}
