# NodeApiPortFromServer.Tests.ps1
# El puerto sale de la configuración que corre, no del archivo local (issue #83).
#
# Con el `.env` como sharedPath (ADR 0014) la configuración de runtime vive en el servidor, pero
# el cmdlet seguía tomando el puerto del archivo local:
#
#   $envConfig = Read-DotEnv -Path $envProdPath -DefaultPort 8080
#   $port = $envConfig.Port          # <- y la app arranca leyendo PORT de shared/.env
#
# Son dos fuentes para el mismo dato, y el contrato de .env.example compara NOMBRES de claves,
# no valores: nada impide que diverjan. El caso benigno es un healthcheck que falla estando todo
# bien. El malo es el contrario — que en el puerto sondeado responda otra cosa, un proceso
# anterior que quedó vivo, y el despliegue termine en verde sin que la app nueva esté sirviendo.
# Es la misma clase de fallo que el issue #76: un check que responde a la pregunta equivocada.
#
# Y hay una consecuencia práctica: mientras el puerto salga del archivo local, Publish-NodeApi
# no puede correr en un runner de CI, donde ese archivo no existe. PORT era el último dato que
# lo ataba a la máquina del operador.

BeforeAll {
    . "$PSScriptRoot/../Private/EnvContract.ps1"
    $script:Cmdlet = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
}

Describe "New-RemoteEnvKeysScript — qué valores salen del servidor" {

    It "sin -ValueKeys no sale ningún valor" {
        # El default no cambia: el sondeo del contrato solo lee nombres.
        (New-RemoteEnvKeysScript -SharedEnvPath '/x/.env') | Should -Not -Match 'ENVVALUE'
    }

    It "con -ValueKeys exporta solo las claves declaradas" {
        # La lista es explícita a propósito: qué valor sale del servidor es una decisión, no un
        # efecto secundario de cómo se escribió un sed.
        $s = New-RemoteEnvKeysScript -SharedEnvPath '/x/.env' -ValueKeys @('PORT')
        $s | Should -Match 'ENVVALUE'
        $s | Should -Match 'PORT'
    }

    It "sigue reportando los nombres de todas las claves" {
        $s = New-RemoteEnvKeysScript -SharedEnvPath '/x/.env' -ValueKeys @('PORT')
        $s | Should -Match 'ENVKEY:'
    }
}

Describe "ConvertFrom-EnvValuesOutput — leer los valores exportados" {

    It "devuelve el valor de la clave" {
        $v = ConvertFrom-EnvValuesOutput -Lines @('ENVFILE:present', 'ENVKEY:PORT', 'ENVVALUE:PORT=3050')
        $v['PORT'] | Should -Be '3050'
    }

    It "sin la línea, la clave no está" {
        $v = ConvertFrom-EnvValuesOutput -Lines @('ENVFILE:present', 'ENVKEY:PORT')
        $v.ContainsKey('PORT') | Should -BeFalse
    }

    It "un valor que contiene un igual no se parte" {
        $v = ConvertFrom-EnvValuesOutput -Lines @('ENVVALUE:URL=https://x/?a=1')
        $v['URL'] | Should -Be 'https://x/?a=1'
    }

    It "ignora lo que no es del sondeo" {
        $v = ConvertFrom-EnvValuesOutput -Lines @('Welcome to Ubuntu', 'ENVVALUE:PORT=3050')
        $v['PORT'] | Should -Be '3050'
    }
}

Describe "Resolve-NodeApiPort — dos fuentes para el mismo dato" {

    It "sin archivo local, manda el servidor: es el caso del runner" {
        $r = Resolve-NodeApiPort -LocalPort '' -ServerPort '3050' -EnvFile '.env.production'
        $r.Port  | Should -Be 3050
        $r.Level | Should -Be 'ok'
    }

    It "sin servidor, manda el archivo local: nada cambia para quien no migró" {
        $r = Resolve-NodeApiPort -LocalPort '8080' -ServerPort '' -EnvFile '.env'
        $r.Port  | Should -Be 8080
        $r.Level | Should -Be 'ok'
    }

    It "si coinciden, no hay nada que decir" {
        (Resolve-NodeApiPort -LocalPort '3050' -ServerPort '3050' -EnvFile '.env').Level | Should -Be 'ok'
    }

    It "si difieren, bloquea" {
        # Sondear un puerto donde la app no escucha es, en el mejor caso, un despliegue que
        # falla estando bien; en el peor, uno que pasa sin que la app nueva esté sirviendo.
        (Resolve-NodeApiPort -LocalPort '8080' -ServerPort '3050' -EnvFile '.env').Level |
            Should -Be 'error'
    }

    It "y el mensaje nombra los dos valores con su origen" {
        $t = (Resolve-NodeApiPort -LocalPort '8080' -ServerPort '3050' -EnvFile '.env.production').Text
        $t | Should -Match '8080'
        $t | Should -Match '3050'
        $t | Should -Match '\.env\.production'
    }

    It "cuando difieren, el que manda es el del servidor" {
        # Aunque bloquee, el dato correcto es el de la configuración que la app va a leer.
        (Resolve-NodeApiPort -LocalPort '8080' -ServerPort '3050' -EnvFile '.env').Port |
            Should -Be 3050
    }

    It "sin ninguno de los dos, no se inventa un default" {
        # Un 8080 por defecto sondea un puerto que nadie declaró y da un verde sin fundamento.
        (Resolve-NodeApiPort -LocalPort '' -ServerPort '' -EnvFile '.env').Level | Should -Be 'error'
    }

    It "un puerto que no es un número es un error, no un cero" {
        (Resolve-NodeApiPort -LocalPort 'ocho mil' -ServerPort '' -EnvFile '.env').Level |
            Should -Be 'error'
    }
}

Describe "Publish-NodeApi — cableado" {

    It "usa el resolvedor de puerto del módulo" {
        $script:Cmdlet | Should -Match 'Resolve-NodeApiPort'
    }

    It "pide el valor de PORT al servidor" {
        $script:Cmdlet | Should -Match "ValueKeys"
    }

    It "el env file deja de ser obligatorio cuando la configuración vive en el servidor" {
        # Es la consecuencia que hace desplegable la API desde CI. Si el guard vuelve a ser
        # incondicional, el runner se queda fuera otra vez.
        $script:Cmdlet | Should -Match 'envEsShared'
    }
}
