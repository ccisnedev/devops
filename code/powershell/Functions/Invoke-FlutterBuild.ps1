<#
.SYNOPSIS
Compila la aplicación Flutter en diferentes modos.

.DESCRIPTION
El cmdlet `Invoke-FlutterBuild` permite compilar una aplicación Flutter en modo APK, web o Windows. 
Crea una carpeta de lanzamiento si no existe y lee el archivo `pubspec.yaml` para obtener información de la versión.

.PARAMETER Apk
Compila la aplicación en modo APK.

.PARAMETER Web
Compila la aplicación en modo web.

.PARAMETER Windows
Compila la aplicación en modo Windows.

.PARAMETER SplitPerAbi
Compila la aplicación en modo APK con la opción --split-per-abi.

.PARAMETER EnvFile
Env file del entorno (.env, .env.uat, .env.demo, .env.production). Sus claves, salvo las
MACSS_*, llegan al build como dart-defines (`String.fromEnvironment`). Si declara
MACSS_FLUTTER_FLAVOR, el APK se compila con `--flavor` y su nombre lleva el flavor
(app_<nombre>_v<versión>_<flavor>.apk). Lo que entra en el binario se puede leer
descompilándolo: las claves con nombre de secreto (KEY, SECRET, PASSWORD) producen un aviso.
Sin -EnvFile el build es el de siempre (ADR 0018).

.EXAMPLE
Invoke-FlutterBuild
Compila la aplicación Flutter en modo APK por defecto.

.EXAMPLE
Invoke-FlutterBuild -Web
Compila la aplicación Flutter en modo web.

.EXAMPLE
Invoke-FlutterBuild -Apk -SplitPerAbi
Compila la aplicación Flutter en modo APK con la opción --split-per-abi.

.EXAMPLE
Invoke-FlutterBuild -Apk -EnvFile .env.uat
Compila el APK de uat: dart-defines de .env.uat y el flavor de MACSS_FLUTTER_FLAVOR.

