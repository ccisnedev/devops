# EnvContract.Tests.ps1
# El .env como sharedPath, con .env.example como contrato verificable (issue #79).
#
# El problema: la configuración de runtime de producción vive solo en la máquina del operador,
# así que CI no puede desplegar la API — no hay origen del que copiarla. El mecanismo para
# arreglarlo ya existía en el módulo y `impulsa` ya lo usaba para otro secreto: las llaves RSA
# son un sharedPath, viven en el servidor, y el despliegue solo las enlaza. El .env era la
# excepción, sin razón que lo justifique.
#
# Por qué la comprobación no es un extra
# --------------------------------------
# Si shared/.env persiste entre releases, una versión que introduzca una variable nueva se
# desplegaría con éxito y fallaría en runtime, porque el archivo del servidor seguiría siendo
# el viejo. Mover el .env sin verificar el contrato cambia un fallo VISIBLE —"no puedo
# desplegar desde CI"— por uno SILENCIOSO, que es peor que el problema original.
#
# Al preparar el issue se compararon las claves reales de impulsa: 6 variables corrían en
# producción sin estar en .env.example, y 5 estaban documentadas sin existir en producción.
# El contrato ya estaba roto en ambas direcciones y nada lo señalaba.

BeforeAll {
    . "$PSScriptRoot/../Private/EnvContract.ps1"
    $script:Cmdlet   = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
    $script:Instalar = Get-Content "$PSScriptRoot/../Private/scripts/Install-NodeApi.sh" -Raw
}

Describe "Publish-NodeApi — cableado del contrato" {

    It "el plan sondea las claves del servidor" {
        $script:Cmdlet | Should -Match 'New-RemoteEnvKeysScript'
    }

    It "y las compara con el módulo, no con sus propios if" {
        $script:Cmdlet | Should -Match 'ConvertTo-EnvContractState'
    }

    It "-Apply no despliega si falta una clave" {
        # Sin este guardia, mover el .env a shared/ cambia un fallo visible por uno silencioso:
        # el despliegue termina en verde y la app falla en runtime con una variable ausente.
        $script:Cmdlet | Should -Match 'Test-EnvContractOrThrow'
    }

    It "-PushShared toma el .env del env file elegido" {
        $script:Cmdlet | Should -Match 'Resolve-SharedSourcePath'
    }
}

Describe "Install-NodeApi.sh — el .env enlazado no es un archivo ausente" {

    It "no avisa de un .env que falta cuando es un sharedPath" {
        # El aviso "No se encontró" era correcto cuando el .env se subía siempre. Con el .env
        # como sharedPath no se sube: lo enlaza el paso siguiente, y avisar de su ausencia
        # convierte lo normal en sospechoso.
        $script:Instalar | Should -Match 'SHARED_PATHS'
        $script:Instalar | Should -Match 'env_es_shared|ENV_ES_SHARED'
    }
}

Describe "Get-DotEnvKeys — leer nombres, nunca valores" {

    It "extrae los nombres de las claves" {
        $k = Get-DotEnvKeys -Lines @('DB_HOST=localhost', 'DB_PORT=5432')
        $k | Should -Be @('DB_HOST', 'DB_PORT')
    }

    It "no devuelve ningún valor" {
        # El plan compara contratos, no lee secretos. Es la garantía que permite ejecutarlo
        # contra producción sin pensarlo dos veces.
        $k = Get-DotEnvKeys -Lines @('JWT_SECRET=un-secreto-de-verdad')
        "$k" | Should -Not -Match 'un-secreto'
    }

    It "ignora comentarios y líneas en blanco" {
        $k = Get-DotEnvKeys -Lines @('# comentario', '', '   ', 'FOO=1')
        $k | Should -Be @('FOO')
    }

    It "acepta la forma 'export'" {
        (Get-DotEnvKeys -Lines @('export FOO=1')) | Should -Be @('FOO')
    }

    It "tolera espacios alrededor del igual" {
        (Get-DotEnvKeys -Lines @('  FOO = 1')) | Should -Be @('FOO')
    }

    It "una clave declarada sin valor sigue siendo parte del contrato" {
        # En un .env.example lo normal es justamente eso: 'DB_PASSWORD=' sin valor.
        (Get-DotEnvKeys -Lines @('DB_PASSWORD=')) | Should -Be @('DB_PASSWORD')
    }

    It "un valor que contiene un igual no inventa una segunda clave" {
        (Get-DotEnvKeys -Lines @('URL=https://x/?a=1')) | Should -Be @('URL')
    }

    It "ignora lo que no es una asignación" {
        (Get-DotEnvKeys -Lines @('esto no es una clave', 'FOO=1')) | Should -Be @('FOO')
    }

    It "no repite una clave declarada dos veces" {
        (Get-DotEnvKeys -Lines @('FOO=1', 'FOO=2')) | Should -Be @('FOO')
    }

    It "sin contenido devuelve una lista vacía, no un error" {
        @(Get-DotEnvKeys -Lines @()).Count | Should -Be 0
    }
}

