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

    # El nombre de archivo se deriva de -Timestamp, no de un Get-Date propio: si no, una llamada
    # "determinista" seguía generando un nombre distinto en cada ejecución.
    It "-Timestamp también fija el nombre del archivo (determinismo completo)" {
        $a = Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root -Timestamp '2026-07-23T09:00:00Z'
        $b = Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root -Timestamp '2026-07-23T09:00:00Z'
        (Split-Path -Leaf $a) | Should -Be (Split-Path -Leaf $b)
        (Split-Path -Leaf $a) | Should -Match '20260723090000\.md$'
    }

    It "un -Timestamp no parseable no rompe la escritura" {
        { Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $script:root -Timestamp 'no-es-fecha' } |
            Should -Not -Throw
    }

    # El reporte lleva alias e IP del servidor: '.macss/' debe auto-ignorarse para que un
    # proyecto consumidor no lo publique por olvidar la entrada en su .gitignore.
    It "crea .macss/.gitignore que ignora todo el directorio" {
        $root = Join-Path $script:root ("gi_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $root | Out-Null
        $ignore = Join-Path $root '.macss/.gitignore'
        Test-Path $ignore | Should -BeTrue
        (Get-Content $ignore -Raw).Trim() | Should -Be '*'
    }

    It "no crea .macss cuando se usa -OutFile" {
        $root = Join-Path $script:root ("of_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Save-DeployPlan -Plan (New-SamplePlan) -ProjectRoot $root -OutFile (Join-Path $root 'p.md') | Out-Null
        Test-Path (Join-Path $root '.macss') | Should -BeFalse
    }
}

Describe "ConvertTo-DeployPlanCell" {
    It "escapa el pipe para que no rompa la columna" {
        ConvertTo-DeployPlanCell -Text 'a | b' | Should -Be 'a \| b'
    }
    It "colapsa saltos de línea a espacio" {
        ConvertTo-DeployPlanCell -Text "a`nb" | Should -Be 'a b'
        ConvertTo-DeployPlanCell -Text "a`r`nb" | Should -Be 'a b'
    }
    It "deja intacto un texto normal" {
        ConvertTo-DeployPlanCell -Text 'v1.2.3 (nueva)' | Should -Be 'v1.2.3 (nueva)'
    }
}

Describe "Format-DeployPlanMarkdown — robustez de la tabla" {
    It "una fila con '|' sigue teniendo exactamente 2 columnas" {
        $sections = [ordered]@{ 'S' = [ordered]@{ 'Cmd' = (New-DeployPlanRow -Text 'a | b' -Level 'info') } }
        $plan = New-DeployPlan -Cmdlet 'X' -Target 't' -Sections $sections
        $row = (Format-DeployPlanMarkdown -Plan $plan) -split "`n" | Where-Object { $_ -like '| Cmd *' }
        # 2 columnas => 3 separadores sin escapar (inicio, medio, fin)
        ([regex]::Matches($row, '(?<!\\)\|')).Count | Should -Be 3
    }
}

Describe "Get-DeployPlanBlocker" {
    It "devuelve las filas de nivel 'error' con su etiqueta" {
        $blockers = @(Get-DeployPlanBlocker -Plan (New-SamplePlan))
        $blockers.Count | Should -Be 1
        $blockers[0] | Should -Be 'Nginx: PUERTO 4020 EN USO'
    }

    # Contrato: emite 0..N strings al stream de salida, así que el llamador envuelve en @().
    # (Un `return ,$array` rompería justo esto: @(cmd) volvería a envolver y contaría 1.)
    It "envuelto en @() cuenta 0 cuando no hay bloqueantes" {
        $sections = [ordered]@{
            'S' = [ordered]@{
                'a' = (New-DeployPlanRow -Text 'ok' -Level 'ok')
                'b' = (New-DeployPlanRow -Text 'cuidado' -Level 'warn')
                'c' = 'texto plano'
            }
        }
        $plan = New-DeployPlan -Cmdlet 'X' -Target 't' -Sections $sections
        $blockers = @(Get-DeployPlanBlocker -Plan $plan)
        $blockers.Count | Should -Be 0
    }

    It "recorre todas las secciones, no solo la primera" {
        $sections = [ordered]@{
            'S1' = [ordered]@{ 'a' = (New-DeployPlanRow -Text 'bien' -Level 'ok') }
            'S2' = [ordered]@{ 'b' = (New-DeployPlanRow -Text 'mal' -Level 'error') }
        }
        $plan = New-DeployPlan -Cmdlet 'X' -Target 't' -Sections $sections
        @(Get-DeployPlanBlocker -Plan $plan).Count | Should -Be 1
    }
}

Describe "Show-DeployPlan" {
    It "renderiza sin lanzar excepción" {
        { Show-DeployPlan -Plan (New-SamplePlan) 6>$null } | Should -Not -Throw
    }
}