.NOTES
Versión: 1.2.0
Autor: @ccisnedev
#>
function Invoke-FlutterBuild {
    [CmdletBinding()]
    param(
        [switch]$Apk,
        [switch]$Web,
        [switch]$Windows,
        [switch]$SplitPerAbi,
        [string]$EnvFile
    )

    # Verificar si no se especifica ninguna plataforma, asumir Android por defecto
    if (-not $Apk -and -not $Web -and -not $Windows) {
        $Apk = $true
    }

    # Verificar si SplitPerAbi está activo pero no se está compilando para APK
    if ($SplitPerAbi -and -not $Apk) {
        Write-Warning "La opción -SplitPerAbi solo es válida para la compilación APK. Será ignorada."
        $SplitPerAbi = $false
    }

    # Env file del entorno (ADR 0018): se lee antes de compilar nada, para fallar pronto.
    $buildEnv = $null
    $defineArgs = @()
    $flavorArgs = @()
    $defineFile = $null
    if ($EnvFile) {
        $buildEnv = Get-FlutterBuildEnv -Path $EnvFile
        Write-Host "Env file: $($buildEnv.Path)" -ForegroundColor Cyan
        $keys = if ($buildEnv.Defines.Count) { $buildEnv.Defines.Keys -join ', ' } else { '(ninguno)' }
        Write-Host "Dart-defines: $keys" -ForegroundColor Cyan
        if ($buildEnv.Flavor) {
            if ($Apk) {
                Write-Host "Flavor: $($buildEnv.Flavor)" -ForegroundColor Cyan
                $flavorArgs = @('--flavor', $buildEnv.Flavor)
            } else {
                Write-Host "Flavor: $($buildEnv.Flavor) (solo aplica al APK)" -ForegroundColor DarkGray
            }
        }
        foreach ($key in $buildEnv.SecretLikeKeys) {
            Write-Warning "La clave '$key' parece un secreto y quedará dentro del binario, que se puede descompilar."
        }
        if ($buildEnv.Defines.Count) {
            $defineFile = New-FlutterDefineFile -Defines $buildEnv.Defines
            $defineArgs = @("--dart-define-from-file=$defineFile")
        }
    }

    try {
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

        # Buscar la línea que contiene el nombre de la aplicación
        $nameLine = $content | Where-Object { $_ -match "name:" }

        # Extraer el nombre de la aplicación
        $name = $nameLine -replace "name: ", "" -replace '"', ''

        # Compilar para APK
        if ($Apk) {
            $flavorSuffix = if ($buildEnv -and $buildEnv.Flavor) { "_$($buildEnv.Flavor)" } else { '' }
            $apkName = "app_${name}_v${version}${flavorSuffix}.apk"

            if (Test-Path -Path "./release/$apkName") {
                Remove-Item -Path "./release/$apkName"
            }

            if ($SplitPerAbi) {
                Write-Host "Iniciando la construcción del APK con --split-per-abi..." -ForegroundColor Yellow
                flutter build apk --release --obfuscate --split-debug-info=build/debug_info/ --split-per-abi @flavorArgs @defineArgs
                if ($LASTEXITCODE -ne 0) { throw "flutter build apk falló (código $LASTEXITCODE)." }
            } else {
                Write-Host "Iniciando la construcción del APK..." -ForegroundColor Yellow
                flutter build apk --release --obfuscate --split-debug-info=build/debug_info/ @flavorArgs @defineArgs
                if ($LASTEXITCODE -ne 0) { throw "flutter build apk falló (código $LASTEXITCODE)." }
            }

            # Con -SplitPerAbi se toma solo el de arm64-v8a
            $flavorName = if ($buildEnv) { $buildEnv.Flavor } else { $null }
            $builtApk = Resolve-FlutterApkOutput -OutputDir "./build/app/outputs/flutter-apk" `
                -Flavor $flavorName -SplitPerAbi:$SplitPerAbi
            Move-Item -Path $builtApk -Destination "./release/$apkName"
            Write-Host "APK generado exitosamente ./$apkName" -ForegroundColor Green
        }

        # Compilar para Web
        if ($Web) {
            Write-Host "Iniciando la construcción de la versión web..." -ForegroundColor Yellow
            flutter build web @defineArgs
            if ($LASTEXITCODE -ne 0) { throw "flutter build web falló (código $LASTEXITCODE)." }

            # Mover y renombrar la carpeta
            Move-Item -Path "./build/web" -Destination "./release/app_${name}_v${version}_web"
        }

        # Compilar para Windows
        if ($Windows) {
            Write-Host "Iniciando la construcción de la versión Windows..." -ForegroundColor Yellow
            flutter build windows @defineArgs
            if ($LASTEXITCODE -ne 0) { throw "flutter build windows falló (código $LASTEXITCODE)." }

            # Mover y renombrar la carpeta
            Move-Item -Path "./build/windows" -Destination "./release/app_${name}_v${version}_windows"
        }

        # Abrir carpeta release en Windows (solo si hay GUI disponible)
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            try {
                $openWindows = New-Object -ComObject Shell.Application
            
                $folderPath = (Get-Item ".\release").FullName
                $normalizedFolderPath = "file:///$($folderPath.Replace('\', '/'))"
            
                foreach ($window in $openWindows.Windows()) {
                    $normalizedWindowURL = $window.LocationURL -replace '%20', ' '
                    if ($normalizedWindowURL -eq $normalizedFolderPath) {
                        $window.Quit()
                        break
                    }
                }
            
                $window = $openWindows.ShellExecute("explorer.exe", $folderPath, "", "open", 1)
            } catch {
                # Silenciar si no hay GUI (ej: CI/CD)
            }
        }

        Write-Host "=======================================" -ForegroundColor Yellow
    } finally {
        if ($defineFile -and (Test-Path -LiteralPath $defineFile)) {
            Remove-Item -LiteralPath $defineFile -Force
        }
    }
}