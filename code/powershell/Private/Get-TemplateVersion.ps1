function Get-TemplateVersion {
    <#
    .SYNOPSIS
    Extrae la versión semver del encabezado de un template de workflow.

    .DESCRIPTION
    Busca la línea "# Version: vX.Y.Z" en el contenido y retorna la versión.

    .PARAMETER Content
    Contenido del template como string.

    .OUTPUTS
    String con la versión (e.g. "v1.0.0") o $null si no se encuentra.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    if ($Content -match '# Version:\s+(v\d+\.\d+\.\d+)') {
        return $Matches[1]
    }

    return $null
}
