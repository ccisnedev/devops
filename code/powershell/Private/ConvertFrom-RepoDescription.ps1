<#
.SYNOPSIS
Convierte una descripción de metadata de repositorio en un PSObject estructurado.

.DESCRIPTION
Parsea una cadena con formato key:value delimitada por | en un PSObject.
Keys desconocidas se preservan en el campo _extra.

.PARAMETER Description
La cadena de metadata a parsear.

.OUTPUTS
PSCustomObject con propiedades: type, stack, deploy, model, ci, criticality, _raw, _extra

.EXAMPLE
$obj = ConvertFrom-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy"
$obj.type   # "flutter-web"
$obj.deploy # "v2.30.23"
#>
function ConvertFrom-RepoDescription {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Description
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Description)) {
            return $null
        }

        $pairs = @{}
        $extra = @{}

        foreach ($segment in $Description.Split('|')) {
            if ($segment -match '^([^:]+):(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2]
                $pairs[$key] = $value
            }
        }

        $knownKeys = @('type', 'stack', 'deploy', 'model', 'ci', 'criticality')
        foreach ($key in $pairs.Keys) {
            if ($key -notin $knownKeys) {
                $extra[$key] = $pairs[$key]
            }
        }

        [PSCustomObject]@{
            type        = if ($pairs.ContainsKey('type'))        { $pairs['type'] }        else { $null }
            stack       = if ($pairs.ContainsKey('stack'))       { $pairs['stack'] }       else { $null }
            deploy      = if ($pairs.ContainsKey('deploy'))      { $pairs['deploy'] }      else { $null }
            model       = if ($pairs.ContainsKey('model'))       { $pairs['model'] }       else { $null }
            ci          = if ($pairs.ContainsKey('ci'))          { $pairs['ci'] }          else { 'github-actions' }
            criticality = if ($pairs.ContainsKey('criticality')) { $pairs['criticality'] } else { 'medium' }
            _raw        = $Description
            _extra      = $extra
        }
    }
}
