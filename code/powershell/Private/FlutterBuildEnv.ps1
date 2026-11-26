# FlutterBuildEnv.ps1
# El env file de una app Flutter (ADR 0018): de .env / .env.uat / .env.demo / .env.production
# salen los dart-defines del build y, opcionalmente, el flavor de Android.
#
#   Get-FlutterBuildEnv       — lee el archivo y separa defines, flavor y claves sospechosas.
#   New-FlutterDefineFile     — escribe los defines a un JSON temporal para --dart-define-from-file.
#   Resolve-FlutterApkOutput  — encuentra el APK que dejo Gradle (el nombre cambia con el flavor).
#   Test-FlutterEnvContract   — compara el env file con el .env.example del proyecto (contrato).
#
# Las claves MACSS_* son de las herramientas (destino de despliegue, flavor) y nunca llegan al
# binario. Todo lo demas SI llega, y un binario de Flutter se puede descompilar: por eso las
# claves con nombre de secreto producen un aviso.

# Nombres que delatan un secreto. Solo avisan: el nombre no prueba nada (KEYBOARD_LAYOUT no
# es un secreto) y bloquear obligaria a renombrar claves legitimas.
$script:FlutterSecretLikeKeyPattern = '(?i)(KEY|SECRET|PASSWORD)'

function Get-FlutterBuildEnv {
    <#
    .SYNOPSIS
        Lee el env file de un build de Flutter y devuelve defines, flavor y claves sospechosas.
    .DESCRIPTION
        Falla si el archivo no existe: un -EnvFile mal escrito no puede terminar en un build
        sin configuracion que apunta a un entorno por defecto.
    .OUTPUTS
        [pscustomobject] con Path, Flavor (o $null), Defines (ordered, por nombre) y
        SecretLikeKeys (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontro el env file '$Path'. Cree el archivo o corrija -EnvFile."
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    $vars = (Read-DotEnv -Path $resolved).Env

    $flavor = $null
    if ($vars.ContainsKey('MACSS_FLUTTER_FLAVOR') -and "$($vars['MACSS_FLUTTER_FLAVOR'])".Trim()) {
        $flavor = "$($vars['MACSS_FLUTTER_FLAVOR'])".Trim()
        # Gradle deriva tareas y carpetas del nombre: un espacio o un guion rompen el build
        # con un error que no menciona el env file.
        if ($flavor -notmatch '^[A-Za-z][A-Za-z0-9]*$') {
            throw "MACSS_FLUTTER_FLAVOR='$flavor' en '$Path' no es un nombre de flavor valido " +
                  "(letras y digitos, empezando por letra)."
        }
    }

    $defines = [ordered]@{}
    foreach ($key in ($vars.Keys | Where-Object { $_ -notlike 'MACSS_*' } | Sort-Object)) {
        $defines[$key] = [string]$vars[$key]
    }
    $secretLike = @($defines.Keys | Where-Object { $_ -match $script:FlutterSecretLikeKeyPattern })

    return [pscustomobject]@{
        Path           = $resolved
        Flavor         = $flavor
        Defines        = $defines
        SecretLikeKeys = [string[]]$secretLike
    }
}

function New-FlutterDefineFile {
    <#
    .SYNOPSIS
        Escribe los defines a un JSON temporal y devuelve su ruta. El llamador lo borra.
    .DESCRIPTION
        JSON y no el env file original: el original lleva las claves MACSS_*, que no deben
        llegar al binario.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defines
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("macss-dart-defines-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $json = if ($Defines.Count -eq 0) { '{}' } else { $Defines | ConvertTo-Json -Depth 2 }
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Resolve-FlutterApkOutput {
    <#
    .SYNOPSIS
        Ruta del APK que produjo `flutter build apk` en OutputDir.
    .DESCRIPTION
        Sin flavor: app-release.apk / app-arm64-v8a-release.apk. Con flavor 'uat':
        app-uat-release.apk / app-arm64-v8a-uat-release.apk. Falla nombrando lo que hay en la
        carpeta si no lo encuentra, en vez de un Move-Item sobre una ruta inexistente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$Flavor,
        [switch]$SplitPerAbi
    )

    $parts = @('app')
    if ($SplitPerAbi) { $parts += 'arm64-v8a' }
    if ($Flavor) { $parts += $Flavor.ToLowerInvariant() }
    $parts += 'release.apk'
    $expected = Join-Path $OutputDir ($parts -join '-')

    if (Test-Path -LiteralPath $expected) { return $expected }

    $found = @(Get-ChildItem -LiteralPath $OutputDir -Filter '*.apk' -ErrorAction SilentlyContinue |
               ForEach-Object Name)
    $list = if ($found.Count) { $found -join ', ' } else { '(ninguno)' }
    throw "No se encontro el APK esperado '$expected'. APKs en la carpeta: $list"
}

function Test-FlutterEnvContract {
    <#
    .SYNOPSIS
        Problemas del env file de un build contra el .env.example del proyecto (ADR 0018 §8).
    .DESCRIPTION
        El .env.example versionado es el contrato: la app declara ahi las variables que lee con
        String.fromEnvironment. Sin .env.example no hay contrato y no hay problemas: el build de
        siempre. Con .env.example, cada clave que no sea MACSS_* tiene que llegar al build con un
        valor no vacio.

        Existe porque el fallo es silencioso: un String.fromEnvironment sin define devuelve '' y
        `flutter build` compila sin error. Sin esta comprobacion, la app saldria con URLs vacias y
        el despliegue en verde.

        Solo compara NOMBRES y si el valor esta vacio. Nunca devuelve valores.
    .OUTPUTS
        string[] con un problema por elemento; vacio si cumple. Envolver en @() al contar.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        $BuildEnv
    )

    $examplePath = Join-Path $ProjectRoot '.env.example'
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) { return @() }

    $required = @(Get-DotEnvKeys -Lines @(Get-Content -LiteralPath $examplePath) |
                  Where-Object { $_ -notlike 'MACSS_*' })
    if ($required.Count -eq 0) { return @() }

    if (-not $BuildEnv) {
        return @("La app declara variables en .env.example ($($required -join ', ')) y el build " +
                 "no recibe env file. Use -EnvFile <archivo> (.env, .env.uat, .env.production).")
    }

    $file = Split-Path -Leaf $BuildEnv.Path
    $problems = [System.Collections.Generic.List[string]]::new()
    $missing = @($required | Where-Object { -not $BuildEnv.Defines.Contains($_) })
    if ($missing.Count) {
        $problems.Add("Faltan en $file claves declaradas en .env.example: $($missing -join ', ').")
    }
    $empty = @($required | Where-Object {
        $BuildEnv.Defines.Contains($_) -and -not "$($BuildEnv.Defines[$_])".Trim()
    })
    if ($empty.Count) {
        $problems.Add("Estan vacias en ${file}: $($empty -join ', '). " +
                      "String.fromEnvironment las leeria como '' sin que el build falle.")
    }
    return $problems.ToArray()
}
