# Persistent stack — backups bucket, barman IAM user, platform image (lab account)

Separate-lifecycle stack: **persistent**, applied **locally** with
lab-account credentials, region **eu-west-1**. It is never part of
`apply.yml`/`destroy.yml` — destroying the cluster must never touch what
lives here. Second persistent piece of the lab, after `tofu/envs/identity`.

## Two classes of thing, persistent for different reasons

Since the node-readiness piece (INCIDENTS #20) this stack custodies **two
kinds of thing**, and conflating them would be a mistake:

| clase | qué es | por qué persiste | ciclo |
|---|---|---|---|
| **datos de conservación** | el bucket de backups (`etcd/`, `cnpg/`) | para que un destroy total del cluster no pierda nada | escriben los clusters, continuamente |
| **artefactos de plataforma** | el repositorio ECR `node-readiness` | porque el DaemonSet **fija su imagen por digest** en el repo: si el repositorio muriera con el cluster, ese digest nombraría algo inexistente y el siguiente apply levantaría un componente roto | **propio**: se reconstruye cuando cambia el binario, **nunca en cada apply** |

La diferencia es operativa, no decorativa. Los repositorios ECR de la
aplicación viven en el stack `lab` con `force_delete = true` y mueren en cada
destroy, que es lo correcto para ellos. Este **no** lleva `force_delete`:
borrarlo es un acto deliberado, no un efecto colateral.

| Piece | Purpose |
|---|---|
| S3 bucket `<cluster>-backups-<account>` | One bucket, two prefixes: `etcd/` (snapshots, 7-day lifecycle) and `cnpg/` (base backups + WAL, **18-day lifecycle** — barman's 14d retention prunes first; the lifecycle is the safety net). Versioned, SSE-S3, public access fully blocked |
| IAM user `k8s-vanilla-lab-cnpg-backup` | barman's identity — Put/Get/Delete/List scoped to `cnpg/*` only. Static user because the IMDS CCNP denies the instance profile to CNPG pods and is not to be widened |
| ECR repo `k8s-vanilla-lab-node-readiness` | Image of the per-node readiness aggregator (INCIDENTS #20). IMMUTABLE, scan-on-push, AES256, last-10 lifecycle. Built and pushed by `.github/workflows/build-node-readiness.yml` on `workflow_dispatch`; the DaemonSet pins the resulting **digest** |

The etcd CronJob does NOT use this user: it runs `hostNetwork` on the CP,
so the **CP instance role** covers it (write-only grant on `etcd/*`, managed
in the cluster stack).

## Apply (one-time, manual)

```bash
cd tofu/envs/persistent
cp terraform.tfvars.example terraform.tfvars   # fill in — never commit
tofu init
tofu plan
tofu apply
```

## Deposit the barman keys (one-time, manual — never in Git, never printed)

The access keys are deliberately NOT managed by OpenTofu (they would land in
the state file). Create them and deposit them in SSM under the persistent
prefix — `/k8s/persistent/...` survives cluster destroys (the cluster's
destroy-time cleanup only wipes `/k8s/<cluster_name>`), while staying inside
the `parameter/k8s/*` scope the CI role already has:

```bash
aws iam create-access-key --user-name k8s-vanilla-lab-cnpg-backup \
  --profile k8s-vanilla-lab --query 'AccessKey.{ACCESS_KEY_ID:AccessKeyId,SECRET_ACCESS_KEY:SecretAccessKey}' \
  --output json | aws ssm put-parameter \
    --name /k8s/persistent/k8s-vanilla-lab/cnpg-backup-keys \
    --type SecureString --value file:///dev/stdin \
    --region eu-west-1 --profile k8s-vanilla-lab
```

`platform/install.sh` reads that parameter on every run and (re)creates the
`data/cnpg-backup-creds` Secret — reentrant, values never printed.

**Rotation (manual until External Secrets, S3 sprint)** — complete flow:

1. `aws iam create-access-key --user-name k8s-vanilla-lab-cnpg-backup` (the
   user supports two concurrent keys — no gap).
2. Overwrite the SSM parameter with the new pair (same command as above).
3. `make platform` — re-projects `data/cnpg-backup-creds`; the Secret
   carries the `cnpg.io/reload: "true"` LABEL (CNPG requires a label, not
   an annotation), so CNPG reloads it into the pods without a rollout.
4. Verify archiving stayed green: `kubectl -n data get cluster logistics-pg
   -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'`
   → `True`, and a fresh WAL lands under `cnpg/<serverName>/wals/`.
5. `aws iam delete-access-key` for the OLD key id. Debt noted in
   CLUSTER.md §5.

## Destroy

Manual only, and only when the lab is retired for good:

```bash
tofu destroy   # requires emptying the bucket first (versioned)
```
