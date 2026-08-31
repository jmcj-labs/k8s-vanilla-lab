# logistics-lab — Plan por Fases

Reescritura de `PLAN-SPRINTS.md` bajo nomenclatura única (30-ago-2026).
Estado de partida: `main` en `2f4a347`, Fase 1 coronada y documentada.

Método: decisiones de diseño en chat; ejecución de código en Cursor/Claude
Code; el repo nunca va por detrás de la realidad.

---

## Nomenclatura

Este documento usa **Fases** y solo Fases. Hasta hoy convivían tres
numeraciones incompatibles describiendo el mismo trabajo:

| Sistema | Qué era | Estado |
|---|---|---|
| **Fases 1-2-3** | Producto, del HANDOFF | **Único vigente** |
| Sprints 1-2 | Producto, del plan viejo | Historial fechado, al final |
| "Fase 1.5" / "Fase 2" del path | Itinerario formativo de Cilium/observabilidad | Renombrado a **Trayecto** |

El itinerario formativo se renombra porque colisionaba por nombre con las
Fases de producto sin tener relación con ellas.

---

## Fase 1 — Bootstrap directo al estado final · 👑 CORONADA (27-ago-2026)

El cluster nace en Cilium 1.20.1 + Gateway API v1.6.1 desde el primer
arranque, por ruta híbrida (seis CRDs standard individuales + overlay del
TLSRoute experimental, que sirve `v1alpha2`). Transporte de renders por S3 con
stub que verifica SHA-256 horneado por tofu. Gates fail-closed: join
secuencial por SSM, esquema Gateway API por discovery real, KPR por token de
dato, tamaño de `user_data` en CI.

**Evidencia**: dos verdes consecutivos sobre `c641d01` — run `33085372641`
(cluster vivo) y run `33087225268` (vacío absoluto). Smoke: **64 checks OK en
CI, 60 en local**. Detalle y método de conteo en [HANDOFF.md](HANDOFF.md).

---

## Fase 2 — Profesionalizar el cluster · SIGUIENTE

El riesgo aquí es de alcance, no técnico: timeboxing estricto por frente.

### Pieza 0 — Endpoint de readiness por nodo (INCIDENTS #20) · 👑 CORONADA (31-ago-2026)

**Coronada con la prueba, no con un razonamiento.** `kill -STOP` sobre el
`cilium-envoy` de un worker: el TG marcó **ese** target `unhealthy` entre 19 s
y 24 s después, y los otros dos siguieron `healthy` en las 34 muestras. La
misma intervención contra el health check TCP anterior daba 22 muestras
seguidas de `healthy`. Criterio escrito antes de ejecutar, con sus dos formas
de fallar declaradas. Evidencia en
[`docs/evidence/pieza0-2026-08-31/`](evidence/pieza0-2026-08-31/).

Entregado: agregador `node-readiness` (DaemonSet `hostNetwork` en workers,
imagen pinada por digest desde ECR), health check del TG a `HTTP :8910/healthz`
con `matcher=200`, regla de SG, 4 checks nuevos en el smoke y el gate de
tamaño de user_data intacto. Cuatro incidentes por el camino: #26 (tercera
manifestación, el extremo lector del pull de ECR), #28 (la constante `:9890`
heredada de un prototipo nunca desplegado, que colisiona con `cilium-agent`) y
#29 (la guarda que mataba la instalación justo cuando pasaba, con un falso
negativo por SIGPIPE en su único cometido). Los cuatro los cazó el hierro.

**Límite que NO cierra**: la prueba mata a Envoy, no al datapath del agente. Un
agente que se reporta sano con su datapath roto sigue sin detectarse. Ver
[CLUSTER.md](CLUSTER.md) §5.


No es una elección: el propio plan lo declara **prerrequisito del upgrade de
Cilium en vivo (4a-v3)**, y multi-AZ agrava el fallo en vez de tolerarlo.

#### El enunciado, ahora con dato en vez de hipótesis

