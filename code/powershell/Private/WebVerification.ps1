# WebVerification.ps1
# Verificación post-deploy de un sitio web estático: comprueba que se esté sirviendo LO QUE
# SE ACABA DE DESPLEGAR, no solo que algo responda en un puerto (issue #76).
#
# Dividido en cuatro, como el resto del módulo, para que la decisión sea testeable sin servidor:
#   New-WebVerificationScript  — genera el bash del sondeo. Puro.
#   ConvertFrom-WebProbeOutput — salida cruda del sondeo -> objeto. Puro.
#   ConvertTo-WebVerification  — sondeo + versión esperada -> resultado con severidad. Puro.
#   Invoke-WebVerification     — composición: ejecuta el sondeo por SSH, lee e interpreta.
#
# El corte entre el SSH y el parseo es el que permite que la prueba de contenedor lleve la salida
# de un nginx real hasta el veredicto, sin necesitar un servidor con SSH.
#
# Qué reemplaza
# -------------
# El check anterior pedía 200 y trataba todo lo demás como sospechoso:
#
#   WARNING: HTTP 3048 respondió 301 (puede necesitar tiempo para iniciar)
#
# Cinco de siete sitios devuelven 301, porque el puerto declarado pertenece a un bloque que
# solo redirige y la web la sirve el :443. El aviso saltaba siempre y por eso dejó de leerse.
#
# Y aunque aceptara el 3xx, no probaba nada: un redirect responde igual con el symlink movido
# o sin mover. El caso de 'micro' lo demuestra —servía desde un directorio plano, así que
# mover 'current' no cambiaba nada— y el check habría terminado en verde.

function New-WebVerificationScript {
    <#
    .SYNOPSIS
    Genera el sondeo remoto: sigue la redirección y lee la versión servida.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][int]$Port
    )

    # --resolve no es un detalle: sin él, un 'curl -L' sale hacia el DNS público y puede
    # fallar por enrutamiento, salida a internet o hairpin NAT — motivos que no tienen nada
    # que ver con el despliegue. Se fuerza a resolver contra el propio servidor.
    #
    # -k es necesario porque el certificado es del dominio y la conexión va a 127.0.0.1.
    return @"
#!/bin/bash
# No lleva 'set -e': un código de error de curl es un dato a reportar, no un motivo para
# abortar el sondeo. Interpretar es tarea de ConvertTo-WebVerification.
sleep 1

BASE="http://127.0.0.1:$Port"
# Se pregunta por vacio en vez de encadenar '|| echo 000': cuando curl falla imprime su propio
# '000' Y ADEMAS sale con error, asi que el encadenado devolvia '000000' y el mensaje al
# operador terminaba diciendo 'HTTP 000000' en lugar de 'sin respuesta'.
HTTP=`$(curl -s -o /dev/null -w '%{http_code}' "`$BASE/" 2>/dev/null)
[ -z "`$HTTP" ] && HTTP=000
echo "HTTP:`$HTTP"

FINAL_URL="`$BASE"
if [ "`$HTTP" -ge 300 ] 2>/dev/null && [ "`$HTTP" -lt 400 ] 2>/dev/null; then
    LOC=`$(curl -s -o /dev/null -w '%{redirect_url}' "`$BASE/" 2>/dev/null)
    echo "LOCATION:`$LOC"
    FINAL_URL="`${LOC%/}"
fi

# El host del destino se resuelve contra 127.0.0.1: se verifica ESTE servidor, no el que
# devuelva el DNS.
HOST=`$(echo "`$FINAL_URL" | sed -E 's#^https?://##; s#[:/].*##')
SCHEME=`$(echo "`$FINAL_URL" | sed -E 's#^(https?)://.*#\1#')

# El puerto del destino puede venir explicito en la redireccion ('host:8100'). Si se
# descarta, el --resolve se arma para el puerto por defecto y NO aplica: curl sale al DNS
# publico, que es justo lo que --resolve existe para evitar.
PUERTO_URL=`$(echo "`$FINAL_URL" | sed -E 's#^https?://[^:/]+##; s#^:([0-9]+).*#\1#; s#^[^0-9].*##')
if [ -n "`$PUERTO_URL" ]; then
    PUERTO="`$PUERTO_URL"
elif [ "`$SCHEME" = "http" ]; then
    PUERTO=80
else
    PUERTO=443
fi

