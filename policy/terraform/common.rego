package terraform.common

import data.lib
import rego.v1

deny contains r if some r in lib.blocking(findings)

warn contains r if some r in lib.advisory(findings)

required_keys := {"project", "environment", "managed-by"}

# AWS: tags_all includes provider default_tags. GCP: terraform_labels includes default_labels.
tag_attribute := {"tags_all", "terraform_labels"}

findings contains {"id": "TAG-001", "resource": r.address, "msg": msg} if {
	some r in input.resource_changes
	r.mode == "managed"
	r.change.actions != ["delete"]
	some attr in tag_attribute
	tags := object.get(lib.after(r), attr, null)
	is_object(tags)
	not lib.unknown(r, attr)
	missing := required_keys - {k | some k, _ in tags}
	count(missing) > 0
	msg := sprintf("%s is missing %v", [attr, sort(missing)])
}
