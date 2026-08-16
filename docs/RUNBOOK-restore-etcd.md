# RUNBOOK — Restore de etcd (single-CP, línea base pre-HA)

Drill de aceptación de S2 pieza 1: **ceremonia documentada, ejecutada una
vez y repetible** — no entra en el smoke de cada apply. Con HA (S2 pieza 3)
este runbook se revisa: el restore multi-miembro es otro procedimiento.

Principio: sin restore probado no es backup.

> **Ceremonia ejecutable**: el ciclo completo de este runbook (testigo →
> snapshot → borrado → restore vía Job nsenter en el CP — el patrón sin-SSH
> del rollout ECR — → testigo de vuelta → tiempos) vive en
> [`scripts/drill-restore-etcd.sh`](../scripts/drill-restore-etcd.sh):
>
> ```bash
> export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
> AWS_PROFILE=k8s-vanilla-lab bash scripts/drill-restore-etcd.sh
> ```
>
> La API cae ~30-60s a mitad de drill (esperado, medido e impreso). Los
> pasos manuales de abajo quedan como referencia y para ejecuciones
> parciales.

## Preparación del drill

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf   # break-glass (ADR-004)
BACKUP_BUCKET="k8s-vanilla-lab-backups-<ACCOUNT_ID>"

# 1. Testigo: un ConfigMap con timestamp que el restore deberá resucitar
kubectl create configmap drill-marker \
  --from-literal=ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 2. Snapshot manual (mismo camino que el CronJob de las 6h) y verificación
kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-drill
kubectl -n kube-system wait --for=condition=complete job/etcd-drill --timeout=300s
aws s3 ls "s3://${BACKUP_BUCKET}/etcd/" | tail -1     # ← anotar el objeto

# 3. Borrar el testigo (esto es lo que el restore debe deshacer)
kubectl delete configmap drill-marker
```

## Restore (en el control plane — `make ssh-cp`)

> El plano de control se detiene durante el restore: API caída unos minutos.
> Single-CP: no hay quórum que preservar — es la razón de este drill como
> línea base antes de HA.

```bash
# 4a. DESDE TU MÁQUINA (identidad de operador — el rol del CP es write-only
#     a etcd/* a propósito y NO se amplía): URL prefirmada de 10 min
aws s3 presign "s3://<BACKUP_BUCKET>/etcd/<SNAPSHOT>.db" \
  --expires-in 600 --profile k8s-vanilla-lab --region eu-west-1
# → copiar la URL

# 4b. EN EL CP: descargar con la URL prefirmada + etcdutl pinneado con
#     checksum verificado contra el SHA256SUMS oficial de la release
curl -fsSL -o /tmp/restore.db '<URL_PREFIRMADA>'

ETCD_VER=v3.6.4    # mantener alineado con el etcd que corre kubeadm
TARBALL="etcd-${ETCD_VER}-linux-amd64.tar.gz"
# Descargar con su NOMBRE DE RELEASE: sha256sum -c resuelve literalmente el
# nombre de cada linea del SHA256SUMS (PR #57 — el script ya lo hace asi).
curl -fsSL -o "/tmp/${TARBALL}" \
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/${TARBALL}"
curl -fsSL -o /tmp/etcd-SHA256SUMS \
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS"
(cd /tmp && grep "${TARBALL}$" etcd-SHA256SUMS | sha256sum -c -)
tar -xzf "/tmp/${TARBALL}" -C /tmp --strip-components=1 \
  "etcd-${ETCD_VER}-linux-amd64/etcdutl"

# 5. Parar los pods estáticos (kubelet los relanzará al reaparecer el manifest)
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 20   # dar tiempo a kubelet a parar etcd y liberar el data dir

# 6. Restaurar en un data dir nuevo (nunca sobre el vivo)
sudo mv /var/lib/etcd /var/lib/etcd.pre-drill
sudo /tmp/etcdutl snapshot restore /tmp/restore.db \
  --data-dir /var/lib/etcd

# 7. Relanzar el plano de control
sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

## Aceptación

```bash
# 8. Desde tu máquina: el API vuelve y EL TESTIGO HA VUELTO
kubectl get nodes                       # 4/4 Ready (los kubelet reconectan)
kubectl get configmap drill-marker -o jsonpath='{.data.ts}'   # ← debe existir
```

El drill es aceptado si `drill-marker` existe con su timestamp original.
Después: `kubectl delete configmap drill-marker` y
`sudo rm -rf /var/lib/etcd.pre-drill /tmp/restore.db /tmp/etcd.tgz /tmp/etcdutl /tmp/etcd-SHA256SUMS` en el CP.

> Nota: los objetos creados DESPUÉS del snapshot vuelven a existir solo si
> sus reconciliadores los recrean (Deployments sí; objetos sueltos no). En
> el drill el cluster está quieto — en un restore real, evaluar la deriva.

## Tiempos medidos

| Fecha | Snapshot→S3 | Restore completo (API caída) | Testigo verificado | Operador |
|-------|-------------|------------------------------|--------------------|----------|
| 2026-08-15 | 11s (`etcd-20260815T195612Z.db`, 42 MB) | 45s | ✅ `drill-marker` ts=2026-08-15T19:56:09Z intacto — **THE WITNESS IS BACK** | jmcastellanojimenez (vía `scripts/drill-restore-etcd.sh`) |

Primera ejecución real: drill completo en **58s** end-to-end. Nota de la
ejecución: el primer intento abortó a los 7s por el nombre del tarball en
la verificación de checksum (PR #57) — fail-closed exacto: el plano de
control no se tocó hasta que la verificación pasó.