RESOLVE=""
[ -n "`$HOST" ] && RESOLVE="--resolve `$HOST:`$PUERTO:127.0.0.1"

FINAL=`$(curl -sk `$RESOLVE -o /dev/null -w '%{http_code}' "`$FINAL_URL/" 2>/dev/null)
[ -z "`$FINAL" ] && FINAL=000
echo "FINAL:`$FINAL"

VERSION=`$(curl -sk `$RESOLVE "`$FINAL_URL/version.json" 2>/dev/null \
           | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
           | sed -E 's/.*"([^"]*)"`$/\1/')
echo "VERSION:`$VERSION"
"@
}

function ConvertFrom-WebProbeOutput {
    <#
    .SYNOPSIS
    Lee la salida del sondeo remoto y la convierte en un objeto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Lines
    )

    # La salida puede llegar como arreglo o como una sola cadena según cómo se consuma ssh; son
    # la misma salida y no pueden dar veredictos distintos.
    $lineas = @($Lines) | ForEach-Object { "$_" -split "`r?`n" }

    $probe = [pscustomobject]@{ HttpCode = ''; FinalCode = ''; ServedVersion = ''; Location = '' }
    foreach ($linea in $lineas) {
        # Solo se leen las claves conocidas: un banner del shell remoto o un aviso de ssh no
        # puede corromper la lectura.
        switch -Regex ("$linea".Trim()) {
            '^HTTP:(.*)$'     { $probe.HttpCode      = $Matches[1] }
            '^FINAL:(.*)$'    { $probe.FinalCode     = $Matches[1] }
            '^VERSION:(.*)$'  { $probe.ServedVersion = $Matches[1] }
            '^LOCATION:(.*)$' { $probe.Location      = $Matches[1] }
        }
    }

    return $probe
}

function ConvertTo-WebVerification {
    <#
    .SYNOPSIS
    Interpreta el sondeo: responde si se está sirviendo lo desplegado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Probe,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $final = "$($Probe.FinalCode)".Trim()
    $servida = "$($Probe.ServedVersion)".Trim()

    # El build number ('+349') es metadato de Dart y no aparece en el version.json servido,
    # que solo lleva 'version'. Compararlo daría un falso desajuste en cada release.
    $esperada = ($ExpectedVersion -split '\+')[0].Trim().TrimStart('v')
    $servidaN = ($servida -split '\+')[0].Trim().TrimStart('v')

    # 2xx y 3xx son respuestas sanas de nginx. Solo 4xx, 5xx y la ausencia de respuesta son
    # anomalías: exigir 200 convertía en aviso permanente algo que era correcto.
    $codigoOk = $false
    if ($final -match '^\d+$') { $codigoOk = ([int]$final -ge 200 -and [int]$final -lt 400) }

    if (-not $codigoOk) {
        $visto = if ($final -eq '000' -or -not $final) { 'sin respuesta' } else { "HTTP $final" }
        return [pscustomobject]@{
            Level = 'error'
            Text  = "el sitio no responde correctamente ($visto)"
        }
    }

    # Sin version.json no se puede afirmar nada, ni bien ni mal. Es 'warn' y no 'error': el
    # despliegue puede estar perfecto y el sitio simplemente no publicar ese archivo.
    if (-not $servidaN) {
        return [pscustomobject]@{
            Level = 'warn'
            Text  = "responde correctamente, pero no se pudo comprobar qué versión sirve (sin version.json)"
        }
    }

    if ($servidaN -ne $esperada) {
        return [pscustomobject]@{
            Level = 'error'
            Text  = "se desplegó $esperada pero el sitio sirve $servidaN"
        }
    }

    return [pscustomobject]@{
        Level = 'ok'
        Text  = "sirviendo $servidaN"
    }
}

function Invoke-WebVerification {
    <#
    .SYNOPSIS
    Ejecuta el sondeo por SSH e interpreta el resultado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$IP,
        [Parameter(Mandatory = $true)][string]$SshPort,
        [Parameter(Mandatory = $true)][string]$KeyPath
    )

    $salida = Invoke-RemoteScript -ScriptContent (New-WebVerificationScript -Port $Port) `
                                  -User $User -IP $IP -Port $SshPort -KeyPath $KeyPath `
                                  -ScriptPrefix "psdevops_verify_web_"

    $probe = ConvertFrom-WebProbeOutput -Lines $salida

    return ConvertTo-WebVerification -Probe $probe -ExpectedVersion $ExpectedVersion
}
