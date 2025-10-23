<#
.SYNOPSIS
Convierte una ruta de Windows a una ruta compatible con WSL.

.DESCRIPTION
Esta función helper convierte rutas de Windows al formato requerido por WSL,
utilizando el comando wslpath interno de WSL.

.PARAMETER winPath
La ruta de Windows que se desea convertir.

.EXAMPLE
ConvertTo-WSLPath "C:\Users\usuario\proyecto"
Devuelve la ruta equivalente en formato WSL.

.NOTES
Función helper interna del módulo PSDevOps.
#>
function ConvertTo-WSLPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$winPath,
        
        [Parameter()]
        [string]$WSLDistro = "Ubuntu-22.04"
    )
    
    $p = $winPath.Replace('\','/')
    $cmd = "wsl.exe -d $WSLDistro wslpath -a `"$p`""
    $out = & cmd /c $cmd
    return $out.Trim()
}