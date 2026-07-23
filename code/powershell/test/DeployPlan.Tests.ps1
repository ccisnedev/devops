# DeployPlan.Tests.ps1
# Tests para el artefacto de plan compartido (ADR 0009):
# New-DeployPlanRow, ConvertTo-DeployPlanRow, New-DeployPlan, Format-DeployPlanMarkdown,
# Save-DeployPlan, Show-DeployPlan.

BeforeAll {
    . "$PSScriptRoot/../Private/DeployPlan.ps1"

    function New-SamplePlan {
        $sections = [ordered]@{
            'Configuración local' = [ordered]@{
                'Proyecto' = 'pyme'
                'Versión'  = 'v0.9.3'
                'Servidor' = 'prod (192.168.10.18)'
                'Puerto'   = '4020'
            }
            'Estado del servidor' = [ordered]@{
                'Current' = (New-DeployPlanRow -Text '0.7.1' -Level 'info')
                'Release' = (New-DeployPlanRow -Text 'v0.9.3 (nueva)' -Level 'ok')
                'Nginx'   = (New-DeployPlanRow -Text 'PUERTO 4020 EN USO' -Level 'error')
            }
        }
        return New-DeployPlan -Cmdlet 'Publish-FlutterWeb' -Target 'prod (192.168.10.18)' `
            -Sections $sections -Actions @('Compilar', 'Subir', 'Instalar')
    }
}

Describe "New-DeployPlanRow" {
    It "por defecto usa el nivel 'info'" {
        (New-DeployPlanRow -Text 'x').Level | Should -Be 'info'
    }
    It "conserva texto y nivel" {
        $r = New-DeployPlanRow -Text 'algo' -Level 'warn'
        $r.Text | Should -Be 'algo'
        $r.Level | Should -Be 'warn'
    }
    It "rechaza niveles fuera del set" {
        { New-DeployPlanRow -Text 'x' -Level 'critical' } | Should -Throw
    }
}

Describe "ConvertTo-DeployPlanRow" {
    It "envuelve un string plano como fila 'info'" {
        $r = ConvertTo-DeployPlanRow 'texto'
        $r.Text | Should -Be 'texto'
        $r.Level | Should -Be 'info'
    }
    It "deja intacta una fila ya construida" {
        $row = New-DeployPlanRow -Text 'ya' -Level 'error'
        (ConvertTo-DeployPlanRow $row) | Should -Be $row
    }
    It "trata \$null como fila vacía 'muted'" {
        $r = ConvertTo-DeployPlanRow $null
        $r.Text | Should -Be ''
        $r.Level | Should -Be 'muted'
    }
}

Describe "New-DeployPlan" {
    It "expone Cmdlet, Target, Sections y Actions" {
        $plan = New-SamplePlan
        $plan.Cmdlet | Should -Be 'Publish-FlutterWeb'
        $plan.Target | Should -Be 'prod (192.168.10.18)'
        $plan.Sections.Keys | Should -Contain 'Estado del servidor'
        $plan.Actions.Count | Should -Be 3
    }
}

Describe "Format-DeployPlanMarkdown" {
    BeforeAll { $script:md = Format-DeployPlanMarkdown -Plan (New-SamplePlan) -Timestamp '2026-07-23T09:00:00-05:00' }

    It "es un string" { $script:md | Should -BeOfType [string] }
    It "incluye el título con el cmdlet" { $script:md | Should -Match '# Deploy plan — Publish-FlutterWeb' }
    It "incluye el target y el timestamp inyectado" {
        $script:md | Should -Match 'Target:\*\* prod'
        $script:md | Should -Match 'Generated:\*\* 2026-07-23T09:00:00'
    }
    It "renderiza cada sección como tabla" {
        $script:md | Should -Match '## Configuración local'
        $script:md | Should -Match '## Estado del servidor'
        $script:md | Should -Match '\| Campo \| Valor \|'
    }
    It "marca las filas de error con el marcador FAIL" {
        $script:md | Should -Match 'FAIL PUERTO 4020 EN USO'
    }
    It "lista las acciones numeradas" {
        $script:md | Should -Match '## Acciones que realizará -Apply'
        $script:md | Should -Match '1\. Compilar'
        $script:md | Should -Match '3\. Instalar'
    }
    It "omite el timestamp cuando no se pasa" {
        (Format-DeployPlanMarkdown -Plan (New-SamplePlan)) | Should -Not -Match 'Generated'
    }
}

Describe "Save-DeployPlan" {
    BeforeAll {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ("deployplan_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }
    AfterAll {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
    }

    It "escribe el reporte bajo .macss/plans y retorna la ruta" {
        $path = Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root
        Test-Path $path | Should -BeTrue
        $path | Should -Match '\.macss[\\/]plans[\\/]Publish-FlutterWeb-.*\.md$'
    }

    It "el contenido escrito coincide con el markdown formateado" {
        $plan = New-SamplePlan
        $path = Save-DeployPlan -Plan $plan -ProjectRoot $script:root -Timestamp '2026-07-23T09:00:00-05:00'
        $written = Get-Content $path -Raw
        $written | Should -Match '# Deploy plan — Publish-FlutterWeb'
        $written | Should -Match 'FAIL PUERTO 4020 EN USO'
    }

    It "-OutFile fuerza la ruta exacta" {
        $target = Join-Path $script:root 'custom/plan.md'
        $path = Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root -OutFile $target
        $path | Should -Be $target
        Test-Path $target | Should -BeTrue
    }

    It "escribe UTF-8 sin BOM" {
        $path = Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # No debe empezar con el BOM EF BB BF
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}

Describe "Show-DeployPlan" {
    It "renderiza sin lanzar excepción" {
        { Show-DeployPlan -Plan (New-SamplePlan) 6>$null } | Should -Not -Throw
    }
}
