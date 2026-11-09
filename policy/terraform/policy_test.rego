# Unit tests: `opa test policy/terraform policy/data -v`
package terraform_test

import data.terraform.aws
import data.terraform.common
import data.terraform.gcp
import rego.v1

# ------------------------------------------------------------------ helpers
plan(env, resources) := {
	"variables": {"stack": {"value": env}},
	"resource_changes": [{
		"address": r.address,
		"mode": "managed",
		"type": r.type,
		"change": {"actions": ["create"], "after": r.after, "after_unknown": object.get(r, "unknown", {})},
	} |
		some r in resources
	],
}

ids(results) := {r.details.id | some r in results}

tags := {"project": "idea-board", "stack": "staging", "managed-by": "terraform"}

good_rds := {"address": "module.database.aws_db_instance.this", "type": "aws_db_instance", "after": {
	"storage_encrypted": true, "publicly_accessible": false, "backup_retention_period": 7,
	"deletion_protection": true, "multi_az": true, "auto_minor_version_upgrade": true,
	"enabled_cloudwatch_logs_exports": ["postgresql", "upgrade"], "manage_master_user_password": true,
	"tags_all": tags,
}}

good_eks := {"address": "module.cluster.module.eks.aws_eks_cluster.this[0]", "type": "aws_eks_cluster", "after": {
	"encryption_config": [{"resources": ["secrets"], "provider": [{}]}],
	"enabled_cluster_log_types": ["api", "audit", "authenticator"],
	"vpc_config": [{"endpoint_public_access": true, "public_access_cidrs": ["203.0.113.0/24"]}],
	"tags_all": tags,
}}

good_lt := {"address": "module.cluster.aws_launch_template.this[0]", "type": "aws_launch_template", "after": {
	"metadata_options": [{"http_tokens": "required"}],
	"block_device_mappings": [{"ebs": [{"encrypted": "true"}]}],
	"tags_all": tags,
}}

good_vpc := {"address": "module.vpc.aws_vpc.this[0]", "type": "aws_vpc", "after": {"tags_all": tags}}

good_flow := {"address": "module.vpc.aws_flow_log.this[0]", "type": "aws_flow_log", "after": {"tags_all": tags}}

good_cni := {"address": "module.cluster.module.eks.aws_eks_addon.this[\"vpc-cni\"]", "type": "aws_eks_addon", "after": {"addon_name": "vpc-cni", "configuration_values": "{\"enableNetworkPolicy\":\"true\"}", "tags_all": tags}}

good_aws := [good_rds, good_eks, good_lt, good_vpc, good_flow, good_cni]

with_after(r, patch) := object.union(r, {"after": object.union(r.after, patch)})

# ---------------------------------------------------------------- AWS tests
test_compliant_aws_production_has_no_findings if {
	count(aws.deny) == 0 with input as plan("production", good_aws)
	count(aws.warn) == 0 with input as plan("production", good_aws)
}

test_unencrypted_public_rds_blocks if {
	bad := with_after(good_rds, {"storage_encrypted": false, "publicly_accessible": true, "backup_retention_period": 1})
	found := ids(aws.deny) with input as plan("staging", [bad])
	{"AWS-RDS-001", "AWS-RDS-002", "AWS-RDS-003"} - found == set()
}

test_production_only_rules_skip_staging if {
	bad := with_after(good_rds, {"deletion_protection": false, "multi_az": false})
	not "AWS-RDS-004" in ids(aws.deny) with input as plan("staging", [bad])
	"AWS-RDS-004" in ids(aws.deny) with input as plan("production", [bad])
	"AWS-RDS-005" in ids(aws.deny) with input as plan("production", [bad])
}

test_password_in_state_is_a_warning_not_a_block if {
	bad := with_after(good_rds, {"manage_master_user_password": null})
	"AWS-RDS-008" in ids(aws.warn) with input as plan("staging", [bad])
	not "AWS-RDS-008" in ids(aws.deny) with input as plan("staging", [bad])
}

test_eks_missing_encryption_logs_and_open_endpoint if {
	bad := with_after(good_eks, {
		"encryption_config": [], "enabled_cluster_log_types": ["api"],
		"vpc_config": [{"endpoint_public_access": true, "public_access_cidrs": ["0.0.0.0/0"]}],
	})
	{"AWS-EKS-001", "AWS-EKS-002"} - ids(aws.deny) == set() with input as plan("staging", [bad])
	"AWS-EKS-003" in ids(aws.warn) with input as plan("staging", [bad])
}

