# ADR 0014: La configuración de runtime vive en el servidor, y `.env.example` es su contrato

**Status:** Accepted (2026-08-11)

**Relacionada con:** ADR 0004 (el destino del despliegue sale del env file), ADR 0003
(sharedPaths), ADR 0009 (el plan y el apply dicen lo mismo).

## Context

La ADR 0004 puso el **destino** del despliegue en el env file gitignoreado. Ese archivo quedó
haciendo dos trabajos a la vez:

1. **Nombra el destino** — `MACSS_DEPLOY_SSH_ALIAS`, que es metadato de despliegue.
2. **Es la configuración de runtime de la app** — todo lo demás, que `-Apply` sube al servidor
   como el `.env` del release, filtrando las claves `MACSS_DEPLOY_*` justo antes de subirlo.

El primer trabajo es correcto y no se toca. El segundo tiene una consecuencia que nadie
decidió: **la configuración con la que corre producción existe únicamente en la máquina del
operador que desplegó por última vez**. De ahí se siguen cuatro cosas, y ninguna es sobre CI:

- Nadie puede decir con qué configuración corre producción hoy.
- No es recuperable si esa máquina se pierde.
- No es auditable: no hay registro de qué cambió, cuándo ni quién.
- Cambiar un timeout obliga a hacer un release.

Y una quinta que sí es sobre CI: tras `actions/checkout` no hay env file, así que un job de
deploy **no tiene de dónde copiar la configuración**. `deploy.api.yml` no es una plantilla
incompleta; es una plantilla imposible de completar.

### Lo que ya estaba a mano

El módulo ya resolvía este problema para otro secreto. Las llaves RSA de `impulsa` se declaran
así:

```yaml
runtime:
  sharedPaths:
    - key        # key/privatekey.pem + publickey.pem
```

No están en git, viven en `/opt/app/impulsa/shared/`, se suben una vez con `-PushShared`, y el
despliegue **no las carga: solo las enlaza** en cada release. El `.env` era la excepción, sin
ninguna razón que la justifique. Dos secretos del mismo proyecto por dos caminos distintos.

### Por qué mover el archivo, solo, es peor que no hacer nada

Un `shared/.env` persiste entre releases. Una versión que introduzca una variable nueva se
desplegaría con éxito y fallaría en runtime, porque el archivo del servidor seguiría siendo el
viejo. Eso cambia un fallo **visible** —"no puedo desplegar desde CI"— por uno **silencioso**
—"desplegué y la aplicación no arranca"—, y el segundo es peor.

Al preparar esta decisión se compararon las claves reales de `impulsa`: **6 variables corrían en
producción sin estar en `.env.example`**, y **5 estaban documentadas y no existían en
producción**, corriendo con el valor por defecto del código sin que nadie lo hubiera decidido.
El contrato ya estaba roto en ambas direcciones y nada lo señalaba.

## Decision

**El `.env` puede declararse como `sharedPath`. Cuando lo está, la configuración de runtime vive
en el servidor y el despliegue solo la enlaza — y `.env.example` pasa a ser un contrato que el
despliegue hace cumplir.**

Las dos mitades son una sola decisión. La primera sin la segunda no se implementa.

```yaml
runtime:
  sharedPaths:
    - key
    - .env
```

Es **opt-in por proyecto**: quien no lo declare sigue subiendo el env file como hasta ahora.

### El contrato

`-Plan` y `-Apply` comparan las claves de `.env.example` —versionado, y por tanto viaja con el
código— contra las de `shared/.env` en el servidor:

| Resultado | Significado | Severidad |
|---|---|---|
| Coinciden | el servidor tiene lo que el código pide | `ok` |
| Falta alguna en el servidor | la release necesita una variable que no está | **bloqueante** |
| Sobra alguna | configuración obsoleta, o el ejemplo se quedó atrás | aviso |
| No hay `shared/.env` | no hay configuración que enlazar | **bloqueante** |
| No hay `.env.example` | no se puede afirmar nada | aviso |

Se comparan **solo nombres de claves**. El sondeo recorta el valor en el servidor antes de
imprimirlo: la garantía tiene que estar donde se lee el archivo, no en quien recibe la salida, o
los secretos terminan en la salida del `ssh` y en cualquier log que la capture.

**Con una excepción declarada: `PORT`.** Su valor sí sale del servidor, porque el despliegue
necesita saber a qué puerto sondear el healthcheck y la app lo lee de ese mismo archivo. Mientras
salía del archivo local había dos fuentes para el mismo dato y nada impedía que divergieran: el
caso benigno es un healthcheck que falla estando todo bien; el malo es que en el puerto sondeado
responda otra cosa —un proceso anterior que quedó vivo— y el despliegue termine en verde sin que
la release nueva esté sirviendo. Si ambos lo declaran y difieren, bloquea.

La excepción es una **lista explícita** en el sondeo, no un efecto secundario: qué valor sale del
servidor es una decisión que se lee en el código.

La distinción entre bloqueante y aviso es la misma que el módulo ya aplica en otros lugares: lo
que **no se puede comprobar** avisa; lo que **se comprobó y está mal** bloquea.

### De dónde sale el `.env` que se sube

De **el env file elegido con `-EnvFile`**, no del `.env` local, y sin las claves
`MACSS_DEPLOY_*`. Sin esto, `-PushShared -EnvFile .env.production` subiría la configuración de
desarrollo a producción — exactamente el accidente que este esquema existe para evitar. Es la
misma limpieza que `-Apply` hacía al subir el archivo, movida al único lugar que ahora escribe
configuración en el servidor.

## Consequences

- **Cae uno de los dos bloqueos de CI**, no los dos. Ya existe un origen para la configuración
  de runtime que no es un portátil, que era el bloqueo grande. El otro sigue en pie: el env file
  está gitignoreado, así que tras `actions/checkout` tampoco existe `MACSS_DEPLOY_SSH_ALIAS` y el
  job no sabe a dónde ir (issue #75). Con solo esta decisión, un job de deploy de API todavía no
  corre.
- **Cambiar configuración deja de exigir un release.** Hoy ajustar un timeout obliga a
  desplegar; con esto es `-PushShared`.
- **`.env.example` deja de ser documentación que se desactualiza en silencio.** Pasa a ser un
  contrato que el despliegue verifica, y una PR que agrega una variable sin agregarla al ejemplo
  se detecta en el plan siguiente.
- **Hay un momento de migración por proyecto:** correr `-PushShared` una vez antes del primer
  despliegue con el nuevo esquema. `-Plan` lo detecta y lo dice.
- **La configuración sigue sin estar versionada.** Pasa de un portátil —que se pierde, se cambia,
  se rompe— a un servidor con respaldo. Es una mejora grande y no es el ideal: no hay historial
  de qué cambió ni quién lo cambió.
- **El rollback a una versión anterior no recupera su configuración.** `shared/.env` es siempre
  el actual, no el que correspondía a la release a la que se vuelve. El contrato al menos avisa
  si faltan o sobran claves. Versionar la configuración por release es otro problema.
- **El destino del despliegue en CI sigue abierto.** `MACSS_DEPLOY_SSH_ALIAS` necesita llegar al
  runner de alguna forma, y eso es una decisión aparte (issue #75).
