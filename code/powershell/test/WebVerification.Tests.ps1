# WebVerification.Tests.ps1
# Tests de la verificación post-deploy de Publish-FlutterWeb (issue #76).
#
# Cubren `ConvertTo-WebVerification`, la parte PURA: mapea el sondeo crudo del servidor a un
# resultado con severidad. Al estar separada de `Invoke-WebVerificationProbe` (el I/O por SSH)
# se puede testear sin servidor. El sondeo real se cubre en la prueba de contenedor.
#
# Lo que se corrige aquí: el check anterior exigía 200 y trataba cualquier otra cosa como
# sospechosa. Cinco de siete sitios devuelven 301 porque el puerto declarado solo redirige,
# así que el aviso saltaba siempre y dejó de leerse. Y aunque aceptara el 3xx, no probaba
# nada: un redirect responde igual con el symlink movido o sin mover.

BeforeAll {
    . "$PSScriptRoot/../Private/WebVerification.ps1"

    function New-Sonda {
        param(
            [string]$Http = '200',
            [string]$Final = '200',
            [string]$Version = '1.7.3',
            [string]$Location = ''
        )
        return [pscustomobject]@{
            HttpCode      = $Http
            FinalCode     = $Final
            ServedVersion = $Version
            Location      = $Location
        }
    }

    function Get-Resultado {
        param($Sonda, [string]$Esperada = '1.7.3')
        return ConvertTo-WebVerification -Probe $Sonda -ExpectedVersion $Esperada
    }
}

Describe "ConvertTo-WebVerification — respuestas sanas" {

    It "un 200 directo con la versión esperada es 'ok'" {
        $r = Get-Resultado (New-Sonda -Http '200' -Final '200' -Version '1.7.3')
        $r.Level | Should -Be 'ok'
    }

    It "un 301 que termina en 200 con la versión esperada es 'ok'" {
        $r = Get-Resultado (New-Sonda -Http '301' -Final '200' -Version '1.7.3' `
                                      -Location 'https://impulsa.santaisabel.com.pe/')
        $r.Level | Should -Be 'ok'
    }

    It "un 302 también es una respuesta sana, no una anomalía" {
        $r = Get-Resultado (New-Sonda -Http '302' -Final '200' -Version '1.7.3')
        $r.Level | Should -Be 'ok'
    }

    It "el texto del resultado nombra la versión servida" {
        $r = Get-Resultado (New-Sonda -Version '1.7.3')
        $r.Text | Should -Match '1\.7\.3'
    }
}

Describe "ConvertTo-WebVerification — el desajuste de versión es un fallo" {

    It "si la versión servida difiere de la desplegada, es 'error'" {
        $r = Get-Resultado (New-Sonda -Version '1.7.1') -Esperada '1.7.3'
        $r.Level | Should -Be 'error'
    }

    It "el mensaje nombra AMBAS versiones, para que se vea el desajuste" {
        $r = Get-Resultado (New-Sonda -Version '1.7.1') -Esperada '1.7.3'
        $r.Text | Should -Match '1\.7\.1'
        $r.Text | Should -Match '1\.7\.3'
    }

    It "detecta el caso de 'micro': 200 sano pero sirviendo lo viejo" {
        # El sitio respondía bien desde un directorio plano, así que mover 'current' no
        # cambiaba nada. El check anterior lo daba por bueno.
        $r = Get-Resultado (New-Sonda -Http '200' -Final '200' -Version '0.15.0') -Esperada '0.15.1'
        $r.Level | Should -Be 'error'
    }

    It "compara ignorando el build number, que no forma parte de la versión servida" {
        $r = Get-Resultado (New-Sonda -Version '1.7.3') -Esperada '1.7.3+349'
        $r.Level | Should -Be 'ok'
    }
}

Describe "ConvertTo-WebVerification — lo que no se puede afirmar" {

    It "sin version.json es 'warn', no 'error': no se puede afirmar nada" {
        $r = Get-Resultado (New-Sonda -Version '')
        $r.Level | Should -Be 'warn'
    }

    It "el mensaje de 'warn' explica que no se pudo comprobar" {
        $r = Get-Resultado (New-Sonda -Version '')
        $r.Text | Should -Match 'no se pudo|sin version'
    }
}

Describe "ConvertTo-WebVerification — anomalías reales" {

    It "un 404 es 'error'" {
        (Get-Resultado (New-Sonda -Http '404' -Final '404' -Version '')).Level | Should -Be 'error'
    }

    It "un 500 es 'error'" {
        (Get-Resultado (New-Sonda -Http '500' -Final '500' -Version '')).Level | Should -Be 'error'
    }

    It "la ausencia de respuesta ('000') es 'error'" {
        (Get-Resultado (New-Sonda -Http '000' -Final '000' -Version '')).Level | Should -Be 'error'
    }

    It "una cadena de redirección rota es 'error', aunque el primer salto sea 3xx" {
        $r = Get-Resultado (New-Sonda -Http '301' -Final '000' -Version '' `
                                      -Location 'https://impulsa.santaisabel.com.pe/')
        $r.Level | Should -Be 'error'
    }

    It "el mensaje de una anomalía nombra el código recibido" {
        (Get-Resultado (New-Sonda -Http '404' -Final '404' -Version '')).Text | Should -Match '404'
    }
}

