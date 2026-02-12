function New-Issue {
    <#
    .SYNOPSIS
        Crea una nueva issue en GitHub desde un archivo markdown con formato frontmatter.
    
    .DESCRIPTION
        Lee un archivo markdown con formato frontmatter YAML que contiene el título,
        labels y cuerpo de una issue, y la crea en el repositorio de GitHub actual.
        
        El archivo debe tener el siguiente formato:
        ---
        title: Título de la issue
        labels: bug,enhancement
        ---
        
        Cuerpo de la issue en markdown...
    
    .PARAMETER Path
        Ruta al archivo markdown que contiene la definición de la issue.
        El archivo debe tener formato frontmatter YAML válido.
    
    .PARAMETER Repository
        Repositorio de GitHub donde crear la issue.
        Formato: owner/repo
        Si no se especifica, usa el repositorio del directorio actual.
    
    .PARAMETER WhatIf
        Muestra qué se haría sin crear realmente la issue.
    
    .EXAMPLE
        New-Issue -Path .\issues\bug-login.md

        Crea una issue en el repositorio actual usando el archivo especificado.

    .EXAMPLE
        New-Issue -Path .\issues\feature-dark-mode.md -Repository "usuario/proyecto"

        Crea una issue en un repositorio específico.

    .EXAMPLE
        New-Issue -Path .\issues\bug-performance.md -WhatIf
        Muestra un preview de la issue sin crearla realmente.
    
    .NOTES
        Requiere:
        - GitHub CLI (gh) instalado y autenticado
        - Estar en un repositorio Git (si no se especifica -Repository)
        
        Author: @ccisnedev
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(
            Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName,
            HelpMessage = "Ruta al archivo de issue con formato frontmatter YAML"
        )]
        [ValidateScript({
            if (-not (Test-Path $_ -PathType Leaf)) {
                throw "El archivo '$_' no existe"
            }
            if ($_ -notmatch '\.(md|markdown)$') {
                throw "El archivo debe ser un archivo markdown (.md o .markdown)"
            }
            $true
        })]
        [string]$Path,

        [Parameter(
            HelpMessage = "Repositorio GitHub (formato: owner/repo)"
        )]
        [ValidatePattern('^[\w-]+/[\w-]+$')]
        [string]$Repository
    )

    begin {
        $ErrorActionPreference = 'Stop'
        Write-Verbose "Iniciando New-Issue"
    }

    process {
        try {
            # Banner
            Write-Host ""
            Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║         🎫 CREAR NUEVA ISSUE EN GITHUB                    ║" -ForegroundColor Cyan
            Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host ""

            # Validación 1: GitHub CLI
            Write-Host "🔍 Verificando GitHub CLI..." -ForegroundColor Yellow
            if (-not (Test-GitHubCLI)) {
                throw "GitHub CLI no está disponible"
            }
            Write-Host "   ✅ GitHub CLI disponible y autenticado" -ForegroundColor Green
            Write-Host ""

            # Validación 2: Repositorio Git (solo si no se especifica -Repository)
            if (-not $Repository) {
                Write-Host "🔍 Verificando repositorio Git..." -ForegroundColor Yellow
                if (-not (Test-GitRepository)) {
                    throw "No estás en un repositorio Git y no especificaste -Repository"
                }
                Write-Host "   ✅ Repositorio Git válido" -ForegroundColor Green
                Write-Host ""
            }

            # Validación 3: Leer y parsear archivo
            Write-Host "📄 Leyendo archivo de issue..." -ForegroundColor Yellow
            Write-Host "   Archivo: $Path" -ForegroundColor Gray
            
            $resolvedPath = Resolve-Path $Path
            $issueData = Read-IssueFile -Path $resolvedPath
            
            Write-Host "   ✅ Archivo parseado correctamente" -ForegroundColor Green
            Write-Host ""

            # Mostrar información de la issue
            Write-Host "📋 INFORMACIÓN DE LA ISSUE" -ForegroundColor Cyan
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
            Write-Host "   Título:  " -NoNewline -ForegroundColor Yellow
            Write-Host $issueData.Title -ForegroundColor White
            
            if ($issueData.Labels) {
                $formattedLabels = Format-Labels -Labels $issueData.Labels
                Write-Host "   Labels:  " -NoNewline -ForegroundColor Yellow
                Write-Host $formattedLabels -ForegroundColor Magenta
            } else {
                Write-Host "   Labels:  " -NoNewline -ForegroundColor Yellow
                Write-Host "(ninguno)" -ForegroundColor DarkGray
            }
            
            Write-Host "   Cuerpo:  " -NoNewline -ForegroundColor Yellow
            Write-Host "$($issueData.Body.Length) caracteres" -ForegroundColor Gray
            Write-Host ""

            # WhatIf: Mostrar preview y salir
            if ($PSCmdlet.ShouldProcess($issueData.Title, "Crear issue en GitHub")) {
                
                # Crear archivo temporal para el cuerpo
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    Set-Content -Path $tempFile -Value $issueData.Body -Encoding UTF8 -NoNewline

                    # Construir comando gh issue create
                    $ghArgs = @('issue', 'create', '--title', $issueData.Title, '--body-file', $tempFile)
                    
                    if ($issueData.Labels) {
                        $formattedLabels = Format-Labels -Labels $issueData.Labels
                        $ghArgs += @('--label', $formattedLabels)
                    }
                    
                    if ($Repository) {
                        $ghArgs += @('--repo', $Repository)
                    }

                    Write-Host "🚀 Creando issue en GitHub..." -ForegroundColor Yellow
                    Write-Verbose "Ejecutando: gh $($ghArgs -join ' ')"
                    
                    # Ejecutar gh issue create
                    $output = & gh @ghArgs 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host ""
                        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
                        Write-Host "║            ✅ ISSUE CREADA EXITOSAMENTE                   ║" -ForegroundColor Green
                        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
                        Write-Host ""
                        Write-Host "🔗 URL: $output" -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Mostrar últimas issues
                        Write-Host "📋 Últimas issues del repositorio:" -ForegroundColor Yellow
                        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
                        
                        $listArgs = @('issue', 'list', '--limit', '5')
                        if ($Repository) {
                            $listArgs += @('--repo', $Repository)
                        }
                        & gh @listArgs
                        Write-Host ""
                        
                        # Retornar URL de la issue
                        return [PSCustomObject]@{
                            Success = $true
                            IssueUrl = $output.ToString().Trim()
                            Title = $issueData.Title
                            Labels = $issueData.Labels
                        }
                    }
                    else {
                        throw "Error al crear issue: $output"
                    }
                }
                finally {
                    # Limpiar archivo temporal
                    if (Test-Path $tempFile) {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "ℹ️  Modo WhatIf: No se creó ninguna issue" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "PREVIEW DEL CUERPO:" -ForegroundColor Yellow
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
                Write-Host $issueData.Body -ForegroundColor Gray
                Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
                Write-Host ""
                
                return [PSCustomObject]@{
                    Success = $false
                    WhatIf = $true
                    Title = $issueData.Title
                    Labels = $issueData.Labels
                }
            }
        }
        catch {
            Write-Host ""
            Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "║                    ❌ ERROR                                ║" -ForegroundColor Red
            Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            
            if ($_.Exception.Message -notmatch "formato|frontmatter|title") {
                Write-Host "💡 Para ver el formato esperado del archivo, revisa:" -ForegroundColor Yellow
                $templatePath = Join-Path $PSScriptRoot "..\Resources\New-Issue\templates\issue-template.md"
                Write-Host "   $templatePath" -ForegroundColor Cyan
                Write-Host ""
            }
            
            throw
        }
    }

    end {
        Write-Verbose "New-Issue completado"
    }
}
