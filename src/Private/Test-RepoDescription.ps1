<#
.SYNOPSIS
Valida que una descripción de metadata de repositorio cumple con el schema.

.DESCRIPTION
Prueba una cadena contra el regex del METADATA_SCHEMA y verifica valores de enum.
Retorna $true si es válida, $false si no.

.PARAMETER Description
La cadena de metadata a validar.

.OUTPUTS
[bool]

.EXAMPLE
Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy"
# True
#>
function Test-RepoDescription {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Description
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Description)) {
            return $false
        }

        $regex = '^type:(flutter-web|flutter-apk|node-api|sqlserver-db|macss|tooling|documentation|archived|unknown)\|stack:(dart|javascript|typescript|sql|csharp|generic)\|deploy:(v\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?|none)\|model:(legacy|monorepo)(?:\|ci:(github-actions|manual|none))?(?:\|criticality:(critical|high|medium|low))?$'

        return [bool]($Description -match $regex)
    }
}
