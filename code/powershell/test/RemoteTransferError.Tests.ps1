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

Describe "Publish-NodeApi y Publish-FlutterWeb — cableado" {

    BeforeAll {
        $script:NodeApi    = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
        $script:FlutterWeb = Get-Content "$PSScriptRoot/../Functions/Publish-FlutterWeb.ps1" -Raw
        $script:Helpers    = Get-Content "$PSScriptRoot/../Private/PublishHelpers.ps1" -Raw
    }

    It "Publish-NodeApi ya no descarta la salida de scp" {
        $script:NodeApi | Should -Not -Match '&\s*scp[^\n]*Out-Null'
    }

    It "Publish-FlutterWeb ya no descarta la salida de scp" {
        $script:FlutterWeb | Should -Not -Match '&\s*scp[^\n]*Out-Null'
    }

    It "ambos usan el helper compartido" {
        $script:NodeApi    | Should -Match 'Invoke-RemoteCopy'
        $script:FlutterWeb | Should -Match 'Invoke-RemoteCopy'
    }

    It "los helpers de ejecución remota tampoco lo descartan" {
        # Invoke-RemoteScript y su variante Capture son por donde pasan los dos cmdlets para
        # ejecutar en el servidor, y tenian el mismo agujero.
        $script:Helpers | Should -Not -Match '&\s*scp[^\n]*Out-Null'
    }
}
