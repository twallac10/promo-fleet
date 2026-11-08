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
