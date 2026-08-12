# EnvContract.ps1
# El .env como sharedPath, con .env.example como contrato verificable (issue #79).
#
# La configuración de runtime de producción vivía solo en la máquina del operador: se subía por
# scp en cada -Apply. CI no podía desplegar la API porque no había origen del que copiarla, y si
# esa máquina se perdía, se perdía la configuración de producción.
#
# El mecanismo para resolverlo ya existía: las llaves RSA de impulsa son un sharedPath, viven en
# /opt/app/<app>/shared/ y el despliegue solo las enlaza. El .env era la excepción, sin razón.
#
# Pero mover el .env a shared/ sin verificar nada empeora la situación: el archivo persiste entre
# releases, así que una versión que introduzca una variable nueva se desplegaría en verde y
# fallaría en runtime. Por eso .env.example —que sí está versionado, y por tanto viaja con el
# código— pasa a ser el contrato que el plan hace cumplir.
#
# Solo se comparan NOMBRES de claves. El plan no lee secretos, y el sondeo los corta en el
# servidor: la garantía tiene que estar donde se lee el archivo, no en quien recibe la salida.

function Get-DotEnvKeys {
    <#
    .SYNOPSIS
    Nombres de las claves declaradas en un archivo de entorno. Nunca los valores.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Lines
    )

    $claves = [System.Collections.Generic.List[string]]::new()
    foreach ($linea in @($Lines)) {
        # El '=' cierra la captura: lo que venga después es el valor y no se mira.
        if ("$linea" -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            if (-not $claves.Contains($Matches[1])) { $claves.Add($Matches[1]) }
        }
    }

    return $claves.ToArray()
}

function New-RemoteEnvKeysScript {
    <#
    .SYNOPSIS
    Genera el bash que lista las claves del .env del servidor, sin transportar los valores.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$SharedEnvPath
    )

    # El sed recorta todo lo que sigue al '=' antes de imprimir: los valores no salen del
    # servidor, así que no terminan en la salida del ssh ni en ningún log que la capture.
    return @"
if [ -f "$SharedEnvPath" ]; then
    echo "ENVFILE:present"
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/ENVKEY:\2/p' "$SharedEnvPath"
else
    echo "ENVFILE:absent"
fi
"@
}

function ConvertTo-EnvContractState {
    <#
    .SYNOPSIS
    Compara las claves que el código declara contra las que el servidor tiene.
    #>
    [CmdletBinding()]
    param(
        # $null = no hay .env.example (no se puede afirmar nada)
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$ExampleKeys,
        # $null = no hay .env en el servidor
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$ServerKeys
    )

    $vacio = [string[]]@()

    if ($null -eq $ExampleKeys) {
        return [pscustomobject]@{
            Level = 'warn'; Missing = $vacio; Extra = $vacio
            Text  = "no hay .env.example: no se puede comprobar que el servidor tenga lo que el código necesita"
        }
    }

    if ($null -eq $ServerKeys) {
        return [pscustomobject]@{
            Level = 'error'; Missing = @($ExampleKeys); Extra = $vacio
            Text  = "el servidor no tiene shared/.env: súbelo con 'Publish-NodeApi -PushShared' antes de desplegar"
        }
    }

    $faltan = @(@($ExampleKeys) | Where-Object { $_ -notin @($ServerKeys) })
    $sobran = @(@($ServerKeys)  | Where-Object { $_ -notin @($ExampleKeys) })

    # Lo que falta bloquea; lo que sobra avisa. Una clave ausente hace que la release nueva
    # falle en runtime; una de más es configuración obsoleta, y eso no impide que corra.
    if ($faltan.Count -gt 0) {
        return [pscustomobject]@{
            Level = 'error'; Missing = $faltan; Extra = $sobran
            Text  = "el servidor no tiene $($faltan.Count) clave(s) que el código declara: $($faltan -join ', ')"
        }
    }

    if ($sobran.Count -gt 0) {
        return [pscustomobject]@{
            Level = 'warn'; Missing = $vacio; Extra = $sobran
            Text  = "el servidor tiene $($sobran.Count) clave(s) que .env.example no declara: $($sobran -join ', ')"
        }
    }

    return [pscustomobject]@{
        Level = 'ok'; Missing = $vacio; Extra = $vacio
        Text  = "el servidor tiene las $(@($ExampleKeys).Count) clave(s) que .env.example declara"
    }
}

