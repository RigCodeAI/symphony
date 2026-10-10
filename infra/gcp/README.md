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

DEV-233's opt-in `coordinator_workflow`, `coordinator_secret_env` and
`enable_linear_webhook` wiring is described in [Linear deployment](../../docs/linear-delegation.md#gcp-coordinator-deployment).
Default ingress remains off. The public webhook backend exposes a separate listener;
the dashboard backend keeps IAP. Prepare a reviewed plan only after resolving the
[remaining pilot decisions](../../docs/dev-233-morning-decision.md); no source test applies resources.

Dashboard access supports managed domains through `iap_viewer_domains`, alongside
the existing `iap_viewer_emails`. The selected pilot audience is `domain:rig.ai`
(`iap_viewer_domains = ["rig.ai"]`), pending managed-domain and IAP organization
eligibility verification. Grants stay on the dashboard backend with
`roles/iap.httpsResourceAccessor`; operator access is configured separately.
