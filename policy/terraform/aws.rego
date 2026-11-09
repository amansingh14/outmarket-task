package terraform.aws

import data.lib
import rego.v1

deny contains r if some r in lib.blocking(findings)

warn contains r if some r in lib.advisory(findings)

# ------------------------------------------------------------------ RDS
findings contains {"id": "AWS-RDS-001", "resource": r.address, "msg": "storage_encrypted must be true"} if {
	some r in lib.resources("aws_db_instance")
	not lib.after(r).storage_encrypted == true
}

findings contains {"id": "AWS-RDS-002", "resource": r.address, "msg": "publicly_accessible must be false"} if {
	some r in lib.resources("aws_db_instance")
	lib.after(r).publicly_accessible == true
}

findings contains {"id": "AWS-RDS-003", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_db_instance")
	days := object.get(lib.after(r), "backup_retention_period", 0)
	days < 7
	msg := sprintf("backup_retention_period is %v; must be >= 7", [days])
}

findings contains {"id": "AWS-RDS-004", "resource": r.address, "msg": "deletion_protection must be true in production"} if {
	some r in lib.resources("aws_db_instance")
	not lib.after(r).deletion_protection == true
}

findings contains {"id": "AWS-RDS-005", "resource": r.address, "msg": "multi_az must be true in production"} if {
	some r in lib.resources("aws_db_instance")
	not lib.after(r).multi_az == true
}

findings contains {"id": "AWS-RDS-006", "resource": r.address, "msg": "auto_minor_version_upgrade should be true"} if {
	some r in lib.resources("aws_db_instance")
	lib.after(r).auto_minor_version_upgrade == false
}

findings contains {"id": "AWS-RDS-007", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_db_instance")
	not "postgresql" in lib.arr(object.get(lib.after(r), "enabled_cloudwatch_logs_exports", []))
	msg := "enabled_cloudwatch_logs_exports should include \"postgresql\""
}

findings contains {"id": "AWS-RDS-008", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_db_instance")
	not lib.after(r).manage_master_user_password == true
	msg := "master password is set by Terraform and stored in state; use manage_master_user_password"
}

# ------------------------------------------------------------------ EKS
findings contains {"id": "AWS-EKS-001", "resource": r.address, "msg": "encryption_config must cover \"secrets\""} if {
	some r in lib.resources("aws_eks_cluster")
	not secrets_encrypted(r)
}

secrets_encrypted(r) if {
	some cfg in lib.arr(object.get(lib.after(r), "encryption_config", []))
	"secrets" in lib.arr(cfg.resources)
}

findings contains {"id": "AWS-EKS-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_eks_cluster")
	enabled := {t | some t in lib.arr(object.get(lib.after(r), "enabled_cluster_log_types", []))}
	missing := {"audit", "authenticator"} - enabled
	count(missing) > 0
	msg := sprintf("enabled_cluster_log_types is missing %v", [sort(missing)])
}

findings contains {"id": "AWS-EKS-003", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_eks_cluster")
	some vpc in lib.after(r).vpc_config
	vpc.endpoint_public_access == true
	some cidr in public_cidrs(vpc)
	cidr in lib.world_cidrs
	msg := "public API endpoint is reachable from 0.0.0.0/0; set api_allowed_cidrs"
}

# AWS defaults an unset allow-list to 0.0.0.0/0.
public_cidrs(vpc) := cidrs if {
	cidrs := lib.arr(object.get(vpc, "public_access_cidrs", []))
	count(cidrs) > 0
} else := ["0.0.0.0/0"]

findings contains {"id": "AWS-EKS-004", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_launch_template")
	not imdsv2_required(r)
	msg := "metadata_options.http_tokens must be \"required\" (IMDSv2)"
}

imdsv2_required(r) if {
	some m in lib.after(r).metadata_options
	m.http_tokens == "required"
}

findings contains {"id": "AWS-EKS-005", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_launch_template")
	not root_volume_encrypted(r)
	msg := "block_device_mappings must declare an encrypted EBS root volume"
}

# The provider models `encrypted` as a string ("true") on launch templates.
root_volume_encrypted(r) if {
	some bdm in lib.after(r).block_device_mappings
	some ebs in bdm.ebs
	ebs.encrypted in {"true", true}
}

# ------------------------------------------------------------------ Network
findings contains {"id": "AWS-NET-001", "resource": "aws_vpc", "msg": msg} if {
	vpcs := count(lib.resources("aws_vpc"))
	logs := count(lib.resources("aws_flow_log"))
	vpcs > logs
	msg := sprintf("%d VPC(s) but only %d flow log(s)", [vpcs, logs])
}

findings contains {"id": "AWS-NET-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_vpc_security_group_ingress_rule")
	a := lib.after(r)
	object.get(a, "cidr_ipv4", "") in lib.world_cidrs
	some p in lib.sensitive_ports
	lib.port_open(object.get(a, "from_port", -1), object.get(a, "to_port", -1), p)
	msg := sprintf("ingress from %s to port %d", [a.cidr_ipv4, p])
}

findings contains {"id": "AWS-NET-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_security_group_rule")
	a := lib.after(r)
	a.type == "ingress"
	some cidr in lib.arr(object.get(a, "cidr_blocks", []))
	cidr in lib.world_cidrs
	some p in lib.sensitive_ports
	lib.port_open(a.from_port, a.to_port, p)
	msg := sprintf("ingress from %s to port %d", [cidr, p])
}

findings contains {"id": "AWS-NET-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_security_group")
	some rule in lib.arr(object.get(lib.after(r), "ingress", []))
	some cidr in lib.arr(object.get(rule, "cidr_blocks", []))
	cidr in lib.world_cidrs
	some p in lib.sensitive_ports
	lib.port_open(rule.from_port, rule.to_port, p)
	msg := sprintf("inline ingress from %s to port %d", [cidr, p])
}

# ------------------------------------------------------------- NetworkPolicy
findings contains {"id": "AWS-EKS-006", "resource": r.address, "msg": msg} if {
	some r in lib.resources("aws_eks_cluster")
	not vpc_cni_network_policy
	msg := "vpc-cni addon must set enableNetworkPolicy=\"true\" so NetworkPolicies are enforced"
}

vpc_cni_network_policy if {
	some a in lib.resources("aws_eks_addon")
	lib.after(a).addon_name == "vpc-cni"
	cfg := json.unmarshal(lib.after(a).configuration_values)
	object.get(cfg, "enableNetworkPolicy", "false") in {"true", true}
}
