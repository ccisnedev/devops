# FlutterWebPlan.Tests.ps1
# Tests de la lógica de decisión del plan de Publish-FlutterWeb (ADR 0009).
#
# Cubren `ConvertTo-FlutterWebPlan`, que es la parte PURA del builder: mapea los tres estados
# crudos del sondeo (Current/Release/Nginx) a filas con severidad y a la lista de acciones.
# Al estar separada de `Invoke-FlutterWebProbe` (el I/O por SSH) se puede testear sin servidor.
# El sondeo real contra un servidor vivo se cubre en PublishFlutterWebPlan.container.test.ps1.

BeforeAll {
    . "$PSScriptRoot/../Private/DeployPlan.ps1"
    . "$PSScriptRoot/../Private/FlutterWebPlan.ps1"

    function New-Probe {
        param([string]$Current = 'v1.0.0', [string]$Release = 'new', [string]$Nginx = 'exists')
        return [pscustomobject]@{ Current = $Current; Release = $Release; Nginx = $Nginx }
    }

    function New-PlanFrom {
        param($Probe)
        return ConvertTo-FlutterWebPlan -Probe $Probe -AppName 'pyme' -Release 'v1.2.3' `
            -Server 'prod' -IP '10.0.0.5' -Port 4020 -RemoteWebRoot '/var/www'
    }

    function Get-Row {
        param($Plan, [string]$Label)
        return ConvertTo-DeployPlanRow $Plan.Sections['Estado del servidor'][$Label]
    }
}

Describe "ConvertTo-FlutterWebPlan — identidad del plan" {
    It "fija el cmdlet y el target a partir de server e IP" {
        $plan = New-PlanFrom (New-Probe)
        $plan.Cmdlet | Should -Be 'Publish-FlutterWeb'
        $plan.Target | Should -Be 'prod (10.0.0.5)'
    }

    It "expone la configuración local leída del proyecto" {
        $local = (New-PlanFrom (New-Probe)).Sections['Configuración local']
        $local['Proyecto'] | Should -Be 'pyme'
        $local['Versión'] | Should -Be 'v1.2.3'
        $local['Servidor'] | Should -Be 'prod (10.0.0.5)'
        $local['Puerto'] | Should -Be '4020'
    }

    It "no hace I/O (es puro: no necesita servidor ni clave SSH)" {
        { New-PlanFrom (New-Probe) } | Should -Not -Throw
    }
}

Describe "ConvertTo-FlutterWebPlan — fila Current" {
    It "marca 'none' como primer deploy con nivel warn" {
        $row = Get-Row (New-PlanFrom (New-Probe -Current 'none')) 'Current'
        $row.Text | Should -Be '(primer deploy)'
        $row.Level | Should -Be 'warn'
    }

    It "muestra la versión desplegada con nivel info" {
        $row = Get-Row (New-PlanFrom (New-Probe -Current 'v0.9.1')) 'Current'
        $row.Text | Should -Be 'v0.9.1'
        $row.Level | Should -Be 'info'
    }
}

Describe "ConvertTo-FlutterWebPlan — fila Release" {
    It "avisa (warn) si la release destino ya existe: se sobrescribe" {
        $row = Get-Row (New-PlanFrom (New-Probe -Release 'exists')) 'Release'
        $row.Text | Should -Match 'ya existe'
        $row.Level | Should -Be 'warn'
    }

    It "marca una release nueva como ok" {
        $row = Get-Row (New-PlanFrom (New-Probe -Release 'new')) 'Release'
        $row.Text | Should -Be 'v1.2.3 (nueva)'
        $row.Level | Should -Be 'ok'
    }
}

Describe "ConvertTo-FlutterWebPlan — fila Nginx" {
    It "config existente => info, y no se modifica" {
        $row = Get-Row (New-PlanFrom (New-Probe -Nginx 'exists')) 'Nginx'
        $row.Level | Should -Be 'info'
        $row.Text | Should -Match 'no se modifica'
    }

    It "will-create => ok, nombrando el puerto" {
        $row = Get-Row (New-PlanFrom (New-Probe -Nginx 'will-create')) 'Nginx'
        $row.Level | Should -Be 'ok'
        $row.Text | Should -Match '4020'
    }

    # Este es el caso que -Apply debe convertir en abort: el plan ya sabe que el deploy fallará.
    It "port-in-use => error (única severidad bloqueante)" {
        $row = Get-Row (New-PlanFrom (New-Probe -Nginx 'port-in-use')) 'Nginx'
        $row.Level | Should -Be 'error'
        $row.Text | Should -Match 'PUERTO 4020 EN USO'
    }
}

Describe "ConvertTo-FlutterWebPlan — acciones" {
    It "lista los 5 pasos base cuando nginx ya existe" {
        $plan = New-PlanFrom (New-Probe -Nginx 'exists')
        $plan.Actions.Count | Should -Be 5
        $plan.Actions | Should -Not -Contain 'Crear configuración nginx en puerto 4020'
    }

    It "añade el paso de nginx cuando la config no existe" {
        $plan = New-PlanFrom (New-Probe -Nginx 'will-create')
        $plan.Actions.Count | Should -Be 6
        $plan.Actions | Should -Contain 'Crear configuración nginx en puerto 4020'
    }

    It "también añade el paso de nginx cuando el puerto está en uso" {
        (New-PlanFrom (New-Probe -Nginx 'port-in-use')).Actions.Count | Should -Be 6
    }
}

Describe "ConvertTo-FlutterWebPlan — integración con Get-DeployPlanBlocker" {
    It "un plan con el puerto ocupado produce exactamente un bloqueante" {
        $blockers = @(Get-DeployPlanBlocker -Plan (New-PlanFrom (New-Probe -Nginx 'port-in-use')))
        $blockers.Count | Should -Be 1
        $blockers[0] | Should -Match 'Nginx: PUERTO 4020 EN USO'
    }

    It "un plan sano no produce bloqueantes, ni siquiera con avisos" {
        $probe = New-Probe -Current 'none' -Release 'exists' -Nginx 'will-create'
        @(Get-DeployPlanBlocker -Plan (New-PlanFrom $probe)).Count | Should -Be 0
    }
}

Describe "ConvertTo-FlutterWebPlan — el site debe servir desde 'current'" {

    # Caso real que lo motivo: micro sirve con `root /var/www/micro;` --plano, sin symlink--.
    # El deploy creaba releases/ y movia current, reportaba DEPLOYED y terminaba en verde, pero
    # nginx seguia sirviendo los archivos viejos de la raiz. Un exito falso: nada en la salida
    # delataba que el sitio no habia cambiado.
    #
    # El plan solo comprobaba que el archivo de config existiera, nunca a donde apuntaba.

    It "marca como BLOQUEANTE que el site no apunte a current" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'root-mismatch') -AppName 'micro' `
            -Release 'v0.15.1' -Server 'prod' -IP '10.0.0.5' -Port 3046 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Nginx').Level | Should -Be 'error'
    }

    It "el texto dice que el deploy no se veria, no solo que hay un desajuste" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'root-mismatch') -AppName 'micro' `
            -Release 'v0.15.1' -Server 'prod' -IP '10.0.0.5' -Port 3046 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Nginx').Text | Should -Match 'current'
    }

    # Un bloqueante hace que -Apply aborte antes de compilar (ADR 0009), que es justo lo que
    # habria evitado el despliegue silencioso.
    It "produce un bloqueante que -Apply puede detectar" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'root-mismatch') -AppName 'micro' `
            -Release 'v0.15.1' -Server 'prod' -IP '10.0.0.5' -Port 3046 -RemoteWebRoot '/var/www'
        @(Get-DeployPlanBlocker -Plan $plan).Count | Should -BeGreaterThan 0
    }

    It "no anuncia crear la config: el archivo ya existe, solo apunta mal" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'root-mismatch') -AppName 'micro' `
            -Release 'v0.15.1' -Server 'prod' -IP '10.0.0.5' -Port 3046 -RemoteWebRoot '/var/www'
        ($plan.Actions -join ' ') | Should -Not -Match 'Crear configuración nginx'
    }

    It "un site que si apunta a current sigue siendo informativo" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'exists') -AppName 'impulsa' `
            -Release 'v1.7.1' -Server 'prod' -IP '10.0.0.5' -Port 3048 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Nginx').Level | Should -Be 'info'
    }
}

