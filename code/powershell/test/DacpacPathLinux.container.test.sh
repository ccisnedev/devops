#!/usr/bin/env bash
# La ruta del .dacpac, resuelta por PowerShell en LINUX.
#
# Por que hace falta un contenedor
# --------------------------------
# El defecto solo existe fuera de Windows, y los tests de Pester corren en la maquina del
# operador. Cinco meses de despliegues manuales desde Windows no podian encontrarlo; el primer
# despliegue automatico lo encontro en su primera corrida:
#
#   *** Could not load package from '.\bin\Debug\IMPULSA.dacpac'.
#   Could not find file '/tmp/runner/work/impulsa/impulsa/code/db/.\bin\Debug\IMPULSA.dacpac'.
#
# Y hay una trampa que este test existe para vigilar: PowerShell en Unix normaliza la
# contrabarra, asi que el 'Test-Path' que el cmdlet hacia ANTES de invocar a sqlpackage daba
# verdadero sobre la ruta rota. Se intento reproducirlo aqui y resulta que las APIs de archivo
# de .NET en esta imagen tambien la normalizan: el unico que no lo hace es sqlpackage, y de eso
# la prueba es el log de produccion de arriba.
#
# La conclusion practica no cambia, y es lo que se comprueba: la cadena NO PUEDE llevar
# contrabarras, porque hay al menos un consumidor que las toma literales. Verificar con
# Test-Path no sirve, y por eso este test mira la cadena.
#
# Usage: bash DacpacPathLinux.container.test.sh [path-to-Private/scripts]
# Requires: docker.
set -euo pipefail

IMG="mcr.microsoft.com/powershell:latest"

aWindows() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" | tr '\\' '/'; else echo "$1"; fi; }
PRIV_POSIX="$(cd "$(dirname "$0")/../Private" && pwd)"
PRIV_WIN="$(aWindows "$PRIV_POSIX")"

echo "Private dir: $PRIV_WIN"

docker run --rm -v "$PRIV_WIN:/priv:ro" "$IMG" pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    . /priv/SqlPackageHelpers.ps1

    $raiz = "/tmp/proyecto"
    New-Item -ItemType Directory -Path "$raiz/bin/Debug" -Force | Out-Null
    Set-Content "$raiz/IMPULSA.sqlproj" "<Project />"
    Set-Content "$raiz/bin/Debug/IMPULSA.dacpac" "x"

    $p = Find-DacpacPath -ProjectRoot $raiz
    Write-Host "  ruta: $p"

    # 1. Sin contrabarras: es lo que sqlpackage recibe tal cual.
    if ($p -match "\\\\") {
        Write-Host "  FALLO: la ruta lleva contrabarras en Linux" -ForegroundColor Red
        exit 1
    }
    Write-Host "  caso 1 (sin contrabarras): PASS"

    # 2. Absoluta: no depende del directorio actual cuando sqlpackage la resuelva.
    if (-not [IO.Path]::IsPathRooted($p)) {
        Write-Host "  FALLO: la ruta no es absoluta" -ForegroundColor Red
        exit 1
    }
    Write-Host "  caso 2 (absoluta): PASS"

    # 3. Existe DE VERDAD. Se comprueba con .NET y no con Test-Path: el proveedor de
    #    PowerShell normaliza la contrabarra y daria por buena la ruta rota, que es
    #    exactamente como el guard anterior dejo pasar el defecto.
    if (-not [IO.File]::Exists($p)) {
        Write-Host "  FALLO: la ruta no resuelve al archivo real" -ForegroundColor Red
        exit 1
    }
    Write-Host "  caso 3 (resuelve al dacpac real): PASS"

    # 4. TEMP no existe fuera de Windows. Se comprueba aqui porque es el hecho del entorno
    #    que justifica el barrido de $env:TEMP en Pester: sin esto, alguien podria pensar
    #    que aquella regla es una manía y volver a escribir Join-Path $env:TEMP.
    #
    #    Fue el segundo defecto del despliegue 010: "Cannot bind argument to parameter
    #    Path because it is null", sin decir cual de los siete sitios.
    if ([string]::IsNullOrEmpty($env:TEMP)) {
        Write-Host "  caso 4 (TEMP no existe en Linux, por eso el barrido): PASS"
    } else {
        Write-Host "  FALLO: TEMP existe en esta imagen; la premisa del barrido hay que revisarla" -ForegroundColor Red
        exit 1
    }

    # 5. Y lo que se usa en su lugar si funciona.
    $tmp = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrEmpty($tmp) -or -not (Test-Path $tmp)) {
        Write-Host "  FALLO: GetTempPath no resuelve en Linux" -ForegroundColor Red
        exit 1
    }
    Write-Host "  caso 5 (GetTempPath resuelve a $tmp): PASS"
'

echo "DacpacPathLinux: PASS"
