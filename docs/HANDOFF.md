# HANDOFF — Fase 1 coronada (2026-08-27)

Estado de entrega a 27-ago-2026 y punto de entrada para la Fase 2. La
evidencia del Sprint 1 (15-ago) se conserva íntegra al final, como sección
histórica: no se borra, se fecha.

**Fuente de verdad: el repo.** Este documento resume; los detalles viven en
[PLAN-SPRINTS.md](PLAN-SPRINTS.md), [INCIDENTS.md](INCIDENTS.md) y
[CLUSTER.md](CLUSTER.md).

---

## Estado: el bootstrap NACE en el estado final

Hasta el 26-ago el cluster nacía en Cilium 1.19.6 + Gateway API v1.2.1 y se
escalaba en vivo. Eso se abandonó. Hoy el bootstrap instala **Cilium 1.20.1 y
Gateway API v1.6.1 desde el primer arranque**, por la **ruta híbrida**: los
seis CRDs standard individuales más el CRD experimental de TLSRoute como
overlay — TLSRoute sirve `v1alpha2`, que es la versión que Cilium 1.20 vigila.

### Transporte por S3 (INCIDENTS #25)

Los renders de `templatefile` suben como `aws_s3_object` al prefijo
`bootstrap/<cluster>/` del bucket persistente, propiedad del stack `lab`: el
destroy se los lleva y el bucket sobrevive. En `user_data` viaja solo un stub
que descarga, **verifica el SHA-256 horneado por tofu** y ejecuta. Nunca se
ejecuta lo que no se ha verificado.

El límite de 16.384 B de EC2 no ha desaparecido: lo que salió de `user_data`
es el payload grande. `scripts/check-user-data-size.sh` mide los tres perfiles
renderizados en CI y falla por encima de 14.336 B.

| perfil | antes | ahora |
|---|---|---|
| control plane índice 0 | 16.704 B (excedía) | 3.840 B |
| control plane 1..N | ~8.800 B | 3.789 B |
| worker | 4.901 B | 4.901 B — inline por decisión, nunca estuvo cerca del techo |

### Gates fail-closed

- **Join secuencial** por SSM: `absent` significa esperar, error significa
  abortar, nunca inventar un 0. Monotónico, con relectura.
