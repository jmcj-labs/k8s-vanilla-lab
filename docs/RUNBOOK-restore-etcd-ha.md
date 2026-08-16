# RUNBOOK — Restore de etcd en HA (3 CPs, etcd stacked)

**Pieza**: S2-3 (ADR-007) · **Script**: `scripts/drill-restore-etcd-ha.sh` ·
**Sustituye a**: [RUNBOOK-restore-etcd.md](RUNBOOK-restore-etcd.md) (single-CP, queda como histórico)

> Regla de la casa: **runbook no probado = esperanza, no backup.** La tabla de
> tiempos de abajo se rellena con la ejecución real del drill.

## Naturaleza distinta al restore single-CP

Restaurar etcd en HA **no es** rehidratar un miembro: es la **reconstrucción de
un cluster lógico nuevo**. La membresía vieja no sobrevive al snapshot — se
paran los TRES control planes, se apartan los data dirs, se restaura en UNO con
`etcdutl` y los otros dos **se re-unen** con `member add`, de uno en uno.

Dos flags de `etcdutl snapshot restore` son **obligatorios** aquí
(recomendación expresa de etcd 3.6 al restaurar bajo clientes con caché):

- `--bump-revision <N>` — salta la revisión muy por delante de la encarnación
  vieja, para que ningún controller/watcher con caché considere "más nuevo" lo
  que ya murió.
- `--mark-compacted` — fuerza a los watchers a resincronizar desde cero en vez
  de continuar desde una revisión que ya no significa nada.

## Por qué la orquestación es fuera de banda, y por qué SSM

En el escenario real la API está caída — ese es el escenario. `kubectl` solo
abre el drill (testigo + snapshot) y lo cierra (testigo recuperado); todo lo
demás viaja por **SSM Run Command** (`AWS-RunShellScript`, que ejecuta como
**root**, sin `sudo`).

Antes esto era SSH. Dejó de serlo por [INCIDENTS #16](INCIDENTS.md): al ir a
ejecutar este mismo drill se descubrió que **la clave privada no existía en
ningún sitio** — el procedimiento era correcto y a la vez inejecutable. El
canal SSM viaja con el instance profile, así que ninguna máquina nueva nace
sin él y ningún portátil puede perderlo.

**El preflight prueba el canal en los tres CPs antes de tocar nada.** Si la
puerta no abre, la ceremonia se detiene con el cluster intacto — que es
exactamente la lección que la originó.

### Reentrada

Cada fase publica un marcador en un parámetro SSM, y el lock también vive
ahí (un ConfigMap no puede arbitrar exclusión mutua cuando la API en la que
vive está muerta). Si la ceremonia se interrumpe —incluso después de apartar
los data dirs, el punto delicado— **se relanza el mismo comando y continúa
donde estaba**. Para abandonarla a conciencia:

```bash
aws ssm delete-parameter --name /k8s/<cluster>/oob/restore-lock  --region <region>
aws ssm delete-parameter --name /k8s/<cluster>/oob/restore-phase --region <region>
```

## Precondiciones

- Snapshot en `s3://<cluster>-backups-<account>/etcd/` (el CronJob de backup
  corre en **cualquier** CP sano — sin pin, a propósito: pinearlo a un nodo
  mataría el backup justo al perder ese nodo).
- Credenciales de operador con `ssm:SendCommand` sobre `AWS-RunShellScript`
  y presign de S3 (el role de CP es write-only a `etcd/*` por diseño y no se
  amplía para drills).
- **Sin clave SSH ni puerto 22**: no existen desde INCIDENTS #16.
- Los manifests generados por kubeadm en cada nodo (supuesto que el script
  explota, generado por el propio kubeadm):
  - **CP-0 (fundador)**: `etcd.yaml` con `--initial-cluster=<cp0>` solo,
    `state=new`. Con data dir restaurado, etcd **ignora** los flags initial-*
    → arranca la membresía del snapshot (solo cp0) sin cirugía de manifest.
  - **CP-1/2 (joins)**: `--initial-cluster` con la lista acumulada a SU join
    (`cp0,cp1` / `cp0,cp1,cp2`), `state=existing`. Con data dir VACÍO tras el
    `member add`, esos flags son exactamente los correctos.
- **Máquinas distintas a las originales** (restore tras reemplazo): los flags
  de join ya no coinciden — editar `--initial-cluster` en el manifest del nodo
  nuevo con los nombres/IPs actuales antes de devolverlo a `manifests/`.

## Ceremonia

```bash
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
AWS_PROFILE=k8s-vanilla-lab bash scripts/drill-restore-etcd-ha.sh
```

Fases (el script las cronometra):

1. **Testigo + snapshot** — ConfigMap `drill-marker`, Job forzado del CronJob
   real, objeto fresco en S3, y se borra el testigo.
2. **STOP total** — en los 3 CPs: `manifests/*.yaml` → `manifests-stopped/`;
   espera a que 2379/6443 dejen de escuchar. Desde aquí, **API caída**.
3. **Data dirs apartados** — `/var/lib/etcd` → `/var/lib/etcd.pre-restore-<ts>`
   en los 3 (nunca `rm`: evidencia y rollback).
4. **Restore en CP-0** — descarga por URL presignada, `etcdutl` verificado
   contra `SHA256SUMS` del release, `snapshot restore` con `--name`/`
   --initial-cluster` de cp0, `--bump-revision` + `--mark-compacted`.
5. **CP-0 arriba** — manifests de vuelta; `/readyz` == ok. API sirviendo desde
   etcd de un solo miembro.
6. **Re-join secuencial** — por cada CP-i (1, luego 2): `etcdctl member add`
   desde CP-0 → manifests de vuelta en CP-i → esperar miembro *started*.
   **Nunca los dos a la vez.**
7. **El testigo vuelve** — `drill-marker` presente con el ts exacto.

## Tiempos (drill del AAAA-MM-DD — pendiente de ejecución)

| Fase | Tiempo |
|------|--------|
| Stop → API restaurada (CP-0 solo) | — |
| Quorum 3/3 completo | — |
| Drill total (testigo → testigo) | — |

## Después del drill

- Limpiar los `etcd.pre-restore-<ts>` de los 3 nodos cuando la evidencia ya
  no haga falta.
- Los workers y la capa de datos NO se tocan: kubelets y pods siguen; los
  controllers resincronizan solos gracias a bump+mark-compacted.
- Si un CP no re-une (manifest con membresía desalineada), ver la nota de
  máquinas distintas en Precondiciones.
