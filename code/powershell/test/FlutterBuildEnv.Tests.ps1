# FlutterBuildEnv.Tests.ps1
# El env file de un build de Flutter (ADR 0018): que defines llegan al binario, que flavor se
# usa, que claves avisan, y donde deja Gradle el APK segun el flavor.

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
    . "$PSScriptRoot/../Private/FlutterBuildEnv.ps1"

    function New-EnvFile {
        param([string[]]$Lines)
        $path = Join-Path $TestDrive ".env.$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Set-Content -Path $path -Value $Lines -Encoding UTF8
        return $path
    }
}

Describe 'Get-FlutterBuildEnv' {
    It 'falla si el archivo no existe, nombrando la ruta' {
        { Get-FlutterBuildEnv -Path (Join-Path $TestDrive '.env.nope') } | Should -Throw '*.env.nope*'
    }

    It 'pasa como defines todas las claves salvo las MACSS_*' {
        $f = New-EnvFile @(
            '# comentario',
            'APP_ENV=uat',
            'IMPULSA_BASE_URL=https://api-uat.example.com',
            'MACSS_DEPLOY_SSH_ALIAS=uat',
            'MACSS_FLUTTER_FLAVOR=uat'
        )
        $r = Get-FlutterBuildEnv -Path $f
        @($r.Defines.Keys) | Should -Be @('APP_ENV', 'IMPULSA_BASE_URL')
        $r.Defines['IMPULSA_BASE_URL'] | Should -Be 'https://api-uat.example.com'
    }

    It 'toma el flavor de MACSS_FLUTTER_FLAVOR' {
        $r = Get-FlutterBuildEnv -Path (New-EnvFile @('APP_ENV=uat', 'MACSS_FLUTTER_FLAVOR=uat'))
        $r.Flavor | Should -Be 'uat'
    }

    It 'sin MACSS_FLUTTER_FLAVOR (o vacio) no hay flavor' {
        (Get-FlutterBuildEnv -Path (New-EnvFile @('APP_ENV=dev'))).Flavor | Should -BeNullOrEmpty
        (Get-FlutterBuildEnv -Path (New-EnvFile @('MACSS_FLUTTER_FLAVOR='))).Flavor | Should -BeNullOrEmpty
    }

    It 'rechaza un flavor que Gradle no acepta' {
        { Get-FlutterBuildEnv -Path (New-EnvFile @('MACSS_FLUTTER_FLAVOR=pre-prod')) } |
            Should -Throw '*pre-prod*'
    }

    It 'marca las claves con nombre de secreto' {
        $r = Get-FlutterBuildEnv -Path (New-EnvFile @('APP_ENV=uat', 'MAPS_API_KEY=x', 'DB_PASSWORD=y', 'CLIENT_SECRET=z'))
        $r.SecretLikeKeys | Should -Be @('CLIENT_SECRET', 'DB_PASSWORD', 'MAPS_API_KEY')
    }

    It 'no marca nada si no hay claves sospechosas' {
        (Get-FlutterBuildEnv -Path (New-EnvFile @('APP_ENV=uat'))).SecretLikeKeys | Should -HaveCount 0
    }

    It 'las claves MACSS_* no se marcan aunque su nombre lo parezca (no llegan al binario)' {
        $r = Get-FlutterBuildEnv -Path (New-EnvFile @('APP_ENV=uat', 'MACSS_DEPLOY_KEY=x'))
        $r.SecretLikeKeys | Should -HaveCount 0
    }
}

Describe 'New-FlutterDefineFile' {
    It 'escribe un JSON con los defines tal cual' {
        $defines = [ordered]@{ APP_ENV = 'uat'; IMPULSA_BASE_URL = 'https://api-uat.example.com' }
        $path = New-FlutterDefineFile -Defines $defines
        try {
            $json = Get-Content $path -Raw | ConvertFrom-Json
            $json.APP_ENV | Should -Be 'uat'
            $json.IMPULSA_BASE_URL | Should -Be 'https://api-uat.example.com'
        } finally { Remove-Item $path -Force }
    }

    It 'sin BOM: flutter lee el archivo como JSON estricto' {
        $path = New-FlutterDefineFile -Defines ([ordered]@{ A = '1' })
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Be ([byte][char]'{')
        } finally { Remove-Item $path -Force }
    }
}

Describe 'Resolve-FlutterApkOutput' {
    BeforeEach {
        $script:out = Join-Path $TestDrive "apk_$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:out | Out-Null
    }

    It 'sin flavor: app-release.apk' {
        New-Item -ItemType File -Path (Join-Path $script:out 'app-release.apk') | Out-Null
        Resolve-FlutterApkOutput -OutputDir $script:out | Should -BeLike '*app-release.apk'
    }

    It 'con flavor: app-<flavor>-release.apk' {
        New-Item -ItemType File -Path (Join-Path $script:out 'app-uat-release.apk') | Out-Null
        Resolve-FlutterApkOutput -OutputDir $script:out -Flavor 'uat' | Should -BeLike '*app-uat-release.apk'
    }

    It 'con flavor y -SplitPerAbi: app-arm64-v8a-<flavor>-release.apk' {
        'app-armeabi-v7a-uat-release.apk', 'app-arm64-v8a-uat-release.apk' | ForEach-Object {
            New-Item -ItemType File -Path (Join-Path $script:out $_) | Out-Null
        }
        Resolve-FlutterApkOutput -OutputDir $script:out -Flavor 'uat' -SplitPerAbi |
            Should -BeLike '*app-arm64-v8a-uat-release.apk'
    }

    It 'si no lo encuentra, falla listando lo que hay' {
        New-Item -ItemType File -Path (Join-Path $script:out 'app-prod-release.apk') | Out-Null
        { Resolve-FlutterApkOutput -OutputDir $script:out -Flavor 'uat' } |
            Should -Throw '*app-prod-release.apk*'
    }
}
