<#
.SYNOPSIS
Convierte una ruta de Windows a una ruta compatible con WSL.

.DESCRIPTION
Esta función helper convierte rutas de Windows al formato requerido por WSL,
utilizando el comando wslpath interno de WSL.

.PARAMETER winPath
La ruta de Windows que se desea convertir.

.PARAMETER WSLDistro
Nombre de la distribución WSL a usar (default: "Ubuntu-22.04").

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
    
    # Normalizar separadores a forward slash
    $normalized = $winPath.Replace('\','/')
    
    # Ejecutar wslpath directamente (sin cmd /c innecesario)
    $result = & wsl.exe -d $WSLDistro wslpath -a $normalized 2>&1
    
    # Limpiar caracteres de control y espacios
    return ($result -replace '\p{C}', '').Trim()
}