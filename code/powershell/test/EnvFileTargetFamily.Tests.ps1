# EnvFileTargetFamily.Tests.ps1
# Tests de superficie de la familia de cmdlets de despliegue (ADR 0010, y REQ-3 de ADR 0007).
#
# ADR 0004 fijó un solo modelo mental: "¿qué entorno? = ¿qué env file?". Estos tests verifican que
# la interfaz de los cinco cmdlets lo cumple de forma uniforme, y que las dos asimetrías
# deliberadas siguen siendo deliberadas:
#
#   - `Invoke-PgSchema` recibe `-EnvFile` pero NO `MACSS_DEPLOY_SERVER`: su destino es una conexión
#     PostgreSQL, no un alias SSH al que saltar (ADR 0010 §2).
#   - `Publish-FlutterWeb` no sube ningún env file al servidor, porque la web es estática
#     (ADR 0007 §2). `Publish-DockerStack` sí lo sube, y por eso debe filtrar `MACSS_DEPLOY_*`.
#
# Cubre REQ-5 a REQ-9 de ADR 0010.

BeforeAll {
    Remove-Module 'macss-devops' -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force

    $script:FunctionsDir = Join-Path $PSScriptRoot '..\Functions'

    function Get-ParamSetsWithEnvFile {
        param([string]$CmdletName)
        $cmd = Get-Command $CmdletName
        if (-not $cmd.Parameters.ContainsKey('EnvFile')) { return @() }
        return @($cmd.Parameters['EnvFile'].ParameterSets.Keys)
    }

    # Las aserciones sobre el fuente se hacen contra un booleano, no contra el texto. Un
    # `Should -Match` sobre un archivo de 400 líneas vuelca el archivo entero al fallar y
    # vuelve el informe ilegible.
    function Test-FunctionSource {
        param([string]$CmdletName, [string]$Pattern)
        $src = Get-Content (Join-Path $script:FunctionsDir "$CmdletName.ps1") -Raw -Encoding UTF8
        return [bool]($src -match $Pattern)
    }

    function Test-FileContent {
        param([string]$Path, [string]$Pattern)
        $src = Get-Content $Path -Raw -Encoding UTF8
        return [bool]($src -match $Pattern)
    }
}

Describe "REQ-5: los cmdlets con destino SSH exponen -EnvFile" {

    # Publish-NodeApi ya lo cumple desde ADR 0004: es la referencia contra la que se mide el resto.
    It "<Cmdlet> declara el parámetro -EnvFile" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
    ) {
        (Get-Command $Cmdlet).Parameters.Keys | Should -Contain 'EnvFile'
    }

    It "<Cmdlet> ofrece -EnvFile tanto en Plan como en Apply" -ForEach @(
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
    ) {
        $sets = Get-ParamSetsWithEnvFile -CmdletName $Cmdlet
        $sets | Should -Contain 'Plan'
        $sets | Should -Contain 'Apply'
    }

    # Producción nunca es el default (ADR 0010 §4): un -Apply desnudo apunta a .env.
    It "<Cmdlet> usa '.env' como valor por defecto de -EnvFile" -ForEach @(
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
    ) {
        Test-FunctionSource -CmdletName $Cmdlet -Pattern "\`$EnvFile\s*=\s*'\.env'" | Should -BeTrue
    }
}

Describe "REQ-5: el destino deja de salir del archivo versionado" {

    It "Publish-FlutterWeb ya no resuelve el destino desde publish.yaml" {
        Test-FunctionSource -CmdletName 'Publish-FlutterWeb' -Pattern '\$server\s*=\s*\$deployConfig\.server' | Should -BeFalse
    }

    It "Publish-FlutterWeb usa el helper compartido" {
        Test-FunctionSource -CmdletName 'Publish-FlutterWeb' -Pattern 'Resolve-DeployTargetFromEnv' | Should -BeTrue
    }

    It "Publish-DockerStack usa el helper compartido" {
        Test-FunctionSource -CmdletName 'Publish-DockerStack' -Pattern 'Resolve-DeployTargetFromEnv' | Should -BeTrue
    }
}

Describe "REQ-6: Invoke-PgSchema gana -EnvFile y nada más" {

    It "declara el parámetro -EnvFile" {
        (Get-Command Invoke-PgSchema).Parameters.Keys | Should -Contain 'EnvFile'
    }

    It "ofrece -EnvFile en los cuatro modos" {
        $sets = Get-ParamSetsWithEnvFile -CmdletName 'Invoke-PgSchema'
        foreach ($set in @('Plan', 'Apply', 'Dump', 'Script')) {
            $sets | Should -Contain $set
        }
    }

    It "usa '.env' como valor por defecto" {
        Test-FunctionSource -CmdletName 'Invoke-PgSchema' -Pattern "\`$EnvFile\s*=\s*'\.env'" | Should -BeTrue
    }

    # Su destino son las variables PG* del propio env. Un alias SSH sería inventar un salto
    # que no existe (ADR 0010 §2).
    It "NO adopta MACSS_DEPLOY_SERVER en ninguna ruta de código" {
        Test-FunctionSource -CmdletName 'Invoke-PgSchema' -Pattern 'MACSS_DEPLOY_SERVER' | Should -BeFalse
    }

    It "deja de leer '.env' de forma fija" {
        Test-FunctionSource -CmdletName 'Invoke-PgSchema' -Pattern "Read-DotEnv\s+-Path\s+'\.env'" | Should -BeFalse
    }
}

Describe "REQ-7 y REQ-8: qué env viaja al servidor y qué no" {

    # Publish-DockerStack sube el .env como env-file del stack: las claves de despliegue no
    # son config de runtime y no deben viajar (ADR 0004 §2).
    It "Publish-DockerStack filtra las claves MACSS_DEPLOY_* del env que sube" {
        Test-FunctionSource -CmdletName 'Publish-DockerStack' -Pattern 'Remove-DeployOnlyEnvKeys' | Should -BeTrue
    }

    # La web es estática: no hay env que subir, así que tampoco hay filtrado que hacer.
    It "Publish-FlutterWeb no sube ningún env file" {
        Test-FunctionSource -CmdletName 'Publish-FlutterWeb' -Pattern 'Remove-DeployOnlyEnvKeys' | Should -BeFalse
    }
}

Describe "REQ-9: -Init siembra el destino en el env, no en el archivo versionado" {

    It "el template de stack.yaml ya no trae 'server'" {
        $template = Join-Path $PSScriptRoot '..\Resources\Publish-DockerStack\templates\stack.yaml'
        $template | Should -Exist
        Test-FileContent -Path $template -Pattern '(?m)^\s*server\s*:' | Should -BeFalse
    }

    It "Publish-DockerStack -Init siembra MACSS_DEPLOY_SERVER en el .env que genera" {
        Test-FunctionSource -CmdletName 'Publish-DockerStack' -Pattern 'MACSS_DEPLOY_SERVER=' | Should -BeTrue
    }
}
