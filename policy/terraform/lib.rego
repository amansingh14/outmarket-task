# Shared helpers for Terraform plan policies.
#
# Input: `terraform show -json tfplan`. The pipeline plans the full desired state against an
# empty local state, so every resource appears as a create and every policy sees the complete
# configuration, including defaults set inside third-party modules.
package lib

import rego.v1

# Managed resources that will exist after apply (anything except a pure delete).
resources(type) := [r |
	some r in input.resource_changes
	r.mode == "managed"
	r.type == type
	r.change.actions != ["delete"]
]

after(r) := object.get(r.change, "after", {})

# true when Terraform only learns the value during apply.
unknown(r, path) if object.get(object.get(r.change, "after_unknown", {}), path, false) == true

# Plan JSON uses null for unset lists; treat null/missing as [].
arr(x) := x if is_array(x)

arr(x) := [] if not is_array(x)

environment := object.get(input, ["variables", "environment", "value"], "unknown")

applies(id) if {
	envs := object.get(data.catalog[id], "environments", [environment])
	environment in envs
}

waiver_list := w if {
	w := data.waivers
	is_array(w)
} else := []

waived(id, address) if {
	some w in waiver_list
	w.id == id
	glob.match(object.get(w, "resource", "*"), null, address)
	environment in object.get(w, "environments", [environment])
	regex.match(`^\d{4}-\d{2}-\d{2}$`, w.expires)
	today < w.expires # ISO dates compare correctly as strings (and never overflow, unlike ns timestamps)
}

today := sprintf("%04d-%02d-%02d", time.date(time.now_ns()))

result(v, is_waived) := {
	"msg": sprintf("[%s] %s: %s", [v.id, v.resource, v.msg]),
	"details": {
		"id": v.id,
		"resource": v.resource,
		"message": v.msg,
		"severity": data.catalog[v.id].severity,
		"title": data.catalog[v.id].title,
		"controls": data.catalog[v.id].controls,
		"environment": environment,
		"waived": is_waived,
	},
}

# Turn a package's `findings` set into conftest deny / warn results.
blocking(findings) := {result(v, false) |
	some v in findings
	applies(v.id)
	data.catalog[v.id].severity == "high"
	not waived(v.id, v.resource)
}

# Medium findings warn; waived findings (any severity) also warn so they stay visible in the report.
advisory(findings) := medium | waived_findings if {
	medium := {result(v, false) |
		some v in findings
		applies(v.id)
		data.catalog[v.id].severity != "high"
		not waived(v.id, v.resource)
	}
	waived_findings := {result(v, true) |
		some v in findings
		applies(v.id)
		waived(v.id, v.resource)
	}
}

# "port p is inside [from, to]" or the rule allows every protocol.
port_open(from, to, _) if {
	from == -1
	to == -1
}

port_open(from, to, p) if {
	from <= p
	p <= to
}

world_cidrs := {"0.0.0.0/0", "::/0"}

sensitive_ports := [22, 3389, 5432]
