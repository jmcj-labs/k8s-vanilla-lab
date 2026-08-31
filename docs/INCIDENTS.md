# Incidents — platform sprint (2026-08-10)

Findings 1-4 come from the hands-on session that built the evolved cluster
manually; findings 5-7 from automating it (CI apply runs the same day).
Format: what happened → root cause → fix in IaC/bootstrap.

## 1. Multi-line paste with `apt-get` consumed stdin

**Symptom**: pasting multi-line command blocks into an SSH session silently
skipped lines; `apt-get` (and other interactive-capable tools) read the rest
of the pasted block from stdin, so subsequent commands never executed.

**Root cause**: interactive tools consume stdin; a pasted block is stdin.

**Fix**: never drive the cluster by pasting blocks. All procedures live in
scripts executed as files with `set -euxo pipefail` so every line runs, echoes
and fails loudly ([`platform/install.sh`](../platform/install.sh),
[`scripts/smoke-test.sh`](../scripts/smoke-test.sh), bootstrap scripts).

## 2. IMDSv2 hop limit 1 blocked pods from reaching instance metadata

**Symptom**: the EBS CSI driver could not reach IMDS from its pods; metadata
requests timed out.

**Root cause**: with `http_put_response_hop_limit = 1`, the IMDSv2 PUT
response dies at the first network hop, and traffic from containers crosses
one extra hop.

**Fix**: raising the hop limit in `metadata_options` for control plane and
workers ([`tofu/modules/control-plane/main.tf`](../tofu/modules/control-plane/main.tf),
[`tofu/modules/worker/main.tf`](../tofu/modules/worker/main.tf)). IMDSv2
(`http_tokens = "required"`) stays enforced. The manual sprint raised it to 2,
which was still one hop short — see incident #4 for the final value (3) and
the real root cause.

## 3. Empty providerID on kubeadm-vanilla nodes broke the EBS CSI driver

**Symptom**: volume provisioning failed; the EBS CSI controller could not map
nodes to EC2 instances.

**Root cause**: kubeadm without a cloud provider leaves `spec.providerID`
empty, and the EBS CSI driver requires it (`aws:///<az>/<instance-id>`) as its
metadata source.

**Fix**: every node (CP and workers) passes `--provider-id` to the kubelet
**before** `kubeadm init`/`join` via `/etc/default/kubelet`, written by
[`bootstrap/common.yaml`](../bootstrap/common.yaml) (Step 7b) with AZ +
instance-id read from IMDSv2 — the kubelet publishes it at node registration.
Chosen over the post-init/post-join `kubectl patch` validated in the manual
run because it is one mechanism for all nodes, needs no cluster credentials
on workers and no reconciler on the CP. The smoke test asserts providerID is
non-empty on every node.

## 4. IMDS unreachable from the pod network even with hop limit 2 — RESOLVED

**Symptom**: even after fix #2, pods on the pod network (as opposed to
hostNetwork) still cannot reach 169.254.169.254. In the automated cluster this
crashed the entire EBS CSI driver: the controller could not fetch
instance-profile **credentials** ("no EC2 IMDS role found … context deadline
exceeded") and the node plugin could not fetch metadata (its `kubernetes`
fallback also fails — it needs topology labels that vanilla kubeadm does not
set, not just providerID).

**Root cause (confirmed 2026-08-10, CI diagnostics)**: Cilium runs in tunnel
routing mode with iptables masquerade. Pod egress to IMDS is SNATed to the
node IP, but the IMDS response TTL crosses one more routing hop on the way
back to the pod than a plain container bridge — hop limit 2 is exactly one
short. It was never link-local masquerade exclusion (`bpf ipmasq` unused;
the `CILIUM_POST` MASQUERADE rule covers non-cluster destinations).

**Fix**: `http_put_response_hop_limit = 3` on CP and workers. Verified by a
fresh CI apply: EBS CSI healthy, dynamic gp3 PVC Bound + mounted. The
explicit `--set controller.region` in
[`platform/install.sh`](../platform/install.sh) stays as defense in depth.

**Security debt (priority)**: hop 3 makes IMDS (and the node's instance
profile) reachable from ANY pod, not just the EBS CSI. Before running
untrusted workloads, add a CiliumNetworkPolicy allowing 169.254.169.254 only
from the EBS CSI pods and denying it for the rest of the pod network.
**→ Paid on 2026-08-11**: `platform/policies/ccnp-deny-imds.yaml`
(clusterwide egressDeny, EBS CSI excluded from the endpointSelector),
verified by the smoke with Hubble drop evidence.

## 5. Gzip cloud-init passed as plain `user_data` broke in-place updates

**Symptom**: the first apply that modified live instances in place
(`metadata_options` change) aborted with `Provider produced inconsistent
final plan … Value is base64 encoded … use the user_data_base64 argument`.

**Root cause**: `cloudinit_config` renders gzip+base64, but both modules
passed it to `aws_instance.user_data`, which expects plain UTF-8 — a
contract violation that stayed invisible while instances were only ever
created, never updated.

**Fix**: both modules use `user_data_base64`
([`tofu/modules/control-plane/main.tf`](../tofu/modules/control-plane/main.tf),
[`tofu/modules/worker/main.tf`](../tofu/modules/worker/main.tf)), with
`user_data` kept in `ignore_changes` to absorb the attribute migration.

## 6. Inline + standalone rules on the same security group wiped a rule

**Symptom**: the aborted apply from #5 still "completed" the CP security
group modification — deleting the worker→CP allow rule in AWS on a live
cluster.

**Root cause**: the CP SG declared inline `ingress` blocks while the worker
module attached a standalone rule to the same SG. Inline rules are enforced
as the complete set: any apply deletes externally attached rules. (The inline
"All from workers" rule was also mislabeled — `self = true` allows CP→CP,
not worker→CP.)

**Fix**: the CP SG has no inline rules; every rule is a standalone
`aws_vpc_security_group_ingress_rule`/`egress_rule`, including the worker→CP
rule owned by the worker module. Never mix inline and standalone rules on
one SG.

## 7. Gateway never `Programmed` without a LoadBalancer implementation

**Symptom**: `shared-gw` reached `Accepted=True` but `Programmed` timed out;
its generated LoadBalancer Service stayed `Pending` forever.

**Root cause**: no cloud-controller-manager in a kubeadm-vanilla cluster →
nothing assigns LoadBalancer IPs, and Cilium only programs a Gateway once its
Service has an address.

**Fix**: a `CiliumLoadBalancerIPPool`
([`platform/manifests/lb-ipam-pool.yaml`](../platform/manifests/lb-ipam-pool.yaml))
scoped to namespace `infra` — Cilium LB-IPAM assigns a virtual IP
(`172.20.255.0/24`, not announced externally) and the Gateway programs.
External access remains via NodePort until the Sprint 2 ingress decision
(NLB — shipped in S2-2: the NLB is now the public application entry).

## 8. A deny-only Cilium policy blacked out the whole cluster's egress

**Symptom**: right after applying the clusterwide IMDS deny, the smoke's gp3
PVC never bound. Live diagnosis: the EBS CSI controller could not resolve
`ec2.eu-west-1.amazonaws.com`; CoreDNS logged i/o timeouts to its upstream
(10.0.0.2); Hubble showed **Policy denied DROPPED** from CoreDNS to both the
VPC resolver and the API server. Every pod except the EBS CSI had lost all
egress.

**Root cause**: in Cilium, a policy containing ONLY deny rules still flips
the selected endpoints into **default-deny** for that direction. The CCNP
selected every endpoint except the CSI with an `egressDeny` — so everything
else's egress became "deny everything", not "deny just IMDS".

**Fix**: `enableDefaultDeny: {egress: false, ingress: false}` on the CCNP —
the documented switch that turns a policy into a pure deny overlay
([`platform/policies/ccnp-deny-imds.yaml`](../platform/policies/ccnp-deny-imds.yaml)).
Verified live: DNS recovered instantly, IMDS still denied with
`Policy denied by denylist` drops, CSI exception intact.

**Bonus finding (smoke flakiness)**: `hubble observe | grep -q` under
`set -o pipefail` is racy — `grep -q` exits on first match, the writer can
catch SIGPIPE, and the pipeline (inside `if`) reads as false. The smoke now
captures output first and greps the variable, plus uses precise `--from-pod`
filters instead of fishing in the last-N global drops.

## 9. Kafka under network policy: three traps found live (phase 2)

**Symptom(s)**: (a) the entity operator stayed Pending forever and the Kafka
CR never went Ready; (b) after fixing that, a neutral-namespace pod could
still reach the brokers on 9093 despite the operand CNP; (c) after a broker
restart, that broker never became Ready and operator reconciliation stalled.

**Root causes** (each pinned with live evidence, not theory):

1. **Label spillover**: Strimzi puts `strimzi.io/cluster` (and `kind=Kafka`)
   on the entity operator too. Both the required anti-affinity and the CNP
   endpointSelector must use `strimzi.io/pool-name` — the only label
   exclusive to the broker/controller pods — or the entity operator gets
   repelled off every worker / strangled by the operand default-deny.
