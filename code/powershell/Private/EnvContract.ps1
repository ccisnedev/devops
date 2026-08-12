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
        [Parameter(Mandatory = $true)][string]$SharedEnvPath,

        # Claves cuyo VALOR se exporta además del nombre. La lista es explícita a propósito: qué
        # sale del servidor es una decisión, no un efecto secundario de cómo se escribió un sed.
        # Hoy solo PORT, que el despliegue necesita para sondear y que no es un secreto.
        [Parameter()][string[]]$ValueKeys = @()
    )

    # El sed recorta todo lo que sigue al '=' antes de imprimir: los valores no salen del
    # servidor, así que no terminan en la salida del ssh ni en ningún log que la capture.
    $bloqueValores = ""
    foreach ($k in @($ValueKeys)) {
        $bloqueValores += @"

    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?$k[[:space:]]*=[[:space:]]*(.*)/ENVVALUE:${k}=\2/p' "$SharedEnvPath"
"@
    }

    return @"
if [ -f "$SharedEnvPath" ]; then
    echo "ENVFILE:present"
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/ENVKEY:\2/p' "$SharedEnvPath"$bloqueValores
else
    echo "ENVFILE:absent"
fi
"@
}

function ConvertFrom-EnvValuesOutput {
    <#
    .SYNOPSIS
    Lee los valores que el sondeo exportó explícitamente.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Lines
    )

    $valores = @{}
    foreach ($linea in (@($Lines) | ForEach-Object { "$_" -split "`r?`n" })) {
        # El primer '=' separa; el resto es el valor, que puede llevar más.
        if ("$linea".Trim() -match '^ENVVALUE:([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $valores[$Matches[1]] = $Matches[2].Trim()
        }
    }

    return $valores
}

function Resolve-NodeApiPort {
    <#
    .SYNOPSIS
    Decide el puerto a sondear cuando hay dos fuentes: el archivo local y el del servidor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LocalPort,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ServerPort,
        [Parameter(Mandatory = $true)][string]$EnvFile
    )

    $local    = "$LocalPort".Trim()
    $servidor = "$ServerPort".Trim()

    $n = 0
    $localNum    = if ($local -and [int]::TryParse($local, [ref]$n)) { $n } else { 0 }
    $servidorNum = if ($servidor -and [int]::TryParse($servidor, [ref]$n)) { $n } else { 0 }

    if (-not $localNum -and -not $servidorNum) {
        # Un 8080 por defecto sondea un puerto que nadie declaró y da un verde sin fundamento.
        return [pscustomobject]@{
            Port = 0; Level = 'error'
            Text = "no hay PORT ni en '$EnvFile' ni en el shared/.env del servidor; declárelo en uno de los dos"
        }
    }

    if ($localNum -and $servidorNum -and $localNum -ne $servidorNum) {
        # Manda el del servidor aunque bloquee: es el que la app va a leer al arrancar. Sondear
        # el otro es, en el mejor caso, un despliegue que falla estando bien; en el peor, uno que
        # pasa porque en ese puerto responde otra cosa.
        return [pscustomobject]@{
            Port = $servidorNum; Level = 'error'
            Text = "'$EnvFile' declara PORT=$localNum y el shared/.env del servidor declara PORT=$servidorNum; la app leerá el del servidor"
        }
    }

    $elegido = if ($servidorNum) { $servidorNum } else { $localNum }
    $origen  = if ($servidorNum) { 'shared/.env del servidor' } else { "'$EnvFile'" }
    return [pscustomobject]@{ Port = $elegido; Level = 'ok'; Text = "PORT=$elegido (desde $origen)" }
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
        [Parameter(Mandatory = $true)][string]$KeyPath,

        # Claves cuyo valor se necesita además del nombre (hoy PORT, issue #83). Viajan en el
        # mismo sondeo: abrir un segundo ssh para un dato es latencia sin ninguna ventaja.
        [Parameter()][string[]]$ValueKeys = @()
    )

    # Capture y no Invoke-RemoteScript: aquel imprime la salida y devuelve el código de salida.
    $sonda = New-RemoteEnvKeysScript -SharedEnvPath $SharedEnvPath -ValueKeys $ValueKeys
    $salida = Invoke-RemoteScriptCapture -ScriptContent ("#!/bin/bash`n" + $sonda) `
                                         -User $User -IP $IP -Port $SshPort -KeyPath $KeyPath `
                                         -ScriptPrefix "psdevops_envkeys_"

    $servidor = ConvertFrom-EnvKeysOutput -Lines $salida

    $ejemplo = $null
    if (Test-Path -LiteralPath $ExamplePath) {
        $ejemplo = Get-DotEnvKeys -Lines @(Get-Content -LiteralPath $ExamplePath)
    }

    $estado = ConvertTo-EnvContractState -ExampleKeys $ejemplo -ServerKeys $servidor
    Add-Member -InputObject $estado -NotePropertyName 'Values' `
               -NotePropertyValue (ConvertFrom-EnvValuesOutput -Lines $salida) -Force
    return $estado
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
        [Parameter(Mandatory = $true)][string]$KeyPath,
        [Parameter()][string[]]$ValueKeys = @()
    )

    $estado = Invoke-EnvContractCheck -SharedEnvPath $SharedEnvPath -ExamplePath $ExamplePath `
                                      -User $User -IP $IP -SshPort $SshPort -KeyPath $KeyPath `
                                      -ValueKeys $ValueKeys

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

function New-SharedEnvRestartNotice {
    <#
    .SYNOPSIS
    Aviso tras subir un .env a shared/: el proceso todavía corre con la configuración anterior.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessManager,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$Server
    )

    # '--update-env' no es opcional: sin esa bandera pm2 reutiliza el entorno que ya tenia
    # cargado, el comando termina sin error, y la variable nueva sigue sin aplicarse.
    $comando = if ($ProcessManager -eq 'systemd') {
        "sudo systemctl restart $AppName"
    } else {
        "pm2 restart $AppName --update-env"
    }

    return @(
        "El archivo cambio, pero el proceso sigue corriendo con la configuracion anterior:",
        "el .env se lee una sola vez, al arrancar.",
        "",
        "Para aplicarla, una de las dos:",
        "  - en '$Server':  $comando",
        "  - o un release nuevo:  Publish-NodeApi -Apply"
    )
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
