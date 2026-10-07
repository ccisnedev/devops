# Invoke-FlutterBuild.Tests.ps1
# Lo que Invoke-FlutterBuild le pasa a `flutter` con y sin -EnvFile (ADR 0018). `flutter` se
# simula: el mock registra los argumentos, lee el JSON de defines mientras existe y deja el
# artefacto donde lo dejaria el build real.

BeforeAll {
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
    # Pester solo simula comandos que existen: en una maquina sin Flutter se define un stub.
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { function global:flutter {} }

    function New-FlutterProject {
        $dir = Join-Path $TestDrive "app_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'pubspec.yaml') -Value "name: demoapp`nversion: 1.2.3+4" -Encoding UTF8
        return $dir
    }
}

Describe 'Invoke-FlutterBuild' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:proj = New-FlutterProject
        Push-Location $script:proj

        Mock -ModuleName macss-devops flutter {
            $argList = @($args)
            $defineArg = $argList | Where-Object { "$_" -like '--dart-define-from-file=*' }
            $json = if ($defineArg) { Get-Content ("$defineArg" -replace '^--dart-define-from-file=', '') -Raw | ConvertFrom-Json } else { $null }
            $script:calls.Add([pscustomobject]@{ Args = $argList; Defines = $json; DefineFile = ("$defineArg" -replace '^--dart-define-from-file=', '') })

            $flavorIdx = [array]::IndexOf($argList, '--flavor')
            $flavor = if ($flavorIdx -ge 0) { "-$($argList[$flavorIdx + 1])" } else { '' }
            if ($argList[1] -eq 'apk') {
                $out = 'build/app/outputs/flutter-apk'
                New-Item -ItemType Directory -Path $out -Force | Out-Null
                New-Item -ItemType File -Path "$out/app$flavor-release.apk" -Force | Out-Null
            } elseif ($argList[1] -eq 'web') {
                New-Item -ItemType Directory -Path 'build/web' -Force | Out-Null
            }
            $global:LASTEXITCODE = 0
        }
        # No abrir el Explorador durante los tests.
        Mock -ModuleName macss-devops New-Object { throw 'sin GUI' } -ParameterFilter { $ComObject }
    }

    AfterEach { Pop-Location }

    It 'sin -EnvFile compila como siempre: sin defines ni flavor' {
        Invoke-FlutterBuild -Apk 6>$null
        $script:calls | Should -HaveCount 1
        $script:calls[0].Args | Should -Not -Contain '--flavor'
        ($script:calls[0].Args -like '--dart-define-from-file=*') | Should -BeNullOrEmpty
        Test-Path 'release/app_demoapp_v1.2.3.apk' | Should -BeTrue
    }

    It 'con -EnvFile pasa los defines sin las claves MACSS_* y el flavor al APK' {
        Set-Content -Path '.env.uat' -Encoding UTF8 -Value @(
            'APP_ENV=uat', 'IMPULSA_BASE_URL=https://api-uat.example.com',
            'MACSS_FLUTTER_FLAVOR=uat', 'MACSS_DEPLOY_SSH_ALIAS=uat')
        Invoke-FlutterBuild -Apk -EnvFile .env.uat 6>$null

        $call = $script:calls[0]
        $call.Args | Should -Contain '--flavor'
        $call.Args[[array]::IndexOf($call.Args, '--flavor') + 1] | Should -Be 'uat'
        $call.Defines.APP_ENV | Should -Be 'uat'
        $call.Defines.IMPULSA_BASE_URL | Should -Be 'https://api-uat.example.com'
        $call.Defines.PSObject.Properties.Name | Should -Not -Contain 'MACSS_FLUTTER_FLAVOR'
        $call.Defines.PSObject.Properties.Name | Should -Not -Contain 'MACSS_DEPLOY_SSH_ALIAS'
    }

    It 'el APK con flavor lleva el flavor en el nombre' {
        Set-Content -Path '.env.uat' -Value @('APP_ENV=uat', 'MACSS_FLUTTER_FLAVOR=uat') -Encoding UTF8
        Invoke-FlutterBuild -Apk -EnvFile .env.uat 6>$null
        Test-Path 'release/app_demoapp_v1.2.3_uat.apk' | Should -BeTrue
    }

    It 'borra el JSON temporal de defines al terminar' {
        Set-Content -Path '.env.uat' -Value @('APP_ENV=uat') -Encoding UTF8
        Invoke-FlutterBuild -Apk -EnvFile .env.uat 6>$null
        Test-Path $script:calls[0].DefineFile | Should -BeFalse
    }

    It 'web: pasa los defines pero no el flavor (Flutter web no tiene flavors)' {
        Set-Content -Path '.env.uat' -Value @('APP_ENV=uat', 'MACSS_FLUTTER_FLAVOR=uat') -Encoding UTF8
        Invoke-FlutterBuild -Web -EnvFile .env.uat 6>$null
        $script:calls[0].Args | Should -Not -Contain '--flavor'
        $script:calls[0].Defines.APP_ENV | Should -Be 'uat'
        Test-Path 'release/app_demoapp_v1.2.3_web' | Should -BeTrue
    }

    It 'avisa si una clave parece un secreto, sin bloquear' {
        Set-Content -Path '.env.uat' -Value @('APP_ENV=uat', 'MAPS_API_KEY=x') -Encoding UTF8
        Invoke-FlutterBuild -Apk -EnvFile .env.uat -WarningVariable w -WarningAction SilentlyContinue 6>$null
        ($w -join "`n") | Should -BeLike '*MAPS_API_KEY*'
        $script:calls | Should -HaveCount 1
    }

    It 'falla antes de compilar si el env file no existe' {
        { Invoke-FlutterBuild -Apk -EnvFile .env.nope 6>$null } | Should -Throw '*.env.nope*'
        $script:calls | Should -HaveCount 0
    }

    It 'falla si flutter build termina con error' {
        Mock -ModuleName macss-devops flutter { $global:LASTEXITCODE = 1 }
        { Invoke-FlutterBuild -Apk 6>$null } | Should -Throw '*flutter build apk*'
    }
}
