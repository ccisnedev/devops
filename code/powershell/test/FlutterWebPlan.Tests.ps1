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
