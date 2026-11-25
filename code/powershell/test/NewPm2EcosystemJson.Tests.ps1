# Pester (v5) — generador puro del ecosystem pm2 en formato JSON desde publish.yaml
# (ADR 0005). El JSON es config-as-data: pm2 lo carga nativo (sin trampa CJS/ESM) y el
# schema es la interseccion systemd n pm2.

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
}

Describe 'New-Pm2EcosystemJson' {

    It 'single-process: genera un app desde entrypoint + runtime.env (versionado, no-secreto)' {
        $json = New-Pm2EcosystemJson -AppName 'micro' -Entrypoint 'server.js' -RuntimeEnv @{
            NODE_ENV = 'production'; LD_LIBRARY_PATH = '/opt/oracle/instantclient_11_2'
        }
        $obj = $json | ConvertFrom-Json
        @($obj.apps).Count            | Should -Be 1
        $obj.apps[0].name             | Should -Be 'micro'
        $obj.apps[0].script           | Should -Be 'server.js'
        $obj.apps[0].env.NODE_ENV     | Should -Be 'production'
        $obj.apps[0].env.LD_LIBRARY_PATH | Should -Be '/opt/oracle/instantclient_11_2'
    }

    It 'multi-process: un app por proceso (api + worker) fusionando runtime.env con env por proceso' {
        $json = New-Pm2EcosystemJson -AppName 'micro' -Entrypoint 'server.js' `
            -RuntimeEnv @{ NODE_ENV = 'production' } `
            -Processes @(
                @{ name = 'api';    script = 'server.js'; env = @{ ROLE = 'api' } },
                @{ name = 'worker'; script = 'worker.js'; env = @{ ROLE = 'worker' } }
            )
        $obj = $json | ConvertFrom-Json
        @($obj.apps).Count | Should -Be 2
        $api = $obj.apps | Where-Object name -eq 'api'
        $wk  = $obj.apps | Where-Object name -eq 'worker'
        $api.script       | Should -Be 'server.js'
        $api.env.ROLE     | Should -Be 'api'
        $api.env.NODE_ENV | Should -Be 'production'   # runtime.env se hereda
        $wk.env.ROLE      | Should -Be 'worker'
        $wk.env.NODE_ENV  | Should -Be 'production'
    }

    It 'interseccion: rechaza claves pm2-only en processes (instances/cluster)' {
        { New-Pm2EcosystemJson -AppName 'x' -Entrypoint 'server.js' -Processes @(
            @{ name = 'api'; script = 'server.js'; instances = 'max' }
        ) } | Should -Throw -ExpectedMessage '*instances*'
    }

    It 'restart:no -> autorestart:false' {
        $json = New-Pm2EcosystemJson -AppName 'micro' -Entrypoint 'server.js' -Restart 'no'
        ($json | ConvertFrom-Json).apps[0].autorestart | Should -Be $false
    }

    It 'restart:always (default) -> autorestart:true + restart_delay en ms' {
        $json = New-Pm2EcosystemJson -AppName 'micro' -Entrypoint 'server.js' -RestartDelaySec 5
        $app = ($json | ConvertFrom-Json).apps[0]
        $app.autorestart   | Should -Be $true
        $app.restart_delay | Should -Be 5000
    }
}

# cwd por el symlink del release (ccisnedev/devops#110). Sin cwd, pm2 resuelve script y cwd
# contra process.cwd() del CLI, que Node entrega ya resuelto (getcwd): el app queda anclado a
# releases/<release> y un 'pm2 restart' tras cambiar 'current' sigue corriendo el release viejo.
Describe 'New-Pm2EcosystemJson -WorkingDir' {

    It 'single-process sin cwd declarado: cwd = WorkingDir (el symlink current)' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'dist/server.js' `
            -RuntimeEnv @{ NODE_ENV = 'production' } -WorkingDir '/opt/app/api/current'
        ($json | ConvertFrom-Json).apps[0].cwd | Should -Be '/opt/app/api/current'
    }

    It 'multi-process: cada proceso sin cwd recibe WorkingDir' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'server.js' -WorkingDir '/opt/app/api/current' `
            -Processes @(
                @{ name = 'api';    script = 'server.js' },
                @{ name = 'worker'; script = 'worker.js' }
            )
        $apps = ($json | ConvertFrom-Json).apps
        @($apps | Where-Object cwd -eq '/opt/app/api/current').Count | Should -Be 2
    }

    It 'cwd relativo declarado: se resuelve contra WorkingDir, no contra el release fisico' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'server.js' -WorkingDir '/opt/app/api/current' `
            -Processes @( @{ name = 'worker'; script = 'w.js'; cwd = 'worker' } )
        ($json | ConvertFrom-Json).apps[0].cwd | Should -Be '/opt/app/api/current/worker'
    }

    It 'cwd relativo con ./ y barra final: se normaliza' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'server.js' -WorkingDir '/opt/app/api/current/' `
            -Processes @( @{ name = 'worker'; script = 'w.js'; cwd = './worker/' } )
        ($json | ConvertFrom-Json).apps[0].cwd | Should -Be '/opt/app/api/current/worker'
    }

    It 'cwd absoluto declarado: se respeta tal cual' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'server.js' -WorkingDir '/opt/app/api/current' `
            -Processes @( @{ name = 'worker'; script = 'w.js'; cwd = '/srv/shared/worker' } )
        ($json | ConvertFrom-Json).apps[0].cwd | Should -Be '/srv/shared/worker'
    }

    It 'sin -WorkingDir: no inventa cwd (retrocompat del generador puro)' {
        $json = New-Pm2EcosystemJson -AppName 'api' -Entrypoint 'server.js'
        ($json | ConvertFrom-Json).apps[0].PSObject.Properties.Name | Should -Not -Contain 'cwd'
    }

    It 'Publish-NodeApi pasa -WorkingDir al generar el ecosystem' {
        $src = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
        $call = [regex]::Match($src, 'New-Pm2EcosystemJson(?:[^\r\n]*`\r?\n)*[^\r\n]*').Value
        $call | Should -Match '-WorkingDir\s+\$workingDir'
    }
}
