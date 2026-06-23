
<#
.SYNOPSIS
Automatiza el flujo de trabajo para fusionar la rama dev en main y subir los cambios a un repositorio remoto.

.DESCRIPTION
El cmdlet `Merge-DevToMain` automatiza el proceso de subir los cambios de la rama dev a un repositorio remoto, cambiar a la rama main, actualizarla, fusionar los cambios de dev en main y subir los cambios de main al repositorio remoto.

.PARAMETER remote
El nombre del repositorio remoto. El valor predeterminado es "origin".

.PARAMETER devBranch
El nombre de la rama de desarrollo. El valor predeterminado es "dev".

.PARAMETER mainBranch
El nombre de la rama principal. El valor predeterminado es "main".

.EXAMPLE
Merge-DevToMain
Automatiza el flujo de trabajo para fusionar la rama dev en main y subir los cambios a un repositorio remoto.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Merge-DevToMain {
    param(
        [string]$remote = "origin",
        [string]$devBranch = "dev",
        [string]$mainBranch = "main"
    )
    Write-Host "Subiendo cambios de $devBranch a $remote..." -ForegroundColor Yellow
    git push $remote $devBranch

    Write-Host "Cambiando a $mainBranch..." -ForegroundColor Yellow
    git checkout $mainBranch
    git fetch $remote
    git pull $remote $mainBranch

    Write-Host "Fusionando $devBranch en $mainBranch..." -ForegroundColor Yellow
    git merge $devBranch

    Write-Host "Subiendo cambios de $mainBranch a $remote..." -ForegroundColor Yellow
    git push $remote $mainBranch

    Write-Host "Regresando a $devBranch..." -ForegroundColor Yellow
    git checkout $devBranch
}