Describe "ConvertTo-EnvContractState — el contrato entre el código y el servidor" {

    It "las mismas claves son 'ok'" {
        $r = ConvertTo-EnvContractState -ExampleKeys @('A', 'B') -ServerKeys @('B', 'A')
        $r.Level | Should -Be 'ok'
    }

    It "una clave que falta en el servidor es bloqueante" {
        # Es el caso que existe para impedir: la release nueva necesita una variable que el
        # servidor no tiene, y sin esto el despliegue termina en verde y la app falla en runtime.
        $r = ConvertTo-EnvContractState -ExampleKeys @('A', 'B') -ServerKeys @('A')
        $r.Level | Should -Be 'error'
        $r.Missing | Should -Be @('B')
    }

    It "dice qué clave falta, porque es lo que hay que ir a agregar" {
        $r = ConvertTo-EnvContractState -ExampleKeys @('A', 'OTP_SERVICE_URL') -ServerKeys @('A')
        $r.Text | Should -Match 'OTP_SERVICE_URL'
    }

    It "una clave que sobra en el servidor avisa, no bloquea" {
        # Puede ser configuración obsoleta o un ejemplo que se quedó atrás. Ninguna de las dos
        # impide que la release corra.
        $r = ConvertTo-EnvContractState -ExampleKeys @('A') -ServerKeys @('A', 'VIEJA')
        $r.Level | Should -Be 'warn'
        $r.Extra | Should -Be @('VIEJA')
    }

    It "si falta una y sobra otra, manda la que bloquea" {
        $r = ConvertTo-EnvContractState -ExampleKeys @('A', 'NUEVA') -ServerKeys @('A', 'VIEJA')
        $r.Level   | Should -Be 'error'
        $r.Missing | Should -Be @('NUEVA')
        $r.Extra   | Should -Be @('VIEJA')
    }

    It "sin .env.example avisa: no se puede afirmar nada" {
        $r = ConvertTo-EnvContractState -ExampleKeys $null -ServerKeys @('A')
        $r.Level | Should -Be 'warn'
        $r.Text  | Should -Match '\.env\.example'
    }

    It "sin .env.example NO bloquea el despliegue" {
        # La ausencia del contrato no es prueba de que el servidor esté mal.
        (ConvertTo-EnvContractState -ExampleKeys $null -ServerKeys @('A')).Level | Should -Not -Be 'error'
    }

    It "sin .env en el servidor es bloqueante y dice cómo poblarlo" {
        $r = ConvertTo-EnvContractState -ExampleKeys @('A') -ServerKeys $null
        $r.Level | Should -Be 'error'
        $r.Text  | Should -Match 'PushShared'
    }

    It "ningún mensaje transporta un valor" {
        $r = ConvertTo-EnvContractState -ExampleKeys @('JWT_SECRET') -ServerKeys @()
        $r.Text | Should -Not -Match '='
    }
}

Describe "New-RemoteEnvKeysScript — el sondeo del servidor" {

    It "emite los nombres de las claves" {
        (New-RemoteEnvKeysScript -SharedEnvPath '/opt/app/demo/shared/.env') | Should -Match 'ENVKEY:'
    }

    It "corta el valor en el servidor: nunca viaja por la red" {
        # La garantía tiene que estar en el sondeo, no en quien lo lee. Un 'cat' del archivo
        # dejaría los secretos en la salida del ssh y en cualquier log que la capture.
        $s = New-RemoteEnvKeysScript -SharedEnvPath '/opt/app/demo/shared/.env'
        $s | Should -Match 'sed'
        $s | Should -Not -Match 'cat\s+"?/opt'
    }

    It "distingue que el archivo no exista" {
        (New-RemoteEnvKeysScript -SharedEnvPath '/opt/app/demo/shared/.env') | Should -Match 'ENVFILE:absent'
    }

    It "consulta la ruta que se le da" {
        (New-RemoteEnvKeysScript -SharedEnvPath '/opt/app/impulsa/shared/.env') | Should -Match 'impulsa'
    }
}

Describe "ConvertFrom-EnvKeysOutput — leer el sondeo" {

    It "devuelve las claves cuando el archivo existe" {
        $r = ConvertFrom-EnvKeysOutput -Lines @('ENVFILE:present', 'ENVKEY:A', 'ENVKEY:B')
        $r | Should -Be @('A', 'B')
    }

    It "devuelve null cuando el archivo no existe, que no es lo mismo que vacío" {
        # Un .env ausente y un .env sin claves llevan a mensajes distintos: uno se arregla con
        # -PushShared y el otro es un archivo que alguien vació.
        ConvertFrom-EnvKeysOutput -Lines @('ENVFILE:absent') | Should -BeNullOrEmpty
    }

    It "un archivo presente y sin claves es una lista vacía, no null" {
        $r = ConvertFrom-EnvKeysOutput -Lines @('ENVFILE:present')
        $null -eq $r | Should -BeFalse
        @($r).Count  | Should -Be 0
    }

    It "ignora lo que no es del sondeo" {
        (ConvertFrom-EnvKeysOutput -Lines @('Welcome to Ubuntu', 'ENVFILE:present', 'ENVKEY:A')) | Should -Be @('A')
    }
}