function ConvertFrom-EnvKeysOutput {
    <#
    .SYNOPSIS
    Lee la salida del sondeo. Devuelve $null si el archivo no existe en el servidor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Lines
    )

    $lineas = @($Lines) | ForEach-Object { "$_" -split "`r?`n" }

    # Ausente y vacío no son lo mismo: uno se arregla con -PushShared y el otro es un archivo
    # que alguien vació. Por eso el sondeo declara la presencia por separado.
    $existe = $false
    $claves = [System.Collections.Generic.List[string]]::new()
    foreach ($linea in $lineas) {
        switch -Regex ("$linea".Trim()) {
            '^ENVFILE:present$' { $existe = $true }
            '^ENVKEY:(.+)$'     { if (-not $claves.Contains($Matches[1])) { $claves.Add($Matches[1]) } }
        }
    }

    if (-not $existe) { return $null }
    return , $claves.ToArray()
}

function Invoke-EnvContractCheck {
    <#
    .SYNOPSIS
    Compara el .env.example local con las claves del shared/.env del servidor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SharedEnvPath,
        [Parameter(Mandatory = $true)][string]$ExamplePath,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$IP,
        [Parameter(Mandatory = $true)][string]$SshPort,
        [Parameter(Mandatory = $true)][string]$KeyPath
    )

    # Capture y no Invoke-RemoteScript: aquel imprime la salida y devuelve el código de salida.
    $salida = Invoke-RemoteScriptCapture -ScriptContent ("#!/bin/bash`n" + (New-RemoteEnvKeysScript -SharedEnvPath $SharedEnvPath)) `
                                         -User $User -IP $IP -Port $SshPort -KeyPath $KeyPath `
                                         -ScriptPrefix "psdevops_envkeys_"

    $servidor = ConvertFrom-EnvKeysOutput -Lines $salida

    $ejemplo = $null
    if (Test-Path -LiteralPath $ExamplePath) {
        $ejemplo = Get-DotEnvKeys -Lines @(Get-Content -LiteralPath $ExamplePath)
    }

    return ConvertTo-EnvContractState -ExampleKeys $ejemplo -ServerKeys $servidor
}

function Test-EnvContractOrThrow {
    <#
    .SYNOPSIS
    Guardia de -Apply: aborta antes de desplegar si al servidor le falta una clave.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SharedEnvPath,
        [Parameter(Mandatory = $true)][string]$ExamplePath,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$IP,
        [Parameter(Mandatory = $true)][string]$SshPort,
        [Parameter(Mandatory = $true)][string]$KeyPath
    )

    $estado = Invoke-EnvContractCheck -SharedEnvPath $SharedEnvPath -ExamplePath $ExamplePath `
                                      -User $User -IP $IP -SshPort $SshPort -KeyPath $KeyPath

    switch ($estado.Level) {
        'ok'   { Write-Host "  Config:     $($estado.Text)" -ForegroundColor Green }
        'warn' { Write-Host "  Config:     AVISO: $($estado.Text)" -ForegroundColor Yellow }
        default {
            # Desplegar igual dejaría la app arrancando sin una variable que su código pide: un
            # despliegue en verde y un fallo en runtime. Es justo lo que el contrato evita.
            throw ("El servidor no cumple el contrato de .env.example: " + $estado.Text)
        }
    }

    return $estado
}

function Resolve-SharedSourcePath {
    <#
    .SYNOPSIS
    Ruta local que alimenta a un sharedPath al subirlo con -PushShared.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$SharedPath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvFile
    )

    # El .env del servidor sale del env file elegido, no del .env local. ADR 0004: -EnvFile
    # selecciona el entorno; sin esto, '-PushShared -EnvFile .env.production' subiría la
    # configuración de desarrollo a producción — el accidente que este esquema evita.
    $origen = if ($SharedPath -eq '.env') { $EnvFile } else { $SharedPath }

    if ([IO.Path]::IsPathRooted($origen)) { return $origen }
    return (Join-Path $ProjectRoot $origen)
}
