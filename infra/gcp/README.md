# GCP pilot

Start with [the operator walkthrough](../../docs/gcp-pilot.md). This directory
contains a separate state-bucket bootstrap and a pilot root using the GCP module.
Portable application/bootstrap tools live in [factory/deploy](../../factory/deploy).

The checked-in files are deployment code, not evidence of an applied deployment.
DEV-230 is complete only after the live smoke, restart, invalid rollout, retained
compute recreation and second plan have been recorded.

```bash
terraform -chdir=infra/gcp/bootstrap init
terraform -chdir=infra/gcp/bootstrap validate
terraform -chdir=infra/gcp/pilot init -backend=false
terraform -chdir=infra/gcp/pilot validate
terraform fmt -check -recursive infra/gcp
python3 -m unittest discover -s factory/deploy/tests -v
```

No secret values belong in `.tfvars`, backend files, release archives or state.
Keep generated state/plans and private inputs outside Git. The example `.tfvars`
contains safe project/capacity settings; required release, billing and budget
inputs must be resolved before a real plan.
