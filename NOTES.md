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

## Notifications and the dispatch token
- Each app repo's `tiers/<tier>/notify.yaml` holds a `githubdispatch` Provider and an Alert on that tier's
  HelmRelease: `promote-failure` (error, `^Helm (install|upgrade|test) failed`), adding `tier` and
  `app` to the event metadata. Success comes from the behaviour tests (Test evidence); the
  `promote-success` Alert of Phase 2 is gone. `notify.yaml` is tier-only and never promoted.
- **Release id.** Each `release.yaml` sets the HelmRelease annotation
  `event.toolkit.fluxcd.io/release-id`: a sha256 of the file without that annotation
  (`scripts/release-id.sh` in each app repo). Flux copies `event.toolkit.fluxcd.io/` annotations into
  event metadata, so each event names the exact release (digest and shared values) it is about.
  A copied `release.yaml` keeps its id, so ids match across tiers.
- **Token.** One fine-grained PAT per tier (`promo-dispatch-<tier>`): resource owner `twallac10`,
  the four app repos, permission **Contents: write** (the minimum GitHub accepts for
  `repository_dispatch`), 90-day expiry. Save it to `~/.config/promo/dispatch-<tier>.token`
  (`chmod 600`). `task up` loads it into every app namespace as Secret `promo-dispatch` and refuses
  to start a tier without it.

## Trust boundary
GitHub Actions can't reach the clusters, so a dispatch event is trusted as the cluster's attestation.
- **What the checks stop:** stale and out-of-order events (the event's digest and release id must
  equal `tiers/<tier>/release.yaml` on `main`), and malformed or injected payload fields (each field
  is checked against a strict pattern before use; payload values are never interpolated into shell).
- **What they don't stop:** a forged event that carries the correct digest and release id. Both are
  public in Git, so anyone holding a dispatch token can claim a release passed. The token is the
  boundary: it lives only in-cluster, one per tier (revoke one tier without the others).
- **Scope is wider than ideal:** Contents: write could also push to the app repos. GitHub has no
  dispatch-only permission. Branch protection (Phase 3) limits what a leaked token can merge.
- **Forged failure events open revert PRs.** A token holder can send a failure event with the
  current digest and id for a rollback tier; the workflow opens a revert PR to the previous
  `release.yaml`. Once Phase 3 auto-merges revert PRs in non-approval tiers, that becomes a way to
  roll stg back (not forward: it only restores what was there). Phase 3 should keep revert PRs
  behind the same guardrails, or require approval for them.
- **On AKS:** use a GitHub App installation token minted per event (short-lived) or workload
  identity federation, rather than a long-lived PAT in a Secret.

## Environments and the gate (Phase 3)
Every PR to an app repo's `main` needs one check, **`promotion-gate`** (branch protection; set up by
`task gh:envs`). The app repo's `gate.yaml` runs two jobs: `guardrails` (the composite action in
`promo-workflows/actions/guardrails`), then `promotion-gate` in the environment `guardrails` chose.

| PR (by branch name) | Checks | Environment |
|---|---|---|
| `promote/<t>` | only `tiers/<t>/release.yaml` changed; it equals the previous tier's on main; that tier's latest Deployment is `success` for the same release id; sources; gitleaks | `<t>` |
| `revert/<t>` | only `tiers/<t>/release.yaml`; it equals the file before main's last change to it; `<t>`'s latest Deployment is `failure`; sources; gitleaks | `<t>` |
| anything else | no `release.yaml` outside the first tier (later tiers change only by promotion); sources; gitleaks | last tier it touches, or none; **the last tier** if it touches `base/` (deploys to every tier at once), `.github/` or `scripts/` |

- **Approval = deploy.** Promotion, revert and mirror PRs enable squash auto-merge. dev and stg
  gates pass at once; prd's waits for your environment approval, then the PR merges itself.
- **Fails closed.** GitHub counts a skipped required check as passed, so `promotion-gate` runs
  `if: always()` and fails unless `guardrails` succeeded.
- **No PR code runs in the gate.** It checks out `main`, reads PR files with `git show`, and
  computes release ids with main's `release-id.sh`.
- **The gate is `pull_request_target`**, so GitHub always runs main's `gate.yaml`; on
  `pull_request` it would run the PR's own, which a PR could rewrite to pass. Safe because the
  token is read-only, no secrets are passed and no PR code runs. It also means the gate's ref is
  `main`, so environment branch policy is **main only**, as the spec asks.
