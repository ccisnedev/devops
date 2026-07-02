# Publish-DockerStack

Despliega un stack de **Docker Compose** a un servidor Linux remoto por **SSH**, con el mismo
modelo `Init` / `Plan` / `Apply` de `Publish-NodeApi` (ADR 0002). Es la contraparte para
infraestructura contenedorizada: donde `Publish-NodeApi` gestiona una API Node, este gestiona
un stack Compose (Keycloak, bases, workers, etc.).

## Por qué un cmdlet y no Terraform

Son dos capas distintas:

- **Provisioning** (crear VM, instalar Docker, firewall, DNS): on-prem, lo entrega Infra. Terraform
  brilla solo sobre sustratos API/cloud; aquí aporta poco.
- **Deploy del stack** (build, `docker compose up`, verificar): recurrente. Terraform encaja mal
  (usarías `remote-exec`). Compose ya es declarativo/idempotente; este cmdlet es el transporte +
  ciclo de vida + verificación alrededor, en el mismo toolchain que ya operas.

## Uso

```powershell
Publish-DockerStack -Init     # genera stack.yaml + .env (gitignored)
Publish-DockerStack -Plan     # dry-run: release, servidor, estado remoto (docker compose ps)
Publish-DockerStack -Apply    # empaqueta, sube, levanta, healthcheck, postDeploy
```

`-Apply` pide confirmación (ADR 0002); use `-AutoApprove` para CI y `-AllowDirty` para silenciar
el aviso de árbol de git sucio.

## Modelo remoto

```
/opt/stacks/<name>/
├── releases/
│   └── v{version}+{gitSha}/     # compose + include + .env (600)
└── current -> releases/…        # rollback = repuntar este symlink y up -d
```

El stack corre como proyecto compose `-p <name>`, así que los contenedores se reconcilian por
nombre de proyecto independientemente del directorio del release.

## stack.yaml

| Clave | Descripción |
|---|---|
| `server` | alias en `~/.ssh/config` |
| `stack.name` | nombre del proyecto compose (`-p`) y carpeta remota |
| `stack.version` | etiqueta; el release es `v{version}+{gitSha}` |
| `stack.composeFile` | ruta del compose (default `docker-compose.yml`) |
| `stack.build` | `server` (build en el servidor) · `transfer` (build local + `docker save`/`load`) · `none` |
| `stack.image` | requerido con `build: transfer` |
| `include` | archivos/carpetas a subir (en `build:server`, todo el contexto de build) |
| `health.container` / `health.url` | espera `healthy`/`running` o una URL (`url` tiene precedencia) |
| `postDeploy` | comandos en el servidor tras `up -d` (ej. aplicar realm-as-code) |

Los **secretos NO van en stack.yaml** (se versiona). Van en `.env` (gitignored), que se copia al
servidor como env-file del stack.

## Modos de build

- **server**: sube el contexto declarado en `include` y hace `docker compose up -d --build` en el
  servidor. Requiere que el servidor pueda construir (imágenes base / internet según el Dockerfile).
- **transfer**: `docker compose build` local, `docker save` de `stack.image`, se transfiere y
  `docker load` en el servidor, luego `up -d --no-build`. **Mismo artefacto** validado localmente,
  sin registry. Requiere Docker local.
- **none**: la imagen ya está en el servidor o compose la hace `pull`.

## Requisitos

- Alias del host en `~/.ssh/config`.
- Docker + plugin compose en el servidor.
- Docker local solo para `build: transfer`.
- Módulo `powershell-yaml`.
