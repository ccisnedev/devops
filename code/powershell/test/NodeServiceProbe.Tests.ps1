# NodeServiceProbe.Tests.ps1
# Tests del estado del servicio en `Publish-NodeApi -Plan` (issue #78).
#
# El caso real: planificando sobre un servidor donde la API llevaba 4 h 34 min corriendo, el
# reporte dijo "Servicio: se creará". El servicio existía. El reporte corre por SSH NO
# interactivo, pm2 vive bajo un gestor de versiones de Node que solo se carga en shells
# interactivos, la invocación falla, y el `else` concluye que no hay servicio.
#
# El defecto no rompe el despliegue —el despliegue sí carga nvm antes de llamar a pm2— pero un
# plan existe para que se le crea. Si afirma que va a crear un servicio que lleva horas
# corriendo, quien lo lea con atención va a dudar también de la versión actual y del estado de
# los sharedPaths. La credibilidad se gasta entera.
#
# Regla que se implementa aquí: nunca afirmar un estado que no se pudo comprobar. "No sé" y
# "no hay" tienen que ser salidas distintas.

BeforeAll {
    . "$PSScriptRoot/../Private/NodeServiceProbe.ps1"
    $script:Cmdlet = Get-Content "$PSScriptRoot/../Functions/Publish-NodeApi.ps1" -Raw
}

Describe "Publish-NodeApi — cableado del sondeo" {
    # Un helper probado que nadie llama no corrige nada: ya pasó al migrar la identidad de base
    # desde el .sqlproj, donde el helper pasaba sus tests y el cmdlet seguía pidiendo DB_NAME.

    It "el reporte usa el sondeo del módulo" {
        $script:Cmdlet | Should -Match 'New-NodeServiceProbeScript'
    }

    It "y traduce el estado con el módulo, no con sus propios if" {
        $script:Cmdlet | Should -Match 'ConvertTo-NodeServiceState'
    }

    It "ya no lleva su propia versión del sondeo" {
        # Si reaparece, vuelven a existir dos formas de resolver pm2 y con ellas la discrepancia.
        $script:Cmdlet | Should -Not -Match 'echo "SERVICE:not-configured"'
    }

    It "ya no decide en el cmdlet que el servicio se creará" {
        $script:Cmdlet | Should -Not -Match "Servicio:\s+se creará"
    }
}

Describe "ConvertTo-NodeServiceState — lo que el plan anuncia" {

    It "un servicio corriendo se reiniciará, no se creará" {
        $r = ConvertTo-NodeServiceState -Status 'running' -ProcessManager 'pm2'
        $r.Text | Should -Match 'reinici'
        $r.Text | Should -Not -Match 'creará'
    }

    It "'online' es como pm2 dice 'running'" {
        # pm2 describe reporta 'online'. El código anterior lo pasaba tal cual y caía en la
        # rama de estado desconocido: el plan mostraba "Servicio: online" en amarillo, como si
        # algo anduviera mal, con la API perfectamente arriba.
        $r = ConvertTo-NodeServiceState -Status 'online' -ProcessManager 'pm2'
        $r.Level | Should -Be 'ok'
        $r.Text  | Should -Match 'reinici'
    }

    It "un servicio detenido se iniciará" {
        $r = ConvertTo-NodeServiceState -Status 'stopped' -ProcessManager 'pm2'
        $r.Text | Should -Match 'detenid'
    }

    It "sin servicio, se creará" {
        $r = ConvertTo-NodeServiceState -Status 'not-configured' -ProcessManager 'pm2'
        $r.Level | Should -Be 'ok'
        $r.Text  | Should -Match 'creará'
    }

    It "'errored' es una anomalía, no una nota al pie" {
        (ConvertTo-NodeServiceState -Status 'errored' -ProcessManager 'pm2').Level | Should -Be 'error'
    }

    It "nombra el gestor de procesos, porque la acción depende de cuál sea" {
        (ConvertTo-NodeServiceState -Status 'not-configured' -ProcessManager 'systemd').Text | Should -Match 'systemd'
    }
}

Describe "ConvertTo-NodeServiceState — 'no sé' no es 'no hay'" {

    It "si el binario no se pudo ejecutar, el plan NO afirma que creará el servicio" {
        # Es el defecto entero: la afirmación falsa, no el color del texto.
        $r = ConvertTo-NodeServiceState -Status 'unknown' -ProcessManager 'pm2'
        $r.Text | Should -Not -Match 'creará'
    }

    It "lo declara como no comprobado, y es un aviso" {
        $r = ConvertTo-NodeServiceState -Status 'unknown' -ProcessManager 'pm2'
        $r.Level | Should -Be 'warn'
        $r.Text  | Should -Match 'no se pudo comprobar|no se pudo determinar'
    }

    It "dice por qué, para que sea accionable" {
        # Un 'desconocido' sin causa manda a alguien a mirar el servidor a ciegas.
        (ConvertTo-NodeServiceState -Status 'unknown' -ProcessManager 'pm2').Text | Should -Match 'pm2'
    }

    It "un estado que nadie previó tampoco se convierte en una afirmación" {
        $r = ConvertTo-NodeServiceState -Status 'launching' -ProcessManager 'pm2'
        $r.Text | Should -Not -Match 'creará'
        $r.Text | Should -Match 'launching'
    }
}

Describe "New-NodeServiceProbeScript — el sondeo del servidor" {

    It "resuelve pm2 como lo hace el despliegue: cargando nvm" {
        # El despliegue funciona porque Manage-NodeProcess.sh carga nvm antes de llamar a pm2.
        # El reporte lo llamaba a secas, y por eso plan y apply discrepaban.
        $s = New-NodeServiceProbeScript -ProcessManager 'pm2' -AppName 'demo'
        $s | Should -Match 'nvm\.sh'
    }

    It "resuelve el binario igual que Manage-NodeProcess.sh, no de una segunda forma" {
        # Dos maneras de resolver el mismo binario vuelven a abrir la discrepancia que este
        # cambio cierra. Si el despliegue cambia su forma de resolver, esta prueba lo señala.
        $deploy = Get-Content "$PSScriptRoot/../Private/scripts/Manage-NodeProcess.sh" -Raw
        $sonda  = New-NodeServiceProbeScript -ProcessManager 'pm2' -AppName 'demo'
        foreach ($t in 'NVM_DIR', 'nvm.sh') {
            $deploy | Should -Match ([regex]::Escape($t))
            $sonda  | Should -Match ([regex]::Escape($t))
        }
    }

    It "distingue 'no pude ejecutar pm2' de 'no hay servicio'" {
        $s = New-NodeServiceProbeScript -ProcessManager 'pm2' -AppName 'demo'
        $s | Should -Match 'SERVICE:unknown'
        $s | Should -Match 'SERVICE:not-configured'
    }

    It "con systemd no toca nvm: no tiene nada que ver" {
        $s = New-NodeServiceProbeScript -ProcessManager 'systemd' -AppName 'demo'
        $s | Should -Match 'systemctl'
        $s | Should -Not -Match 'nvm'
    }

    It "systemd también distingue el caso de no poder comprobar" {
        # Si systemctl no está, el servidor no usa systemd para nada: afirmar que no hay
        # servicio es igual de falso que en el caso de pm2.
        (New-NodeServiceProbeScript -ProcessManager 'systemd' -AppName 'demo') | Should -Match 'SERVICE:unknown'
    }

    It "consulta por el nombre de la app" {
        (New-NodeServiceProbeScript -ProcessManager 'pm2' -AppName 'impulsa-api') | Should -Match 'impulsa-api'
    }
}