- **Esquema Gateway API** por discovery real (`kubectl get --raw`), no por
  flags de `kubectl api-resources` que no existen (#22).
- **KPR** por token de dato, no por prosa (#23), esperando a que `cilium-dbg`
  **conteste** — `Ready` no es *contestable* (#24).
- **Tamaño de `user_data`** en CI (#25) y **ASCII** sobre fuente y render.

Precisión sobre la evidencia: en los arranques de coronación cada gate se
ejercitó **en vivo por su camino de éxito**. El de join ejercitó además sus
ramas de espera y aborto en los arranques rojos previos. Las ramas de espera y
error restantes están validadas por sus tablas de decisión ejecutables
(`make test`), no en hierro.

---

## Coronación: dos verdes consecutivos

| | acumulativo | **coronación** |
|---|---|---|
| run | `33085372641` | **`33087225268`** |
| SHA | `c641d01` | `c641d01` |
| partida | cluster vivo | **vacío absoluto** |
| smoke CI | 64 checks OK | **64 checks OK** |
| resultado | verde | **verde** |

### Cómo se cuentan los checks

**El banner final `✓ Smoke test passed` NO es un check.** Es una línea de
cierre que empieza por `✓` y se contaba como si fuera una comprobación: de ahí
salieron las cifras **65/61 que circularon y son erróneas**.

El conteo real son las llamadas a `OK()` de `scripts/smoke-test.sh` más los
checks que imprime `scripts/verify-cilium-120-schema.sh`. En el run de
coronación: **54 de `OK()` + 10 del sub-script = 64**.

Desde este PR el número lo lleva un contador (`CHECKS_OK`) y lo imprime el
propio banner, para que deje de ser una cuenta de líneas a ojo.

| canal | checks | qué cubre y qué no |
|---|---|---|
| **CI** | **64** | Incluye los 5 checks IAM. §15d se declara **no ejecutado**: el rol de CI carece de `ssm:StartSession` por diseño |
| **local** | **60** | §15d **ejecutado en verde**, con sesión SSM real sobre CP-0. Los 5 IAM se saltan: la identidad local no puede asumir `platform-admin` (`AccessDenied` previsto — trust = puentes SSO + rol de CI) |

Los cinco checks solo-CI, por nombre: `sts:AssumeRole works for both access
roles` · `IAM platform-admin: kubectl get nodes works` · `IAM developer:
create deployment in logistics works` · `IAM developer: infra is Forbidden` ·
`IAM developer RBAC: grpcroutes yes · jobs no · data no`.

64 − 5 + 1 = 60. Cada frontera cubierta por su canal; **ninguna comprobación
desaparecida, y ninguna sumada dos veces**.

### Tiempos medidos (dos muestras)

| medida | acumulativo | coronación |
|---|---|---|
| stub: descarga + verificación SHA-256 | 2 s | 2 s |
| `kpr_gate` | 0 s | 1 s |
| fundador completo, 9 Steps | 1 m 32 s | 1 m 42 s |
| joins secuenciales CP-1 / CP-2 | 67 s / 67 s | 69 s / 34 s |

Sobre el `kpr_gate`: **la carrera de #24 no se reprodujo**. El gate se ejerció
por su rama rápida; la rama de espera está probada por su test de tres rutas.
Un seguro que no se cobra no es un seguro inútil.

---

## Reglas de método ganadas el 27-ago

Checklist de revisión permanente:

1. Se parsea **el dato, no la prosa**: `cilium-dbg` intercala IPs y paréntesis
   en el mismo renglón que el valor (#23).
2. Los stubs de test son **fail-closed sobre la interfaz real**, no sobre sus
   datos (#22).
3. **Todo canal nuevo tiene dos extremos**: lector y escritor se revisan
   juntos (#26).
4. Las listas de acciones IAM salen del **call graph de la versión del
   provider fijada en el lock**, nunca de memoria ni del último 403 — así
   apareció `s3:ListBucketVersions`, acción de *bucket* que ninguna lista de
   acciones de *objeto* podía contener (#26).
5. Quien **acota** un encargo de revisión declara qué queda fuera: el revisor
   externo confirma lo que se le pidió, no lo que hacía falta (#26).
6. Los presupuestos de transporte se vigilan con **gates de CI**, no con
   memoria de revisores (#25).
7. Verificación de permisos: **ejercitar el ciclo real**; `simulate` solo
   cuando el rol no sea asumible, y con lista tomada del call graph (#26).
8. Un check que **declara dónde no llega** vale más que un ✓ que suma sin
   ejecutar: los resúmenes no son ejecuciones (#22, §15d).

---

## Coste del día

8 applies y 4 destroys. **Total 0,8393 USD** — base EC2 + NLB; **no incluye**
EBS, IPv4 pública, NLCU ni transferencia, así que la factura real será mayor.

- **Medido** (calculado de `LaunchTime`/`StateTransitionReason` reales):
  **0,3741 USD** — acumulativo 0,2498 + coronación 0,1243.
- **Estimado** (arranques ya fuera de la retención de EC2; cifras calculadas
  cuando aún eran medibles): **0,4652 USD**.

---

## Plan

- **Fase 1 — bootstrap directo al estado final: CORONADA (27-ago).**
- **Fase 2 — SIGUIENTE**: multi-AZ, GitOps/ArgoCD, DNS y certificados reales,
  backup de Kafka, rotación de secretos, DR cross-region. El riesgo principal
  es de alcance, no técnico: timeboxing estricto por frente.
- **Fase 3**: mini-proyectos de operación. Estado real de partida: la escalera
  de Gateway API (4b) fue **ejecutada y coronada en vivo**; el upgrade de
  Cilium en vivo con drenaje coordinado (4a-v3) está **revisado y listo como
  runbook pero NUNCA ejecutado** — su primera ejecución es un mini-proyecto,
  no una re-ejecución.

## Deuda y pendientes

Backlog ejecutable en [PLAN-SPRINTS.md](PLAN-SPRINTS.md). Además:

- **Higiene de repo**, aprobada y pendiente: archivar runbooks a
  `docs/operations/`, borrar prototipos muertos, podar ramas mergeadas y
  divergentes. `TODO(verificar)`: número exacto de ramas a podar.
- **Guía para dummies** de crear-cuenta-AWS hasta el borde final, con sección
  de última milla a PROD real.
- **logistics-lab** (Repo 2, app Go): en pausa explícita desde el pivote al
  bootstrap.

---

# Histórico — Sprint 1 coronado (2026-08-15)

Estado de entrega del Sprint 1. El criterio de coronación se cumplió punto por
punto y observado en real, no solo por checks internos.

### Criterio de coronación → evidencia del 15-ago

| Criterio | Evidencia |
|----------|-----------|
| `make apply` → cluster completo sin intervención manual | Run de Apply 31880994078: 47 recursos desde estado vacío, plataforma instalada, smoke 38/38, 18 min |
| App respondiendo por el Gateway con TLS | E2E **exterior** (fuera del cluster): `POST /shipments` → HTTP 201 con pinning de clave pública y SNI `shipments.logistics.lab` (shipment `CORONATION-001`, id `f12833dd…`); `grpcurl` lista e invoca `CalculateRoute` vía la GRPCRoute `routing.logistics.lab` sobre TLS |
| Eventos fluyendo por Kafka | Histórico del envío con envelope completo: `shipment.created` + `route.calculated` (`valid:true`, 5 ms entre eventos); topics con 2.721 mensajes cada uno en simetría creación↔ruta |
| Datos en PG | 902 shipments / 1.804 shipment_events en `logistics` (primaria `logistics-pg-1`), 2 eventos por envío |
| Grafana mostrando métricas de la app | `logistics_service_info` de los 4 servicios en Prometheus, Grafana sirviendo en el NodePort |

### Qué pasó por el camino (todo registrado)

- **INCIDENTS #12**: el primer deploy real murió en `AssumeRoleWithWebIdentity`
  — logistics-lab emite el subject OIDC **ID-qualified** (inmutable,
  `repo:org@id/repo@id`) y la trust solo casaba el esquema clásico. Fix en
  PR #42 (`app_repo_ids`, ambos esquemas, solo main+tags), aplicado y
  verificado con el deploy siguiente.
- **Bump de grpc por CVE** (Repo 2): el escaneo de Trivy del pipeline bloqueó
  el push hasta subir la dependencia — la puerta de supply-chain trabajando
  en su primer día real.
- **Deploy ×2 idempotente**: el segundo `workflow_dispatch` sobre el mismo
  estado terminó verde reutilizando los SHA inmutables ya publicados.
- **`make smoke-app-contract GITHUB_SHA=c39bde15…` verde**: 4 servicios
  Ready con imagen traída de ECR **por digest**, `up==1` y
  `logistics_service_info` con muestras en los 4.

### Cómo operar esto (los runbooks)

- Ciclo diario post-apply (logins SSO, kubeconfig, refresh de variables de
  Repo 2): [RUNBOOK-post-apply.md](RUNBOOK-post-apply.md)
- Qué login necesita cada target de make: [CLUSTER.md](CLUSTER.md) §4
- Destroy: volúmenes EBS huérfanos del CSI + borrar `K8S_SERVER` en
  logistics-lab: [troubleshooting.md](troubleshooting.md)

### Lo que quedaba entonces — Road to go-live

Por orden ([PLAN-SPRINTS.md](PLAN-SPRINTS.md)): backups con restore probado
(primero, nunca tocar etcd sin backup) → NLB de entrada → HA del control
plane → upgrade en vivo. Más la automatización de los dos residuos del
destroy (EBS huérfanos, variable stale de Repo 2).
