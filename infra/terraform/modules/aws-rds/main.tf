variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_group_name" { type = string }
variable "allowed_security_group_ids" { type = list(string) }
variable "instance_class" { type = string }
variable "engine_version" {
  type    = string
  default = "16"
}
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
variable "backup_retention_days" {
  type    = number
  default = 7
}
variable "db_name" {
  type    = string
  default = "ideas"
}
variable "username" {
  type    = string
  default = "ideas"
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL access from the Kubernetes workloads only"
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_workloads" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS"
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.storage_gb
  max_allocated_storage = var.storage_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.username
  # RDS generates and rotates the master password in Secrets Manager, so it never enters
  # Terraform state (policy AWS-RDS-008). The pipeline reads it via clouds/aws/db-admin-url.sh.
  manage_master_user_password = true

  db_subnet_group_name   = var.subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.high_availability

  backup_retention_period    = var.backup_retention_days
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = !var.deletion_protection
  final_snapshot_identifier  = "${var.name}-final"
  auto_minor_version_upgrade = true
  apply_immediately          = true
  copy_tags_to_snapshot      = true

  # Database and upgrade logs to CloudWatch for audit trails (AWS-RDS-007).
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = var.tags
}

output "host" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "db_name" { value = var.db_name }
output "username" { value = var.username }
output "admin_secret" {
  description = "ARN of the RDS-managed Secrets Manager secret with the master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