- **Revert PRs** are gated like promotions, so a forged failure event (Trust boundary) can at worst
  open a revert to the release that ran before, which still needs the tier's latest Deployment to
  be a failure, and prd's approval.
- Labels are informational; the gate goes by branch name, which only people with push access set.

## Test evidence (signed, Testkube)
Promotion follows **behaviour tests**, not Helm smoke tests. Each wrapper chart ships a Testkube
`TestWorkflow` (`<app>-behaviour`, checks in `chart/templates/behaviour.yaml`, shared machinery in
`_behaviour.tpl`) and a post-install/post-upgrade hook `TestWorkflowExecution`
(`<app>-behaviour-r<revision>`), so every Helm revision runs once. Its last step, the
`promo-report` template (`testkube/report/`), builds one JUnit file (a check that never reported is
an `<error>`) and sends it to the app repo as `repository_dispatch` `TestReport/<app>.<app>`.
- **The promote workflow** (promo-workflows v0.6.0) checks the report against `main` (chart digest
  and release id), attaches `junit.xml` to the chart digest in GHCR (`oras attach`, artifact type
  `application/vnd.promo.junit.v1+xml`), signs a `https://in-toto.io/attestation/test-result/v0.1`
  attestation on the chart digest (`actions/attest`, Sigstore keyless, logged in Rekor), records the
  Deployment and opens the next tier's PR only on PASSED.
- **The gate** (`check-attestation`) runs `gh attestation verify` for the PR's chart digest, accepts
  only the signer `twallac10/promo-workflows/.github/workflows/promote.yaml@refs/tags/v*` from the
  app repo's `refs/heads/main`, keeps entries for the source tier and the PR's release id, and takes
  the newest by Rekor time: it must be PASSED. Revert PRs keep the Deployment check.
- **Smoke tests** still gate the HelmRelease (readiness only); a smoke failure still records a
  `failure` Deployment (Alert `promote-failure`). Smoke success no longer records anything.
- **Re-run:** `task retest -- <tier> <app>` applies a new execution for the running release; the
  newest result for (tier, release) counts.
- **Proves:** the promote workflow (exact identity, in Rekor) received these results for this digest
  and release and checked them against `main`. An attestation signed by anything else (another
  workflow, branch, repo or a laptop) is ignored, even if it is newer and says PASSED.
- **Doesn't prove:** that the cluster produced them. A dispatch-token holder can still send fake
  results and the workflow would sign them (see Trust boundary). The JUnit artifact in GHCR is for
  people; the gate never reads it.
