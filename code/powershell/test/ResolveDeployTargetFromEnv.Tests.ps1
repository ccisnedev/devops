# ResolveDeployTargetFromEnv.Tests.ps1
# Tests del helper compartido que resuelve el destino de despliegue (ADR 0010).
#
# `Resolve-DeployTargetFromEnv` concentra el patrón que ADR 0004 fijó y que hoy `Publish-NodeApi`
# resuelve en línea: el destino sale del env file gitignored elegido con `-EnvFile`, no de un
# archivo versionado. Lo consumen `Publish-FlutterWeb` y `Publish-DockerStack`.
#
# Es puro salvo por la lectura del env file, así que se testea con directorios temporales y sin
# servidor. El salto SSH real se cubre en los tests de contenedor.
#
# Cubre REQ-1 a REQ-4 de ADR 0010.

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
}

Describe "Resolve-DeployTargetFromEnv — REQ-1: el destino sale del env file" {

    It "devuelve MACSS_DEPLOY_SERVER del env file por defecto (.env)" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=uat`nOTRA=cosa"
        Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-FlutterWeb' |
            Should -Be 'uat'
    }

    It "honra el env file indicado con -EnvFile" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=prod" -EnvFileName '.env.production'
        Resolve-DeployTargetFromEnv -ProjectRoot $root -EnvFile '.env.production' -Cmdlet 'Publish-FlutterWeb' |
            Should -Be 'prod'
    }

    It "recorta espacios alrededor del alias" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=  uat  "
        Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-DockerStack' |
            Should -Be 'uat'
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-2: fallback al archivo versionado, con deprecación" {

    It "cae a LegacyServer cuando el env file no existe" {
        $root = New-TestProject
        $w = @()
        $target = Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' `
            -Cmdlet 'Publish-FlutterWeb' -WarningVariable w -WarningAction SilentlyContinue
        $target | Should -Be 'prod'
        $w | Should -Not -BeNullOrEmpty
    }

    It "cae a LegacyServer cuando el env file existe pero no define la clave" {
        $root = New-TestProject -EnvContent "ALGO=1`nOTRO=2"
        $target = Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' `
            -Cmdlet 'Publish-DockerStack' -WarningAction SilentlyContinue
        $target | Should -Be 'prod'
    }

    It "el warning nombra el cmdlet y la clave que debería usarse" {
        $root = New-TestProject
        $w = @()
        Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' `
            -Cmdlet 'Publish-DockerStack' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        ($w -join ' ') | Should -Match 'Publish-DockerStack'
        ($w -join ' ') | Should -Match 'MACSS_DEPLOY_SERVER'
    }

    It "no emite deprecación cuando el destino vino del env file" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=uat"
        $w = @()
        Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' `
            -Cmdlet 'Publish-FlutterWeb' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        $w | Should -BeNullOrEmpty
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-3: fail-fast accionable" {

    It "lanza cuando no hay env file ni legacy" {
        $root = New-TestProject
        { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-FlutterWeb' } |
            Should -Throw
    }

    It "el error nombra el env file buscado y la clave faltante" {
        $root = New-TestProject -EnvContent "ALGO=1"
        $err = $null
        try {
            Resolve-DeployTargetFromEnv -ProjectRoot $root -EnvFile '.env.production' -Cmdlet 'Publish-FlutterWeb'
        } catch { $err = $_.Exception.Message }
        $err | Should -Match '\.env\.production'
        $err | Should -Match 'MACSS_DEPLOY_SERVER'
    }

    It "un MACSS_DEPLOY_SERVER vacío no cuenta como destino" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER="
        { Resolve-DeployTargetFromEnv -ProjectRoot $root -Cmdlet 'Publish-DockerStack' } |
            Should -Throw
    }
}

Describe "Resolve-DeployTargetFromEnv — REQ-4: precedencia" {

    It "el env file gana sobre el archivo versionado cuando ambos declaran destino" {
        $root = New-TestProject -EnvContent "MACSS_DEPLOY_SERVER=uat"
        Resolve-DeployTargetFromEnv -ProjectRoot $root -LegacyServer 'prod' `
            -Cmdlet 'Publish-FlutterWeb' -WarningAction SilentlyContinue |
            Should -Be 'uat'
    }
}