test_launch_template_without_imdsv2_or_encryption if {
	bad := with_after(good_lt, {"metadata_options": [{"http_tokens": "optional"}], "block_device_mappings": []})
	{"AWS-EKS-004", "AWS-EKS-005"} - ids(aws.deny) == set() with input as plan("staging", [bad])
}

test_vpc_without_flow_log if {
	"AWS-NET-001" in ids(aws.deny) with input as plan("staging", [good_vpc])
}

test_open_postgres_port_blocks if {
	rule := {
		"address": "aws_vpc_security_group_ingress_rule.x", "type": "aws_vpc_security_group_ingress_rule",
		"after": {"cidr_ipv4": "0.0.0.0/0", "from_port": 5000, "to_port": 6000, "tags_all": tags},
	}
	"AWS-NET-002" in ids(aws.deny) with input as plan("staging", [rule])
	ok := with_after(rule, {"from_port": 443, "to_port": 443})
	not "AWS-NET-002" in ids(aws.deny) with input as plan("staging", [ok])
}

# ---------------------------------------------------------------- GCP tests
good_sql := {"address": "module.database.google_sql_database_instance.this", "type": "google_sql_database_instance", "after": {
	"database_version": "POSTGRES_16", "deletion_protection": true,
	"settings": [{
		"availability_type": "REGIONAL",
		"ip_configuration": [{"ipv4_enabled": false, "ssl_mode": "ENCRYPTED_ONLY"}],
		"backup_configuration": [{"enabled": true, "point_in_time_recovery_enabled": true}],
		"database_flags": [
			{"name": "log_connections", "value": "on"}, {"name": "log_disconnections", "value": "on"},
			{"name": "cloudsql.enable_pgaudit", "value": "on"},
		],
	}],
	"terraform_labels": tags,
}}

good_gke := {"address": "module.cluster.google_container_cluster.this", "type": "google_container_cluster", "after": {
	"private_cluster_config": [{"enable_private_nodes": true}],
	"workload_identity_config": [{"workload_pool": "p.svc.id.goog"}],
	"enable_legacy_abac": false,
	"master_authorized_networks_config": [{"cidr_blocks": [{"cidr_block": "203.0.113.0/24"}]}],
	"database_encryption": [{"state": "ENCRYPTED", "key_name": "k"}],
	"datapath_provider": "ADVANCED_DATAPATH",
	"terraform_labels": tags,
}}

good_pool := {
	"address": "module.cluster.google_container_node_pool.default", "type": "google_container_node_pool",
	"after": {
		"management": [{"auto_repair": true, "auto_upgrade": true}],
		"node_config": [{
			"service_account": null,
			"workload_metadata_config": [{"mode": "GKE_METADATA"}],
			"shielded_instance_config": [{"enable_secure_boot": true}],
		}],
	},
	# email comes from google_service_account, so it is unknown at plan time
	"unknown": {"node_config": [{"service_account": true}]},
}

good_subnet := {
	"address": "module.network.google_compute_subnetwork.nodes", "type": "google_compute_subnetwork",
	"after": {"log_config": [{"aggregation_interval": "INTERVAL_1_MIN"}]},
}

good_user := {
	"address": "module.database.google_sql_user.this", "type": "google_sql_user",
	"after": {"name": "ideas", "password": null, "password_wo_version": 1},
}

good_gcp := [good_sql, good_gke, good_pool, good_subnet, good_user]

test_compliant_gcp_production_has_no_findings if {
	count(gcp.deny) == 0 with input as plan("production", good_gcp)
	count(gcp.warn) == 0 with input as plan("production", good_gcp)
}

test_public_cloud_sql_without_tls_or_backups if {
	bad := with_after(good_sql, {"settings": [{
		"availability_type": "ZONAL",
		"ip_configuration": [{"ipv4_enabled": true, "ssl_mode": "ALLOW_UNENCRYPTED_AND_ENCRYPTED"}],
		"backup_configuration": [{"enabled": false}],
		"database_flags": [],
	}]})
	found := ids(gcp.deny) with input as plan("production", [bad])
	{"GCP-SQL-001", "GCP-SQL-002", "GCP-SQL-003", "GCP-SQL-005"} - found == set()
	"GCP-SQL-006" in ids(gcp.warn) with input as plan("production", [bad])
}

