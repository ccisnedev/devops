# DacpacPathCrossPlatform.Tests.ps1
# La ruta del .dacpac se armaba con separadores de Windows (issue del primer despliegue
# automático de impulsa, 2026-08-13).
#
# El caso real, en el runner Linux:
#
#   Build exitoso
#   Generando reporte de cambios...
#   *** Could not load package from '.\bin\Debug\IMPULSA.dacpac'.
#   Could not find file '/tmp/runner/work/impulsa/impulsa/code/db/.\bin\Debug\IMPULSA.dacpac'.
#
# El proyecto compiló bien; lo que no existe es esa ruta. En Linux una contrabarra no separa
# directorios: '.\bin\Debug\IMPULSA.dacpac' es un nombre de archivo con contrabarras dentro.
#
# Por qué no lo detuvo la validación previa
# -----------------------------------------
# El cmdlet comprueba `Test-Path $dacpacPath` antes de invocar a sqlpackage, y esa
# comprobación PASÓ. PowerShell en Unix normaliza la contrabarra en sus propios proveedores,
# así que Test-Path la resuelve; sqlpackage recibe la cadena literal y no. Un guard que
# depende de que dos programas interpreten igual la misma cadena no es un guard.
#
# Cinco meses de despliegues manuales desde Windows no podían encontrar esto. El primer
# despliegue automático lo encontró en su primera corrida.

BeforeAll {
    . "$PSScriptRoot/../Private/SqlPackageHelpers.ps1"

    function New-ProyectoDb {
        param([string]$Nombre = 'IMPULSA', [switch]$ConDacpac)
        $raiz = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $raiz -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $raiz "$Nombre.sqlproj") -Value '<Project />'
        if ($ConDacpac) {
            $bin = Join-Path (Join-Path $raiz 'bin') 'Debug'
            New-Item -ItemType Directory -Path $bin -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bin "$Nombre.dacpac") -Value 'x'
        }
        return $raiz
    }
}

Describe "Find-DacpacPath — la ruta tiene que servirle a sqlpackage, no solo a PowerShell" {

    It "no lleva contrabarras cuando el separador del sistema no lo es" {
        # Es el defecto entero: sqlpackage recibe la cadena tal cual.
        $p = Find-DacpacPath -ProjectRoot (New-ProyectoDb)
        if ([IO.Path]::DirectorySeparatorChar -ne '\') {
            $p | Should -Not -Match '\\'
        }
    }

    It "apunta al dacpac que produce el build" {
        $raiz = New-ProyectoDb -ConDacpac
        $p = Find-DacpacPath -ProjectRoot $raiz
        Test-Path -LiteralPath $p | Should -BeTrue
    }

    It "toma el nombre del .sqlproj, no uno fijo" {
        $p = Find-DacpacPath -ProjectRoot (New-ProyectoDb -Nombre 'CONTRATOS')
        $p | Should -Match 'CONTRATOS\.dacpac$'
    }

    It "devuelve una ruta absoluta" {
        # Una ruta relativa depende de que el directorio actual siga siendo el mismo cuando
        # sqlpackage la resuelva. No cuesta nada quitar esa suposición.
        $p = Find-DacpacPath -ProjectRoot (New-ProyectoDb)
        [IO.Path]::IsPathRooted($p) | Should -BeTrue
    }

    It "sin .sqlproj falla diciendo qué falta" {
        $vacio = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $vacio -Force | Out-Null
        { Find-DacpacPath -ProjectRoot $vacio } | Should -Throw -ExpectedMessage '*sqlproj*'
    }

    It "sin -ProjectRoot mira el directorio actual, como siempre" {
        $raiz = New-ProyectoDb
        Push-Location $raiz
        try { (Find-DacpacPath) | Should -Match 'IMPULSA\.dacpac$' } finally { Pop-Location }
    }
}

Describe "New-SqlPackageError — el mensaje no puede apuntar al sitio equivocado" {

    It "incluye lo que dijo sqlpackage" {
        $m = New-SqlPackageError -Accion 'generar el reporte' -ExitCode 1 `
                                 -Salida @("*** Could not load package from '.\bin\Debug\IMPULSA.dacpac'.")
        $m | Should -Match 'Could not load package'
    }

    It "no afirma que es la conexión cuando sqlpackage dijo otra cosa" {
        # El mensaje anterior era "Verifique la conexión y permisos" pasara lo que pasara. En
        # el caso real la conexión estaba perfecta y faltaba un archivo: mandaba a revisar
        # credenciales y firewall durante un rato.
        $m = New-SqlPackageError -Accion 'generar el reporte' -ExitCode 1 `
                                 -Salida @('Could not find file /x/y.dacpac')
        $m | Should -Not -Match 'Verifique la conexión y permisos'
    }

    It "nombra la acción que falló" {
        (New-SqlPackageError -Accion 'exportar' -ExitCode 1 -Salida @('x')) | Should -Match 'exportar'
    }

    It "conserva el código de salida" {
        (New-SqlPackageError -Accion 'exportar' -ExitCode 7 -Salida @('x')) | Should -Match '7'
    }

    It "cuando sqlpackage no dijo nada, ahí sí sugiere dónde mirar" {
        # Sin salida no hay nada que interpretar; la conexión y los permisos vuelven a ser la
        # sospecha razonable.
        $m = New-SqlPackageError -Accion 'generar el reporte' -ExitCode 1 -Salida @()
        $m | Should -Match 'conexi[oó]n'
    }

    It "se queda con las últimas líneas, no con el volcado entero" {
        # sqlpackage escribe decenas de lineas de progreso; el motivo esta al final.
        $ruido = 1..60 | ForEach-Object { "linea $_" }
        $m = New-SqlPackageError -Accion 'x' -ExitCode 1 -Salida ($ruido + @('EL MOTIVO'))
        $m | Should -Match 'EL MOTIVO'
        ($m -split "`n").Count | Should -BeLessThan 20
    }
}

Describe "Invoke-SqlPackage — cableado" {

    BeforeAll { $script:Cmdlet = Get-Content "$PSScriptRoot/../Functions/Invoke-SqlPackage.ps1" -Raw }

    It "ninguna invocación se queda con el mensaje genérico" {
        $script:Cmdlet | Should -Not -Match 'Verifique la conexión y permisos'
    }

    It "todas usan el compositor del mensaje" {
        # Seis sitios tenían la misma forma; una lista a mano deja fuera el séptimo.
        ([regex]::Matches($script:Cmdlet, 'New-SqlPackageError')).Count | Should -BeGreaterOrEqual 6
    }
}