Describe "Add-EnvDeployKey — el env sembrado no inventa claves de otro runtime" {

    # -Init de Publish-FlutterWeb reutiliza este helper, y la plantilla traia PORT=8080 y
    # NODE_ENV=production: claves de una API Node que en una web estatica no las lee nadie.
    # PORT ademas confunde, porque el puerto de nginx vive en publish.yaml.
    BeforeAll { . "$PSScriptRoot/../Private/PublishHelpers.ps1" }

    It "sin -NodeDefaults siembra solo la clave de destino" {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("envseed_" + [guid]::NewGuid().ToString('N') + ".env")
        Add-EnvDeployKey -Path $f -EnvLabel 'prueba' | Out-Null
        $c = Get-Content $f -Raw
        $c | Should -Match 'MACSS_DEPLOY_SSH_ALIAS='
        $c | Should -Not -Match 'PORT='
        $c | Should -Not -Match 'NODE_ENV='
    }

    It "con -NodeDefaults conserva las de la API Node" {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("envseed_" + [guid]::NewGuid().ToString('N') + ".env")
        Add-EnvDeployKey -Path $f -EnvLabel 'prueba' -NodeDefaults | Out-Null
        $c = Get-Content $f -Raw
        $c | Should -Match 'PORT='
        $c | Should -Match 'NODE_ENV='
    }
}

