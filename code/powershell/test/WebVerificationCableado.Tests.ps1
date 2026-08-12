# WebVerificationCableado.Tests.ps1
# Verifica que Publish-FlutterWeb USE la verificación, no solo que la verificación exista.
#
# Existe por una lección concreta: en la migración a la identidad de base desde el .sqlproj
# se implementó el helper, pasaron sus tests, y nadie lo llamaba. El cmdlet siguió pidiendo
# DB_NAME hasta que fallo en uso real. Probar que una pieza funciona no prueba que esté
# conectada.
#
# Se inspecciona el texto del cmdlet en vez de ejecutarlo: un despliegue real necesita
# servidor, y eso ya lo cubre la prueba de contenedor. Aquí solo se afirma el cableado.

BeforeAll {
    $script:Cmdlet = Get-Content "$PSScriptRoot/../Functions/Publish-FlutterWeb.ps1" -Raw
}

Describe "Publish-FlutterWeb — cableado de la verificación post-deploy" {

    It "invoca Invoke-WebVerification" {
        $script:Cmdlet | Should -Match 'Invoke-WebVerification'
    }

    It "le pasa la versión que acaba de desplegar, no una constante" {
        $script:Cmdlet | Should -Match '-ExpectedVersion\s+\$appVersion'
    }

    It "ya no usa el check viejo, que solo miraba el código HTTP" {
        # El check anterior exigía 200 y salía con exit 0 pasara lo que pasara: nunca podía
        # fallar un despliegue. Si esta cadena reaparece, alguien lo revivió.
        $script:Cmdlet | Should -Not -Match 'puede necesitar tiempo para iniciar'
    }

    It "un resultado 'error' aborta el despliegue" {
        # Es el punto de todo el cambio: si el sitio no sirve lo desplegado, el cmdlet no
        # puede terminar en verde.
        $script:Cmdlet | Should -Match 'verificación falló'
    }

    It "un resultado 'warn' no aborta" {
        # Sin version.json no se puede afirmar nada; eso no es motivo para fallar.
        $script:Cmdlet | Should -Match "'warn'\s*\{[^}]*AVISO"
    }
}
