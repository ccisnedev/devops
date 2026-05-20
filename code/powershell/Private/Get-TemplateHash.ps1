function Get-TemplateHash {
    <#
    .SYNOPSIS
    Calcula el hash SHA1 de un template de workflow excluyendo las líneas de versión y hash.

    .DESCRIPTION
    Filtra las líneas que comienzan con "# Version:" y "# SHA1:" del contenido,
    luego calcula el SHA1 del contenido restante.

    .PARAMETER Content
    Contenido del template como string.

    .OUTPUTS
    String de 40 caracteres hexadecimales (SHA1) o $null si el contenido está vacío.
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

    $filteredLines = $Content -split "`n" | Where-Object {
        $_ -notmatch '^# Version:\s' -and $_ -notmatch '^# SHA1:\s'
    }

    $filtered = ($filteredLines -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($filtered)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hashBytes = $sha1.ComputeHash($bytes)
    return ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ''
}