Describe "ConvertTo-FlutterWebPlan — el puerto declarado vs el que nginx escucha" {

    # publish.yaml declara un puerto; si el site ya existe, ese valor no se aplica a nada --el
    # site no se modifica-- pero sigue usandose para la verificacion final por HTTP. Un puerto
    # equivocado no rompe el deploy, pero hace que el reporte compruebe algo que no es el sitio,
    # y deja el repo documentando un puerto que nadie sirve.
    #
    # No es bloqueante: con el root correcto el deploy funciona igual. Es una advertencia.

    It "advierte cuando el declarado no coincide con el del site" {
        $probe = New-Probe -Nginx 'exists'
        $probe | Add-Member -NotePropertyName NginxPorts -NotePropertyValue @(3046)
        $plan = ConvertTo-FlutterWebPlan -Probe $probe -AppName 'micro' -Release 'v0.15.1' `
            -Server 'prod' -IP '10.0.0.5' -Port 4000 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Puerto').Level | Should -Be 'warn'
    }

    It "el aviso nombra los dos puertos, para poder corregir publish.yaml" {
        $probe = New-Probe -Nginx 'exists'
        $probe | Add-Member -NotePropertyName NginxPorts -NotePropertyValue @(3046)
        $plan = ConvertTo-FlutterWebPlan -Probe $probe -AppName 'micro' -Release 'v0.15.1' `
            -Server 'prod' -IP '10.0.0.5' -Port 4000 -RemoteWebRoot '/var/www'
        $t = (Get-Row -Plan $plan -Label 'Puerto').Text
        $t | Should -Match '4000'
        $t | Should -Match '3046'
    }

    It "no advierte cuando coinciden" {
        $probe = New-Probe -Nginx 'exists'
        $probe | Add-Member -NotePropertyName NginxPorts -NotePropertyValue @(3048)
        $plan = ConvertTo-FlutterWebPlan -Probe $probe -AppName 'impulsa' -Release 'v1.7.1' `
            -Server 'prod' -IP '10.0.0.5' -Port 3048 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Puerto').Level | Should -Not -Be 'warn'
    }

    # Un site puede escuchar en varios puertos (80, 443 y el dedicado). Basta con que el
    # declarado este entre ellos.
    It "acepta que el site escuche en varios puertos si el declarado esta entre ellos" {
        $probe = New-Probe -Nginx 'exists'
        $probe | Add-Member -NotePropertyName NginxPorts -NotePropertyValue @(80, 443, 3048)
        $plan = ConvertTo-FlutterWebPlan -Probe $probe -AppName 'impulsa' -Release 'v1.7.1' `
            -Server 'prod' -IP '10.0.0.5' -Port 3048 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Puerto').Level | Should -Not -Be 'warn'
    }

    # Sin sondeo de puertos (site que no existe aun) no hay nada que comparar.
    It "no advierte si no hay puertos sondeados" {
        $plan = ConvertTo-FlutterWebPlan -Probe (New-Probe -Nginx 'will-create') -AppName 'nueva' `
            -Release 'v1.0.0' -Server 'prod' -IP '10.0.0.5' -Port 4100 -RemoteWebRoot '/var/www'
        (Get-Row -Plan $plan -Label 'Puerto').Level | Should -Not -Be 'warn'
    }
}

Describe "Publish-FlutterWeb — el puerto declarado debe ser un puerto" {

    # El template siembra '<PORT>' en vez de un numero: un default plausible como 4000 se queda
    # tal cual y acaba desplegando contra un puerto que nadie sirve. El placeholder solo sirve si
    # el cmdlet lo rechaza antes de tocar el servidor.
    BeforeAll {
        Get-Module 'macss-devops' -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force

        function New-AppWith {
            param([string]$Port)
            $d = Join-Path ([IO.Path]::GetTempPath()) ("fwport_" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content (Join-Path $d 'pubspec.yaml')  "name: t`nversion: 1.0.0" -Encoding UTF8
            Set-Content (Join-Path $d 'publish.yaml')  "port: $Port" -Encoding UTF8
            Set-Content (Join-Path $d '.env')          'MACSS_DEPLOY_SSH_ALIAS=alias-inexistente-xyz' -Encoding UTF8
            return $d
        }
        function Get-PlanError {
            param([string]$Dir)
            Push-Location $Dir
            try { Publish-FlutterWeb -Plan *> $null; return $null } catch { return $_.Exception.Message } finally { Pop-Location }
        }
    }

    It "rechaza el placeholder del template" {
        Get-PlanError (New-AppWith -Port '<PORT>') | Should -Match 'no es un puerto valido'
    }

    It "rechaza un puerto fuera de rango" {
        Get-PlanError (New-AppWith -Port '70000') | Should -Match 'no es un puerto valido'
    }

    It "acepta un puerto valido y sigue hasta el servidor" {
        # Falla despues, al resolver el alias SSH inexistente: la validacion de puerto ya paso.
        Get-PlanError (New-AppWith -Port '3046') | Should -Not -Match 'no es un puerto valido'
    }
}
