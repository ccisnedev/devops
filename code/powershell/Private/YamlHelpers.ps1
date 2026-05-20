# YamlHelpers.ps1
# Carga bajo demanda para powershell-yaml cuando una función realmente lo necesita.

function Ensure-YamlModule {
    [CmdletBinding()]
    param()

    if (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        return
    }

    try {
        Import-Module powershell-yaml -ErrorAction Stop | Out-Null
    }
    catch {
        throw @"
No se encontró el módulo requerido 'powershell-yaml'.
Instálelo y vuelva a intentar:

  Install-Module powershell-yaml -Scope CurrentUser -Force
"@
    }
}
