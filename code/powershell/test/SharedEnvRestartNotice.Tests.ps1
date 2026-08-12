# SharedEnvRestartNotice.Tests.ps1
# -PushShared cambia la configuración pero el proceso sigue con la anterior (issue #84).
#
# Cuando los sharedPaths eran llaves RSA, reemplazar el archivo bastaba: la app las lee del disco
# cuando las necesita. El .env no funciona así — se lee UNA VEZ, al arrancar el proceso.
#
# La ADR 0014 promete que cambiar una variable deja de exigir un release. Hoy eso es verdad a
# medias: el archivo cambia y el comportamiento no. El operador ve un comando que termina en
# verde y se va, y la aplicación sigue con el valor anterior.
#
# Un comando que dice "hecho" cuando el efecto buscado no ocurrió es peor que uno que falla.

BeforeAll {
    . "$PSScriptRoot/../Private/EnvContract.ps1"
    $script:Cmdlet = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
}

Describe "New-SharedEnvRestartNotice — decir lo que no ocurrió" {

    It "dice que el proceso sigue con la configuración anterior" {
        $t = New-SharedEnvRestartNotice -ProcessManager 'pm2' -AppName 'impulsa-api' -Server 'prod'
        "$t" | Should -Match 'anterior|no toma efecto|sigue corriendo'
    }

    It "nombra el comando que la aplica, no solo el problema" {
        # Un aviso sin remedio manda a alguien a buscar en la documentación algo que el comando
        # ya sabe.
        "$(New-SharedEnvRestartNotice -ProcessManager 'pm2' -AppName 'impulsa-api' -Server 'prod')" |
            Should -Match 'pm2 restart impulsa-api'
    }

    It "el reinicio de pm2 lleva --update-env" {
        # Sin esa bandera pm2 reutiliza el entorno que ya tenía cargado: el comando parece
        # correcto, se ejecuta sin error, y la variable nueva sigue sin aplicarse.
        "$(New-SharedEnvRestartNotice -ProcessManager 'pm2' -AppName 'x' -Server 'prod')" |
            Should -Match '--update-env'
    }

    It "con systemd nombra systemctl, no pm2" {
        $t = "$(New-SharedEnvRestartNotice -ProcessManager 'systemd' -AppName 'impulsa-api' -Server 'prod')"
        $t | Should -Match 'systemctl restart impulsa-api'
        $t | Should -Not -Match 'pm2'
    }

    It "nombra el servidor, porque el comando se corre allá y no aquí" {
        "$(New-SharedEnvRestartNotice -ProcessManager 'pm2' -AppName 'x' -Server 'prod')" |
            Should -Match 'prod'
    }

    It "ofrece también el camino del despliegue completo" {
        # Un release nuevo también aplica la configuración, y a veces es lo que se quiere.
        "$(New-SharedEnvRestartNotice -ProcessManager 'pm2' -AppName 'x' -Server 'prod')" |
            Should -Match 'Publish-NodeApi -Apply'
    }
}

Describe "Publish-NodeApi — cableado del aviso" {

    It "-PushShared usa el aviso" {
        $script:Cmdlet | Should -Match 'New-SharedEnvRestartNotice'
    }

    It "solo cuando se subió un .env" {
        # Subir una llave RSA no deja nada pendiente: avisar siempre convertiría el aviso en
        # ruido, y un aviso que sale siempre deja de leerse. Ya pasó con el health check.
        $script:Cmdlet | Should -Match "'\.env'\s+-in\s+\`$sharedList|\`$sharedList\s+-contains\s+'\.env'"
    }
}