2. **Strimzi generates its own per-listener NetworkPolicy, open to ANY** —
   and network policies compose by union of allows, so the generated
   `ANY:9093` defeats the CNP's scoping (seen as `Allow Ingress ANY
   9093/TCP` in the BPF policy map). The listener's `networkPolicyPeers`
   is the supported way to scope it (to `logistics`).
3. **Brokers need egress to the API server and ingress 8443 from the
   cluster operator (KafkaAgent)** — Hubble showed the restarted broker
   dropping SYNs to kube-apiserver under the CNP's default-deny, and the
   operator timing out reading broker configs. The CNP now includes both,
   self-sufficient instead of leaning on Strimzi's generated policy.

**Fix**: pool-name selectors everywhere, `networkPolicyPeers` on the
listener, `toEntities: kube-apiserver` + operator 8443 in
[`cnp-data-kafka.yaml`](../platform/policies/cnp-data-kafka.yaml). Verified
by the full smoke: RF3 produce/consume from logistics, broker-loss
tolerance, neutral namespace denied with Hubble drops.

## 10. Egress to the Gateway VIP is not gated by a client-side network policy

**Symptom**: building the app contract (brief 3b entregable 5b), a
CiliumNetworkPolicy meant to allow ONLY `traffic-generator` pods egress to
the shared Gateway (`toEntities: [ingress]`, TCP/443) neither restricted nor
was needed. Live fixture proof: a `logistics` pod WITH the label reached the
Gateway (HTTP 200) — and so did a pod WITHOUT it (HTTP 200). The intended
negative assertion could never pass.

**Root cause**: traffic to the Cilium Gateway LoadBalancer VIP is
`to-proxy` redirected to the built-in Envoy at the datapath BEFORE the pod's
L3/L4 egress policy toward the destination is evaluated. Hubble shows the
destination as `reserved:world` with verdict `to-proxy FORWARDED`, and the
endpoint's realized BPF policy carries no matching egress allow. The
`reserved:ingress` identity governs INGRESS from Envoy to the backend (which
is why the `logistics` default-deny opens `fromEntities: [ingress]`), not the
client's egress to the Gateway. Control confirmed the default-deny itself
works: the same pod to another `world` IP (1.1.1.1:443) times out.

**Fix**: remove the client-side egress CNP (it is a no-op) and keep the
smoke fixture positive-only — "a `logistics` pod reaches the Gateway over
HTTPS with SNI". No `world`/`host`/`cluster` shortcut was taken, per the
brief's tripwire.

Note on `allowedRoutes`: it controls **route ownership** (which namespaces
may attach HTTPRoutes to the Gateway — scoped to `logistics` here), NOT
**request authorization** (which client pods may send requests through the
Gateway). So it does not substitute for the missing egress control. Risk
accepted for the MVP: there is no requirement to isolate clients *within*
`logistics` from each other. The real future control is L7/auth at the
Gateway plus per-service network policies — Phase 1.5 (CLUSTER.md §5).

## 11. `count`/`for_each` on unknown values — latent until a plan from empty state

**Symptom**: after the cluster was destroyed, the first `tofu plan` against the
now-empty state failed:
`Error: Invalid count argument … count value depends on resource attributes
that cannot be determined until apply` at
`modules/registry/main.tf:161`. Every prior PR's Validate had passed —
because the resources already existed in state, so the values the `count`
read were known. Nothing in the code had changed; only the state emptied.

**Root cause**: `count = var.developer_role_arn != "" ? 1 : 0`, where
`developer_role_arn` comes from `module.access` and is **unknown-after-apply**
on a create-from-scratch plan. OpenTofu forbids `count`/`for_each` depending
on a value not known until apply — it cannot expand the resource. Same family
as the fresh-safe trust of PR #36 and INCIDENTS' recurring theme: **the graph
does not plan from zero**. Bugs that only touch known-after-apply values stay
invisible as long as the state is populated, and surface the moment you plan
against an empty state — i.e. exactly at the coronation apply.

**Fix**: gate the `count` on a STATIC boolean (`attach_assume_developer`,
known at plan), keeping `developer_role_arn` only as the policy **Resource**
(Resources may be unknown at plan; `count`/`for_each` may not). Swept the
whole graph for the family — the only other candidate,
`worker` `count = length(var.ecr_repository_arns) > 0`, is safe because the
list length is fixed by a static `for_each` even when the ARNs are unknown.

**Guardrail (so the family can never hide again)**: a permanent Validate job
runs `tofu plan` against an **empty local-backend state** (`make plan-empty`),
turning "plans from zero" into a CI invariant. Verified: `47 to add, 0 change,
0 destroy`.

## 12. First real app deploy: OIDC trust rejected the ID-qualified subject claim

**Symptom**: logistics-lab's first `workflow_dispatch` deploy on `main`
(run 31885711901) died at `configure-aws-credentials`:
`Not authorized to perform sts:AssumeRoleWithWebIdentity` after 12 retries.
Audience, provider and the six repo variables were all correct, and the
`sub` pattern in the trust — `repo:jmcj-labs/logistics-lab:ref:refs/heads/main`
— looked like an exact match for a dispatch on main (without `environment:`
in the job, `workflow_dispatch` emits the same ref-based sub as push).

**Root cause**: the repo emits its OIDC subject in GitHub's **ID-qualified
(immutable) naming scheme** — the repo's OIDC customization endpoint reports
`sub_claim_prefix: repo:jmcj-labs@284581373/logistics-lab@1331865297` — so
the token's sub is `repo:jmcj-labs@284581373/logistics-lab@1331865297:ref:…`,
which the classic-form `StringLike` can never match. Rename-proof subjects
protect against repo-resurrection attacks; the trust policy predates the
scheme. The two `@` IDs are the org and repo database IDs — stable across
renames, unique to this exact repo.

**Fix**: trust BOTH naming schemes of the same repo — the classic pair and
the ID-qualified pair (`app_repo_ids` in `tofu/modules/registry`), still
main + tags only, still zero wildcards on the repo identity. GitHub decides
which scheme a token carries, so the trust covers both; nothing is widened
(the IDs are strictly narrower than the name — they survive renames).
Smoke check 11b updated to accept either scheme while still failing on any
foreign repo or broad wildcard.

## 13. First live run of S2-1: base backup vs failover drill — a 1800s shutdown inside a 300s wait

**Symptom**: the first Apply after merging S2-1 (incremental, onto the live
cluster) failed at the smoke's failover drill:
`CNPG failover did not complete in 300s (phase: Failing over, primary:
logistics-pg-1)`. The old primary sat in `Terminating` for far longer than
any failover should take; `targetPrimary` was already `logistics-pg-2`.

**Root cause**: a race between two features shipped in the same piece. The
`immediate: true` ScheduledBackup started the FIRST base backup on the
primary (CNPG's default backup target) right after `make platform`; minutes
later the smoke killed that primary for the failover drill. CNPG pods carry
`terminationGracePeriodSeconds: 1800` — the smart shutdown deliberately
holds a terminating instance while its backup/checkpoint drains — so the
old primary would not die for up to 30 minutes, and the smoke only waits
300s. Nothing was broken: archiving stayed green
(`ContinuousArchiving=True`) and the promotion completed once the pod
finally went away. The drill's clock lost to the shutdown's clock.

**Fix (both sides, defense in depth)**:
- `spec.backup.target: prefer-standby` on the Cluster: base backups run on
  a REPLICA, so losing the primary never collides with a backup. With 3
  instances a standby is always available; CNPG only falls back to the
  primary in degraded states.
- Smoke guard before the failover drill: wait (up to 600s) until no Backup
  is `running` — covers exactly that degraded fallback.
- The failed first Backup object is superseded by an on-demand Backup after
  recovery; `immediate: true` stays (a fresh apply still converges fast —
  on a standby now).

## 14. Barman vs the bucket: a wrong theory, then the real 403

> **Correction record**: the first version of this entry blamed "env-less
> pods pending a credential rollout". That mechanism is FALSE for CNPG's
> in-tree barman — the instance manager reads the credentials Secret via
> the Kubernetes API at exec time, and NO AWS envs ever appear in the pod
> spec (verified on a fresh, correctly-configured cluster: zero AWS envs,
> archiving attempted with the right credentials anyway). The env-based
> gate shipped on that theory waited for a signal that cannot exist and
> failed every install. Kept here because the correction IS the lesson.

**Symptom (fresh cluster, everything born configured)**:
`ContinuousArchiving=False (ContinuousArchivingFailing)`; the primary's
logs show the deterministic culprit:
`barman-cloud-check-wal-archive … (403) when calling the HeadBucket
operation: Forbidden`.

**Root cause**: barman-cloud runs `HeadBucket` as its connectivity check,
and HeadBucket maps to `s3:ListBucket` with **no prefix in the request**.
The `cnpg-backup` IAM user's ListBucket was conditioned on
`s3:prefix = cnpg/*` — so the very first check 403s and archiving never
starts. A too-clever prefix condition, not a network mystery.

**Fixes**:
- IAM (tofu/envs/persistent): ListBucket on the bucket without the prefix
  condition — documented trade-off: barman can list KEY NAMES bucket-wide,
  object content stays scoped to `cnpg/*`.
- install.sh gate rewritten to check FUNCTION, not plumbing: wait for
  `ContinuousArchiving=True` (the condition only turns True after a real
  successful check against the real bucket), bounded, with the reason
  printed on timeout.

**On the older cluster's 30-minute hangs (#13's second act)**: with the
env theory dead, the honest status is *cause not fully proven* — the old
pods predated the barman config entirely, and their wal-restore processes
hung rather than 403ing. Plausible candidates (stale instance-manager
state; a blocked metadata path under the old pod identity) died with the
cluster. What survives: the wedge presentation, the surgical exits, and
the fact that a fresh cluster with this IAM fix archives cleanly.

**Lessons**:
- Gate on the system's own health signals (conditions that require a real
  round-trip), never on inferred plumbing details of an operator's
  internals.
- When a check fails, read the failing component's OWN error before
  theorizing: the 403 was in the logs all along.
- IAM prefix conditions and client-side connectivity probes (HeadBucket)
  are a known-bad pairing.

### Adenda a #13/#14: el interbloqueo del operador — y la salida quirúrgica que no usamos

Estado alcanzado durante la recuperación: `currentPrimary=logistics-pg-1`
(pod ya inexistente), `targetPrimary=logistics-pg-2` (pod borrado durante el
desatasco, PVC intacta). La máquina de estados del operador entra en bucle:
"There is a switchover or a failover in progress, waiting for the operation
to complete" — **no recrea el pod del target mientras el failover esté en
curso, y el failover no puede completar sin ese pod**. Reiniciar el
operador no ayuda: el bucle es status-driven, no de caché.

Promocionar la única instancia viva (`kubectl cnpg promote … logistics-pg-3`)
habría arriesgado el mismo cuelgue de wal-restore que atascó a pg-2 (la
causa exacta de esos cuelgues quedó sin probar — ver la corrección de #14).

**La salida quirúrgica existe y es esta** (para el día en que esto ocurra
con datos que importen): editar el **status subresource** del Cluster para
desbloquear la máquina de estados — vaciar/realinear `targetPrimary` (p. ej.
apuntándolo a una instancia viva y con envs, o igualándolo a
`currentPrimary` para cancelar el failover) vía
`kubectl -n data patch cluster logistics-pg --subresource=status --type=merge -p '…'`,
y dejar que el reconcile continúe desde un estado consistente. Es cirugía de
riesgo (el status es propiedad del operador; hacerlo con un backup base +
WAL verificados en S3, nunca sin ellos).

**Aquí no la usamos a propósito**: cluster de laboratorio efímero, datos
sintéticos, incidente ya convertido en tres fixes de código (#49 prefer-standby
+ guard, #50 gate de convergencia de envs) — el ciclo limpio destroy→apply
ejercita además el propio S2-1 (cleanup de EBS, supervivencia del bucket,
pods nacidos con envs). La cirugía queda documentada; la decisión de usarla
es del operador y depende del valor de los datos.

## 15. The missing link: the data CNP was blackholing barman's road to S3

**Symptom (fresh cluster, IAM fixed)**: `ContinuousArchiving` turned True at
18:49, the platform finished at 18:51, and the first base backup then sat in
`running` for 25+ minutes — barman's postgres session idle in `ClientRead`,
nothing in `base/`, and a direct probe from the PG pods to the bucket
endpoint timing out from EVERY instance.

**Root cause**: `cnp-data-postgres` (phase 2) flips the PG operand pods into
default-deny and its egress list opened exactly three things: kube-dns,
replication peers, kube-apiserver. It predates S2-1 — **no rule for S3**.
The two-minute window between archiving turning green (18:49) and step 11
applying the policies (18:51:36) explains the deceptive sequence: the WALs
that landed did so inside that window, the condition stayed True (it
re-evaluates on failures, and barman's calls were HANGING, not failing),
and everything after the policy landed was silently blackholed.

**This retroactively closes #13/#14's "cause not fully proven"**: on the
old cluster the policies were in place all along, so every barman S3 call
(wal-restore during the promotion, the zombie backup) hung exactly the same
way. Not IMDS, not credentials, not stale config — a default-deny doing its
job on traffic nobody had declared.

**Fix**: explicit egress opening in `cnp-data-postgres` — `toEntities:
world` on TCP/443 (S3 has no stable CIDR; tightening to `toFQDNs` via the
DNS-proxy path is a Sprint 3 candidate). Verified live: the S3 probe went
from timeout to an instant HTTP 403 (anonymous, correct) on every pod, and
an on-demand `Backup` completed in ~30 seconds.

**Lessons**:
- A hang is a NETWORK answer; an error is a SERVICE answer. barman hanging
  (instead of 403ing) pointed at packet drop from the start — the IMDS
  rabbit hole of #14 was chased because the 403 arrived first and stole
  the spotlight.
- When a default-deny namespace gains a new external dependency (S2-1
  adding S3), the policy is part of the feature's definition of done.
  Hubble would have shown the DROP immediately: it is the FIRST tool for
  any silent degradation (the house rule existed; it was not applied).
- `ContinuousArchiving=True` is a health signal with hysteresis: it proves
  the last attempt worked, not the current path. The install gate now
  passing on it is still right — but drills remain the only proof that
  matters.

---

## 16. The drill found the door locked: no out-of-band access to the control planes

**When**: 2026-08-16, S2 piece 3 (HA), acceptance phase.
**Severity**: the documented recovery procedure for the worst scenario was
**not executable**. Nothing was broken — which is the point: it had never
been tried.

### What happened

The HA etcd restore is the one ceremony that cannot use `kubectl`: it stops
all three control planes, so by design the API is gone and the only way in
is out-of-band. The runbook uses SSH, and SSH from `my_ip` was open — the
NLB piece closed 6443, never 22. The procedure was sound.

But the **private key of the `k8s-vanilla-lab` key pair does not exist in
the operating environment**. Verified five ways before concluding: no file
in `~/.ssh` (only `agent/` and `known_hosts`), `ssh-add -l` → *The agent has
no identities*, no `~/.ssh/config`, no match in a disk-wide search for
`*.pem` / `id_rsa` / `id_ed25519` / `*k8s-vanilla*`, and a direct connection
answering `Permission denied (publickey)`. The node's
`authorized_keys` holds exactly one `ssh-ed25519` key — the lost one.

Nobody had noticed because since 2026-05-14 every operation went through CI,
SSM parameters and `kubectl`. **The channel was never exercised, so its
absence was invisible.**

### Why it matters beyond this drill

A recovery procedure that depends on an untested channel is not a procedure.
This is the same house rule that produced the backup drills in S2-1 —
*untested restore is hope, not backup* — applied one level down: **the
ACCESS the restore depends on also needs proving.**

### The trap inside the workaround

"Rotate a new key" is not the small fix it appears to be. An EC2 key pair is
baked into `authorized_keys` at first boot: changing the key pair in AWS does
nothing to a running instance. Injecting a key by hand (possible today via a
privileged pod, since the cluster is healthy) produces access that is **not
reproducible by IaC and vanishes at the next node replacement** — and this
piece just made node replacement a routine ceremony.

### Fix

Session Manager, whose agent turned out to be **already installed and active**
on the nodes (`amazon-ssm-agent 3.3.4793.0`, snap, service active) and only
missing the IAM permission to register. Access then travels with the instance
profile: every future node gets it from the IaC, replacement-proof, audited in
CloudTrail, and it lets the SSH ingress rules disappear entirely — which also
removes the `my_ip` drift class (see the note in EVIDENCE-S2-piece3 §4b).

### The lesson that generalises

**The smoke must assert the out-of-band channel on every apply.** A door you
never open is indistinguishable from a door that is locked, until the day you
need it. Every recovery dependency deserves the same treatment as the backups
themselves: exercised automatically, not documented and trusted.

### Resolution (same day)

SSM adopted as the out-of-band channel, in the order the brief demanded:
**prove the new door before closing the old one.**

1. `AmazonSSMManagedInstanceCore` on both node roles → 6/6 nodes `Online`.
2. Canary Run Command executed on each node, asserting its exact output.
3. Interactive Session Manager shell opened and verified running a command.
4. **Only then** the inbound TCP/22 rules were removed from both security
   groups, and `my_ip` retired from the modules with it.

Two things the live run taught that the plan did not anticipate:

- **Attaching the policy is not enough on a running node.** The agent had
  already failed to get credentials and had backed off:
  `[CredentialRefresher] Sleeping for 27m48s before retrying`. Without
  restarting the agent, registration appears broken for half an hour. Nodes
  born after this change are unaffected — the permission is in the profile
  from first boot.
- **`AWS-RunShellScript` executes with `/bin/sh`** (dash on Ubuntu), which
  rejects `set -o pipefail` outright. A shebang as the FIRST command IS
  honoured (verified: bash 5.2.21), which is how `scripts/lib/ssm-exec.sh`
  keeps the strictness the SSH helper had. Without this the ceremonies would
  have silently lost their error handling.

**The generalised lesson is now enforced, not just written**: smoke §15
proves the channel on every apply — exact inventory, all `Online`, a canary
Run Command per node, the absence of inbound TCP/22, and (locally, where the
plugin exists) an interactive shell that opens and runs a command.

---

## 17. The optimistic condition: eight faces of one bug

**When**: 2026-08-16 (S2 piece 3 and its closing deliverable) and
2026-08-17 (the piece-4 scaffolding). It has now outlived the piece that
named it.
**Severity**: none reached production — every instance was caught by a cross
review or by executing. That is the point of recording it.

### The pattern

Four times in one piece, a check that could not determine something decided
**"fine, carry on"**:

| Where | The optimistic condition | What it would have allowed |
|---|---|---|
| Recreate guard | `tofu state list 2>/dev/null \|\| true` | Any credential/backend/lock failure read as "empty state" → apply over the pre-HA singleton |
| Founder autodetect | `if aws ssm get-parameter; then` | Any SSM error read as "no cluster" → a second `kubeadm init` on top of a live one |
| Ceremony inventory | `tofu output ... \|\| echo 3` | An unreadable state read as "3 control planes" → destructive ceremony against an invented number |
| Restore phase markers | flag set on meeting the completed phase | Every phase read as "already done" → a restore that skips the restore |

Different files, different days, different reviewers catching them. Same
shape: **the absence of an answer treated as a good answer.**

### Why it keeps happening

Shell makes the optimistic form the *shorter* one. `|| true`, `|| echo N`
and `if cmd; then` are what fingers type; the fail-closed version always
costs more lines — capture the exit code, capture stderr, name the ONE
signature that legitimately means "nothing there", abort on everything else.
The cheap form is also the one that reads fine in review, because it looks
like it is handling the error.

### The rule this leaves behind

**In anything that guards a destructive action, "I could not tell" is a
failure, not a pass.** Concretely:

- Never `|| true` / `|| echo <default>` on a value a safety decision depends on.
- Capture rc and stderr separately; enumerate the exact signature that means
  "legitimately absent" (`ParameterNotFound`, `No state file was found`);
  everything else aborts with the cause named.
- Prove the decision table, do not read it. The phase-marker bug survived
  review and died to a four-row truth table.

### The fifth face: inside the script that documents this

Codex found it **in this very entry's own enforcement list**. The HA restore
drill — the file cited below as an example of failing closed — had:

- the **anti-witness check** reading `if kubectl get …; then FAIL; fi`, so a
  `Forbidden` while RBAC settled after the rewind, a timeout, or an API still
  coming up all fell through to "it is gone" and PASSED the proof. The exact
  trap that had to be dodged by hand minutes earlier.
- `phase_get` / `state_get` back on `|| echo none` — expired credentials or a
  throttle read as "no progress recorded", i.e. "start from scratch" on a
  cluster possibly halfway through a restore.
- a lock that treated **any** put-parameter failure as "someone holds it" and
  then inferred a resume from the presence of a phase marker, so two
  concurrent ceremonies could both proceed.

**Writing the rule in prose does not install it in the artefact.** The lesson
had been documented for a day and was still being committed. That is why the
enforcement list below is a list of *files*, checked one by one, rather than a
claim about having learnt something.

### The sixth face: the instrument whose whole job is not to commit it

2026-08-17, S2 piece 4 scaffolding. The upgrade witness — an instrument built
**specifically** to refuse the optimistic reading during a live upgrade — was
handed to review and came back with this face found in it.

Codex described the mechanism as a `|| echo "000"` in the HTTP probe,
collapsing "I could not measure" into "I measured a 000". That exact line was
**not** in the code: rc and code were already separate variables. Chasing it
anyway is what exposed three real holes, each worse than the one reported:

- **A witness that died still passed.** If the probing loop was killed or
  crashed mid-window, the series simply stopped growing. `stop` then computed
  `sent == successful` over the truncated record and returned PASS — a green
  verdict for a window nobody was watching. The failure mode of a witness is
  not "it reports a failure", it is **silence**, and silence looked identical
  to success. Liveness is now checked *before* the kill, so it reflects the
  loop's own state.
- **Every success counted as a failure.** `line.split(None, 3)` keeps the
  trailing newline on the final field with `maxsplit`, so `"ok\n" != "ok"`.
  Harmless in direction (it failed closed) but it made the instrument useless:
  every window would have failed. It had passed a read-through of the code.
- **An unreadable record was counted and then ignored.** A malformed line
  incremented a failure counter but never entered the series, so it never
  reached the `sent`-vs-`successful` comparison, and the window still passed.
  The finding existed, was tallied, and **changed nothing** — the optimistic
  condition with an audit trail.

All three were found by the **negative tests**, not by reading. The second and
third had already survived being written, reviewed and reasoned about.

**And then the fix for the first one turned out to have the same shape.** The
liveness check was `kill -0 <pid>`, which asks *does a process with this
number exist* — not *was my loop still working*. It answers yes for a PID the
OS recycled onto an unrelated process, and yes for a loop wedged and probing
nothing. A watchdog added to catch "it stopped and I did not notice" that
itself could not tell the difference between working and merely existing.
Proven, not argued: driving the recycled-PID scenario against the previous
commit returns **rc=0 — it passed a window whose loop had been dead for ten
minutes**. Liveness is now the loop's own heartbeat, stamped before each
probe: evidence of work done, immune to PID reuse, and stale when the loop
hangs. The verifier is held to the same rule — a missing heartbeat, an
unreadable one, an absent `python3`, or a verifier that dies mid-verdict all
fail the window, because *no verdict was produced* is not *the window
passed*.

**What generalises**: measuring instruments need their own negative tests, and
"it failed closed" is not the same as "it works". A witness has two ways to be
worthless — passing what it should fail, and failing what it should pass — and
only executing its decision table finds both. `scripts/test-witness-verdict.sh`
runs 14 synthetic series and asserts the outcome of each; the verdict logic
lives in `scripts/lib/witness-verdict.py` precisely so it can be executed
without a cluster. `scripts/test-witness-liveness.sh` does the same for the
watchdog — 10 cases including a recycled PID, a wedged loop, and killing the
verifier mid-verdict. Both run in CI via `make test`, and that gate was
verified by inducing a red case and watching it fail the PR: a suite that
reports without blocking is the same bug in a lab coat.

### The seventh face: the instrument failed what it should have passed

2026-08-23, driving 4a. The witness had been fixed, tested (24 cases) and
cross-reviewed. Then it was pointed at a live cluster for the first time and
had **two defects that would have failed the whole window with faults that
were ours**:

- **The gRPC probe used the HTTP authority.** The chart composes hostnames as
  `<hostname|service>.<domain>`, so the GRPCRoute answers to
  `routing.logistics.lab` while HTTP answers to `shipments.logistics.lab`.
  Probing gRPC with the HTTP authority matches no route: one probe in five
  fails, forever, with nothing broken.
- **The HTTP probe was missing `-k`.** The selfsigned CA has an empty DN, so
  chain verification *cannot* succeed (the S1 finding) and curl returns 60 on
  every request — classified `transport:tls`. **Every window of 4a would have
  failed before Cilium was touched.** `-k` does not weaken this: pinning is
  enforced independently, proven live — a wrong pin still returns curl 90.
  That rc was also missing from the TLS class, which is the signature of a
  rotated certificate.

Neither was reachable by the negative tests: those cover the **verdict**, and
these were in the **probe targets**. A test suite proves what it exercises.
The instrument was only trustworthy after `witness-traffic.sh once` answered
over the real datapath — a green suite is not a working instrument.

### The eighth face: `Programmed=True` was stale

2026-08-23, the 4a upgrade itself. Cilium 1.20.1 rolled cleanly: helm
`deployed`, both DaemonSets 6/6 ready and updated, Gateway `shared-gw`
reporting **`Accepted=True Programmed=True`** with its LB-IPAM address
unchanged, all app pods Running with zero restarts. Every check the runbook
named as the 4a→4b detector said the Gateway was fine.

It was not. 18 seconds after helm declared success the entry path started
failing, and 138 of 368 witness probes never came back. The operator's log
had the truth:

```
level=error msg="Required GatewayAPI resources are not found"
  tlsroutes... not found
  CRD referencegrants... does not have version "v1"
  backendtlspolicies... not found
```

1.20.1 requires `gateway.networking.k8s.io/v1` for `referencegrants` plus
`tlsroutes` and `backendtlspolicies`; our v1.2.1 CRDs have none of them, so
the operator **never started its Gateway API controller**. The new Envoys
came up and timed out fetching every resource — listeners, clusters, routes,
and the TLS Secret — which is why the failures were `transport:tls` and
`transport`: Envoy accepted the connection with no certificate to present
and no backend to reach.

`Programmed=True` was written by the 1.19.6 operator and **nobody ever
retracted it**, because the controller that would have is the one that did
not start. A Kubernetes status field is a *cache of the last controller that
cared*; absent a controller, it reports the past with total confidence.

**And the first fix for it had the same shape.** The runbook was amended to
"check the operator log has no CRD error" — which is the identical bug one
level up: **absence of a known error message is not evidence of work**. A
controller that never starts, starts and dies, loses leader election, or
wedges writes no such error either. Cross-review caught it before it shipped.

The verification is now **positive and active**
(`scripts/verify-gateway-controller.sh`): create a canary HTTPRoute the
controller has never seen, require it to write a status **naming itself** with
`observedGeneration == generation`, then **change** the route and require
`observedGeneration` to *follow* the new generation. That second step is what
separates "something reconciled this once" from "something is reconciling
now" — a stale status cannot follow a generation it has never seen. A timeout
is a failure. The pre-existing Gateway's own conditions are deliberately not
read: they are the field that lied. Its decision table is executed in
`scripts/test-gateway-canary-logic.sh` (8 cases, including the 4a scenario
and a stale observedGeneration).

**What generalises**: a status field is not a liveness check. Verifying a
condition proves what some controller believed once, not that anything is
still reconciling it. Where a status gates a decision, prove the **controller
is alive** — its logs, its leader election, a change it must observe — not
just that the field says what you hoped. The witness was the only thing in
the room that was not fooled, and only because it measured the datapath
instead of asking the API how it felt.

### Where it is enforced

`scripts/guard-legacy-cp-state.sh`, `bootstrap/control-plane.yaml` (genesis
detection), `scripts/replace-control-plane.sh` (inventory), and
`scripts/drill-restore-etcd-ha.sh` (`after()` plus the resume-without-state
guard), `scripts/witness-traffic.sh` + `scripts/lib/witness-verdict.py`
(liveness, unreadable records, missing series) and
`scripts/preflight-cgroup-v2.sh` (a node that cannot be *proven* on v2 blocks
exactly like one proven on v1) all now fail closed and say why. The witness
pair is additionally **tested**, not just written.

---

## 18. Control-plane join material survived the destroy that should have taken it

**When**: 2026-08-16, right after crowning S2 piece 3 — found while verifying
the closing destroy, not by a review.

### What happened

The destroy reported success and every visible resource was gone: zero
instances, no NLB, zero orphaned volumes, no registered SSM nodes. But the
post-destroy check found **two parameters still alive**:

```
/k8s/k8s-vanilla-lab/cp/certificate-key   SecureString
/k8s/k8s-vanilla-lab/cp/joined-count      String
```

The first is **control-plane join material** — the exact secret this piece
treated as a privilege boundary, scoped away from the worker role and given a
2h TTL precisely because holding it means being able to become a control
plane. It outlived the cluster it belonged to.

### Root cause

The destroy-time sweep listed parameters with `get-parameters-by-path`
**without `--recursive`**, so it only ever saw the top level of
`/k8s/<cluster>/`. It was written when every parameter lived there. S2 piece 3
introduced the `cp/` subpath (join material) and its ceremonies the `oob/`
one (restore lock and phase markers) — **and nobody re-read the sweep that was
supposed to clean up after them.**

A destroy is not the place to discover that a cleanup routine has a blind
spot: by then the cluster is gone and only the secrets remain.

### Second defect in the same five lines

The listing ended in `|| echo ""`, so a failure — expired credentials, a
throttle — produced an empty list, an empty loop, and a **silent success**
that leaves every secret behind. INCIDENTS #17 again, this time in the
destroy path. Now the listing fails closed and the destroy aborts rather than
report a clean teardown it cannot vouch for.

### Fix

`--recursive` on the listing, and a hard failure if the listing itself fails.

### The lesson

**A cleanup routine is a consumer of every path anyone adds.** Introducing a
new subpath is not complete until the thing that deletes it has been re-read.
Worth stating because the mistake is structurally invisible: nothing fails,
nothing warns, and the evidence only shows up if someone counts what remains
after a destroy — which is exactly why that count belongs in the ceremony.

---

## 19. The verification that matched nothing and called it clean

**When**: 2026-08-24, driving the 4b CRD ladder.
**Severity**: none reached a decision — every instance was caught, three of
them by a second, independent check that happened to disagree.

### The pattern

A verification query is written to answer "is the bad thing present?". It
matches nothing. Nothing is reported. Everyone reads that as "clean".

But **a query that matches zero and a state that is absent look identical**,
and the query can be broken in ways that are invisible precisely because a
broken query produces the same silence as a healthy system. This is
INCIDENTS #17 in a different costume: not a condition that decides "fine"
when it cannot tell, but a *question* that cannot tell and is read as "fine".

Four in one day, all mine, all in ad-hoc checks written while executing:

1. **`grep -c conflict` over a server-side diff** reported four conflicts
   that did not exist. All four were prose inside the OpenAPI schema — the
   listener condition `Reason: Conflicted`. Counting a word is not detecting
   a state. *(This one failed loud, not silent — the opposite direction, same
   root: the query did not mean what it looked like.)*
2. **`^[+-]\s+- name: v[0-9]`** to check whether any API version was
   withdrawn. The dash in the pattern is on a different YAML line, so it
   matched **neither additions nor removals**. It reported "no version is
   withdrawn" while also failing to see `referencegrants` gaining `v1`. Only
   noticing that the *addition* was missing exposed it.
3. **jsonpath over an annotation key with dots** (`bundle-version`) returned
   empty, because unescaped dots read as nested fields. It failed closed —
   but as "wrong version", not as "I could not read it".
4. **The worst, inside the gate itself.** The 6a gate that justifies the
   entire hybrid channel used
   `jsonpath='{range .spec.versions[?(@.served)]}'`. That predicate filters
   on **the field existing, not on its value**: `backendtlspolicies` returned
   `v1 v1alpha3` when `v1alpha3` has `served: false`. So the gate asked "is
   v1alpha2 among the versions?" instead of "is v1alpha2 SERVED?" — and would
   have passed a `v1alpha2` with `served: false`, the exact state it exists
   to prevent. Its conclusion happened to be right, confirmed by two
   independent checks, but it was right by luck.

### The rule

**Every verification that could match zero when it should match something
carries a positive control assertion: "expected N, found N".** Not "I did not
find the bad thing" — that sentence is true both when the system is healthy
and when the question is broken.

Concretely, in this repository:

- Assert counts, do not infer from silence
  (`scripts/verify-cilium-120-schema.sh` prints
  `CONTROL ASSERTION: expected 7 kinds serving v1, found 7` and fails if not).
- Prefer `jq` with an explicit value comparison (`select(.served == true)`)
  over kubectl jsonpath predicates, which test presence rather than value.
- Separate "I could not read it" from "the value is wrong" — they are
  different failures with different responses.
- When a check is cheap, run the *opposite* query too: the reason defect 2
  was found is that the addition it should have seen was also missing.

### Where it is enforced

`scripts/crd-diff-gate.sh` (anchored `^Error from server (Conflict)`, with
three distinct outcomes and a decision table in
`scripts/test-crd-diff-gate.sh`) and `scripts/verify-cilium-120-schema.sh`
(control assertion, jq value comparison, unreadable separated from wrong).

---

## 20. `externalTrafficPolicy: Cluster` had nothing to fall back to

**When**: 2026-08-24, second attempt at 4a (Cilium 1.19.6 → 1.20.1).
**Severity**: entry path degraded ~4 min, recovered by rollback in 67s. No
data loss. The cluster was a lab.

### It was NOT a repeat of 2026-08-23

That matters first, because the reflex is to assume it was. The 23rd failed
because Cilium 1.20.1's operator would not start its Gateway API controller
against v1.2.1 CRDs, and every rolled Envoy came up with **no TLS secret** —
83 probes classified `transport:tls`.

This time: the entry gate was green before touching helm (7 kinds served at
`v1`, `bundle-version v1.6.1`), and the witness recorded **zero
`transport:tls`**. 4b fixed the cause of that night and it did not come back.
This is a different failure.

### What happened

`helm upgrade` to 1.20.1 with `envoy.updateStrategy.rollingUpdate.maxUnavailable=1`.
The rollout behaved exactly as designed — one Envoy at a time, 1/5, 2/5, 5/5,
6/6 — and helm reported `Upgrade complete`. The witness froze successes at 68
and accumulated 49 failures: **36 `transport`** (connection refused/reset), 9
`grpc`, 4 `timeout`. Longest consecutive failure run: **35 probes**, far past
the 10 that the pre-agreed discriminator called "door down, roll back now".
Rolled back at the operator's call; Envoy back on v1.36.9 in 67s, traffic
healthy 4s later.

**Root cause of why the new Envoy would not serve is NOT KNOWN, and is
recorded as unknown.** The rollback recreated the DaemonSet pods, so the
1.37.5 containers' logs were gone before anyone could read them. Recovering
the door was the right call and this was its price. No cause is asserted.

### ROOT CAUSE, corrected: it was the AGENT's datapath, not Envoy

The first analysis blamed Envoy, because that was the hypothesis carried into
the window. **The sampling data said otherwise and was misread.**

```
14:07:49Z  cilium 6/6      envoy 6/6     ← nothing rolled yet
14:08:03Z  ← FIRST WITNESS FAILURE
14:08:10Z  cilium 4/4 ROLLING   envoy 1/5
14:08:31Z  cilium 6/6      envoy 1/5
```

The first failure lands inside the window where the **cilium-agent** DaemonSet
was rolling, before any Envoy had been replaced. With strict kube-proxy
replacement and no kube-proxy, **the NodePort is programmed by the agent's
eBPF datapath**: when the agent restarts, the node's door shuts — Envoy never
enters the story on that node.

That reframes everything. It is not "Envoy 1.37.5 would not accept
connections". It is "**every node loses its datapath while its agent
restarts, and the load balancer keeps sending it traffic**", because the
health check cannot see it. Envoy's own roll adds a second window on top, but
the dominant one is the agent's.

`maxUnavailable=1` was irrelevant, now for a sharper reason: it limits how
many nodes roll at once, and losing even one costs its entire share.

### THE FINDING: the assumption underneath the plan was false

The plan tolerated rolling Envoy because `externalTrafficPolicy: Cluster`
would forward traffic from a node whose Envoy was down to a node whose Envoy
was up. **It cannot.** Verified on the live cluster after recovery:

- `Service infra/cilium-gateway-shared-gw` has **no selector**, and its only
  endpoint is a placeholder address bound to **no node** (0 endpoints carry a
  `nodeName`). `Cluster` policy distributes across an endpoint list; here
  there is no list to distribute across.
- The `CiliumEnvoyConfig` for the Gateway has **no `nodeSelector`**: the
  listener is programmed into **each node's local Envoy**. Traffic entering a
  node's NodePort is served by *that node's* Envoy or not at all.
- The NLB health check is **TCP on the NodePort (30443)**, and Cilium
  programs that NodePort on every node **independently of the local Envoy's
  health**. So the check passes while Envoy cannot serve — the NLB has no way
  to notice.

So losing one Envoy does not cost a fraction of capacity that peers absorb.
It costs **the whole share of traffic the NLB sends to that node** — roughly
a third, with three workers — for as long as that Envoy is down, and the load
balancer keeps sending it.

Which is exactly what the timeline shows: the first failure landed
**7 seconds before** the first updated Envoy was even observed, and never
recovered until rollback. The degradation began with the FIRST node rolled,
not on accumulation. `maxUnavailable=1` was not too generous — it was
irrelevant to the failure mode.

### A number that was wrong in the earlier analysis

The 2026-08-23 write-up said the NLB takes "~30s" to remove a failed target.
That came from misreading the AWS CLI's alphabetical key ordering. The real
configuration is `interval=30s, unhealthy threshold=3` → **up to 90 seconds**,
plus a 10s deregistration delay. Three times the assumed blind window — and
moot anyway, since the TCP check cannot detect this failure at all.

### What generalises

**A fallback path is a claim about the system, and claims get verified before
they are relied upon.** "Cluster policy will absorb it" was inherited from how
Services normally work, and was never checked against how Cilium's Gateway
actually wires its data plane. The instrument caught the consequence in
seconds; the assumption had been sitting in the plan for two days.

And: **a health check that probes the wrong layer is worse than none**, because
it manufactures confidence. TCP on a NodePort proves the datapath is
programmed, not that anything behind it can answer.

### The fix is a real readiness endpoint, and it does not exist yet

Checked before designing on top of an assumption: both components already
serve HTTP `/healthz` — the agent on 9879, Envoy on 9878, both
`hostNetwork: true`. **But both bind to 127.0.0.1 only.** From the node's own
address they return nothing:

```
LISTEN 127.0.0.1:9878   LISTEN 127.0.0.1:9879
curl http://<node-ip>:9879/healthz → 000 (fail)
curl http://127.0.0.1:9879/healthz → 200
```

So the NLB cannot reach them, and the fix is not "repoint the health check at
a port that already exists" — the per-node readiness endpoint has to be
built. That is TIEMPO 1 of the plan, and it is the reason the plan has three
separately validated steps instead of one.

---

## 21. El mensaje del commit afirmó cambios que su diff no contenía

**Cuándo**: 2026-08-24, cruce final del PR #72.
**Severidad**: bloqueó el merge; tres correcciones, incluida la retirada de
un gate fail-silent de 4a, se daban por hechas sin estar en el árbol.

### Qué pasó

El commit `6d7db347` describía cuatro fixes con detalle. Su diff real
modificaba una sola línea de `docs/RUNBOOK-upgrade-kubernetes.md`: la
corrección `v1.6.x` → `v1.6.1`. La evidencia del conflicto v1.3.0, el
control positivo de TLSRoute y el rollback instrumentado no aparecían en
ningún fichero. El gate inline de 4a conservaba además el mismo jsonpath
fail-silent que INCIDENTS #19 acababa de prohibir.

CI estaba verde y los 39 tests pasaban. Ese verde era correcto sobre el
árbol que recibió; no comprobaba que la narración del commit correspondiera
al árbol. El fallo estaba un nivel por encima del código: la descripción del
trabajo se leyó como evidencia de que el trabajo existía.

### Mecanismo acreditado y límite de la evidencia

El reflog muestra checkout hacia `fix/canary-positive-signal` y creación del
commit en el mismo segundo. El commit y su índice contenían solo el cambio de
4c, y no hay blob inalcanzable con los otros tres textos. Eso acredita que
los fixes no llegaron al commit ni al índice que lo produjo. Git ya no
permite distinguir con honestidad entre «nunca se editaron» y «se editaron
fuera del árbol o se descartaron antes de añadirlos»; afirmar uno de esos
mecanismos sería inventar una causa que la evidencia no conserva.

La causa de proceso que sí queda demostrada es que se escribió y empujó el
mensaje desde la intención, sin contrastarlo con el índice ni con el commit
resultante. Faltaron las dos aserciones que habrían parado el push:

```bash
git diff --cached --name-status       # antes de commit: ¿están TODOS los ficheros?
git show --stat --oneline HEAD        # después: ¿el commit contiene lo que afirma?
```

### La regla

**Un mensaje de commit es una afirmación no verificada hasta contrastarlo
contra su propio diff.** El CI valida el árbol, no la fidelidad de la
descripción del árbol. Por tanto:

1. El autor verifica `git diff --cached` por fichero antes de crear el commit.
2. Verifica `git show --stat` y el diff concreto inmediatamente después.
3. El mensaje referencia los paths/secciones que implementan cada afirmación.
4. El revisor lee el diff y los ficheros; nunca firma desde el mensaje o el
   cuerpo del PR, aunque CI esté verde.

Este es INCIDENTS #19 aplicado a la evidencia misma: «no vi trabajo ausente»
no equivale a «el trabajo está presente». La aserción positiva es el diff.

---

## 22. Un stub fail-open validó una llamada imposible de kubectl

**Cuándo**: 2026-08-27, primer Apply del bootstrap directo a Cilium 1.20.1 +
Gateway API v1.6.1 (run `33051536412`, `main` en `d2d940d`).
**Severidad**: el bootstrap quedó parcial y el Apply agotó sus 1209s esperando
un kubeconfig que el fundador, correctamente, nunca publicó. Sin pérdida de
datos; laboratorio efímero. Ventana de infraestructura: 42m41s (cada CP
41m40s; cada worker 40m33s), **0,163 USD de coste base** (EC2 + NLB; no
incluye EBS, IPv4, NLCU ni transferencia).

### Cronología UTC

```
07:55:53  02-control-plane-init.sh materializado en CP-0
07:57:32  Step 3/9: kubeadm init
07:57:58  OK kubeadm init completed successfully
07:58:12  OK API target healthy -- el NLB ya enruta a CP-0
07:58:12  aplica Gateway API v1.6.1: seis CRDs standard + TLSRoute overlay
07:58:19  los siete CRDs están Established
07:58:19  error: unknown flag: --api-version
07:58:19  ERROR: [after CRD apply] API discovery .../v1 failed
08:16:27  CI: kubeconfig ausente tras 1209s; Apply rojo
08:27:14  CP-2 aborta cerrado: joined-count=absent tras 1827s
08:27:16  CP-1 aborta cerrado: joined-count=absent tras 1828s
```

Los extractos están deliberadamente redactados. El log íntegro de `kubeadm
init` contiene material de join y queda solo en el archivo forense local; no
entra en Git.

### Causa técnica

El assert de serving real ejecutaba:

```bash
kubectl api-resources --cached=false \
  --api-version=gateway.networking.k8s.io/v1 -o name
```

`kubectl api-resources` no ofrece `--api-version`. El `kubectl v1.35.8` del
nodo lo rechazó antes de que el bootstrap llegara a Helm, por lo que Cilium
nunca se instaló. CP-0 quedó con API y etcd locales vivos pero `NotReady`, y
CoreDNS quedó `Pending`.

Una consulta read-only posterior contra los endpoints de discovery reales
(`/apis/gateway.networking.k8s.io/v1` y `/v1alpha2`) demostró que el estado
que el comando pretendía comprobar **sí era correcto**: conjunto exacto de
siete recursos base en v1, solo TLSRoute en v1alpha2, los siete CRDs con
`bundle-version=v1.6.1`. Falló el verificador, no el apply de CRDs.

### Cómo pasó dos revisiones

El stub de `test-cilium-schema-gate.sh` decidía por substrings de `"$*"`:
cualquier invocación que contuviera `v1` recibía una respuesta válida. No
modelaba la interfaz de kubectl y, por tanto, convirtió una llamada imposible
en verde. Era un **stub fail-open**.

Además, la misma línea pasó la revisión cruzada del director: fue citada y
firmada sin contrastarla con `kubectl api-resources --help`. El revisor leyó
lo que esperaba leer —«filtrar por versión»—, no lo que la CLI realmente
aceptaba. CI y revisión humana fallaron por el mismo sesgo, no por dos causas
independientes.

### Lo que este arranque sí coronó

- El transporte cloud-init ASCII-only: el fundador se materializó, dejó log
  desde su primer Step y fue el script que cloud-init identificó al fallar.
- El segundo gate del NLB: no confundió registrado con enrutado; esperó hasta
  `healthy` antes de aplicar CRDs.
- La ruta híbrida v1.6.1: los siete CRDs llegaron a `Established`, con el
  overlay TLSRoute último y el esquema vivo exacto.
- El gate de join: `ParameterNotFound` significó esperar, nunca `0`; CP-1 y
  CP-2 agotaron 1800s y abortaron cerrados sin tocar el cluster.

### Fix y regla

El discovery se consulta por su contrato real:
`kubectl get --raw /apis/<grupo>/<versión>`. Del `APIResourceList` se comparan
conjuntos exactos de `.resources[].name`, excluyendo subrecursos (nombres con
`/`). El stub solo responde a esas llamadas exactas y devuelve error ante
cualquier otra forma.

**Un stub de una herramienta externa es fail-closed sobre su interfaz, no
solo sobre sus datos.** Si acepta combinaciones que la herramienta real
rechaza, el test demuestra una API imaginaria. Y una línea familiar tampoco
queda revisada por haber sido leída: cuando su contrato decide el arranque,
se contrasta con la CLI real o su ayuda.

---

## 23. El parser que suspendió a un datapath sano

**Cuándo**: 2026-08-27, segundo Apply del bootstrap directo a Cilium 1.20.1 +
Gateway API v1.6.1 (run `33055713509`, `main` en `5534bf9`).
**Severidad**: el fundador abortó a los 2m04s de empezar; el Apply agotó sus
1210s esperando un kubeconfig que nunca se publicaría. Sin pérdida de datos;
laboratorio efímero. Ventana de infraestructura: 41m27s (6 instancias),
**0,1533 USD de coste base** (EC2 + los dos NLB; no incluye EBS, IPv4, NLCU
ni transferencia).

### Cronología UTC

```
08:49:07  CI lanza el Apply
08:52:49  arrancan CP-0, CP-1, CP-2
08:53:30  tofu apply termina -- infra creada limpia
08:53:36  CI empieza a sondear SSM por el kubeconfig
08:54:08  OK registrado en el target group -- kubeadm init autorizado
08:54:27  OK kubeadm init completado
08:54:31  OK API target healthy -- el NLB ya enruta a CP-0
08:54:36  OK [after CRD apply] siete CRDs en v1, TLSRoute en v1alpha2, bundle v1.6.1
08:54:37  helm despliega Cilium 1.20.1; el DaemonSet rueda
08:55:16  ERROR: KubeProxyReplacement='True   [ens5   10.0.1.227 fe80'   <-- abort
08:55:17  cloud-init cierra en error (Up 141.63s)
09:13:46  CI se rinde: kubeconfig ausente tras 1210s
09:24:29  CP-1 aborta cerrado: joined-count=absent tras 1826s
09:24:34  CP-2 aborta cerrado: joined-count=absent tras 1830s
```

Los extractos están deliberadamente redactados. El log íntegro de `kubeadm
init` contiene material de join y queda solo en el archivo forense local; no
entra en Git.

### Causa técnica

El assert del datapath vivo leía la salida de `cilium-dbg status` así:

```bash
KPR=$(... | awk -F: 'tolower($1) ~ /kubeproxyreplacement/ {gsub(...); print $2; exit}')
[ "${KPR}" = "True" ] || { log "ERROR: ..."; exit 1; }
```

La línea real que imprime el agente, capturada del CP-0 vivo:

```
KubeProxyReplacement:    True   [ens5   10.0.1.227 fe80::4a6:16ff:fea6:6065 (Direct Routing)]
```

`-F:` parte por **todos** los dos puntos. `$2` termina en el primero que
aparece dentro de la IPv6 link-local del dispositivo, y el token extraído
fue `True   [ens5   10.0.1.227 fe80`, que no es `True`.

**El sufijo de dispositivos es lo fatal, no la IPv6.** Cilium añade siempre
`[<iface> <ip> ... (Direct Routing)]` cuando KPR está activo. Sin IPv6 el
token habría sido `True   [ens5   10.0.1.227 (Direct Routing)]`: tampoco es
`True`. La IPv6 solo decide **dónde** trunca. El fallo es por tanto
**determinista en todo arranque**, no una carrera ni un caso de borde.

Lo verificado estaba bien. Cilium 1.20.1 se instaló, el DaemonSet rodó, y
`KubeProxyReplacement` era `True` de verdad. Falló el verificador, no el
datapath.

### Procedencia

Regresión introducida en `b9adbaa` (*feat(bootstrap): start on cilium 1.20 and
gateway api 1.6*), la reescritura del bootstrap para nacer en el estado
destino. **No era un latente que despertó**: la línea nació rota ese mismo día
y habría abortado cualquier arranque.

### Lo que este arranque sí coronó

Es el primer arranque en el que **todo lo fail-closed se comportó de punta a
punta**, y conviene registrarlo porque es la prueba en hierro de dos fixes:

- **El fix de #22 (`kubectl get --raw` sobre discovery)**: el primer
  `assert_gateway_schema` **pasó** a las 08:54:36 con el contrato real --
  siete CRDs sirviendo `v1`, TLSRoute también en `v1alpha2`, `bundle-version`
  v1.6.1. Los CRDs van antes de Cilium por diseño y llegaron enteros.
- **El gate de join del 26-ago**: CP-1 y CP-2 leyeron `absent` y **esperaron**
  ~1828s antes de abortar cerrados. Ninguno tradujo "no existe" a "puerta
  abierta". Primera vez que se ejerce contra hierro.
- **El fundador abortó limpio**: cloud-init lo identificó por nombre
  (`Runparts: 1 failures (02-control-plane-init.sh)`), no quedó proceso vivo,
  y **no se publicó ni un byte de estado**: los cinco parámetros SSM
  (`kubeconfig`, `join-command`, `ca-cert-hash`, `cp/certificate-key`,
  `cp/joined-count`) quedaron ausentes.

Lo que este arranque **no** llegó a probar: el segundo
`assert_gateway_schema` ("after Cilium start") y los Steps de publicación
(kubeconfig a SSM, material de join, `joined-count=1`). De ese tramo no hay
evidencia ni a favor ni en contra.

### El defecto espejo

`scripts/smoke-test.sh` comprobaba lo mismo con `grep -q "True"` sobre la
línea entera. Es el mismo error por el otro lado: acepta la subcadena
aparezca donde aparezca -- en un nombre de dispositivo, en un campo futuro --
y habría dado por bueno un datapath en `False`. Uno suspendía a un sistema
sano, el otro aprobaba a uno enfermo; ambos por no extraer el campo.

### Fix y regla

Ambos sitios extraen ahora el token por posición y comparan exacto:

```bash
awk '$1 == "KubeProxyReplacement:" {print $2; exit}'
[ "${KPR}" = "True" ]
```

Validado contra el CP-0 vivo antes de escribir el fix: imprime `True`, sin
espacios ni sufijo.

**Se parsea el dato, no la prosa.** La salida de una herramienta pensada para
humanos no tiene contrato de separadores: `cilium-dbg` intercala IPs, IPv6 y
paréntesis en el mismo renglón que el valor. Cuando el arranque depende de
ese valor, se toma el campo por su posición y se compara exacto -- nunca por
subcadena, nunca troceando por un carácter que el propio valor contiene.

**Y los tests de parsers se alimentan de salida real capturada, no de líneas
inventadas.** `scripts/test-kpr-parser.sh` usa la línea literal del cluster
vivo, e incluye el parser roto como control: si el defecto volviera, el test
falla. Un test escrito contra la salida que uno *imagina* solo demuestra que
el parser coincide con esa imaginación.

---

## 24. `Ready` no es `sabe responder`: el fundador murió en silencio un segundo después del rollout

**Cuándo**: 2026-08-27, cuarto Apply del día, el primero con el parser de #23
corregido (run `33059962416`, `main` en `6964b2c2`).
**Severidad**: el fundador abortó a los 92,8s; el Apply agotó sus 1210s sin
kubeconfig. Sin pérdida de datos. Cluster dejado vivo para el forense.

### Lo primero: el fix de #23 funcionó

Conviene decirlo antes que nada porque condiciona la lectura. El arranque
**cruzó** el punto donde murió #23 y el assert del KPR ya no es el que mata:
consultado despues contra el CP-0 vivo, el comando corregido devuelve
exactamente `True`. El parser esta probado. Lo que fallo es otra cosa, en la
misma linea.

### Cronología UTC

```
09:48:11  arrancan CP-0, CP-1, CP-2
09:49:48  el fundador empieza
09:49:52  OK registrado en el TG -- kubeadm init autorizado
09:50:16  OK kubeadm init completado
09:50:19  OK API target healthy -- el NLB enruta a CP-0
09:50:26  OK [after CRD apply] siete CRDs en v1, TLSRoute en v1alpha2, bundle v1.6.1
09:50:27  helm despliega Cilium 1.20.1
09:50:31  el pod cilium-x6ftr arranca
09:51:17  el agente empieza a servir su monitor API
09:51:18  el agente sigue "Initializing daemon" / "Initializing IPAM"
09:51:19  el pod pasa a Ready -- el rollout de helm retorna
09:51:20  el fundador MUERE. Sin una sola linea de error
10:08:46  CI se rinde: kubeconfig ausente tras 1210s
```

### El silencio es el dato

A diferencia de #23, el log del fundador **no contiene ninguna linea de
ERROR**: termina en la salida de helm y salta al script de join. Y el silencio
no es un log perdido: la linea 10 del script es

```bash
exec >> /var/log/k8s-cp-bootstrap.log 2>&1
```

de modo que **todo** su stderr aterriza en ese fichero. Si hubiera fallado
cualquier `kubectl` sin redirigir, su error estaria escrito ahi.

Eso deja una sola sentencia candidata en todo el tramo entre el rollout y el
siguiente `log`: la unica cuyo stderr se descarta antes de llegar a esa
redireccion.

```bash
KPR=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null \
  | awk '$1 == "KubeProxyReplacement:" {print $2; exit}')
[ "${KPR}" = "True" ] || { log "ERROR: ..."; exit 1; }
```

Bajo `set -euo pipefail`, si `kubectl exec` falla: `2>/dev/null` se traga el
mensaje, `pipefail` propaga el fallo del primer tramo a la tuberia, la
asignacion hereda ese estado y `set -e` mata el script **antes** de que la
comparacion de la linea siguiente pueda registrar nada. La guarda existia y
nunca llego a ejecutarse.

### La carrera

El pod paso a `Ready` a las **09:51:19** y el script hizo `exec` contra el
**09:51:20**, un segundo despues. En ese instante el agente aun estaba
inicializandose: sus propias trazas dicen `Initializing daemon` e
`Initializing IPAM` a las 09:51:18,2. `cilium-dbg status` interroga al agente;
un agente que acaba de pasar su readiness probe todavia no responde ese
status.

**`Ready` no es `sabe responder`.** Es la tercera encarnacion de la misma
familia que ya nos costo dos arranques: *registrado* no era *enrutado* (#77),
*aplicado* no era *servido* (#22), y ahora *rolled out* no es *contestable*.
En los tres casos el gate leyo una senal adyacente a la que le importaba.

### Limite de esta evidencia

**No hay mensaje de error capturado.** El `2>/dev/null` lo destruyo en el
momento de producirse, y la instancia no lo conserva en ningun otro sitio. La
adjudicacion se apoya en la convergencia de tres hechos independientes --
unica sentencia con stderr descartado, muerte a un segundo del Ready, y agente
demostrablemente a medio inicializar-- no en el error en si. Es inferencia
fuerte, no lectura directa, y asi debe constar. Lo que si queda probado es
que **fallo el primer tramo de la tuberia**; con el stderr destruido no se
puede distinguir si `kubectl exec` no llego a alcanzar el contenedor o si
llego y fue `cilium-dbg` quien devolvio rc!=0 contra un daemon a medio
inicializar. Bajo `pipefail` ambos mueren identico, y el fix cubre los dos.

El propio descarte es parte del defecto: una guarda cuya entrada se construye
tirando el stderr **no puede informar de su propio fallo**. Convirtio un error
diagnosticable en una muerte muda, y costo un arranque entero averiguar donde
habia ocurrido.

### Lo que este arranque coronó

Cuarta prueba consecutiva de que lo fail-closed aguanta:

- **El parser de #23**: superado el punto exacto donde abortaba, y verificado
  vivo devolviendo `True`.
- **El fix de #22**: el primer `assert_gateway_schema` volvio a pasar a las
  09:50:26 con los siete CRDs, TLSRoute en `v1alpha2` y bundle v1.6.1.
- **El gate de join**: CP-1 y CP-2 leyeron `absent` y **esperaron**, anotando
  su espera cada ~310s, sin abrir. Siguen cerrados al escribir esto.
- **Cero estado publicado**: los cinco parametros SSM ausentes. Un fundador que
  no termina no deja material de join a medias.

Sigue sin probarse el tramo posterior: segundo `assert_gateway_schema`,
publicacion en SSM, joins reales, quorum etcd 3/3, workers y datapath.

### Hallazgo menor, del mismo forense

La salida de helm aparece **duplicada** en el log. La causa es que el script ya
redirige su stdout al fichero con `exec >>` y ademas hace
`... | tee -a /var/log/k8s-cp-bootstrap.log` en varios puntos: `tee` escribe en
el fichero y en su stdout, que es el mismo fichero. Cosmetico, pero indujo a
error dos veces al leer los logs. Anotado, no corregido.

---

## 25. El presupuesto de transporte que nadie vigilaba

**Cuándo**: 2026-08-27, quinto Apply del día, el primero con el gate de #24
corregido (run `33071611144`, `main` en `10821c61`).
**Severidad**: el apply murió creando la instancia; **CP-0 nunca llegó a
existir**. CP-1 y CP-2 sí se crearon y quedaron esperando a un fundador
imposible. Sin cluster, sin fundador, sin logs que preservar. Ventana:
10m20s, **0,0235 USD**.

### Qué pasó

```
Error: creating EC2 Instance: RunInstances
  InvalidParameterValue: User data is limited to 16384 bytes
  with module.control_plane.aws_instance.control_plane[0]
```

Medido sobre el render real, antes y después del PR que lo rompió:

```
antes de #83   user_data (gzip) = 16289 B   margen  +95
con #83        user_data (gzip) = 16704 B   margen -320
```

El fundador **ya viajaba a 95 bytes del techo**. Las 60 líneas de
`bootstrap/kpr-gate.sh` -- el fix de #24, correcto en su contenido -- lo
cruzaron. Solo falló el índice 0: CP-1 y CP-2 no llevan el script del fundador.

### Por qué no lo vio nadie

**El límite era conocido y estaba medido esa misma mañana.** Durante el
forense del arranque del 26-ago se calculó ese payload y se escribió el
límite de 16384 B en el propio análisis. Se añadieron 2,3 KB al fundador y no
se volvió a medir.

El fallo de revisión es **compartido**: el ejecutor escribió el cambio con la
herramienta de medida ya montada y no la usó; el director aprobó el diff,
añadió una línea más y tampoco midió.

Y **el CI no podía atraparlo**: `Format · Validate · Plan` estaba verde porque
`tofu plan` no llega a `RunInstances`. El límite solo se ejerce al crear la
instancia, de modo que ninguna cantidad de plan lo habría revelado.

### Decisión de diseño: cambiar el transporte, no adelgazar

Raspar bytes compra **un** arranque y deja el techo donde estaba. Peor: pone
cada PR futuro a pelear su margen contra los comentarios que documentan
#22-#24, es decir, invita a borrar precisamente la memoria que ha costado
cinco arranques escribir.

Los renders del fundador y del join pasan a **S3** (`aws_s3_object` sobre el
bucket persistente, pero **propiedad del stack `lab`**: el destroy se lleva los
objetos y deja el bucket). En `user_data` viaja solo un stub que descarga,
**verifica el SHA-256 horneado por `templatefile`** y ejecuta. Nunca se
ejecuta lo que no se ha verificado: una descarga se reintenta, un hash que no
cuadra significa que los bytes no son los que tofu renderizó.

```
perfil    antes      ahora
cp0       16704 B     3840 B
cp1..N     ~8800 B    3789 B
worker     4901 B     4901 B   (inline por decisión: no estaba contra el techo)
```

### El gate que faltaba

`scripts/check-user-data-size.sh`, permanente en CI, mide el `user_data`
**real** -- multipart MIME, gzip y base64 a través del propio provider, no una
reimplementación -- de los tres perfiles y falla por encima de **14336 B**.
Se queda aunque hoy los stubs midan menos de 4 KB: su valor no es el número de
hoy, sino que el número exista y lo vigile algo que no olvida.

**Los presupuestos de transporte se vigilan con gates, no con memoria de
revisores.** Un límite que solo vive en la cabeza de quien revisó ayer no es
un límite: es una probabilidad.

### Efecto colateral a recordar

Los scripts ya no se materializan en `/var/lib/cloud/instance/scripts/`, sino
en `/opt/k8s-bootstrap/`. El listado de esa carpeta era el **primer paso** del
procedimiento forense de #23 y #24; a partir de ahora hay que mirar en los dos
sitios: cloud-init sigue escribiendo ahí el stub, y el script real está en
`/opt`.

---

## 26. El canal nuevo tenía dos extremos y solo se revisó uno

**Cuándo**: 2026-08-27, sexto Apply del día, el primero con el transporte por
S3 de #25 (run `33075639808`, `main` en `0e231df4`).
**Severidad**: el apply murió subiendo los objetos; **ninguna instancia llegó a
crearse**. 29 recursos quedaron creados (VPC, el bloque NLB completo, ECR,
roles) y hubo que destruirlos. Sin cluster, sin fundador, sin nodo que
interrogar.

### Qué pasó

```
Error: uploading S3 Object (bootstrap/k8s-vanilla-lab/02-control-plane-init.sh)
  api error AccessDenied: User: arn:aws:sts::487985088962:assumed-role/
  k8s-vanilla-lab-github-actions/GitHubActions is not authorized to perform:
  s3:PutObject ... because no identity-based policy allows the s3:PutObject action
```

Los cuatro objetos -- el fundador y los tres joins -- fallaron igual.

### Causa

#25 movió los renders del bootstrap a S3 y concedió `s3:GetObject` al **rol de
instancia del control plane**, que es quien descarga. **Nadie concedió
`s3:PutObject` al rol OIDC de CI**, que es quien los crea durante el apply. Su
statement sobre ese bucket se llama, literalmente, `BackupsBucketReadOnly`.

Se revisó el permiso del **lector** y nadie preguntó por el del **escritor**.
El fallo de revisión es compartido: el ejecutor escribió el transporte
completo y solo pensó en un extremo; el director aprobó el diff y tampoco
preguntó por el otro. Además, el alcance de la confirmación cruzada lo fijó el
ejecutor en dos puntos concretos -- el bucle de descarga y la arista IAM del
consumidor -- en vez de "el transporte de punta a punta", de modo que el
revisor externo confirmó exactamente lo que se le pidió y nada más.

### Por qué ningún gate lo vio

El rol de CI **no lo gestiona tofu**: vive en `scripts/bootstrap-aws.sh`, el
setup de una sola vez. Ni `make validate`, ni `make plan-empty`, ni el gate de
tamaño de #25 tienen forma de mirarlo. Y `tofu plan` no ejerce permisos de
escritura: el plan de CI corre con ese mismo rol y pasa en verde porque nunca
llega a `PutObject`.

Es el mismo patrón de #25 en otra capa: **el fallo solo se ejerce en el apply
real**, así que la única defensa posible es que alguien lo compruebe antes, a
propósito.

### Lo que sí funcionó

El `depends_on` de #25 hizo su trabajo: los objetos van **antes** que las
instancias, así que el apply murió con cero nodos arrancados. Ninguna máquina
llegó a bootear contra un script que no existía. Si la arista no hubiera
estado, habrían arrancado tres CPs a descargar un objeto ausente y el
diagnóstico habría costado un forense entero en vez de una línea de log.

### Decisión de diseño

Se descartó darle al stack `lab` un bucket propio para bootstrap. Sería más
limpio conceptualmente -- nace y muere con el stack -- pero exigiría conceder
al rol de CI el **ciclo de vida completo de buckets** (`CreateBucket`,
`DeleteBucket`, políticas, versionado), bastante más superficie que tres
acciones sobre un prefijo. El fix es tres acciones sobre
`bootstrap/k8s-vanilla-lab/*`, y nada sobre `etcd/` ni `cnpg/`. El diseño del
bucket propio queda anotado en `docs/PLAN-SPRINTS.md` como nota de fase 2.

### Fix y regla

`scripts/bootstrap-aws.sh` concede al rol de CI `s3:GetObject`, `s3:PutObject`
y `s3:DeleteObject` **solo** sobre `bootstrap/k8s-vanilla-lab/*`. El
`DeleteObject` no es opcional: sin él, `tofu destroy` no puede retirar los
objetos y el destroy falla. Como el rol no está en tofu, aplicar el fix exige
re-ejecutar `make bootstrap-aws` contra la cuenta, y la política **viva** se
verifica con `aws iam simulate-principal-policy` antes de lanzar nada: las tres
acciones permitidas sobre el prefijo, y `PutObject` sobre `etcd/` denegado.

### Segunda manifestacion: la verificacion circular

El septimo Apply murio **una llamada mas adelante**: `s3:PutObject` ya pasaba
y fallo `s3:PutObjectTagging`, que los `default_tags` del provider hacen
inevitable en cada objeto.

La causa de fondo no fue olvidar una accion, sino el metodo. Se concedieron
tres acciones y se verificaron **esas mismas tres** con
`simulate-principal-policy`: los cuatro veredictos eran correctos y no probaban
nada util, porque comprobaban que la politica decia lo escrito, no que lo
escrito bastara. **Verificacion circular** -- la misma forma que el cruce
externo confirmando el alcance que se le fijo, repetida dentro del mismo
incidente y dos horas despues.

El rol es OIDC-only -- su trust admite solo `sts:AssumeRoleWithWebIdentity`
desde el proveedor OIDC de GitHub -- y **no se puede asumir en local**, que era
la unica forma de enumerar el conjunto ejercitando el ciclo real. Comprobado,
no supuesto.

La primera reaccion fue conceder un superconjunto de diez acciones: **el mismo
error apuntando hacia arriba**. La lista correcta no la dicta ni la memoria ni
el ultimo 403, sino el **call graph del provider fijado**
(`hashicorp/aws 6.46.0`). Con `default_tags` y bucket versionado,
`aws_s3_object` llama: `PutObject` + `PutObjectTagging` al crear, `GetObject` +
`GetObjectTagging` al leer, y al destruir **`ListObjectVersions`** seguido de
`DeleteObject`/`DeleteObjectVersion` por cada version y delete marker.

Ese `ListObjectVersions` es el hallazgo que ninguna de las dos listas anteriores
tenia: corresponde a **`s3:ListBucketVersions`, que es accion de BUCKET**, asi
que el statement de objeto no puede cubrirla por mucho que se amplie. El apply
habria pasado y **el destroy habria fallado** -- un tercer arranque perdido, y
ademas el mas caro de diagnosticar, porque el sintoma habria aparecido al final.
Se acota con condicion `s3:prefix` para que no pueda enumerar `etcd/` ni `cnpg/`.

Quedan **fuera** a proposito, porque este call graph no las alcanza:
`AbortMultipartUpload` (payloads de ~30 KiB, bajo el umbral multipart),
`DeleteObjectTagging` (el destroy borra la version, no sus etiquetas),
`GetObjectVersion` y `GetObjectVersionTagging`.

**Verifique mi lista, no la llamada.** Una verificacion que solo confirma la
lista propia no es una verificacion, y da igual si la lista peca por defecto o
por exceso: ninguna de las dos versiones miraba lo unico que decide, que es
**que llama el codigo**. Cuando el permiso no se puede ejercitar, la fuente es
el call graph de la version exacta del provider que esta fijada -- se lee, no
se recuerda -- y se acota por Resource.

**Todo canal nuevo tiene dos extremos, y el lector y el escritor se revisan
juntos.** Mover un dato de sitio no es un cambio de un lado: es un permiso de
escritura, un permiso de lectura, un orden de creación y un borrado. Revisar
uno y dar por supuestos los otros tres deja tres formas de fallar en el
hierro, que es donde salen más caras.

---

## 27. Un 400 de raw.githubusercontent.com para UN fichero del tag

**Cuándo**: 2026-08-31, primer Apply tras la coronación de Fase 1
(run `33370141698`, `main` en `ee01c736`).
**Severidad**: el fundador murió en Step 5/9; el Apply agotó sus 1209s sin
kubeconfig y el smoke quedó `skipped`, así que **el contador de checks no llegó
a ejecutarse**. Sin pérdida de datos. Cluster dejado vivo para el forense.

### La causa no está en el repo

Primero lo que descarta a este lado, porque es lo que uno mira antes:

```
git diff --stat c641d01 ee01c736 -- bootstrap/ tofu/   →   vacío
```

**Byte a byte idéntico** al que produjo los dos verdes del 27-ago. Los tres
commits del intervalo tocan `platform/access/README.md`,
`scripts/smoke-test.sh` y `scripts/sample-h3.sh`: ninguno está en el camino del
fundador.

### Cronología UTC

```
07:53:44  arranca CP-0
07:54:56  stub: fetching s3://.../02-control-plane-init.sh
07:54:57  OK fetched and verified ... after 1s
07:55:03  Step 3/9: kubeadm init
07:55:22  OK kubeadm init completed successfully
07:55:22  Step 5/9: Installing Cilium CNI
07:55:35  OK API target healthy -- el NLB enruta
07:55:35  Installing Gateway API CRDs v1.6.1
07:55:35  curl: (22) The requested URL returned error: 400
07:55:35  ERROR: /opt/k8s-bootstrap/02-control-plane-init.sh exited 22
08:14:38  CI: kubeconfig ausente tras 1209s
```

### La causa

`bootstrap/control-plane.yaml:405` descarga los seis CRDs standard del canal
individual. El **primero del bucle** devolvió 400:

```
https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
```

`curl -fsSL` con `--retry 3` agotó los reintentos y salió con **22** («HTTP page
not retrieved»). El `set -e` del script propagó ese 22 hasta cloud-init, que lo
registró como `Runparts: 1 failures (02-control-plane-init.sh)`.

### Las cinco pruebas

Cinco intentos consecutivos desde el host del operador, mismo resultado:

```
intento 1: 400   intento 2: 400   intento 3: 400   intento 4: 400   intento 5: 400
```

Respuesta completa:

```
HTTP/2 400
content-type: text/plain; charset=utf-8
x-github-request-id: 2BD2:354ED0:460A51E:4C0847F:6A9538EC
x-github-edge-region: fra
x-served-by: cache-osl6532-OSL
via: 1.1 varnish
x-cache: MISS

400: Bad Request
```

Es **400, no 404**, y lleva cabeceras de GitHub: la petición llega y el
servidor la rechaza.

### El contraste que lo aísla

| recurso | HTTP |
|---|---|
| `gatewayclasses` — raw, tag `v1.6.1` | **400** |
| `gateways` — raw, tag `v1.6.1` | 200 |
| `httproutes` — raw, tag `v1.6.1` | 200 |
| `grpcroutes` — raw, tag `v1.6.1` | 200 |
| `referencegrants` — raw, tag `v1.6.1` | 200 |
| `backendtlspolicies` — raw, tag `v1.6.1` | 200 |
| `tlsroutes` experimental — raw, tag `v1.6.1` | 200 |
| `gatewayclasses` — raw, rama `main` | 200 |
| `gatewayclasses` — `github.com/.../raw/`, tag `v1.6.1` | 400 |
| `gatewayclasses` — **contents API**, ref `v1.6.1` | **200** |

La API de contenidos devuelve el fichero: `name`
`gateway.networking.k8s.io_gatewayclasses.yaml`, **23.255 bytes**, sha
`ea55d0dad02d`. **El fichero existe en el tag.** Lo que falla es el servicio
raw para esa combinación concreta de tag y ruta: las otras seis rutas del mismo
tag se sirven, y la misma ruta en otra referencia se sirve.

### Estado del cluster al hacer el forense

- **El stub de #25 funcionó**: descarga y verificación de SHA-256 en 1s, script
  real de 33.312 B en `/opt/k8s-bootstrap/`, stub de 3.812 B en
  `/var/lib/cloud/instance/scripts/`.
- **`kubeadm init` completó**: `Your Kubernetes control-plane has initialized
  successfully!`, los cuatro manifiestos estáticos presentes, `admin.conf`
  escrito.
- **El fundador está muerto, no colgado**: sin procesos vivos de
  `cloud-init|kubeadm|helm|kubectl`, cloud-init en `error - done`.
- **No publicó nada**: bajo `/k8s/*` solo los **2** parámetros preexistentes de
  `/k8s/persistent/`. Murió en el Step 5 y la publicación es del 7 al 9, así
  que no es «llegó y falló al escribir».
- **`kubelet` activo** repitiendo `cni plugin not initialized` cada 5s, que es
  lo esperado sin CNI instalado. `containerd` activo.
- **CP-1 y CP-2 no intentaron el join**: esperaron el gate con
  `joined-count=absent` y abortaron cerrados al agotar sus 1800s. Ninguno tiene
  `kube-apiserver.yaml`.

### Lo que este arranque vuelve a dejar probado

El transporte por S3 de #25, el gate `healthy` del NLB de #77 y el gate de join
fail-closed se comportaron los tres. El fallo entró por una dependencia
externa en mitad del Step 5, no por ninguno de ellos.

### Fix

Los siete CRDs se **vendorizan en el repo** bajo
`bootstrap/gateway-api/v1.6.1/`, descargados por la **Contents API** — que es
la que sirvió el fichero cuando el endpoint raw lo rechazaba— y viajan por el
**mismo transporte S3** que los renders (`aws_s3_object` con `source` al
fichero local, bajo `bootstrap/<cluster>/gateway-api/`). El Step 5 los descarga
de S3 y **verifica el SHA-256 antes de aplicar**, con el mismo patrón de
`fetch-exec.sh` adaptado a YAML: verificar y aplicar, no ejecutar.

`aws_instance.control_plane` depende explícitamente de esos objetos, así que
ningún CP nace sin ellos.

`bootstrap/gateway-api/v1.6.1/MANIFEST` guarda la procedencia de cada fichero:
`kind`, canal, **sha de blob de git** y **SHA-256**. Y
`scripts/test-gateway-bootstrap-manifests.sh` valida contra los ficheros
vendorizados, sin red: comprueba que los digests siguen siendo los del MANIFEST
—si alguien edita un CRD sin actualizarlo, el test se pone rojo— además de que
TLSRoute solo aparece en el overlay y de que el `bundle-version` es exacto.
GitHub queda fuera también de la validación en CI.

### La razón, que no es «no depender de la red»

Podría parecer que basta con reintentar mejor, o con un mirror. No es eso.

**El digest tiene que preexistir a la descarga.** Aquí lo calcula tofu con
`filesha256()` **del fichero en disco**, en el momento del plan, y lo hornea en
el script del fundador antes de que nada se descargue. Un digest derivado de la
propia descarga probaría solo que los bytes llegaron íntegros — nunca que son
los bytes que este repo revisó.

Esa distinción es lo que protege de una **republicación upstream**: si el
proyecto de Gateway API moviera el tag, o si el contenido servido bajo la misma
ruta cambiara, la verificación falla y el fundador se niega a aplicar. Con el
diseño anterior —descargar y aplicar— el cambio habría entrado sin que nadie
lo notase, y el 400 solo fue la forma ruidosa de un fallo que también tiene
forma silenciosa.

### Lo que este incidente deja fijado

**El arranque no aplica nada que no haya verificado contra un digest que ya
existía antes de la descarga.** Y una dependencia de terceros en el camino
crítico del fundador es una decisión, no un detalle de implementación: aquí
costó un Apply entero con el cluster ya inicializado, `kubeadm init` hecho y el
NLB enrutando.

Queda **fuera de este fix**, anotado: `scripts/run-4b-rung.sh:38` sigue
apuntando a `raw.githubusercontent.com`. Es la ceremonia de la escalera 4b, no
está ni en el bootstrap ni en la validación de CI.
