# promo-fleet notes

## Machine budget
- Apple Silicon (arm64), 8 cores. Docker VM: 6 CPUs, 12.5 GiB.
- Empty kind node (k8s v1.37.0) + Flux 2.10 controllers, 90 s after install: ~0.2 core, 1.29 GiB.

## Decisions
- **No `flux bootstrap`.** Each cluster runs `flux install` and syncs `./clusters/<tier>` from this
  public repo read-only (`clusters/<tier>/flux-sync.yaml`). No fleet write token exists anywhere.
- **etcd on tmpfs.** kind nodes mount `/tmp` as tmpfs; `kind/<tier>.yaml` sets etcd `dataDir: /tmp/etcd`.
  Verified with `findmnt` inside the node. Cluster state does not survive a Docker restart: `task down && task up`.
- **One cluster at a time.** `task up` waits for every Kustomization and HelmRelease in a tier
  before creating the next. `task up -- dev` builds one tier.
- **App namespace = app name.** `kyverno-policies` gets its own namespace so no two Flux
  Kustomizations own the same Namespace.

## Multi-cluster tiers (not built)
A tier is a list of clusters in `tiers.yaml`. With several clusters per tier, the promote workflow
would record one Deployment per cluster (environment `<tier>`, payload carrying cluster + digest)
and open the next tier's PR only when every cluster in the tier has a `success` Deployment for the
same `release.yaml` commit. Any `failure` in the tier blocks promotion.

## Upstream inventory (pins as of 2026-11-08)
Rendered with the intended lightweight values (Kyverno background + cleanup controllers off;
Prometheus alertmanager, kube-state-metrics, node-exporter, pushgateway off; OTel `mode=deployment`,
`-k8s` image).

| Chart | Upstream Helm tests | CRDs | Images (all amd64+arm64 unless noted) |
|---|---|---|---|
| kyverno 3.9.2 (v1.19.2) | 2 enabled: admission-controller and reports-controller metrics endpoints (`readiness-checker`). Liveness/readiness tests for cleanup exist but are off with it. | 22, as **templates** (subcharts `kyverno-api`, `openreports`), not `crds/` | kyverno, kyvernopre, reports-controller, kyverno-cli (v1.19.2); `readiness-checker:latest` in tests **unpinned** → override to v1.19.2 |
| kyverno-policies 3.9.2 | none | none (needs Kyverno's) | none; renders 11 `ValidatingPolicy` (policies.kyverno.io), not `ClusterPolicy` |
| prometheus 29.45.1 (v3.16.0) | none (only the disabled alertmanager subchart has one) | none | prometheus v3.16.0; `prometheus-config-reloader:v0.95.1` is **amd64-only** → override to v0.94.2 (multi-arch) |
| opentelemetry-collector 0.178.2 (0.163.2) | none | none | otel/opentelemetry-collector-k8s:0.163.2 |
| podinfo 6.17.0 (canary) | 3 `test-success` hooks (grpc, jwt, service) | none | podinfo 6.17.0; test images `curl:7.69.0`, `tiny-tools` (unpinned) — canary tests not used |

Kyverno hooks besides tests: `migrate-resources` Job (post-upgrade, kyverno-cli), `rm-webhooks` and
`scale-to-zero` Jobs (pre-delete).

### CRDs and rollback safety
- **kyverno: unsafe to auto-roll back across CRD changes.** Its CRDs are ordinary templates, so a Helm
  rollback *does* revert them (unlike `crds/`), and the post-upgrade `migrate-resources` Job may already
  have migrated stored objects to the new version. Rolling back after a CRD version change can strand
  stored objects. Safe for patch releases that don't touch CRDs; check `kyverno-api` diff first.
- **kyverno-policies, prometheus, otel-collector, podinfo:** no CRDs. Safe to auto-roll back.
