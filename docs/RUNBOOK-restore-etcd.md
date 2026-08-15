# RUNBOOK — Restore de etcd (single-CP, línea base pre-HA)

Drill de aceptación de S2 pieza 1: **ceremonia documentada, ejecutada una
vez y repetible** — no entra en el smoke de cada apply. Con HA (S2 pieza 3)
este runbook se revisa: el restore multi-miembro es otro procedimiento.

Principio: sin restore probado no es backup.

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
# 4. Bajar el snapshot elegido
sudo aws s3 cp "s3://<BACKUP_BUCKET>/etcd/<SNAPSHOT>.db" /tmp/restore.db

# 5. Parar los pods estáticos (kubelet los relanzará al reaparecer el manifest)
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 20   # dar tiempo a kubelet a parar etcd y liberar el data dir

# 6. Restaurar en un data dir nuevo (nunca sobre el vivo)
sudo mv /var/lib/etcd /var/lib/etcd.pre-drill
sudo ETCDCTL_API=3 etcdutl snapshot restore /tmp/restore.db \
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
`sudo rm -rf /var/lib/etcd.pre-drill /tmp/restore.db` en el CP.

> Nota: los objetos creados DESPUÉS del snapshot vuelven a existir solo si
> sus reconciliadores los recrean (Deployments sí; objetos sueltos no). En
> el drill el cluster está quieto — en un restore real, evaluar la deriva.

## Tiempos medidos

| Fecha | Snapshot→S3 | Restore completo (API caída) | Testigo verificado | Operador |
|-------|-------------|------------------------------|--------------------|----------|
| _(pendiente de la primera ejecución con cluster vivo)_ | | | | |
