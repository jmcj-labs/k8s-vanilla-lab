# Persistent stack — backups bucket + barman IAM user (lab account)

Separate-lifecycle stack: **persistent**, applied **locally** with
lab-account credentials, region **eu-west-1**. It is never part of
`apply.yml`/`destroy.yml` — destroying the cluster must never touch
backups. Second persistent piece of the lab, after `tofu/envs/identity`.

| Piece | Purpose |
|---|---|
| S3 bucket `<cluster>-backups-<account>` | One bucket, two prefixes: `etcd/` (snapshots, 7-day lifecycle) and `cnpg/` (base backups + WAL, 14-day lifecycle). Versioned, SSE-S3, public access fully blocked |
| IAM user `k8s-vanilla-lab-cnpg-backup` | barman's identity — Put/Get/Delete/List scoped to `cnpg/*` only. Static user because the IMDS CCNP denies the instance profile to CNPG pods and is not to be widened |

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
   carries `cnpg.io/reload: "true"`, so CNPG reloads it into the pods
   without a rollout.
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
