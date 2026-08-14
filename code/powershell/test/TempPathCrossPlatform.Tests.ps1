# TempPathCrossPlatform.Tests.ps1
# El modulo usaba $env:TEMP, que en Linux no existe (010, primer despliegue de api desde CI).
#
# El caso real, en el runner:
#
#   Auto-approved (-AutoApprove): Deploy impulsa v1.5.2+62d092f to 'prod' (pm2)
#   Publish-NodeApi: Cannot bind argument to parameter 'Path' because it is null.
#
# PowerShell define TEMP solo en Windows; fuera de ahi hay TMPDIR, o ninguna. Un
# 'Join-Path $env:TEMP ...' recibe $null y falla al enlazar el parametro, sin decir cual de
# los siete sitios fue.
#
# Es la misma familia que la ruta del .dacpac: codigo escrito y probado en Windows, correcto
# ahi, y roto en cuanto lo ejecuta un runner Linux. La leccion no es el bug sino su clase.

BeforeAll {
    $script:Fuentes = Get-ChildItem "$PSScriptRoot/../Functions", "$PSScriptRoot/../Private" `
                                    -Filter *.ps1 -Recurse
}

Describe "Rutas temporales — ningun sitio depende de una variable que solo existe en Windows" {

    It "ningun archivo del modulo usa \$env:TEMP" {
        # Barrido y no lista escrita a mano: eran siete sitios en dos cmdlets, y una lista deja
        # fuera el octavo que alguien escriba manana copiando una linea de al lado.
        $culpables = @($script:Fuentes | Where-Object {
            (Get-Content $_.FullName -Raw) -match '\$env:TEMP'
        } | ForEach-Object { $_.Name } | Sort-Object -Unique)

        $culpables -join ', ' | Should -BeNullOrEmpty
    }

    It "los cmdlets que empaquetan resuelven el temporal con .NET" {
        foreach ($n in 'Publish-NodeApi.ps1', 'Publish-DockerStack.ps1') {
            $f = $script:Fuentes | Where-Object Name -eq $n
            (Get-Content $f.FullName -Raw) | Should -Match 'GetTempPath' -Because "$n arma archivos temporales"
        }
    }

    It "GetTempPath devuelve algo utilizable en esta plataforma" {
        # La comprobacion barata de que el reemplazo no cambia nada donde ya funcionaba.
        $t = [System.IO.Path]::GetTempPath()
        $t | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $t | Should -BeTrue
    }
}

Describe "Empaquetado — el binario tiene que existir en las dos plataformas" {
    # Encontrado buscando a proposito, no esperando a que fallara: tras el segundo defecto de
    # esta clase se barrieron las demas suposiciones de Windows, y aparecio 'tar.exe' en tres
    # sitios. En Linux ese binario no existe; habria roto el empaquetado del despliegue
    # siguiente, y el sintoma habria llegado como otro fallo sin relacion aparente.

    It "ningun archivo invoca tar.exe" {
        # 'tar' a secas resuelve en las dos: Windows 10+ lo trae y PATHEXT lo encuentra.
        $culpables = @($script:Fuentes | Where-Object {
            (Get-Content $_.FullName -Raw) -match 'tar\.exe'
        } | ForEach-Object { $_.Name } | Sort-Object -Unique)

        $culpables -join ', ' | Should -BeNullOrEmpty
    }

    It "'tar' existe en la plataforma que corre los tests" {
        Get-Command tar -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