**El health check del NLB no puede distinguir un nodo cuyo Envoy no sirve,
porque sondea un puerto que el agente programa con independencia de Envoy.**

Medido el 31-ago-2026, no deducido de la configuración. Con el proceso
`cilium-envoy` de un worker detenido y el agente vivo, **22 muestras
consecutivas** de la ventana probatoria:

| señal | qué dijo |
|---|---|
| target group | `healthy` — el balanceador siguió mandándole tráfico |
| TCP al NodePort | `open` — el puerto aceptaba, programado por el agente |
| DaemonSet de Envoy | `6/5`, y el pod del nodo `Ready=false` |

**Kubernetes lo sabía y el balanceador no.** Y el `open` sostenido descarta la
única explicación alternativa —saturación de la cola de accept—: el puerto
nunca dejó de aceptar, así que el check no falló ni pudo fallar por cola llena.

Evidencia en [`evidence/h3-2026-08-31/`](evidence/h3-2026-08-31/); cierre del
incidente en [INCIDENTS.md](INCIDENTS.md) #20.

#### Lo que resuelve, y cómo

Que el balanceador reciba la señal que Kubernetes ya tiene. `node-readiness`
—`platform/node-readiness/`, ya **no** un prototipo— corre como DaemonSet
`hostNetwork` **solo en los workers**, escucha en `0.0.0.0:8910` y responde 200
únicamente con el **AND** de `127.0.0.1:9879` (agente) y `127.0.0.1:9878`
(Envoy). Ambos sirven `/healthz` pero **solo en loopback**, y por eso había que
construir el agregador en vez de repuntar el check a un puerto existente.

