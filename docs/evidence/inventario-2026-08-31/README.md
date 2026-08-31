# Inventario AWS post-destroy — 2026-08-31

Cierra el **pendiente de observación #2** de [PLAN-FASES.md](../../PLAN-FASES.md):
*"nadie ha comprobado bucket de bootstrap, parámetros SSM, snapshots, ECR ni
volúmenes EBS huérfanos. La consola de EC2 vacía no es «cuenta a cero»."*

`make destroy` a las 13:48:07Z → **`Destroy complete! Resources: 80 destroyed`**,
`rc=0`, 4 m 44 s. Inventario tomado inmediatamente después, cuenta 487985088962.

## Lo que debía quedar a cero — y quedó

| recurso | antes | después |
|---|---|---|
| EC2 no terminadas | 6 | **0** |
| Load balancers | 1 | **0** |
| Target groups | — | **0** |
| Volúmenes EBS | 12 | **0** |
| ENIs | 7 | **0** |
| EIPs | 0 | **0** |
| VPCs no-default | — | **0** |
| SGs no-default | — | **0** |
| Snapshots propios | — | **0** |
| NAT gateways | — | **0** |
| Auto Scaling groups | — | **0** |
| Spot requests activas | — | **0** |
| CloudWatch log groups | — | **0** |

Barrido de otras regiones (`us-east-1`, `eu-central-1`, `eu-west-2`): **0 EC2**
en las tres. Nada quedó corriendo fuera de `eu-west-1`.

## Lo que persiste, y por qué está bien

| recurso | estado | por qué |
|---|---|---|
| `k8s-vanilla-lab-tfstate-…` | 1 objeto, 791 B | backend del estado |
| `k8s-vanilla-lab-backups-…` | **262 objetos, 509 MB** | etcd cada 6 h + CNPG base/WAL |
| DynamoDB `k8s-vanilla-lab-tflock` | existe | lock del backend |
| ECR `k8s-vanilla-lab-node-readiness` | existe | stack persistente, digest pinado |
| IAM `k8s-vanilla-lab-github-actions` + 2 roles SSO | existen | OIDC y acceso humano |
| OIDC provider `token.actions.githubusercontent.com` | existe | CI sin credenciales largas |
| SSM `/k8s/persistent/…` ×2 | `cnpg-backup-keys`, `cnpg-server-name` | custodia de backups, fuera del ciclo efímero |
| Key pair `k8s-vanilla-lab` | existe | **entrada**, no recurso creado por Tofu: `key_name` es ForceNew y se conserva a propósito (comentado en el módulo) |
| KMS ×2 | `KeyManager=AWS` | claves por defecto de EBS y SSM — **no** son de cliente, no cuestan |

## Hallazgo: los 4 repos ECR de aplicación son EFÍMEROS

El smoke dice `✓ ECR: 4 repositories IMMUTABLE + scan-on-push…` y el inventario
posterior encuentra **uno solo**. No es una contradicción del instrumento: los
cuatro repos de aplicación (`shipments-api`, `routing`, `tracking-events`,
`traffic-generator`) viven en `module.registry`, que está en el stack **lab**, no
en el persistente. El log del destroy los lista uno a uno, y
`tofu/modules/registry/main.tf:39` tiene **`force_delete = true`**: se borran
con sus imágenes dentro, sin avisar.

**No es una regresión ni contradice el flujo documentado** — el handoff tras
recreate ya prevé `workflow_dispatch (rebuild→push SHA→deploy)`, que reconstruye.
Pero sí desmiente la lectura fácil de que "ECR persiste": persiste **el repo del
agregador**, que por eso se movió al stack persistente cuando su digest pasó a
estar pinado en un manifiesto. Los de aplicación no.

## Coste

**No disponible todavía, que no es lo mismo que cero.** Cost Explorer devuelve
`0` para 2026-08-31 con `Estimated: true` — el dato del día en curso llega con
retraso. Que la consulta funciona lo prueban los días anteriores:

| día | USD | cluster |
|---|---|---|
| 2026-08-29 | 0,0008373 | apagado (solo almacenamiento) |
| 2026-08-30 | 0,0009167 | apagado (solo almacenamiento) |
| 2026-08-31 | *sin dato* | 3 CP + 3 workers ~4 h |

La cifra del día hay que volver a pedirla en ≥24 h. Registrar el `0` de hoy
como coste medido sería exactamente el error que este documento existe para
evitar.
