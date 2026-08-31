# Evidencia H3 — 2026-08-31

Serie del muestreador (`scripts/sample-h3.sh`) del experimento que **confirmó
H3 en vivo** y cerró INCIDENTS #20.

| fichero | qué es |
|---|---|
| `series` | 58 muestras, una por ronda, con timestamp **por campo** |
| `meta` | resolución inicial y el **mapa de identidades** `instance-id / IP privada / nodeName`, sin el cual los tres flujos no se pueden cruzar |

`trace` (la traza de `set -x`, 8.668 líneas) **no se archiva**: sirve para
depurar el muestreador, no el cluster.

## Cómo leerla

Corte y reanudación están en la propia serie como `event=`:

```
2026-08-31T09:41:34Z event=kill -STOP cilium-envoy pid=3512 worker-1 i-04c78fcdcb32eb068 10.0.1.234 ip-10-0-1-234
2026-08-31T09:45:09Z event=kill -CONT cilium-envoy pid=3512
```

- **09:41:34 → ~09:43:09** — ventana **CIEGA**. El health check es
  `interval=30s` con `unhealthy threshold=3`: un target no puede cambiar antes
  de ~95 s aunque el check sí detecte. `healthy` aquí no prueba nada.
- **~09:43:09 → 09:45:09** — ventana **PROBATORIA**, 22 muestras.
- El `CONT` a los 215 s, dentro de los 270 del `livenessProbe`, así que el
  contenedor nunca se reinició y el datapath observado fue siempre el mismo.

## Qué dicen las 22 muestras

Sin excepción, y con el worker intervenido siendo
`i-04c78fcdcb32eb068 / 10.0.1.234 / ip-10-0-1-234`:

```
tg   = i-04c78fcdcb32eb068=healthy      ← el balanceador lo da por sano
tcp  = 10.0.1.234=open                  ← el NodePort acepta
ds   = agent=6/6  envoy=6/5             ← Kubernetes sí lo ve caído
pods = ip-10-0-1-234=false
```

`nlb=`: 17 muestras `http404` (código **que el NLB devolvió**) y 5
`ERROR:curl-rc28`. Las cinco con `ERROR:` **no sostienen la conclusión**: son
ausencia de lectura, no prueba de fallo. Las 22 filas de `tg`/`tcp` sí, y son
las que confirman H3.
