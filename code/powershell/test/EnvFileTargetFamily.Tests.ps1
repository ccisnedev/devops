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
# Cubre REQ-6 a REQ-10 de ADR 0010.

BeforeAll {
    # Remove-Module por nombre quita UNA version. Si el modulo publicado esta instalado en
    # PSModulePath, puede quedar cargado junto al del repo y ganar la resolucion de nombres: la
    # suite pasaria a medir el modulo instalado en vez del codigo bajo prueba. -All las quita todas.
    Get-Module 'macss-devops' -All | Remove-Module -Force -ErrorAction SilentlyContinue
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

Describe "REQ-6: los cmdlets con destino SSH exponen -EnvFile" {

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

Describe "REQ-6: el destino deja de salir del archivo versionado" {

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

Describe "REQ-7: Invoke-PgSchema gana -EnvFile y nada más" {

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
    It "NO adopta ningún alias SSH en ninguna ruta de código" {
        Test-FunctionSource -CmdletName 'Invoke-PgSchema' -Pattern 'MACSS_DEPLOY_SSH_ALIAS|MACSS_DEPLOY_SERVER' | Should -BeFalse
    }

    It "deja de leer '.env' de forma fija" {
        Test-FunctionSource -CmdletName 'Invoke-PgSchema' -Pattern "Read-DotEnv\s+-Path\s+'\.env'" | Should -BeFalse
    }
}

Describe "REQ-8 y REQ-9: qué env viaja al servidor y qué no" {

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

Describe "REQ-10: -Init siembra el destino en el env, no en el archivo versionado" {

    It "el template de stack.yaml ya no trae 'server'" {
        $template = Join-Path $PSScriptRoot '..\Resources\Publish-DockerStack\templates\stack.yaml'
        $template | Should -Exist
        Test-FileContent -Path $template -Pattern '(?m)^\s*server\s*:' | Should -BeFalse
    }

    It "Publish-DockerStack -Init siembra MACSS_DEPLOY_SERVER en el .env que genera" {
        Test-FunctionSource -CmdletName 'Publish-DockerStack' -Pattern 'MACSS_DEPLOY_SSH_ALIAS=' | Should -BeTrue
    }
}

Describe "REQ-6: la clave nueva reemplaza a la vieja en toda la familia SSH" {

    # Publish-NodeApi es el que ya tenia el patron: tambien migra al nombre nuevo.
    It "<Cmdlet> referencia MACSS_DEPLOY_SSH_ALIAS" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
    ) {
        Test-FunctionSource -CmdletName $Cmdlet -Pattern 'MACSS_DEPLOY_SSH_ALIAS' | Should -BeTrue
    }

    # La clave vieja solo puede sobrevivir dentro del helper compartido, que la detecta para
    # fallar con instrucciones. En los cmdlets no debe quedar ninguna ruta que la lea como destino.
    It "<Cmdlet> ya no lee MACSS_DEPLOY_SERVER como destino" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
    ) {
        Test-FunctionSource -CmdletName $Cmdlet -Pattern 'MACSS_DEPLOY_SERVER' | Should -BeFalse
    }
}

Describe "REQ-10: el template de publish.yaml tampoco trae 'server'" {

    It "el template de Publish-FlutterWeb no declara 'server:'" {
        $template = Join-Path $PSScriptRoot '..\Resources\Publish-FlutterWeb\templates\publish.yaml'
        $template | Should -Exist
        Test-FileContent -Path $template -Pattern '(?m)^\s*server\s*:' | Should -BeFalse
    }
}

Describe "REQ-10: -Init de Publish-FlutterWeb siembra el env y lo gitignora" {

    # Hueco detectado al migrar los repos reales: un proyecto Flutter no suele tener .env, asi que
    # su .gitignore tampoco lo cubre. Sembrar el destino sin gitignorarlo deja el alias camino de
    # quedar versionado, que es justo lo que ADR 0010 vino a evitar. ADR 0007 §4 ya lo exigia.
    BeforeAll {
        $script:initDir = Join-Path ([IO.Path]::GetTempPath()) ("fwinit_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:initDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:initDir 'pubspec.yaml') -Value "name: t`nversion: 1.0.0" -Encoding UTF8
        Push-Location $script:initDir
        try { Publish-FlutterWeb -Init *> $null } finally { Pop-Location }
    }
    AfterAll { Remove-Item -LiteralPath $script:initDir -Recurse -Force -ErrorAction SilentlyContinue }

    It "crea <File> con la clave de destino" -ForEach @(
        @{ File = '.env' }
        @{ File = '.env.production' }
    ) {
        $p = Join-Path $script:initDir $File
        $p | Should -Exist
        [bool]((Get-Content $p -Raw) -match '(?m)^MACSS_DEPLOY_SSH_ALIAS=') | Should -BeTrue
    }

    It "deja la clave vacia: producir un destino por defecto seria adivinar" {
        [bool]((Get-Content (Join-Path $script:initDir '.env') -Raw) -match '(?m)^MACSS_DEPLOY_SSH_ALIAS=\s*$') |
            Should -BeTrue
    }

    It "agrega .env al .gitignore del proyecto" {
        $gi = Join-Path $script:initDir '.gitignore'
        $gi | Should -Exist
        [bool]((Get-Content $gi -Raw) -match '(?m)^\.env$') | Should -BeTrue
    }
}