- **On AKS:** sign in the cluster instead, with workload identity (Sigstore keyless from the
  cluster's OIDC issuer) or an in-cluster key, and accept that identity in the gate.
- **Verify by hand:**
  ```
  gh attestation verify oci://ghcr.io/twallac10/charts/promo-<app>@<digest> -R twallac10/promo-<app> \
    --predicate-type https://in-toto.io/attestation/test-result/v0.1 --source-ref refs/heads/main \
    --cert-identity-regex '^https://github\.com/twallac10/promo-workflows/\.github/workflows/promote\.yaml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
    --format json | jq '.[].verificationResult.statement.predicate | {result, failedTests, configuration}'
  ```
- **Ordering:** apps depend on `testkube-report`, which depends on `testkube`. The report template is
  a Testkube kind, so it can only be applied after the Testkube chart has installed the CRDs.

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

## Live results
### dev, first bring-up (2026-11-08)
- `task up -- dev` from nothing to every Kustomization and HelmRelease Ready, with no manual steps.
- Helm tests passed on first install: kyverno (3 hooks, including the deny dry-run), kyverno-policies (1),
  prometheus (2, including canary target up), otel-collector (2, including accepted spans).
- 26 pods, 0 restarts. Node right after Ready: ~0.22 core, 2.05 GiB (Docker VM 6 CPU / 12.5 GiB).
- Guardrail: Kyverno generated the native VAP `vpol-oci-only-charts`; a server-side dry-run of a
  `HelmRepository` is denied by the API server.
- Every OCIRepository in the cluster is under `oci://ghcr.io/twallac10/charts/`.
- kyverno-policies: all 11 policies `Audit` in dev.
### dev, 30-minute stability watch (2026-11-08 18:31–19:01)
- 7 samples, 5 min apart, Mac kept awake with `caffeinate -i`. 26 pods, 0 restarts, nothing ever not Ready.
- Idle CPU 0.18–0.33 core (avg ~0.24), memory 1.99–2.16 GiB. Last run (LESSONS #17, etcd on Docker disk): ~1.8 cores idle.
- An earlier attempt was cut short when the Mac slept (18:17–18:30): `sleep` stops counting while macOS
  sleeps, so the watch stalled. The cluster survived sleep and wake with 0 restarts.
- Projection for 3 tiers: ~0.75 core, ~6.5 GiB of the 6 CPU / 12.5 GiB Docker VM.

### All three tiers (2026-11-08, ~19:15)
- stg and prd each came up from nothing with `task up -- <tier>`; every Helm test passed on first install.
- dev, stg, prd running together: 26 pods each, 0 restarts. Idle ~0.13 core each; memory dev 2.13 GiB,
  stg 1.63 GiB, prd 2.40 GiB (~6.2 GiB total of the 12.5 GiB VM).
- Guardrail (native VAP) in every tier: `HelmRepository` and a foreign `OCIRepository` denied; our prefix allowed.
- kyverno-policies: 11 policies `Audit` in dev and stg, `Deny` (Enforce) in prd. A privileged pod is
  rejected in prd; none of prd's own pods were blocked.
- stg and prd HelmReleases: `upgrade.remediation` = rollback, `remediateLastFailure: true`; dev holds.
- Tier isolation, live: changing `promo-prometheus/tiers/dev/tier.yaml` (retention 2h → 3h) moved dev's
  Prometheus release to revision 2 with tests passing; stg and prd stayed at revision 1 (6h, 12h). Reverted.
- Caveat: `flux reconcile ks --with-source` on all three tiers at once took more than 5 minutes to
  return even though dev finished in about 1 minute. Prefer checking HelmRelease status directly.

### Full `task down && task up` on the new machine (2026-11-09)
- Machine: Apple Silicon (arm64), 10 cores. Docker VM: 8 CPUs, 15.6 GiB. Flux 2.10.0, kind 0.33.0.
- One `task up`, no manual steps: dev, stg, prd from nothing to every Kustomization and HelmRelease Ready
  in ~8.5 minutes (07:09:50–07:18:12). Every Helm test passed on first install in every tier.
- 26 pods per tier, 0 restarts.
- Idle, a few minutes after Ready (5 samples): ~0.1 core per tier (spikes to ~0.3); memory dev 2.24 GiB,
  stg 2.25 GiB, prd 2.31 GiB (~6.8 GiB total of the 15.6 GiB VM).

### Phase 2: notifications and promote, live (2026-11-09)
- Fresh `task up` with dispatch tokens: every app reported from every tier. Latest Deployment
  `success` for all 12 app/tier pairs; exactly one promotion PR (kyverno-policies dev 3.9.2-2 →
  stg, diff only `tiers/stg/release.yaml`, label `promotion`, evidence table in the body).
- Real event payloads: `client_payload.metadata` carries `app`, `tier` (Alert `eventMetadata`),
  `release-id` (from the HelmRelease's `event.toolkit.fluxcd.io/release-id` annotation),
  `oci-digest`, `revision` and `token` (helm-controller). Success = reason `TestSucceeded`,
  severity `info`; test failure = `TestFailed`, severity `error`. All 16+ live events parsed and
  verified against Git.
- **Found live:** kyverno's test policy, as a Helm test hook, raced Kyverno's own CRDs on first
  install (Helm couldn't map `ValidatingPolicy`), so stg and prd reported `TestFailed` once before
  passing. Fixed in promo-kyverno 3.9.2-3/-4 (the test pod creates its own policy, RBAC limited to
  it). The failure also showed revert PRs must follow only failed upgrades: promo-workflows
  v0.4.1 skips them after a failed first install (nothing to roll back to).
- Failure in dev (OTel health port off in dev `tier.yaml`): HelmRelease `TestFailed` on v2,
  `failure` Deployment in dev, no PR, no revert (dev holds). Reverted.
- Stale event (old release id): `status=stale`, no Deployment. Forged tier `dev;x`: rejected at
  parse, run fails.
- Revert path (simulated stg upgrade failure for kyverno-policies): `failure` Deployment in stg and
  a revert PR (label `revert`) changing only `tiers/stg/release.yaml` (kyverno-policies #4, a test artifact to close unmerged).
- **Gaps:** test pod logs stay in-cluster only (hook pods kept until the next test run; the
  Deployment carries Flux's message, not the logs). Re-testing a release after an automatic
  rollback is Phase 4 (`demo:stg-rollback`).

### Phase 3: guardrails, environments and auto-merge, live (2026-11-09)
- `task gh:envs` (run by the owner after reviewing `--dry-run`): 32 writes; read back auto-merge,
  the `promotion-gate` required check, prd reviewer and main-only branch policies in all four repos.
- Promotion chain end to end: the two stg PRs from before Phase 3 (kyverno-policies #3,
  promo-kyverno #6) got a new commit from the next dev event, passed `promotion-gate` in stg with no
  approval and merged themselves. stg tested OK and opened prd PRs whose gates **waited**. Approving
  prd for promo-kyverno #7 merged it; prd upgraded to 3.9.2-4 with a `success` Deployment and no
  further PR. Deployments created by the promote workflow still record under the main-only policy.
- Sneaky PR (prometheus, `promote/stg` also changing `tier.yaml`): `guardrails` failed on files;
  `promotion-gate` ran anyway and failed (fail-closed, live).
- Hand-made PR (otel, `promote/prd` with a release stg never ran): failed on the release check. It
  first *asked for prd approval* before failing (the environment came from `guardrails` even though
  it failed); fixed: `promotion-gate` requests an environment only when `guardrails` passed.
- Direct pushes to `main` by the owner still work (`enforce_admins: false`), reported by GitHub as a
  bypass of the required check. Template syncs use this.
- **A Docker restart wipes the clusters** (etcd on tmpfs): after one at 21:09 UTC every API call was
  refused. `task down && task up` rebuilt all three tiers in ~8 min; every app re-reported, every
  latest Deployment `success`, the stg/prd first-install race didn't recur (kyverno 3.9.2-4), and the
  open prd PR was updated in place, its gate waiting again.
- A GitHub outage during the first attempt made runs fail at startup with no jobs and no error in
  the API ("workflow file issue"); the run page is the only place GitHub shows the reason.

### Test evidence, live (2026-11-10 to 2026-11-13)
- Every app reaches stg on signed dev evidence (prometheus 29.45.1-3, otel-collector 0.178.2-2,
  kyverno 3.9.2-5, kyverno-policies 3.9.2-5); stg PR gates log `attestation=dev PASSED`.
- **Fresh prd** (`task down -- prd && task up -- prd`, 2026-11-13): Testkube installs before any policy,
  its volumes bind, then the apps; kyverno-policies, prometheus and otel-collector each got a prd
  `PASSED` attestation and a `success` Deployment within a minute of install. kyverno runs 3.9.2-4 in
  prd, which predates behaviour tests, so it has none until 3.9.2-5 is approved.
- **Found on that fresh prd:** the `testkube` Kustomization failed its dry-run on an empty cluster
  (the report template's kind came from the chart in the same Kustomization). Fixed with
  `testkube-report` (see Test evidence, Ordering). Running tiers never hit it.
- **Earlier, in a running prd:** adding Testkube to a tier that already enforces kyverno-policies
  stalled: kind's local-path provisioner was denied hostPath, so Testkube's volumes stayed Pending,
  and the exemption (kyverno-policies 3.9.2-4+) could not arrive because apps wait on Testkube. A
  fresh tier doesn't have this order problem. Rolling Testkube into an existing enforcing cluster
  needs the exemption first.
- **Ready but broken** (prometheus dev, canary scrape job dropped): smoke PASSED, behaviour FAILED
  (`canary-target-up`), a FAILED attestation, a `failure` Deployment, no stg PR. Restored: PASSED.
  (The first try, on 29.45.1-2, passed wrongly: the check queried before Prometheus reloaded its
  config. 29.45.1-3 checks the loaded config.)
- **Retest:** `task retest -- dev prometheus` added a newer PASSED attestation for the same release;
  the gate's check picked it.
- **Forgery:** a workflow on a branch of promo-prometheus (`forge.yaml@refs/heads/forge/attest`)
  signed a PASSED attestation for the broken dev release, newer than its genuine FAILED one. It is a
  valid Sigstore bundle (`gh attestation verify -R` alone accepts it). A hand-made `promote/stg` PR
  for that release failed `guardrails`: "dev's latest behaviour tests … FAILED (canary-target-up)".
- **Footprint, 3 tiers with Testkube:** ~10.3 GiB in Docker (`docker stats`; containers' working
  set ~8.5 GiB), ~0.45 core idle. Testkube itself (api-server, MongoDB, MinIO) is 0.3–0.4 GiB per tier.
- **Testkube startup restarts:** its api-server restarts 4–5 times on install while MongoDB
  starts ("could not ping MongoDB"), then stays up. Harmless; executions queued meanwhile run once
  it's up.
