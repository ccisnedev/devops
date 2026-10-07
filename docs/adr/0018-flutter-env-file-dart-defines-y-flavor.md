# ADR 0018: El env file de una app Flutter da sus dart-defines y su *flavor*

**Status:** Proposed (2026-10-07)

**Resuelve:** el punto que la [ADR 0017](0017-configuracion-compuesta-desde-archivos-versionados.md)
dejó para una segunda etapa («las apps Flutter con su relación entorno → *flavor*»), sin adelantar
el resto de esa etapa.
**Relacionada con:** [ADR 0004](0004-deploy-target-from-env-file.md) y
[ADR 0010](0010-envfile-deploy-target-family.md) (el entorno se elige con `-EnvFile`),
[ADR 0007](0007-flutterweb-deploy-target-from-env-file.md) (`Publish-FlutterWeb -EnvFile`),
[ADR 0009](0009-deploy-plan-artifact-and-apply-parity.md) (el plan y el apply dicen lo mismo).

## Contexto

En las APIs, el entorno se elige con `-EnvFile`: `.env` en la máquina local, `.env.uat`,
`.env.production`. Una app Flutter no tenía equivalente. `Invoke-FlutterBuild` compilaba siempre
el mismo binario, y la URL del backend se elegía en el código con un booleano (`debug: true` →
localhost, `false` → producción). Compilar para uat significaba editar `main.dart` antes de compilar
y recordar deshacerlo, y no había forma de tener uat y prod instaladas a la vez en un mismo teléfono.

`Publish-FlutterWeb` ya recibía `-EnvFile`, pero solo para leer `MACSS_DEPLOY_SSH_ALIAS`: el mismo
archivo que elige el servidor no llegaba al build. Así podía publicarse en uat un JavaScript
compilado contra producción sin que nada lo señalara.

Flutter resuelve las dos cosas por separado:

- **dart-defines** (`--dart-define-from-file`): constantes que el código lee con
  `String.fromEnvironment`. Sirven para todas las plataformas.
- **flavors** (`--flavor`): variantes nativas de Android (`productFlavors`), con su propio
  `applicationId` y nombre visible. Son lo que permite tener varias variantes instaladas a la vez.
  Flutter web no tiene flavors.

## Decisión

1. **`Invoke-FlutterBuild -EnvFile <archivo>`.** Es opcional. Sin él, el build es exactamente el de
   antes.
2. **Cada clave del archivo que no empiece con `MACSS_` se pasa como dart-define.** Las `MACSS_*`
   son configuración de las herramientas (destino de despliegue, flavor) y nunca llegan al binario.
   Se pasan por un JSON temporal con `--dart-define-from-file`, que se borra al terminar. No se pasa
   el archivo original porque lleva las claves `MACSS_*`.
3. **`MACSS_FLUTTER_FLAVOR` es el flavor.** Si está, el APK se compila con `--flavor <valor>` y su
   nombre lo lleva: `app_<nombre>_v<versión>_<flavor>.apk`. En web y Windows se ignora y se dice.
   El nombre se valida (letras y dígitos), porque Gradle deriva tareas de él y su error no menciona
   el env file.
4. **Un archivo inexistente falla antes de compilar.** Un `-EnvFile` mal escrito no puede terminar
   en un build sin configuración que apunte a un entorno por defecto.
5. **Las claves con nombre de secreto (`KEY`, `SECRET`, `PASSWORD`) avisan, no bloquean.** Lo que
   entra al binario se puede leer descompilándolo, y en web queda en el JavaScript publicado. El
   nombre solo sugiere un secreto, no lo prueba, y bloquear obligaría a renombrar claves legítimas.
   Si el aviso resulta insuficiente, pasar a bloquear es un cambio local.
6. **`Publish-FlutterWeb` compila con el mismo `-EnvFile` que elige el servidor.** Así el destino y
   la configuración compilada salen del mismo archivo y no pueden divergir. Si el archivo no existe
   (un runner que exporta `MACSS_DEPLOY_SSH_ALIAS` al proceso, ADR 0015), compila sin defines,
   como antes.
7. **El plan muestra los nombres de los dart-defines, nunca sus valores.** El plan se persiste en
   disco (ADR 0009). La fila pasa a `warn` si hay claves con nombre de secreto, pero no se cuenta
   como bloqueante.

Los nombres de los archivos siguen la convención de las APIs: `.env` (dev local), `.env.uat`,
`.env.demo`, `.env.production`. Se versiona solo `.env.example`.

## Consecuencias

- Compilar para otro entorno es cambiar un argumento, no editar código: `Invoke-FlutterBuild -Apk
  -EnvFile .env.uat`.
- La app declara los flavors en `android/app/build.gradle(.kts)`. Si el env file nombra un flavor
  que el proyecto no declara, el build falla en Gradle. El módulo no lo comprueba antes.
- **Cambio de comportamiento en `Publish-FlutterWeb`:** si el `.env` de un proyecto web ya traía
  claves distintas de `MACSS_*`, desde esta versión llegan al build. Hasta ahora el archivo solo
  servía para el destino, así que en la práctica traía solo `MACSS_DEPLOY_SSH_ALIAS`. El plan lo
  hace visible antes de confirmar.
- `Invoke-FlutterBuild` ahora falla si `flutter build` termina con error. Antes seguía e intentaba
  mover un artefacto que no existía.
- Queda fuera: componer el env file de una app Flutter desde un archivo versionado y uno de
  secretos (ADR 0017), y los flavors de iOS.
