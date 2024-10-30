<#
.SYNOPSIS
Compila la aplicación Flutter en diferentes modos.

.DESCRIPTION
El cmdlet `Build-FlutterApp` permite compilar una aplicación Flutter en modo APK o web. 
Crea una carpeta de lanzamiento si no existe y lee el archivo `pubspec.yaml` para obtener información de la versión.

.PARAMETER web
Compila la aplicación en modo web.

.EXAMPLE
Build-FlutterApp -web
Compila la aplicación Flutter en modo apk y tambien en modo web.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Build-FlutterApp {
    # Parámetros
    [CmdletBinding()]
    param(
        [switch]$web
    )
    # Verificar si existe la carpeta release y si no existe crearla
    if (!(Test-Path -Path "./release")) {
        New-Item -Path "./release" -ItemType Directory
    }

    # Leer el archivo pubspec.yaml
    $content = Get-Content -Path ./pubspec.yaml

    # Buscar la línea que contiene la versión
    $versionLine = $content | Where-Object { $_ -match "version:" }

    # Extraer el número de versión
    $version = $versionLine -replace "version: ", "" -replace '"', ''
    Write-Host "Versión: $version" -ForegroundColor Cyan
    
    # split en + para tomar solo la primera parte
    $version = $version.Split('+')[0]
    
    # Quita los puntos de la versión
    # $version = $version.Replace(".", "")
    
    #Buscar la línea que contiene el nombre de la aplicación
    $nameLine = $content | Where-Object { $_ -match "name:" }

    # Extraer el nombre de la aplicación
    $name = $nameLine -replace "name: ", "" -replace '"', ''

    # Construir el nombre del archivo APK
    $apkName = "app_${name}_v${version}.apk"
    Write-Host "Nombre del APK: $apkName" -ForegroundColor Green

    # Generar el APK
    Write-Host "Iniciando la construcción del APK..." -ForegroundColor Yellow
    flutter build apk

    # Borrar "./release/$apkName" si es que existe
    if (Test-Path -Path "./release/$apkName") {
        Remove-Item -Path "./release/$apkName"
    }

    # Mover y renombrar el APK
    Move-Item -Path "./build/app/outputs/flutter-apk/app-release.apk" -Destination "./release/$apkName"

    # Mostrar la ruta del APK
    Write-Host "APK generado exitosamente ./$apkName" -ForegroundColor Green

    # Generar versión web
    if ($web.IsPresent) {
        # Write-Host "Iniciando la construcción de la versión web..." -ForegroundColor Yellow
        flutter build web

        # Mover y renombrar la carpeta
        Move-Item -Path "./build/web" -Destination "./release/app_${name}_v${version}_web"
    }

    # Abrir la carpeta "release" o ponerla en primer plano
    $folderPath = (Get-Item ".\release").FullName
    $openWindows = New-Object -ComObject Shell.Application
    $found = $false

    foreach ($window in $openWindows.Windows()) {
        if ($window.LocationURL -eq "file:///$($folderPath.Replace('\', '/'))") {
            $window.Visible = $true
            # $window.Focus()
            $found = $true
            break
        }
    }

    if (-not $found) {
        explorer.exe $folderPath
    }

    Write-Host "=======================================" -ForegroundColor Yellow
}