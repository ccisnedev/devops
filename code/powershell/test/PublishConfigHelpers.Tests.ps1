# PublishConfigHelpers.Tests.ps1
# Tests para los helpers de configuracion de publicacion:
# Format-ApiBasePath, Resolve-ApiBasePath y Resolve-PublishConfigPath

BeforeAll {
    # Cargar los helpers directamente
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
}

Describe "Format-ApiBasePath" {

    It "agrega el slash inicial cuando falta" {
        Format-ApiBasePath -BasePath 'api/v1' | Should -Be '/api/v1'
    }

    It "elimina slashes finales" {
        Format-ApiBasePath -BasePath '/api/v1/' | Should -Be '/api/v1'
    }

    It "retorna vacio para cadena vacia (healthcheck en raiz, retrocompatible)" {
        Format-ApiBasePath -BasePath '' | Should -Be ''
    }

    It "retorna vacio para '/' (equivale a raiz)" {
        Format-ApiBasePath -BasePath '/' | Should -Be ''
    }

    It "deja intacto un basePath ya normalizado" {
        Format-ApiBasePath -BasePath '/api/v1' | Should -Be '/api/v1'
    }

    It "recorta espacios alrededor" {
        Format-ApiBasePath -BasePath '  /api/v1  ' | Should -Be '/api/v1'
    }
}

Describe "Resolve-ApiBasePath" {

    It "prefiere package.json (modularApi.basePath) sobre publish.yaml" {
        $pkg = [PSCustomObject]@{ modularApi = [PSCustomObject]@{ basePath = '/api/v1' } }
        $cfg = @{ api = @{ basePath = '/otro' } }
        Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $cfg | Should -Be '/api/v1'
    }

    It "cae a publish.yaml (api.basePath) cuando package.json no declara la convencion" {
        $pkg = [PSCustomObject]@{ name = 'demo' }
        $cfg = @{ api = @{ basePath = 'api/v2' } }
        Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $cfg | Should -Be '/api/v2'
    }

    It "retorna vacio cuando ninguna fuente declara basePath (retrocompatible)" {
        $pkg = [PSCustomObject]@{ name = 'demo' }
        $cfg = @{ server = 'prod' }
        Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $cfg | Should -Be ''
    }

    It "normaliza el valor venga de donde venga" {
        $pkg = [PSCustomObject]@{ modularApi = [PSCustomObject]@{ basePath = 'api/v1/' } }
        Resolve-ApiBasePath -PackageJson $pkg -PublishConfig $null | Should -Be '/api/v1'
    }
}

Describe "Resolve-PublishConfigPath" {

    BeforeEach {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) "publish-cfg-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force -Path $script:tmpDir -ErrorAction SilentlyContinue
    }

    It "prefiere publish.yaml cuando existe" {
        Set-Content -Path (Join-Path $script:tmpDir 'publish.yaml') -Value 'server: demo'
        Set-Content -Path (Join-Path $script:tmpDir 'deploy.yaml') -Value 'server: viejo'

        $result = Resolve-PublishConfigPath -ProjectRoot $script:tmpDir
        $result.Path | Should -Be (Join-Path $script:tmpDir 'publish.yaml')
        $result.IsLegacy | Should -BeFalse
    }

    It "cae a deploy.yaml marcandolo como legacy" {
        Set-Content -Path (Join-Path $script:tmpDir 'deploy.yaml') -Value 'server: viejo'

        $result = Resolve-PublishConfigPath -ProjectRoot $script:tmpDir
        $result.Path | Should -Be (Join-Path $script:tmpDir 'deploy.yaml')
        $result.IsLegacy | Should -BeTrue
    }

    It "retorna Path nulo cuando no existe ninguno" {
        $result = Resolve-PublishConfigPath -ProjectRoot $script:tmpDir
        $result.Path | Should -BeNullOrEmpty
        $result.IsLegacy | Should -BeFalse
    }
}
