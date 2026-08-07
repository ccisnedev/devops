# DockerStackDestinoVisible.Tests.ps1
# El destino debe estar resuelto ANTES de mostrarse y de pedir confirmacion.
#
# Regresion introducida al migrar Publish-DockerStack a ADR 0010: al retirar 'server:' de
# stack.yaml, las lineas que lo mostraban siguieron leyendo $cfg.Server --ahora $null-- y la
# resolucion del alias quedo despues del prompt. Resultado: -Apply preguntaba
#
#     Apply this change? (Deploy stack 'github-actions-runner' v1.0.0 to '' (build:server))
#
# Confirmar un despliegue sin ver el destino anula el proposito del gate de ADR 0002.

BeforeAll {
    $script:src = Get-Content "$PSScriptRoot/../Functions/Publish-DockerStack.ps1" -Raw -Encoding UTF8

    function Get-Branch {
        param([string]$Name)
        $i = $script:src.IndexOf("'$Name' {")
        if ($i -lt 0) { return '' }
        $j = $script:src.IndexOf("`n            '", $i + 5)
        if ($j -lt 0) { $j = $script:src.Length }
        return $script:src.Substring($i, $j - $i)
    }
}

Describe "Publish-DockerStack — el destino se resuelve antes de usarse" {

    It "en -Apply, la resolucion ocurre antes del prompt de confirmacion" {
        $b = Get-Branch -Name 'Apply'
        $resolve = $b.IndexOf('Resolve-DeployTargetFromEnv')
        $confirm = $b.IndexOf('Confirm-MacssChange')
        $resolve | Should -BeGreaterThan -1
        $confirm | Should -BeGreaterThan -1
        $resolve | Should -BeLessThan $confirm
    }

    It "<Branch> no muestra el destino leyendo la clave retirada de stack.yaml" -ForEach @(
        @{ Branch = 'Apply' }
        @{ Branch = 'Plan' }
    ) {
        $b = Get-Branch -Name $Branch
        [bool]($b -match 'Servidor:[^\r\n]*\$\(?\$cfg\.Server') | Should -BeFalse
    }

    It "<Branch> muestra el alias resuelto" -ForEach @(
        @{ Branch = 'Apply' }
        @{ Branch = 'Plan' }
    ) {
        $b = Get-Branch -Name $Branch
        [bool]($b -match 'Servidor:[^\r\n]*\$server') | Should -BeTrue
    }

    # cfg.Server sigue leyendose, pero solo para pasarlo como -LegacyServer y poder fallar
    # nombrando la clave deprecada. Ese uso es legitimo.
    It "cfg.Server solo sobrevive como -LegacyServer" {
        $usos = [regex]::Matches($script:src, '\$cfg\.Server') | ForEach-Object { $_.Index }
        foreach ($u in $usos) {
            $ctx = $script:src.Substring([Math]::Max(0, $u - 60), 70)
            $ctx | Should -Match 'LegacyServer'
        }
    }
}

Describe "Publish-DockerStack — el plan se numera solo" {

    # Con numeros escritos a mano, saltarse un paso condicional dejaba huecos: 1, 3, 4, 5.
    # Un plan que salta un numero invita a preguntarse que fue del 2 y si fallo en silencio.
    It "no escribe los numeros de paso a mano" {
        [bool]($script:src -match 'Write-Host "  \d\. ') | Should -BeFalse
    }

    It "los enumera al imprimir, desde una lista" {
        [bool]($script:src -match '\$acciones') | Should -BeTrue
        [bool]($script:src -match '\$\(\$i \+ 1\)\. ') | Should -BeTrue
    }
}
