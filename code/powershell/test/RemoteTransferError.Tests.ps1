# RemoteTransferError.Tests.ps1
# Los fallos de scp y ssh tienen que decir qué pasó, no solo que pasó algo (issue #91).
#
# El caso que lo motivó, desplegando impulsa a producción:
#
#   Subiendo archivos a 192.168.10.18...
#   Error al subir tarball (scp exit: 255)
#
# Eso es todo lo que recibía el operador. El 255 es el código con el que ssh reporta SUS
# errores, y cubre causas con remedios opuestos: una conexión que se cortó (reintentar), una
# clave no autorizada (autorizarla), una ruta muerta (mirar la red), una host key cambiada
# (verificar el servidor). scp había dicho cuál era; el 'Out-Null' se lo comió.
#
# Diagnosticarlo exigió reproducir a mano conectividad, identidad, una transferencia de 16 MB y
# el espacio en disco del servidor —cuatro comprobaciones— para llegar a lo que decía la primera
# línea descartada. Resultó ser transitorio.

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"
}

Describe "New-RemoteTransferError — el mensaje que recibe el operador" {

    It "incluye lo que dijo el comando" {
        # Es el punto entero: sin esto el mensaje no distingue causas que se arreglan distinto.
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 255 `
                                     -Salida @('ssh: connect to host 192.168.10.18 port 22: Connection timed out')
        $m | Should -Match 'Connection timed out'
    }

    It "conserva el código de salida" {
        (New-RemoteTransferError -Descripcion 'tarball' -ExitCode 255 -Salida @('x')) | Should -Match '255'
    }

    It "nombra qué se estaba transfiriendo" {
        (New-RemoteTransferError -Descripcion 'el env del release' -ExitCode 1 -Salida @('x')) |
            Should -Match 'el env del release'
    }

    It "explica el 255, que es el que más confunde" {
        # Un 255 no es un problema del archivo ni del destino: es ssh diciendo que no pudo
        # establecer la sesión. Decirlo ahorra buscar en el sitio equivocado.
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 255 -Salida @('Connection closed')
        $m | Should -Match 'conexi[oó]n|ssh'
    }

    It "no adorna un código que no es 255" {
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 1 -Salida @('No such file or directory')
        $m | Should -Not -Match 'no pudo establecer'
    }

    It "cuando el comando no dijo nada, lo dice en vez de inventar" {
        # Un mensaje vacío entre paréntesis es peor que decir que no hubo salida: parece que se
        # perdió algo y manda a buscar un log que no existe.
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 255 -Salida @()
        $m | Should -Match 'sin salida|no dijo'
    }

    It "junta varias líneas sin perder ninguna" {
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 1 `
                                     -Salida @('primera linea', 'segunda linea')
        $m | Should -Match 'primera linea'
        $m | Should -Match 'segunda linea'
    }

    It "descarta las líneas vacías, que solo hacen ruido" {
        $m = New-RemoteTransferError -Descripcion 'tarball' -ExitCode 1 -Salida @('', 'algo', '   ')
        ($m -split "`n" | Where-Object { $_ -match '^\s*$' }).Count | Should -BeLessOrEqual 1
    }
}

Describe "Cableado — ningún sitio del módulo descarta la salida" {
    # Se comprueba por barrido y no archivo por archivo: una lista escrita a mano deja fuera el
    # que se agregue mañana, y este defecto es exactamente el que se propaga copiando una línea.

    BeforeAll {
        $script:Fuentes = Get-ChildItem "$PSScriptRoot/../Functions", "$PSScriptRoot/../Private" `
                                        -Filter *.ps1 -Recurse
    }

    It "ningún archivo del módulo conserva la forma 'scp ... | Out-Null'" {
        $culpables = @($script:Fuentes | Where-Object {
            (Get-Content $_.FullName -Raw) -match '&\s*scp[^\n]*Out-Null'
        } | ForEach-Object { $_.Name })

        $culpables -join ', ' | Should -BeNullOrEmpty
    }

    It "los cuatro que transferían archivos usan el helper" {
        foreach ($n in 'Publish-NodeApi.ps1', 'Publish-FlutterWeb.ps1', 'Publish-DockerStack.ps1', 'FlutterWebPlan.ps1') {
            $f = $script:Fuentes | Where-Object Name -eq $n
            $f | Should -Not -BeNullOrEmpty -Because "$n debería existir"
            (Get-Content $f.FullName -Raw) | Should -Match 'Invoke-RemoteCopy' -Because "$n transfiere archivos"
        }
    }

    It "solo dos archivos invocan scp a mano, y por motivos distintos" {
        # PublishHelpers  — es el helper: captura la salida para poder incluirla en el error.
        # SshHelpers      — New-SshAccess es INTERACTIVO: canaliza a Out-Host para que el prompt
        #                   de contraseña llegue a la terminal durante el bootstrap. Capturar la
        #                   salida ahí dejaría al operador esperando delante de una pantalla
        #                   muda. Es una excepción deliberada, no un olvido.
        #
        # Un tercero significa que alguien volvió a escribir la invocación a mano.
        $conScp = @($script:Fuentes | Where-Object {
            (Get-Content $_.FullName -Raw) -match '&\s*scp\s'
        } | ForEach-Object { $_.Name } | Sort-Object)

        $conScp | Should -Be @('PublishHelpers.ps1', 'SshHelpers.ps1')
    }
}
