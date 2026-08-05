# El health check post-deploy no verifica que se esté sirviendo lo desplegado

**Estado:** propuesta · **Abierto:** 2026-08-05
**Afecta a:** `Publish-FlutterWeb`, y por extensión a cualquier cmdlet con verificación por HTTP.

## Estado actual

Al terminar `-Apply`, el cmdlet ejecuta en el servidor:

```bash
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:<port>/
```

y trata cualquier código distinto de `200` como sospechoso:

```
  Verificando: http://127.0.0.1:3048/
WARNING: HTTP 3048 respondió 301 (puede necesitar tiempo para iniciar)
```

Ese warning apareció en los despliegues reales de **impulsa** y **micro**, y en ambos era un falso
positivo. La causa: en esos sitios el puerto declarado en `publish.yaml` pertenece a un bloque que
**solo redirige**, y la web la sirve el `:443`.

```nginx
server {
    listen 3048 default_server;
    return 301 https://impulsa.santaisabel.com.pe;   # <- el health check pega aquí
}
server {
    listen 443 ssl;
    server_name impulsa.santaisabel.com.pe;
    location / { root /var/www/impulsa/current; }    # <- la app vive aquí
}
```

De siete apps desplegadas, el reparto es:

| Patrón | Apps | Qué devuelve el puerto declarado |
|---|---|---|
| El puerto dedicado **sirve** la web | `gabinete` (4035), `tigre_regalon_2` (4036) | `200` |
| El puerto dedicado **redirige** a `:443` | `impulsa` (3048), `micro` (3046), `pyme` (4020), `tigre` (3052) | `301` |
| No hay puerto dedicado | `fintech`/`gruppi` (80) | `301` |

Cinco de siete devuelven `301`. El aviso salta siempre, y por eso ya no se lee.

### Los dos problemas, que son distintos

**1. Un `3xx` se trata como anomalía.** Es una respuesta sana de nginx. Mientras el check exija
`200`, el warning es ruido permanente — y un aviso que aparece siempre deja de avisar. Es la misma
dinámica que ADR 0012 corrigió en las deprecaciones.

**2. Aunque aceptara el `3xx`, no verificaría nada útil.** Un `301` prueba que nginx está vivo y
que hay un bloque escuchando ese puerto. No prueba que el despliegue haya surtido efecto: el
redirect responde igual con el symlink movido o sin mover.

Ese segundo punto es el importante. **El caso de `micro` lo demuestra**: su site servía desde
`/var/www/micro` plano, así que mover `current` no habría cambiado nada de cara al usuario. El
health check habría devuelto su `301` de siempre y el deploy habría terminado en verde. Lo que lo
detectó fue una comprobación distinta —que el `root` del site apunte a `current`—, no el check.

### Por qué no basta con corregir los puertos

Poner `443` en `publish.yaml` no lo arregla: el check hace `curl http://…` en texto plano contra
un puerto TLS. **Ningún valor de `port` hace verificable un sitio servido por HTTPS.**

`port` además tiene un segundo uso legítimo —`Configure-NginxSite` crea un site en ese puerto
cuando no existe— heredado de cuando se publicaba directo por HTTP en local. Ese uso sigue siendo
válido y no se retira.

## Estado deseado

Que el check responda a la pregunta que importa: **¿se está sirviendo lo que acabo de desplegar?**

### 1. Seguir la redirección, resolviendo contra el propio servidor

Si la primera respuesta es `3xx`, leer el `Location`, extraer el host, y repetir la petición
forzando que resuelva a `127.0.0.1`:

```bash
curl -sk --resolve <host>:443:127.0.0.1 https://<host>/
```

El `--resolve` no es un detalle. Sin él, un `curl -L` sale hacia el DNS público y puede fallar por
enrutamiento, salida a internet o *hairpin NAT* — motivos que no tienen nada que ver con el
despliegue. El `-k` es necesario porque el certificado es del dominio y la conexión va a la IP local.

### 2. Comparar la versión servida contra la desplegada

Al final de esa cadena está `/version.json`, que Flutter genera en cada build:

```json
{"app_name":"micro","version":"0.15.1","build_number":"159"}
```

El cmdlet **ya sabe** qué versión acaba de subir: la lee de `pubspec.yaml`. Comparar ambas convierte
la verificación en una aserción real.

| Resultado | Significado | Severidad |
|---|---|---|
| Coincide | el despliegue surtió efecto | `ok` |
| Difiere | se subió, pero el sitio sirve otra cosa | **`error`** |
| Sin `version.json` | no se puede afirmar nada | `warn` |

El segundo caso es exactamente el escenario de `micro`, y con esto se detecta **por sí solo**, sin
depender del chequeo del `root`.

### 3. Aceptar `2xx` y `3xx` como respuestas sanas

Solo `4xx`, `5xx` y la ausencia de respuesta son anomalías.

### 4. Permitir declarar la URL de salud

Como ya hace `Publish-DockerStack` con `health.url`. Para los sitios detrás de dominio, es más
directo que inferirla desde el puerto:

```yaml
health:
  url: https://micro.santaisabel.com.pe/version.json   # opcional; si falta, se infiere del puerto
```

## Criterio de aceptación

- [ ] Un `3xx` en el puerto declarado deja de producir warning
- [ ] El check sigue la redirección resolviendo el host contra `127.0.0.1`
- [ ] Compara `version.json` servido contra la versión desplegada, y **falla** si difieren
- [ ] Un sitio sin `version.json` produce `warn`, no `error`
- [ ] `health.url` en `publish.yaml` tiene precedencia sobre la inferencia por puerto
- [ ] Cubierto por tests con las respuestas simuladas: `200` directo, `301` a `200`, `301` a
      versión distinta, y cadena rota
- [ ] Verificado contra un despliegue real de los dos patrones: puerto que sirve (`gabinete`) y
      puerto que redirige (`micro`)

## Consecuencias

- El warning vuelve a significar algo, porque deja de aparecer siempre.
- **Un despliegue silencioso se detecta solo.** Hoy hace falta que el plan compruebe el `root`; con
  esto, cualquier causa que impida servir lo nuevo —symlink, caché, proxy intermedio, permisos—
  sale a la luz por el mismo camino.
- Los puertos declarados dejan de ser un problema: `3xx` es válido, y lo que se afirma es la
  versión, no el código de estado.
- **Depende de `version.json`**, que Flutter genera pero una API Node no. Extender esto a
  `Publish-NodeApi` requiere decidir antes qué endpoint cumple ese papel — probablemente el de
  salud que ya expone `modular_api`.
