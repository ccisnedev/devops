# MacssBanner.Tests.ps1
# El banner anuncia la version del modulo que esta corriendo.
#
# No es decoracion. PowerShell no recarga un modulo ya importado aunque haya una version mayor
# instalada, asi que una sesion puede estar ejecutando codigo viejo sin que nada lo indique: el
# plan sale con el formato de una version y el comportamiento de otra. Paso de verdad --una 6.0.1
# quedo por delante de la 6.0.3 y el reporte omitia una fila sin explicacion-- y diagnosticarlo
# obligo a inspeccionar Get-Module a mano.

BeforeAll {
    Get-Module 'macss-devops' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
    $script:expected = (Get-Module 'macss-devops').Version.ToString()

    # El banner escribe por el stream de informacion (Write-Host): 6>&1 lo captura.
    function Get-BannerLines {
        param([string]$Title, [string]$Version)
        $arg = if ($PSBoundParameters.ContainsKey('Version')) { " -Version '$Version'" } else { '' }
        return @((Get-Module 'macss-devops').Invoke([scriptblock]::Create(
                    "Show-MacssBanner -Title '$Title'$arg 6>&1")) |
                 ForEach-Object { "$_" } | Where-Object { $_ -match '[╔║╚]' })
    }
}

Describe "Show-MacssBanner" {

    It "esta disponible" {
        (Get-Module 'macss-devops').Invoke({ Get-Command Show-MacssBanner -ErrorAction SilentlyContinue }) |
            Should -Not -BeNullOrEmpty
    }

    It "anuncia la version del modulo cargado" {
        $out = (Get-Module 'macss-devops').Invoke({ Show-MacssBanner -Title 'Publish-FlutterWeb' 6>&1 }) -join "`n"
        $out | Should -Match ([regex]::Escape("v$script:expected"))
    }

    It "nombra el cmdlet tal como se invoca" {
        $out = (Get-Module 'macss-devops').Invoke({ Show-MacssBanner -Title 'Publish-FlutterWeb' 6>&1 }) -join "`n"
        $out | Should -Match 'Publish-FlutterWeb'
    }

    # El marco se calcula en vez de escribirse a mano. El banner anterior estaba escrito a mano y
    # le faltaba un espacio antes del ║ derecho: la caja no cerraba. Estos tests fijan la forma.
    It "<Case>: las tres lineas miden lo mismo" -ForEach @(
        @{ Case = 'titulo corto';  Title = 'A' }
        @{ Case = 'titulo normal'; Title = 'Publish-FlutterWeb' }
        @{ Case = 'titulo largo';  Title = 'Un-Cmdlet-Con-Nombre-Bastante-Largo-De-Verdad' }
    ) {
        $lines = @(Get-BannerLines -Title $Title)
        $lines.Count | Should -Be 3
        ($lines | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
    }

    It "<Case>: cada linea abre y cierra con su esquina" -ForEach @(
        @{ Case = 'titulo corto';  Title = 'A' }
        @{ Case = 'titulo normal'; Title = 'Publish-FlutterWeb' }
        @{ Case = 'titulo largo';  Title = 'Un-Cmdlet-Con-Nombre-Bastante-Largo-De-Verdad' }
    ) {
        $l = @(Get-BannerLines -Title $Title)
        $l[0][0] | Should -Be ([char]0x2554); $l[0][-1] | Should -Be ([char]0x2557)   # ╔ ╗
        $l[1][0] | Should -Be ([char]0x2551); $l[1][-1] | Should -Be ([char]0x2551)   # ║ ║
        $l[2][0] | Should -Be ([char]0x255A); $l[2][-1] | Should -Be ([char]0x255D)   # ╚ ╝
    }

    It "el borde superior e inferior son solo linea, sin huecos" {
        $l = @(Get-BannerLines -Title 'Publish-FlutterWeb')
        $l[0].Substring(1, $l[0].Length - 2) | Should -Match "^$([char]0x2550)+$"
        $l[2].Substring(1, $l[2].Length - 2) | Should -Match "^$([char]0x2550)+$"
    }

    It "el texto queda centrado (los margenes no difieren en mas de 1)" {
        $l = @(Get-BannerLines -Title 'Publish-FlutterWeb')
        $inner = $l[1].Substring(1, $l[1].Length - 2)
        $izq = $inner.Length - $inner.TrimStart().Length
        $der = $inner.Length - $inner.TrimEnd().Length
        [Math]::Abs($izq - $der) | Should -BeLessOrEqual 1
    }
}

Describe "Los cmdlets usan el banner compartido" {

    It "<Cmdlet> llama a Show-MacssBanner en vez de dibujar el suyo" -ForEach @(
        @{ Cmdlet = 'Publish-NodeApi' }
        @{ Cmdlet = 'Publish-FlutterWeb' }
        @{ Cmdlet = 'Publish-DockerStack' }
        @{ Cmdlet = 'Invoke-SqlPackage' }
        @{ Cmdlet = 'Invoke-PgSchema' }
    ) {
        $src = Get-Content (Join-Path $PSScriptRoot "..\Functions\$Cmdlet.ps1") -Raw -Encoding UTF8
        [bool]($src -match 'Show-MacssBanner') | Should -BeTrue
        [bool]($src -match '╔═')               | Should -BeFalse
    }
}

Describe "Show-MacssBanner — el marco es parametrico, no un ancho fijo" {

    # 50 es un minimo, no un ancho: existe para que los banners de uso normal se vean todos igual
    # de anchos. Cuando el texto no cabe, el marco crece. Estos casos lo fijan por los dos lados.

    It "un titulo corto no encoge el marco por debajo del minimo" {
        (Get-BannerLines -Title 'A' -Version 'v1.0.0')[0].Length | Should -Be 52
    }

    It "un titulo largo ensancha el marco" {
        $corto = (Get-BannerLines -Title 'A' -Version 'v1.0.0')[0].Length
        $largo = (Get-BannerLines -Title 'Un-Cmdlet-Con-Nombre-Verdaderamente-Larguisimo' -Version 'v1.0.0')[0].Length
        $largo | Should -BeGreaterThan $corto
    }

    # La version tambien entra en el calculo: una prerelease es mas larga y no debe romper nada.
    It "una version larga ensancha el marco igual que el titulo" {
        $corta = (Get-BannerLines -Title 'Publish-NodeApi' -Version 'v6.1.0')[0].Length
        $larga = (Get-BannerLines -Title 'Publish-NodeApi' -Version 'v6.1.0-preview.20260805.1')[0].Length
        $larga | Should -BeGreaterThan $corta
    }

    It "<Case>: sigue alineado" -ForEach @(
        @{ Case = 'titulo minimo';     Title = 'A';                    Version = 'v1.0.0' }
        @{ Case = 'version larga';     Title = 'Publish-NodeApi';      Version = 'v6.1.0-preview.20260805.1' }
        @{ Case = 'ambos largos';      Title = 'Un-Cmdlet-Muy-Largo';  Version = 'v10.20.30-rc.1+build.999' }
        @{ Case = 'version ausente';   Title = 'Publish-NodeApi';      Version = '(versión desconocida)' }
    ) {
        $l = @(Get-BannerLines -Title $Title -Version $Version)
        ($l | ForEach-Object { $_.Length } | Select-Object -Unique).Count | Should -Be 1
        $l[1] | Should -Match ([regex]::Escape($Title))
    }

    It "el texto nunca se recorta, por largo que sea" {
        $t = 'Cmdlet-Con-Un-Nombre-Deliberadamente-Excesivo-Para-Probar-El-Limite'
        $v = 'v99.99.99-alpha.beta.gamma'
        $l = @(Get-BannerLines -Title $t -Version $v)
        $l[1] | Should -Match ([regex]::Escape($t))
        $l[1] | Should -Match ([regex]::Escape($v))
    }
}
