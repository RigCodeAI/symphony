# factory.rig.ai HTTPS ingress, 2026-10-10

The user selected Cloudflare DNS-only A `factory` → `8.232.241.86` and
dashboard access for `domain:rig.ai`. The existing Google project is owned by
organization `655940658710`, whose live display name is `rig.ai`. Google-managed
IAP OAuth restricts access to users inside the resource's organization; actual
signed-in viewer access must be checked separately.

## Applied scope

Terraform 1.13.5 and pinned Google provider 8.5.0 used the existing GCS backend
`factory-511117-symphony-tfstate`, prefix `dev-230/pilot`. The coordinator had
already reserved `rig-factory-viewer`; it was imported as
`module.pilot.google_compute_global_address.viewer[0]`. No second address was
allocated.

The initial full source plan proposed two unrelated VM metadata updates. It
was not applied. A private copy of source `cc85ca7871a27afb03bc2b6e86722a142ff93e7e`
plus the narrow `viewer_ipv4` outputs used an explicit temporary
`compute_override.tf` to ignore metadata on both existing VM resources for this
dashboard-only deployment. The exact overlay and ten reviewed creates are in
[the plan receipt](https-plan-review.json). This is an ingress deployment, not
an application/bootstrap update. A future full-source plan will still expose
the pending metadata differences; review them with the application release.

The saved plan applied **10 additions, 0 updates, 0 deletions**. It installed
443 forwarding, a Google-managed certificate, a TLS policy, the dashboard
backend/health check/instance group, URL map/proxy, proxy-range firewall on
8080 only, and a backend-specific `roles/iap.httpsResourceAccessor` grant for
`domain:rig.ai`. No `allUsers`, operator SSH grant, public VM address, worker
change, secret access change, public webhook route or dispatch was added.
See [apply summary](https-apply-summary.log) and
[post-apply VM preservation](https-vm-preservation.json). Both VM identities and
metadata were preserved, both remain private/running, and disks remain retained.
The coordinator's existing private dashboard returned 200 before deployment.
The active application remains `541279aeb6a5366571e1ee8935e134c728d91c63`.

## Checks and remaining work

The post-apply scoped Terraform drift check returned exit 0, no changes.
The final check at 13:20 UTC found backend health HEALTHY, only the expected
IAP domain grant, DNS A `8.232.241.86`, no AAAA, and no CAA restriction. Google
certificate status remained PROVISIONING and TLS was not yet usable. This observation
is superseded only by a later explicit receipt; certificate creation alone is
not HTTPS success.

Registration values: redirect `https://factory.rig.ai/`, webhook
`https://factory.rig.ai/hooks/linear`. The client-credentials grant does not use
the redirect; it is an unused dashboard landing URL, not an implemented OAuth
callback/code exchange. The webhook currently follows the IAP default route.
It must be activated on the separate signed listener after the app identity,
client/signing secret versions and protected workflow are ready. Native dispatch
remains off. No live signed webhook or Linear acceptance is claimed.

Commands used (private inputs and operator tokens are not retained here):

```bash
terraform -chdir=<private-preserved-source>/infra/gcp/pilot init -backend-config=backend.hcl.example
terraform -chdir=infra/gcp/pilot import -var-file=<private-dashboard-inputs> 'module.pilot.google_compute_global_address.viewer[0]' projects/factory-511117/global/addresses/rig-factory-viewer
terraform -chdir=<private-preserved-source>/infra/gcp/pilot plan -var-file=<private-dashboard-inputs> -out=<private-saved-plan>
terraform -chdir=<private-preserved-source>/infra/gcp/pilot apply <private-saved-plan>
terraform -chdir=<private-preserved-source>/infra/gcp/pilot plan -detailed-exitcode -var-file=<private-dashboard-inputs>
gcloud compute ssl-certificates describe rig-factory-viewer --global --project=factory-511117
gcloud compute backend-services get-health rig-factory-coordinator-https --global --project=factory-511117
gcloud iap web get-iam-policy --resource-type=backend-services --service=rig-factory-coordinator-https --project=factory-511117
dig +short A factory.rig.ai
dig +short AAAA factory.rig.ai
curl --max-time 15 -o /dev/null -w '%{http_code}' https://factory.rig.ai/
```

Official guidance: [Google-managed IAP OAuth](https://docs.cloud.google.com/iap/docs/managed-oauth-client),
[Google-managed certificate requirements](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs),
and [Linear client credentials](https://linear.app/developers/oauth-2-0-authentication).
