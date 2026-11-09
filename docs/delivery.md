# Branching, build and deployment in depth

The README covers setup. This page explains how the delivery model works and why it's built this way.

Everything here is driven by [`config/deployments.yaml`](../config/deployments.yaml), read through
`devops-ai delivery …`. Run `devops-ai delivery validate` to print the current model.

## Branches, environments, stacks

| Branch | Environment | Stack | Clouds | Deploy gate | Infra applied from here |
|---|---|---|---|---|---|
| `development` | development | nonprod | AWS | automatic | nonprod |
| `staging` | staging | nonprod | AWS | automatic | – |
| `qa` | qa | nonprod | AWS | automatic | – |
| `preprod` | preprod | preprod | AWS + GCP | approval | preprod |
| `production` | production | production | AWS + GCP | approval | production |

- A **stack** is one cluster plus one managed PostgreSQL instance per cloud. Its sizing is in
  `config/stacks/<stack>.yaml`.
- **nonprod** is shared by development, staging and qa: one namespace and one database each, plus
  a separate database login per environment. About 40% of the cost of dedicated stacks.
- Lower environments run on one cloud and preprod/production on both, so production's multi-cloud
  setup is always rehearsed in preprod first. Add a cloud to an environment by editing its `clouds:` list.

**Branch rules** (`branch-policy` job, `devops-ai delivery check-promotion`):

| From | May merge into |
|---|---|
| `feature/`, `fix/`, `chore/`, `docs/`, `refactor/`, `test/`, `dependabot/`, `renovate/` | `development` |
| `development` → `staging` → `qa` → `preprod` → `production` | the next branch only (no skipping, no going backwards) |
| `hotfix/*` | `production` |
| `production` | `development` (back-merge) |

> Open only **one** PR per branch at a time. GitHub attaches check results to commits, not PRs, so
> two PRs from the same branch show each other's results.

## What happens on a push to an environment branch

```
ci.yml
├─ changes, branch-policy, backend, frontend, ai (+ offline evals), charts, workflows
├─ images ─ build-images.yml: build once · smoke test · Trivy · push + SBOM + provenance + cosign
├─ gate
├─ resolve ─ devops-ai delivery resolve --branch <branch>
├─ infra ─ infra.yml (only if this branch owns a stack AND infra files changed)
│          plan → AI plan review + destructive gate → apply in environment infra-<stack>
└─ deploy ─ deploy.yml (after infra succeeded or was skipped)
           per cloud, in environment <env>: scripts/deploy.sh
           then: promotion PR to the next branch (or back-merge PR from production)
```

**Why deploys run inside CI (`workflow_call`) instead of a `workflow_run` trigger**
- **Versioned with the code.** The deploy uses the workflow and script from the commit being
  deployed. `workflow_run` always uses the default branch's copy.
- **No race with infra.** The deploy waits for infra in the same run, so the first rollout of a
  stack can't start before its cluster exists.
- **No silent drops.** `workflow_run` events are delivered asynchronously. One was never delivered
  during testing, so a merge produced no deploy at all.
- **Real branch locks.** Each GitHub Environment can be locked to its own branch, because the
  deploy job's ref *is* that branch. With `workflow_run` it's always the default branch.

## `scripts/deploy.sh <environment> <cloud>`

1. Read the stack's Terraform outputs (`scripts/tf.sh <cloud> <stack> output`). If the stack isn't
   provisioned, fail with a clear message.
2. Run the `kubeconfig_command` output, and fetch the DB admin password through
   `clouds/<cloud>/db-admin-url.sh`. The password is masked in logs and never stored in Terraform state.
3. Create the namespace and the admin Secret, which only the provisioning hook reads. Add the GHCR
   pull secret if configured.
4. Take a **baseline** of the running release (probes, error counts, restarts).
5. Run `helm upgrade --install` with the environment's values (`devops-ai delivery env-values`)
   and the content-addressed image tags. Hooks: create the environment's own login and database,
   then `alembic upgrade head`.
6. Wait for the load balancer address, then run `devops-ai health-check` with `--baseline`,
   `--rollback` and, if Helm failed, `--helm-failed`. Exit code 1 rolls back and stops the promotion.

`DEPLOY_TARGET=env` points the same script at any cluster: the current kube context plus
`DB_HOST` and `ADMIN_DATABASE_URL`. That's how it was tested end to end on kind.

## Promotion

When every cloud of an environment is deployed and healthy, the pipeline opens or updates the PR
to the next branch. The PR body lists each cloud's status, health verdict, URL and the image tags,
plus the commit changelog. If any cloud was **skipped** (not configured), the PR says so in a
warning: CI passed, but the change wasn't verified in a running environment.

PRs opened with the default `GITHUB_TOKEN` don't trigger CI. Set `PROMOTION_TOKEN` (fine-grained
PAT or GitHub App token) so promotion PRs get their required checks automatically.

## Rollback

- **Automatic.** Any hard gate, or a confident AI "unhealthy" verdict, rolls back to the newest
  revision that actually ran (`deployed`/`superseded`), skipping failed ones. Plain
  `helm rollback 0` would choose a failed revision. A first install has nothing to roll back to,
  so it's left in place for inspection and the pipeline fails.
- **Manual.** Run **Deploy** from the environment's branch with an older commit SHA (images are
  immutable and content-addressed), or `helm rollback idea-board <revision> -n <namespace>`.

## Preview environments (ChatOps)

On a PR, comment `/deploy-preview [aws|gcp] [N replicas]`:
1. The PR head's images are built.
2. Claude plans the kubectl/helm steps, and the command policy checks every step.
3. The release `pr-<N>` is deployed into `preview-pr-<N>` on that cloud's **nonprod** cluster, with
   an embedded throwaway Postgres.

`/teardown-preview` removes it, and closing the PR does the same automatically
(`preview-cleanup.yml`). `/ai <question>` produces read-only diagnosis commands. Without a cluster,
ChatOps does a validated dry run and posts the plan.
