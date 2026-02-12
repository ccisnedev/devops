function Read-IssueFile {
    <#
    .SYNOPSIS
        Lee y parsea un archivo de issue con formato frontmatter YAML.
    
    .DESCRIPTION
        Extrae el título, labels y cuerpo de un archivo markdown con frontmatter YAML.
        Valida la estructura y campos requeridos.
    
    .PARAMETER Path
        Ruta al archivo de issue.
    
    .OUTPUTS
        PSCustomObject con propiedades Title, Labels y Body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ErrorActionPreference = 'Stop'

    try {
        # Leer contenido del archivo
        $content = Get-Content -Path $Path -Raw -Encoding UTF8
        
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "El archivo está vacío"
        }

        # Verificar formato frontmatter
        if (-not $content.StartsWith('---')) {
            Show-IssueFormatHelp
            throw "El archivo debe comenzar con frontmatter YAML (---)"
        }

        # Extraer frontmatter y body
        $pattern = '(?s)^---\s*\r?\n(.*?)\r?\n---\s*\r?\n(.*)$'
        $match = [regex]::Match($content, $pattern)

        if (-not $match.Success) {
            Show-IssueFormatHelp
            throw "Formato de frontmatter inválido. Debe tener --- al inicio y fin del frontmatter."
        }

        $frontmatter = $match.Groups[1].Value
        $body = $match.Groups[2].Value.Trim()

        # Parsear YAML manualmente (simple key: value)
        $title = $null
        $labels = $null

        foreach ($line in $frontmatter -split '\r?\n') {
            $line = $line.Trim()
            if ($line -match '^title:\s*(.+)$') {
                $title = $matches[1].Trim()
            }
            elseif ($line -match '^labels:\s*(.+)$') {
                $labels = $matches[1].Trim()
            }
        }

        # Validar campos requeridos
        if ([string]::IsNullOrWhiteSpace($title)) {
            Show-IssueFormatHelp
            throw "El campo 'title' es requerido en el frontmatter"
        }

        if ([string]::IsNullOrWhiteSpace($body)) {
            Write-Warning "El cuerpo de la issue está vacío"
        }

        # Retornar objeto parseado
        [PSCustomObject]@{
            Title = $title
            Labels = $labels
            Body = $body
        }
    }
    catch {
        throw
    }
}

function Show-IssueFormatHelp {
    <#
    .SYNOPSIS
        Muestra la estructura esperada para un archivo de issue.
    #>
    [CmdletBinding()]
    param()

    $template = @"

╔════════════════════════════════════════════════════════════════╗
║            FORMATO ESPERADO PARA ARCHIVO DE ISSUE              ║
╚════════════════════════════════════════════════════════════════╝

---
title: 🐛 [Bug] Título descriptivo del problema
labels: bug,enhancement,documentation
---

# Descripción

Descripción detallada del problema o feature request.

## Contexto adicional

Información adicional, screenshots, logs, etc.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📝 CAMPOS FRONTMATTER:
   • title:  (REQUERIDO) Título de la issue
   • labels: (OPCIONAL) Labels separados por coma

🏷️  LABELS DISPONIBLES:
   • bug, documentation, duplicate, enhancement
   • good first issue, help wanted, invalid
   • question, wontfix

💡 TIP: Usa emojis como 🐛 (bug), ✨ (feature), 📚 (docs)

"@

    Write-Host $template -ForegroundColor Cyan
}

function Test-GitHubCLI {
    <#
    .SYNOPSIS
        Valida que GitHub CLI esté instalado y autenticado.
    
    .DESCRIPTION
        Verifica la instalación de gh CLI y el estado de autenticación.
    
    .OUTPUTS
        Boolean indicando si gh CLI está listo para usar.
    #>
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'

    # Verificar instalación de gh
    $ghCommand = Get-Command 'gh' -ErrorAction SilentlyContinue
    if (-not $ghCommand) {
        Write-Host "❌ GitHub CLI (gh) no está instalado" -ForegroundColor Red
        Write-Host ""
        Write-Host "📥 Instalar GitHub CLI:" -ForegroundColor Yellow
        Write-Host "   winget install GitHub.cli" -ForegroundColor Cyan
        Write-Host "   https://cli.github.com/" -ForegroundColor Cyan
        return $false
    }

    # Verificar autenticación
    try {
        $null = gh auth status 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ No estás autenticado con GitHub CLI" -ForegroundColor Red
            Write-Host ""
            Write-Host "🔐 Autenticarse con GitHub:" -ForegroundColor Yellow
            Write-Host "   gh auth login" -ForegroundColor Cyan
            return $false
        }
    }
    catch {
        Write-Host "❌ Error al verificar autenticación: $_" -ForegroundColor Red
        return $false
    }

    return $true
}

function Test-GitRepository {
    <#
    .SYNOPSIS
        Verifica que estamos en un repositorio Git válido.
    
    .OUTPUTS
        Boolean indicando si estamos en un repositorio Git.
    #>
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'

    try {
        $null = git rev-parse --git-dir 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ No estás en un repositorio Git" -ForegroundColor Red
            Write-Host ""
            Write-Host "💡 Ejecuta este comando dentro de un repositorio Git" -ForegroundColor Yellow
            return $false
        }
        return $true
    }
    catch {
        Write-Host "❌ Git no está instalado o no se puede ejecutar" -ForegroundColor Red
        return $false
    }
}

function Format-Labels {
    <#
    .SYNOPSIS
        Formatea y valida labels para GitHub.
    
    .PARAMETER Labels
        String con labels separados por coma.
    
    .OUTPUTS
        String con labels formateados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Labels
    )

    if ([string]::IsNullOrWhiteSpace($Labels)) {
        return $null
    }

    # Remover espacios extras y normalizar
    $labelArray = $Labels -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    
    if ($labelArray.Count -eq 0) {
        return $null
    }

    # Retornar labels unidos por coma
    return ($labelArray -join ',')
}