Describe "ConvertFrom-WebProbeOutput — leer la salida del sondeo" {
    # Está separado del SSH para que la prueba de contenedor pueda tomar la salida de un nginx
    # real y llevarla hasta el veredicto. Si el parseo viviera dentro de Invoke-WebVerification,
    # lo único comprobable sin servidor serían las líneas crudas.

    It "extrae las tres claves" {
        $p = ConvertFrom-WebProbeOutput -Lines @('HTTP:301', 'FINAL:200', 'VERSION:1.7.3')
        $p.HttpCode      | Should -Be '301'
        $p.FinalCode     | Should -Be '200'
        $p.ServedVersion | Should -Be '1.7.3'
    }

    It "tolera la salida como una sola cadena con saltos de línea" {
        # ssh puede devolver un string o un arreglo según cómo se consuma; ambas son la misma
        # salida y no pueden dar veredictos distintos.
        $p = ConvertFrom-WebProbeOutput -Lines "HTTP:200`nFINAL:200`nVERSION:1.7.3"
        $p.ServedVersion | Should -Be '1.7.3'
    }

    It "ignora las líneas que no son del sondeo" {
        # Un banner del shell remoto o un aviso de ssh no puede corromper la lectura.
        $p = ConvertFrom-WebProbeOutput -Lines @('Welcome to Ubuntu', 'HTTP:200', 'FINAL:200', 'VERSION:1.7.3')
        $p.FinalCode | Should -Be '200'
    }

    It "deja la versión vacía si el sondeo no la encontró" {
        $p = ConvertFrom-WebProbeOutput -Lines @('HTTP:200', 'FINAL:200', 'VERSION:')
        $p.ServedVersion | Should -BeNullOrEmpty
    }
}

Describe "New-WebVerificationScript — el sondeo" {

    It "sigue la redirección resolviendo el host contra 127.0.0.1" {
        # Sin --resolve, un 'curl -L' sale al DNS público y puede fallar por enrutamiento,
        # salida a internet o hairpin NAT: motivos ajenos al despliegue.
        $s = New-WebVerificationScript -Port 3048
        $s | Should -Match '--resolve'
    }

    It "acepta el certificado del dominio yendo a la IP local" {
        # El certificado es del dominio y la conexión va a 127.0.0.1: sin la opción de
        # inseguro, la validación de la cadena falla y el sondeo no llega a leer nada.
        #
        # Se acepta la forma combinada ('-sk') además de la larga: escribir el patrón como
        # '-k' aislado daba un falso fallo, porque curl agrupa las banderas cortas.
        (New-WebVerificationScript -Port 3048) | Should -Match 'curl\s+-[a-z]*k|--insecure'
    }

    It "consulta /version.json, que es lo que permite afirmar qué se sirve" {
        (New-WebVerificationScript -Port 3048) | Should -Match 'version\.json'
    }

    It "emite las claves que el intérprete espera" {
        $s = New-WebVerificationScript -Port 3048
        foreach ($k in 'HTTP:', 'FINAL:', 'VERSION:') { $s | Should -Match $k }
    }

    It "toma el puerto del destino cuando la redirección lo lleva explícito" {
        # Si el destino es 'http://host:8100/' y se descarta el ':8100', el --resolve se
        # arma para el puerto 80 y no aplica: curl sale al DNS público, que es exactamente
        # lo que --resolve existe para evitar. Se detectó probando contra un nginx real.
        $s = New-WebVerificationScript -Port 3048
        $s | Should -Match 'PUERTO_URL|puerto del destino'
    }
}