| pieza | dónde |
|---|---|
| imagen, fijada por digest | repo ECR en el stack `persistent`; se reconstruye con `.github/workflows/build-node-readiness.yml` |
| DaemonSet | `platform/manifests/node-readiness.yaml`, paso 6/13 de `platform/install.sh` |
| regla de SG | 8910/tcp en el SG de workers, **solo desde el SG del NLB**, standalone (INCIDENTS #6) |
| health check | TG del gateway: `HTTP` `:8910` `/healthz`, `matcher 200`, `interval 10`, umbrales `2`/`2` — **explícitos**, no heredados |

#### El límite que NO cierra

El experimento mató a **Envoy**, no al datapath del agente. Este endpoint le
pregunta al agente si está bien, así que **un agente que se reporta sano con su
propio datapath roto sigue sin detectarse**. Queda abierto, y no es lo mismo
que lo que se ha cerrado.

### Piezas restantes (orden por decidir tras la pieza 0)

- **Multi-AZ** — cierra la deuda de resiliencia zonal (hoy: una AZ, cross-zone
  off, HA de nodo pero no zonal).
- **GitOps / ArgoCD** — retira el `helm --set imageTag=<SHA>` y el refresh
  manual de `K8S_SERVER`/`K8S_CA_DATA`.
- **DNS y certificados reales** — hoy `selfsigned` y sin Route53.
- **Backup de Kafka** — deuda declarada en S2-1; entra si algún topic carga
  estado que importe.
- **Rotación de secretos / External Secrets** — cierra la rotación manual de
  las access keys de barman y la reproyección por `make platform`.
- **DR cross-region**.

### Ya asignadas a esta fase por decisiones previas

- **VPC gateway endpoint de S3 + regla por prefix-list**: cierra el
  `world:443` de egress de los pods PG (INCIDENTS #15). Ratificado como
  primera tarea de este bloque.
- **Bucket propio para los objetos de bootstrap**: hoy los renders viven junto
  a `etcd/` y `cnpg/` en el bucket persistente. Descartado a propósito en su
  momento por la superficie de permisos que exigiría; revisar aquí, cuando el
  reparto de permisos de CI se toque por otras razones.
- **Cleanup automático de volúmenes EBS huérfanos** por tag
  `kubernetes.io/created-for/pvc/*`, como ya se hace con las ENIs.

---

## Fase 3 — Mini-proyectos de operación

Ejecutar en vivo lo que hoy solo existe como runbook. Estado real de partida,
sin redondear:

- **Upgrade de Cilium en vivo con drenaje coordinado (4a-v3)**: revisado y
  listo como runbook, **NUNCA ejecutado**. Su primera ejecución es un
  mini-proyecto, no una re-ejecución. Bloqueado por la pieza 0 de Fase 2.
- **Escalera de Gateway API (4b)**: **ejecutada y coronada en vivo**. No se
  repite.
- **Upgrade de Kubernetes (4c)**: runbook en estado `ESQUELETO`
  (`docs/RUNBOOK-upgrade-kubernetes.md`), ejecución 1.35.x → 1.36.x y tabla de
  tiempos pendientes.
- **Upgrade del operador Strimzi**: 1.1.0 → 1.2.0-rc1. Trabajo posterior, no
  un upgrade encadenado a los anteriores.

Hereda además la **pieza 4 del Sprint 2** ("upgrade del cluster en vivo con la
app sirviendo tráfico"), que nunca se ejecutó — ver histórico.

---

## Trayecto formativo (paralelo, no bloqueante)

Itinerario de aprendizaje sobre el cluster real. No condiciona el orden de las
Fases.

- **Trayecto 1.5** — Cilium a fondo: L7 policies, Hubble avanzado, mesh,
  Tetragon. Aquí entra el control futuro para el límite de "egress a la VIP del
  Gateway no restringible por CNP del cliente" (L7/auth en el Gateway +
  policies por servicio).
- **Trayecto 2** — resto de servicios de logistics-lab, OTel Collector /
  tail-sampling, operator con Kubebuilder.

---

## Backlog de higiene y deuda ejecutable

Aprobado y pendiente, fuera del camino crítico:

- **Higiene de repo**: archivar runbooks a `docs/operations/`, podar ramas
  mergeadas y divergentes. El número de ramas a podar está **sin verificar**.
  *(«Borrar prototipos muertos» sale de esta entrada: el único que había,
  `platform/node-readiness/`, dejó de ser prototipo — es el componente de la
  Pieza 0.)*
- **Guía para dummies** de crear-cuenta-AWS hasta el borde final, con sección
  de última milla a PROD real.
- **Rol OIDC partido en dos** (read-only para PR/validate, completo para
  apply/destroy en `main`) — `TODO` en `docs/bootstrap.md:120`.
- **Acotar `KMSForSSMSecureString.Resource`** de `*` al ARN exacto de
  `alias/aws/ssm` — `TODO` en `docs/bootstrap.md:134`.
- **Ceremonia muerta tras guardar `certificate-key`**: el `if [ $? -eq 0 ]`
  posterior siempre es cero. Eliminar la falsa rama; no bloquea el arranque.
- **Retry acotado en el gate de join** ante errores SSM transitorios,
  conservando fail-closed y el diagnóstico.
- **Estándar de verificación de permisos nuevos** (INCIDENTS #26): un permiso
  nuevo se verifica **ejercitando el ciclo real con el rol asumido** (put + get
  + delete sobre una key canario), no simulando el contrato. Cuando el rol no
  sea asumible —OIDC-only, como el de CI— `simulate-principal-policy` es el
  sustituto, pero la lista de acciones **no sale del 403** (eso nombra el
  siguiente fallo, no el conjunto) **ni de la memoria**: sale del **call graph
  de la versión del provider fijada en el lock**. Así apareció
  `s3:ListBucketVersions`, acción de **bucket** que ninguna lista de acciones de
  **objeto** podía contener y que habría roto el **destroy**, no el apply. Con
  negativa de control sobre un prefijo vecino. Al checklist de revisión.
- **Auditar gates que parsean salida humana** de `cilium-dbg`, `kubeadm` y
  `helm` (INCIDENTS #23), y asignaciones `VAR=$(... 2>/dev/null)` bajo `set -e`
  sin guarda en línea (#24). Auditoría, no reescritura preventiva.
- **Marcador de fallo temprano en SSM** para que CI no sondee 1210 s a un
  fundador muerto al minuto 2.
- **logistics-lab (Repo 2)**: en pausa explícita desde el pivote al bootstrap.

### Deuda consciente que no se paga todavía

Subred pública sin NAT · workers spot · anti-affinity `required` con 3 workers
· memoria justa en t3.medium · token de join con TTL 24h · ventana sin tokens
IAM en cada bootstrap · acoplamiento app/API en el NLB único · API 6443
pública por el NLB y kubeconfig admin en SSM como break-glass · logging de
contenido de sesiones SSM sin configurar.

Detalle de cada una en [CLUSTER.md](CLUSTER.md) §5.

---

## Pendientes de observación (no son deuda: son afirmaciones sin verificar)

1. ~~El contador de checks del smoke está declarado NO OBSERVADO.~~
   **OBSERVADO (31-ago-2026): imprime 64.** Run `33375935701`, `main` en
   `bccebff`: `✓ Smoke test passed — 64 checks OK`. Era su primera ejecución
   real y coincide con la derivación previa (54 llamadas a `OK()` + 10 del
   sub-script de esquema).
2. **Inventario AWS post-destroy sin verificar**: nadie ha comprobado bucket de
   bootstrap, parámetros SSM, snapshots, ECR ni volúmenes EBS huérfanos. La
   consola de EC2 vacía no es "cuenta a cero".
3. ~~Flujo humano SSO de `jm-dev` sin evidencia.~~ **VERIFICADO
   (31-ago-2026).** Login SSO real en incógnito:
   `sts get-caller-identity` devuelve `AWSReservedSSO_K8sDevBridge_.../jm-dev`;
   `get pods -n infra` devuelve el `Forbidden` **del API server**
   (`User "developer:jm-dev" cannot list resource "pods" ... in the namespace
   "infra"`), no el `ForbiddenException: No access` de Identity Center; y
   `get pods -n logistics` devuelve `No resources found`. **Esa última mitad es
   la que cierra la prueba**: sin ella el `Forbidden` sería compatible con «el
   acceso no funciona», y lo que se demuestra con las dos es segregación por
   namespace. Detalle en [CLUSTER.md](CLUSTER.md) §5.
4. **Coste del 27-ago sin medir** en granularidad diaria.

---

# Histórico — Sprints (nomenclatura retirada)

Se conserva fechado. No se reescribe.

## Sprint 1 — Cluster automático + App MVP · 👑 CORONADO 15-ago-2026

`make apply` → cluster completo sin intervención manual; app respondiendo por
el Gateway con TLS (HTTP y gRPC desde fuera del cluster); eventos por Kafka;
datos en PG; métricas de los 4 servicios en Grafana. Evidencia punto por punto
en [HANDOFF.md](HANDOFF.md). Smoke de entonces: 38/38, run `31880994078`.

## Sprint 2 — Road to go-live · 3 de 4 piezas coronadas (16-ago-2026)

| Pieza | Estado |
|---|---|
| 1. Backups con restore probado | 👑 CORONADA — drill etcd 58 s, drill CNPG 121 s, bucket superviviente a 2 destroys |
| 2. LB de entrada real (NLB) | 👑 CORONADA — smoke §13 5/5 ×2, e2e por el DNS del NLB, negativa en las 3 IPs |
| 3. HA del control plane | 👑 CORONADA — 7/7 criterios, restore HA 193 s, acceso OOB restaurado |
| 4. Upgrade del cluster en vivo | **NUNCA EJECUTADA** → migrada a Fase 3 |

**El criterio de coronación del Sprint 2 no se cumplió íntegro**: exigía
"upgrade minor completado con la app sirviendo tráfico" y esa pieza no se
ejecutó. Se deja constar en vez de darlo por cerrado.

## Desviación registrada (12-ago-2026)

Tag-bump del deploy fuera del MVP: Repo 2 despliega con
`helm --set imageTag=<SHA>` y refresh manual de `K8S_SERVER`/`K8S_CA_DATA`
tras cada recreate. El GitOps declarativo se retoma en Fase 2.
