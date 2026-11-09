package terraform.gcp

import data.lib
import rego.v1

deny contains r if some r in lib.blocking(findings)

warn contains r if some r in lib.advisory(findings)

first(xs) := x if {
	arr := lib.arr(xs)
	count(arr) > 0
	x := arr[0]
} else := {}

settings(r) := first(object.get(lib.after(r), "settings", []))

ip_config(r) := first(object.get(settings(r), "ip_configuration", []))

backups(r) := first(object.get(settings(r), "backup_configuration", []))

# --------------------------------------------------------------- Cloud SQL
findings contains {"id": "GCP-SQL-001", "resource": r.address, "msg": "ip_configuration.ipv4_enabled must be false"} if {
	some r in lib.resources("google_sql_database_instance")
	not ip_config(r).ipv4_enabled == false
}

findings contains {"id": "GCP-SQL-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_sql_database_instance")
	mode := object.get(ip_config(r), "ssl_mode", "unset")
	not mode in {"ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"}
	msg := sprintf("ssl_mode is %v; must be ENCRYPTED_ONLY or TRUSTED_CLIENT_CERTIFICATE_REQUIRED", [mode])
}

findings contains {"id": "GCP-SQL-003", "resource": r.address, "msg": "backup_configuration.enabled must be true"} if {
	some r in lib.resources("google_sql_database_instance")
	not backups(r).enabled == true
}

findings contains {"id": "GCP-SQL-004", "resource": r.address, "msg": "deletion_protection must be true in production"} if {
	some r in lib.resources("google_sql_database_instance")
	not lib.after(r).deletion_protection == true
}

findings contains {"id": "GCP-SQL-005", "resource": r.address, "msg": "availability_type must be REGIONAL in production"} if {
	some r in lib.resources("google_sql_database_instance")
	not settings(r).availability_type == "REGIONAL"
}

findings contains {"id": "GCP-SQL-005", "resource": r.address, "msg": "point_in_time_recovery_enabled must be true in production"} if {
	some r in lib.resources("google_sql_database_instance")
	not backups(r).point_in_time_recovery_enabled == true
}

required_pg_flags := {"log_connections": "on", "log_disconnections": "on", "cloudsql.enable_pgaudit": "on"}

findings contains {"id": "GCP-SQL-006", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_sql_database_instance")
	startswith(object.get(lib.after(r), "database_version", ""), "POSTGRES")
	flags := {f.name: f.value | some f in lib.arr(object.get(settings(r), "database_flags", []))}
	some name, want in required_pg_flags
	object.get(flags, name, "unset") != want
	msg := sprintf("database flag %s should be %q (is %q)", [name, want, object.get(flags, name, "unset")])
}

# --------------------------------------------------------------------- GKE
findings contains {"id": "GKE-001", "resource": r.address, "msg": "private_cluster_config.enable_private_nodes must be true"} if {
	some r in lib.resources("google_container_cluster")
	not first(object.get(lib.after(r), "private_cluster_config", [])).enable_private_nodes == true
}

findings contains {"id": "GKE-002", "resource": r.address, "msg": "workload_identity_config must be set"} if {
	some r in lib.resources("google_container_cluster")
	count(lib.arr(object.get(lib.after(r), "workload_identity_config", []))) == 0
}

findings contains {"id": "GKE-002", "resource": r.address, "msg": "node_config.workload_metadata_config.mode must be GKE_METADATA"} if {
	some r in lib.resources("google_container_node_pool")
	nc := first(object.get(lib.after(r), "node_config", []))
	not first(object.get(nc, "workload_metadata_config", [])).mode == "GKE_METADATA"
}

findings contains {"id": "GKE-003", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_container_node_pool")
	not node_sa_unknown(r)
	sa := object.get(first(object.get(lib.after(r), "node_config", [])), "service_account", null)
	default_sa(sa)
	msg := sprintf("node pool uses the default Compute Engine service account (%v)", [sa])
}

node_sa_unknown(r) if {
	nc := first(object.get(object.get(r.change, "after_unknown", {}), "node_config", []))
	nc.service_account == true
}

default_sa(null)

default_sa("default")

default_sa(sa) if endswith(sa, "-compute@developer.gserviceaccount.com")

findings contains {"id": "GKE-004", "resource": r.address, "msg": "management.auto_repair and auto_upgrade must be true"} if {
	some r in lib.resources("google_container_node_pool")
	m := first(object.get(lib.after(r), "management", []))
	not all_true(m, ["auto_repair", "auto_upgrade"])
}

all_true(obj, keys) if every k in keys { object.get(obj, k, false) == true }

findings contains {"id": "GKE-005", "resource": r.address, "msg": "enable_legacy_abac must be false"} if {
	some r in lib.resources("google_container_cluster")
	lib.after(r).enable_legacy_abac == true
}

findings contains {"id": "GKE-006", "resource": r.address, "msg": "shielded_instance_config.enable_secure_boot must be true"} if {
	some r in lib.resources("google_container_node_pool")
	nc := first(object.get(lib.after(r), "node_config", []))
	not first(object.get(nc, "shielded_instance_config", [])).enable_secure_boot == true
}

findings contains {"id": "GKE-007", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_container_cluster")
	not authorized_networks_restricted(r)
	msg := "control plane is reachable from any IP; set api_allowed_cidrs"
}

authorized_networks_restricted(r) if {
	man := first(object.get(lib.after(r), "master_authorized_networks_config", []))
	blocks := lib.arr(object.get(man, "cidr_blocks", []))
	count(blocks) > 0
	every b in blocks { not b.cidr_block in lib.world_cidrs }
}

findings contains {"id": "GKE-008", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_container_cluster")
	not first(object.get(lib.after(r), "database_encryption", [])).state == "ENCRYPTED"
	msg := "database_encryption (Cloud KMS) is not configured for Kubernetes Secrets"
}

# ----------------------------------------------------------------- Network
findings contains {"id": "GCP-NET-001", "resource": r.address, "msg": "log_config (VPC flow logs) must be set"} if {
	some r in lib.resources("google_compute_subnetwork")
	not object.get(lib.after(r), "purpose", "PRIVATE") in {"REGIONAL_MANAGED_PROXY", "GLOBAL_MANAGED_PROXY", "PRIVATE_SERVICE_CONNECT"}
	count(lib.arr(object.get(lib.after(r), "log_config", []))) == 0
}

findings contains {"id": "GCP-NET-002", "resource": r.address, "msg": msg} if {
	some r in lib.resources("google_compute_firewall")
	a := lib.after(r)
	object.get(a, "direction", "INGRESS") == "INGRESS"
	some src in lib.arr(object.get(a, "source_ranges", []))
	src in lib.world_cidrs
	some rule in lib.arr(object.get(a, "allow", []))
	some p in [22, 3389]
	fw_allows(rule, p)
	msg := sprintf("firewall allows %s to port %d", [src, p])
}

fw_allows(rule, _) if rule.protocol == "all"

fw_allows(rule, _) if {
	rule.protocol == "tcp"
	count(lib.arr(object.get(rule, "ports", []))) == 0
}

fw_allows(rule, p) if {
	rule.protocol == "tcp"
	some spec in lib.arr(rule.ports)
	parts := split(spec, "-")
	lo := to_number(parts[0])
	hi := to_number(parts[count(parts) - 1])
	lo <= p
	p <= hi
}