Describe "Invoke-EnvContractCheck — la composición" {
    # Las partes puras pueden estar bien y la composición no funcionar: ya pasó en la
    # verificación web, donde el sondeo se ejecutaba con una función que devuelve el código de
    # salida en vez de las líneas.

    BeforeAll {
        function Invoke-RemoteScriptCapture { param($ScriptContent, $User, $IP, $Port, $KeyPath, $ScriptPrefix) }
        $script:Ejemplo = Join-Path $TestDrive '.env.example'
        Set-Content -LiteralPath $script:Ejemplo -Value @('A=', 'B=')
    }

    It "compara lo que declara el ejemplo contra lo que responde el servidor" {
        Mock Invoke-RemoteScriptCapture { @('ENVFILE:present', 'ENVKEY:A', 'ENVKEY:B') }
        $r = Invoke-EnvContractCheck -SharedEnvPath '/opt/app/d/shared/.env' -ExamplePath $script:Ejemplo `
                                     -User 'u' -IP '1.2.3.4' -SshPort '22' -KeyPath 'k'
        $r.Level | Should -Be 'ok'
    }

    It "una clave que el servidor no tiene llega hasta el veredicto" {
        Mock Invoke-RemoteScriptCapture { @('ENVFILE:present', 'ENVKEY:A') }
        $r = Invoke-EnvContractCheck -SharedEnvPath '/opt/app/d/shared/.env' -ExamplePath $script:Ejemplo `
                                     -User 'u' -IP '1.2.3.4' -SshPort '22' -KeyPath 'k'
        $r.Level   | Should -Be 'error'
        $r.Missing | Should -Be @('B')
    }

    It "sin .env.example no se afirma nada" {
        Mock Invoke-RemoteScriptCapture { @('ENVFILE:present', 'ENVKEY:A') }
        $r = Invoke-EnvContractCheck -SharedEnvPath '/opt/app/d/shared/.env' `
                                     -ExamplePath (Join-Path $TestDrive 'no-existe.example') `
                                     -User 'u' -IP '1.2.3.4' -SshPort '22' -KeyPath 'k'
        $r.Level | Should -Be 'warn'
    }
}

Describe "Test-EnvContractOrThrow — el guardia de -Apply" {

    BeforeAll {
        function Invoke-RemoteScriptCapture { param($ScriptContent, $User, $IP, $Port, $KeyPath, $ScriptPrefix) }
        $script:Ejemplo2 = Join-Path $TestDrive 'ej2.example'
        Set-Content -LiteralPath $script:Ejemplo2 -Value @('A=', 'B=')
    }

    It "aborta el despliegue si falta una clave" {
        Mock Invoke-RemoteScriptCapture { @('ENVFILE:present', 'ENVKEY:A') }
        { Test-EnvContractOrThrow -SharedEnvPath '/x/.env' -ExamplePath $script:Ejemplo2 `
                                  -User 'u' -IP '1.2.3.4' -SshPort '22' -KeyPath 'k' } |
            Should -Throw -ExpectedMessage '*B*'
    }

    It "no aborta por una clave de más" {
        Mock Invoke-RemoteScriptCapture { @('ENVFILE:present', 'ENVKEY:A', 'ENVKEY:B', 'ENVKEY:C') }
        { Test-EnvContractOrThrow -SharedEnvPath '/x/.env' -ExamplePath $script:Ejemplo2 `
                                  -User 'u' -IP '1.2.3.4' -SshPort '22' -KeyPath 'k' } |
            Should -Not -Throw
    }
}

Describe "Resolve-SharedSourcePath — de dónde sale el .env que se sube" {

    It "el .env se toma del env file elegido, no del .env local" {
        # ADR 0004: -EnvFile selecciona el entorno. Sin esto, '-PushShared -EnvFile
        # .env.production' subiría la configuración de desarrollo a producción, que es
        # exactamente el accidente que el sharedPath tiene que evitar.
        $p = Resolve-SharedSourcePath -SharedPath '.env' -ProjectRoot 'C:\proj' -EnvFile '.env.production'
        $p | Should -Match '\.env\.production$'
    }

    It "cualquier otro sharedPath es su propia ruta" {
        $p = Resolve-SharedSourcePath -SharedPath 'key' -ProjectRoot 'C:\proj' -EnvFile '.env.production'
        $p | Should -Match 'key$'
    }

    It "con el env file por defecto, el .env es el .env" {
        $p = Resolve-SharedSourcePath -SharedPath '.env' -ProjectRoot 'C:\proj' -EnvFile '.env'
        $p | Should -Match '\.env$'
    }
}
