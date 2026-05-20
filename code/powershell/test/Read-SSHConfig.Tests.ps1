# Read-SSHConfig.Tests.ps1
# Tests para Read-SSHConfig — compatibilidad Windows/Linux

BeforeAll {
    # Cargar la función directamente
    . "$PSScriptRoot/../Private/Read-SSHConfig.ps1"
}

Describe "Read-SSHConfig" {

    BeforeEach {
        # Crear directorio temporal con ssh config de prueba
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) "ssh-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:sshDir = Join-Path $script:tmpDir ".ssh"
        New-Item -ItemType Directory -Path $script:sshDir -Force | Out-Null

        $sshConfigContent = @"
Host demo-app
    HostName app.example.test
    User deploy
    Port 22
    IdentityFile ~/.ssh/id_rsa

Host demo-web
    HostName web.example.test
    User webuser
    Port 22
    IdentityFile ~/.ssh/id_rsa

Host custom-port
    HostName custom.example.test
    User admin
    Port 2222
    IdentityFile /keys/custom_key
"@
        $script:configPath = Join-Path $script:sshDir "config"
        Set-Content -Path $script:configPath -Value $sshConfigContent -NoNewline
    }

    AfterEach {
        Remove-Item -Recurse -Force $script:tmpDir -ErrorAction SilentlyContinue
    }

    Context "Parsing con ConfigPath explícito" {

        It "Parsea demo-app correctamente" {
            $result = Read-SSHConfig -HostAlias "demo-app" -ConfigPath $script:configPath
            $result.HostName | Should -Be "app.example.test"
            $result.User | Should -Be "deploy"
            $result.Port | Should -Be 22
            $result.IdentityFile | Should -Be "~/.ssh/id_rsa"
        }

        It "Parsea demo-web correctamente" {
            $result = Read-SSHConfig -HostAlias "demo-web" -ConfigPath $script:configPath
            $result.HostName | Should -Be "web.example.test"
            $result.User | Should -Be "webuser"
            $result.Port | Should -Be 22
        }

        It "Parsea puertos custom" {
            $result = Read-SSHConfig -HostAlias "custom-port" -ConfigPath $script:configPath
            $result.Port | Should -Be 2222
            $result.IdentityFile | Should -Be "/keys/custom_key"
        }

        It "Throws si el alias no existe" {
            { Read-SSHConfig -HostAlias "no-existe" -ConfigPath $script:configPath } |
                Should -Throw "*No se encontró el host*"
        }

        It "Throws si el archivo no existe" {
            { Read-SSHConfig -HostAlias "demo-app" -ConfigPath "/ruta/falsa/config" } |
                Should -Throw "*No se encontró el archivo*"
        }
    }

    Context "Resolución de path por defecto (Linux fallback)" {

        It "Usa `$env:HOME cuando `$env:USERPROFILE es null" {
            $originalUP = $env:USERPROFILE
            $originalHome = $env:HOME
            try {
                $env:USERPROFILE = $null
                $env:HOME = $script:tmpDir

                # La función debería resolver a $tmpDir/.ssh/config
                $result = Read-SSHConfig -HostAlias "demo-app"
                $result.HostName | Should -Be "app.example.test"
                $result.User | Should -Be "deploy"
            }
            finally {
                $env:USERPROFILE = $originalUP
                $env:HOME = $originalHome
            }
        }

        It "Usa `$env:USERPROFILE cuando está disponible (Windows)" {
            $originalUP = $env:USERPROFILE
            try {
                $env:USERPROFILE = $script:tmpDir

                $result = Read-SSHConfig -HostAlias "demo-web"
                $result.HostName | Should -Be "web.example.test"
            }
            finally {
                $env:USERPROFILE = $originalUP
            }
        }
    }
}
