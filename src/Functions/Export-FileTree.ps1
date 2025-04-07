function Export-FileTree {
    param(
        [string]$OutputFile = "filetree.md",
        [string[]]$WhiteList = @("assets", "bin", "lib", "src","specs")
    )

    # Ruta del proyecto
    $projectPath = Get-Location
    $tempFile = "$OutputFile.tmp"

    # Función recursiva para generar el árbol de archivos
    function Get-FileTree {
        param(
            [string]$Root,
            [int]$Depth = 0
        )
        $indent = " " * ($Depth * 4)
        $items = Get-ChildItem -Path $Root | Sort-Object -Property @{Expression = { $_.PSIsContainer }; Descending = $true}, Name
        foreach ($item in $items) {
            $escapedName = $item.Name -replace '\[', '\\[' -replace '\]', '\\]'
            if ($item.PSIsContainer) {
                "$indent- **$escapedName/**" | Out-File -FilePath $tempFile -Append -Encoding utf8
                if (($Depth -eq 0 -and ($WhiteList -contains $item.Name)) -or ($Depth -gt 0)) {
                    Get-FileTree -Root $item.FullName -Depth ($Depth + 1)
                }
            } else {
                if ($escapedName -eq $tempFile) {
                    continue
                }
                "$indent- $escapedName" | Out-File -FilePath $tempFile -Append -Encoding utf8
            }
        }
    }

    # Leer el nombre del proyecto desde pubspec.yaml
    $pubspecPath = Join-Path -Path $projectPath -ChildPath "pubspec.yaml"
    $projectName = "Estructura del Proyecto"
    if (Test-Path -Path $pubspecPath) {
        $pubspecContent = Get-Content -Path $pubspecPath -Raw
        if ($pubspecContent -match "name:\s*(\S+)") {
            $projectName = $matches[1]
        }
    }

    # Crear archivo temporal con encabezado
    "## $projectName" | Out-File -FilePath $tempFile -Encoding utf8

    # Generar el árbol de archivos
    Get-FileTree -Root $projectPath

    # Renombrar archivo temporal al archivo final
    Rename-Item -Path $tempFile -NewName $OutputFile
}