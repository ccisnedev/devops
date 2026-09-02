# Instalar y actualizar macss-devops

El módulo se publica en [PSGallery](https://www.powershellgallery.com/packages/macss-devops).

## Instalación (primera vez)

```powershell
Install-Module macss-devops -Repository PSGallery -Scope CurrentUser
Install-Module powershell-yaml -Scope CurrentUser
```

`powershell-yaml` es obligatorio para `Invoke-SqlPackage`, `Invoke-PgSchema`, `Publish-FlutterWeb`,
`Publish-NodeApi` y `Publish-DockerStack` — todos leen su configuración de un `.yaml`. El módulo no
lo instala solo: si falta, falla con un mensaje que pide instalarlo.

Si es tu primer `Install-Module`, PowerShell pedirá confirmar que PSGallery es un repositorio no
confiable. Para no volver a verlo:

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
```

Y si Windows bloquea la ejecución de scripts:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Actualizar a la última versión

```powershell
Update-Module macss-devops
```

**Abre una terminal nueva después de actualizar.** Una sesión que ya importó el módulo se queda con
la versión vieja cargada aunque instales una nueva. Si no quieres cerrar la terminal:

```powershell
Remove-Module macss-devops -ErrorAction SilentlyContinue
Import-Module macss-devops -Force
```

## Verificar qué versión estás usando

```powershell
# La que tienes cargada ahora mismo
Get-Module macss-devops | Select-Object Name, Version

# Todas las instaladas en tu equipo
Get-Module -ListAvailable macss-devops | Select-Object Version, Path

# La última publicada
Find-Module macss-devops -Repository PSGallery | Select-Object Version, PublishedDate
```

Los cmdlets imprimen su versión en el banner, así que también la ves al ejecutar cualquiera:

```
╔══════════════════════════════════════════════════╗
║     Invoke-SqlPackage — macss-devops v6.8.5      ║
╚══════════════════════════════════════════════════╝
```

## Limpiar versiones antiguas

`Update-Module` **no borra** lo anterior: instala la nueva al lado. Con el tiempo se acumulan diez o
más carpetas. No rompe nada —PowerShell carga siempre la mayor—, pero confunde al diagnosticar.

```powershell
$ultima = (Get-Module -ListAvailable macss-devops | Sort-Object Version -Descending)[0].Version
Get-Module -ListAvailable macss-devops |
    Where-Object Version -lt $ultima |
    ForEach-Object { Uninstall-Module macss-devops -RequiredVersion $_.Version -Force }
```

## Instalar una versión concreta

Para CI, o para reproducir el entorno de otra persona:

```powershell
Install-Module macss-devops -RequiredVersion 6.8.5 -Repository PSGallery -Scope CurrentUser
```

## Desarrollo local desde este repo

Sin pasar por PSGallery, para probar cambios antes de publicar:

```powershell
Remove-Module macss-devops -ErrorAction SilentlyContinue
Import-Module .\code\powershell\macss-devops.psd1 -Force
```

`Remove-Module` primero, o la versión instalada en `PSModulePath` puede ganar la resolución de
nombres y acabarás probando el módulo publicado en vez de tu código.

## Antes de pedir ayuda

La versión es lo primero que hay que mirar cuando algo falla de forma rara: los mensajes de error
cambian entre versiones, y un mensaje viejo puede señalar la causa equivocada.

```powershell
Get-Module macss-devops | Select-Object Version
```

La `6.0.0` fue una **release de ruptura**: `-Publish` y `-DeployReport` desaparecieron en favor de
`-Apply` y `-Plan`, y cambiaron claves de los `.env`. Si vienes de una 5.x, lee la sección
[Migración de 6.0.0 en el CHANGELOG](../code/powershell/CHANGELOG.md) antes de actualizar.
