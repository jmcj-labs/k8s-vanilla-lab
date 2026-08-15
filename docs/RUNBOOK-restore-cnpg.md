# RUNBOOK — Restore de CNPG (cluster nuevo desde el object store)

Drill de aceptación de S2 pieza 1: recuperación a un **Cluster CNPG nuevo**
(`bootstrap.recovery`) sin tocar el cluster vivo. Ceremonia documentada +
ejecutada una vez y repetible — no entra en el smoke de cada apply.

**El testigo tiene nombre propio**: el shipment `CORONATION-001`
(id `f12833dd-…`), el dato de la coronación de S1, con sus 2 eventos
(`shipment.created` + `route.calculated`). Si el restore lo trae de vuelta,
trae de vuelta el sprint entero.

## Precondiciones

- Backup base `completed` y WAL archiving `ContinuousArchiving=True`
  (los verifica el smoke en cada apply).
- `data/cnpg-backup-creds` presente (el mismo Secret sirve para el drill).

## Drill

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
BACKUP_BUCKET="k8s-vanilla-lab-backups-<ACCOUNT_ID>"

# 1. Cluster de recuperación — nuevo, pequeño (1 instancia), en data.
#    serverName apunta al nombre con el que barman archiva el cluster vivo.
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: logistics-pg-drill
  namespace: data
spec:
  instances: 1
  storage:
    size: 5Gi
    storageClass: gp3
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      barmanObjectStore:
        serverName: logistics-pg
        destinationPath: s3://${BACKUP_BUCKET}/cnpg
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-backup-creds
            key: SECRET_ACCESS_KEY
        wal:
          compression: gzip
EOF

# 2. Esperar la recuperación (base + replay de WAL)
kubectl -n data wait cluster/logistics-pg-drill \
  --for=jsonpath='{.status.phase}'='Cluster in healthy state' --timeout=900s
```

## Aceptación

```bash
# 3. El testigo con nombre propio está en el cluster RESTAURADO:
kubectl -n data exec logistics-pg-drill-1 -c postgres -- \
  psql -U postgres -d logistics -tAc \
  "select reference, id from shipments where reference='CORONATION-001';
   select count(*) from shipment_events
     where shipment_id=(select id from shipments where reference='CORONATION-001');"
# ← debe devolver CORONATION-001 con su id f12833dd-… y count = 2
```

Aceptado si el shipment y sus **2 eventos** están en `logistics-pg-drill`.

## Limpieza

```bash
kubectl -n data delete cluster logistics-pg-drill
# El PVC del drill lo borra CNPG; verificar que no queda EBS huérfano tras
# el siguiente destroy (runbook de destroy en troubleshooting.md).
```

## Tiempos medidos

| Fecha | Base+WAL replay | Testigo verificado | Tamaño backup | Operador |
|-------|-----------------|--------------------|---------------|----------|
| _(pendiente de la primera ejecución con cluster vivo)_ | | | | |
