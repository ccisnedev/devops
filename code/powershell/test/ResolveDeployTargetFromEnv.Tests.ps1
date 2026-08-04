# ResolveDeployTargetFromEnv.Tests.ps1
# Tests del helper compartido que resuelve el destino de despliegue (ADR 0010).
#
# `Resolve-DeployTargetFromEnv` concentra el patrón que ADR 0004 fijó: el destino sale del env file
# gitignored elegido con `-EnvFile`, no de un archivo versionado. Lo consumen los tres cmdlets cuyo
# destino es una máquina a la que se salta por SSH: Publish-NodeApi, Publish-FlutterWeb y
# Publish-DockerStack.
#
# El contrato de compatibilidad de ADR 0010 §5 NO es un fallback: los mecanismos deprecados
# **fallan**, con un mensaje que dice qué poner en su lugar. Un fallback que sigue funcionando
# perpetúa la deuda, porque nadie migra lo que no le impide trabajar. Buena parte de estos tests
# verifica precisamente que el fallo ocurre y que el mensaje alcanza para migrar sin leer el ADR.
#
# Es puro salvo por la lectura del env file, así que se testea con directorios temporales y sin
# servidor. El salto SSH real se cubre en los tests de contenedor.
#
# Cubre REQ-1 a REQ-5 de ADR 0010.

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"

    function New-TestProject {
        param(
            [string]$EnvContent,
            [string]$EnvFileName = '.env'
        )
        $root = Join-Path ([IO.Path]::GetTempPath()) ("macss_rdtfe_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        if ($PSBoundParameters.ContainsKey('EnvContent')) {
            Set-Content -Path (Join-Path $root $EnvFileName) -Value $EnvContent -Encoding UTF8
        }
        return $root
    }

    # Devuelve el mensaje de error, o $null si no lanzó. Evita `Should -Throw -ExpectedMessage`,
    # que obliga a acertar el texto entero; aquí interesa comprobar que el mensaje CONTIENE lo
    # necesario para migrar, no su redacción exacta.
    function Get-ThrownMessage {
        param([scriptblock]$Action)
        try { & $Action | Out-Null; return $null } catch { return $_.Exception.Message }
    }

    # Un `Should -Throw` a secas se pone verde cuando la función todavía no existe: la
    # CommandNotFoundException satisface la aserción y el test aprueba por la razón equivocada.
    # En TDD eso es peor que un rojo, porque oculta trabajo pendiente. Este helper exige que el
    # fallo venga de la validación y no de la ausencia del comando.
    function Get-ValidationError {
        param([scriptblock]$Action)
        $msg = Get-ThrownMessage $Action
        if ($null -eq $msg) {
            throw "Se esperaba un error de validación y no se lanzó ninguno."
        }
        if ($msg -match 'is not recognized as a name of a cmdlet|no se reconoce como') {
            throw "Falló por comando inexistente, no por la validación esperada: $msg"
        }
        return $msg
    }
}

Describe "Resolve-DeployTargetFromEnv — el helper existe" {

    # Guarda de los `Should -Throw` de abajo: sin esto, media suite aprueba en RED.
    It "está disponible tras cargar PublishHelpers" {
        Get-Command Resolve-DeployTargetFromEnv -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-1: el destino sale del env file" {

    It "devuelve MACSS_DEPLOY_SSH_ALIAS del env file por defecto (.env)" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS=uat`nOTRA=cosa"
        Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-FlutterWeb' |
            Should -Be 'uat'
    }

    It "honra el env file indicado con -EnvFile" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS=prod" -EnvFileName '.env.production'
        Resolve-DeployTargetFromEnv -ProjectRoot $root -EnvFile '.env.production' -Cmdlet 'Publish-FlutterWeb' |
            Should -Be 'prod'
    }

    It "recorta espacios alrededor del alias" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS=  uat  "
        Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-DockerStack' |
            Should -Be 'uat'
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-2: fail-fast accionable cuando no hay destino" {

    It "lanza cuando el env file no existe" {
        $root = New-TestProject
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-FlutterWeb' } |
            Should -Not -BeNullOrEmpty
    }

    It "el error nombra el env file buscado y la clave esperada" {
        $root = New-TestProject -EnvContent "ALGO=1"
        $msg = Get-ThrownMessage {
            Resolve-DeployTargetFromEnv -ProjectRoot $root -EnvFile '.env.production' -Cmdlet 'Publish-FlutterWeb'
        }
        $msg | Should -Match '\.env\.production'
        $msg | Should -Match 'MACSS_DEPLOY_SSH_ALIAS'
    }

    It "un MACSS_DEPLOY_SSH_ALIAS vacío no cuenta como destino" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS="
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-DockerStack' } |
            Should -Not -BeNullOrEmpty
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-3: la clave vieja falla, no se acepta" {

    It "lanza cuando el env declara MACSS_DEPLOY_SERVER en lugar de la clave nueva" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=prod"
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-NodeApi' } |
            Should -Not -BeNullOrEmpty
    }

    It "el mensaje alcanza para migrar sin abrir el ADR: clave vieja, clave nueva y archivo" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=prod" -EnvFileName '.env.production'
        $msg = Get-ThrownMessage {
            Resolve-DeployTargetFromEnv -ProjectRoot $root -EnvFile '.env.production' -Cmdlet 'Publish-NodeApi'
        }
        $msg | Should -Match 'MACSS_DEPLOY_SERVER'
        $msg | Should -Match 'MACSS_DEPLOY_SSH_ALIAS'
        $msg | Should -Match '\.env\.production'
    }

    It "el mensaje nombra el cmdlet que falló" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=prod"
        $msg = Get-ThrownMessage {
            Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-DockerStack'
        }
        $msg | Should -Match 'Publish-DockerStack'
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-4: 'server:' en el archivo versionado falla" {

    It "lanza cuando el archivo versionado declara el destino" {
        $root = New-TestProject -EnvContent "ALGO=1"
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' -Cmdlet 'Publish-FlutterWeb' } |
            Should -Not -BeNullOrEmpty
    }

    It "el mensaje indica mover el valor al env file, y no lo usa como destino" {
        $root = New-TestProject -EnvContent "ALGO=1"
        $msg = Get-ThrownMessage {
            Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' -Cmdlet 'Publish-FlutterWeb'
        }
        $msg | Should -Match 'server'
        $msg | Should -Match 'MACSS_DEPLOY_SSH_ALIAS'
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-5: la coexistencia es ambigua y también falla" {

    It "lanza cuando el env declara la clave nueva Y la vieja" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS=uat`nMACSS_DEPLOY_SERVER=prod"
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-NodeApi' } |
            Should -Not -BeNullOrEmpty
    }

    It "lanza cuando el env declara la clave nueva y el archivo versionado declara 'server:'" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SSH_ALIAS=uat"
        Get-ValidationError { Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' -Cmdlet 'Publish-FlutterWeb' } |
            Should -Not -BeNullOrEmpty
    }
}