test_insecure_gke if {
	cluster := with_after(good_gke, {
		"private_cluster_config": [], "workload_identity_config": [], "enable_legacy_abac": true,
		"master_authorized_networks_config": [], "database_encryption": [{"state": "DECRYPTED"}],
	})
	pool := {"address": good_pool.address, "type": good_pool.type, "after": {
		"management": [{"auto_repair": false, "auto_upgrade": true}],
		"node_config": [{
			"service_account": "123-compute@developer.gserviceaccount.com",
			"workload_metadata_config": [{"mode": "GCE_METADATA"}], "shielded_instance_config": [],
		}],
	}}
	found := ids(gcp.deny) with input as plan("staging", [cluster, pool])
	{"GKE-001", "GKE-002", "GKE-003", "GKE-004", "GKE-005", "GKE-006"} - found == set()
	{"GKE-007", "GKE-008"} - ids(gcp.warn) == set() with input as plan("staging", [cluster, pool])
}

test_unknown_node_sa_is_not_flagged if {
	not "GKE-003" in ids(gcp.deny) with input as plan("staging", [good_pool])
}

test_subnet_without_flow_logs_and_open_ssh if {
	subnet := with_after(good_subnet, {"log_config": []})
	fw := {"address": "google_compute_firewall.ssh", "type": "google_compute_firewall", "after": {
		"direction": "INGRESS", "source_ranges": ["0.0.0.0/0"], "allow": [{"protocol": "tcp", "ports": ["20-25"]}],
		"terraform_labels": tags,
	}}
	{"GCP-NET-001", "GCP-NET-002"} - ids(gcp.deny) == set() with input as plan("staging", [subnet, fw])
}

# ------------------------------------------------------------ common + waivers
test_missing_tags_block if {
	# built directly: object.union would merge the partial map back into the full tag set
	untagged := {"address": good_vpc.address, "type": "aws_vpc", "after": {"tags_all": {"project": "idea-board"}}}
	"TAG-001" in ids(common.deny) with input as plan("staging", [untagged])
	count(common.deny) == 0 with input as plan("staging", good_aws)
}

test_active_waiver_downgrades_to_warning if {
	bad := with_after(good_rds, {"storage_encrypted": false})
	waiver := [{"id": "AWS-RDS-001", "resource": "module.database.*", "expires": "2999-01-01", "reason": "test"}]
	not "AWS-RDS-001" in ids(aws.deny) with input as plan("staging", [bad]) with data.waivers as waiver
	warnings := aws.warn with input as plan("staging", [bad]) with data.waivers as waiver
	some w in warnings
	w.details.id == "AWS-RDS-001"
	w.details.waived == true
}

test_expired_or_mismatched_waiver_still_blocks if {
	bad := with_after(good_rds, {"storage_encrypted": false})
	expired := [{"id": "AWS-RDS-001", "resource": "*", "expires": "2000-01-01"}]
	"AWS-RDS-001" in ids(aws.deny) with input as plan("staging", [bad]) with data.waivers as expired
	other_env := [{"id": "AWS-RDS-001", "resource": "*", "expires": "2999-01-01", "stacks": ["production"]}]
	"AWS-RDS-001" in ids(aws.deny) with input as plan("staging", [bad]) with data.waivers as other_env
}

# ------------------------------------------------- NetworkPolicy / secrets in state
test_eks_without_network_policy_agent if {
	"AWS-EKS-006" in ids(aws.deny) with input as plan("staging", [good_eks])
	no_policy := with_after(good_cni, {"configuration_values": "{}"})
	"AWS-EKS-006" in ids(aws.deny) with input as plan("staging", [good_eks, no_policy])
	not "AWS-EKS-006" in ids(aws.deny) with input as plan("staging", [good_eks, good_cni])
}

test_gke_without_dataplane_v2 if {
	legacy := with_after(good_gke, {"datapath_provider": "LEGACY_DATAPATH"})
	"GKE-009" in ids(gcp.deny) with input as plan("staging", [legacy])
}

test_cloud_sql_password_in_state if {
	leaky := with_after(good_user, {"password": "hunter2"})
	"GCP-SQL-007" in ids(gcp.deny) with input as plan("staging", [leaky])
	not "GCP-SQL-007" in ids(gcp.deny) with input as plan("staging", [good_user])
}
