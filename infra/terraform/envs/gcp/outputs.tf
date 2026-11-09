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
