# EnvSecret.ps1
# Publicar el env file como secret de un GitHub Environment, para que un runner pueda desplegar
# sin dejar de subir la configuración con el release.
#
# La configuración sigue viajando en el paquete
# ---------------------------------------------
# Cada release tiene su propio .env, subido en el despliegue. Volver el symlink 'current' a un
# release anterior devuelve ese código CON su configuración: un rollback real, y hoy funciona.
# Un shared/.env devolvería el código viejo con la configuración de hoy.
#
# Así que lo único que cambia es de dónde toma el ejecutor ese archivo: de la máquina del
# operador, o de un secret del environment cuando quien despliega es un runner. El job lo
# materializa y lo pasa con -EnvFile, que es exactamente para lo que existe ese parámetro.
#
# Se sube el archivo TAL CUAL, sin filtrar nada. El módulo ya quita las claves MACSS_DEPLOY_* al
# instalar el release, así que el .env que acaba en el servidor es idéntico al de un despliegue
# manual. Filtrar aquí crearía dos configuraciones distintas para el mismo entorno.

function ConvertTo-SecretPayload {
    <#
    .SYNOPSIS
    Contenido exacto que se publica como secret, normalizado a LF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Lines
    )

    # A LF: el archivo acaba siendo el .env de un release en Linux, y un retorno de carro se
    # cuela dentro del valor de la última variable de cada línea.
    $limpias = @($Lines) | ForEach-Object { "$_" -replace "`r", '' }
    return (($limpias -join "`n").TrimEnd("`n") + "`n")
}

function Get-ContentFingerprint {
    <#
    .SYNOPSIS
    SHA-256 del contenido, para saber si el secret publicado sigue siendo el archivo local.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    # Un secret no se puede leer de vuelta. Sin esto nunca sabrías si el que está en GitHub
    # corresponde a tu archivo o a uno de hace tres meses. El hash de un archivo de decenas de
    # líneas no revela su contenido, así que puede vivir como variable a la vista.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function ConvertTo-EnvSecretPlan {
    <#
    .SYNOPSIS
    Compara la huella local con la publicada y dice qué va a pasar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalFingerprint,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$RemoteFingerprint
    )

    $remota = "$RemoteFingerprint".Trim()

    if (-not $remota) {
        return [pscustomobject]@{
            Action = 'crear'; Level = 'info'
            Text   = "el secret no existe todavía en este environment; se creará"
        }
    }

    if ($remota -eq $LocalFingerprint) {
        return [pscustomobject]@{
            Action = 'sin-cambios'; Level = 'ok'
            Text   = "el secret publicado corresponde a tu archivo actual; no hay nada que subir"
        }
    }

    # El caso que importa: alguien despliega desde CI creyendo que va lo que tiene en su máquina.
    return [pscustomobject]@{
        Action = 'actualizar'; Level = 'warn'
        Text   = "el secret publicado difiere de tu archivo actual; se reemplazará"
    }
}

function Resolve-EnvSecretName {
    <#
    .SYNOPSIS
    Nombre del secret para un componente.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('db', 'api', 'app')][string]$Component
    )

    # Uno por componente: db, api y app se despliegan por separado y cada uno tiene su propio
    # env file --credenciales de SqlPackage, configuración de runtime, destino--. Un solo secret
    # por environment los mezclaría, y el despliegue de uno se llevaría la configuración de otro.
    return "ENV_FILE_$($Component.ToUpperInvariant())"
}

function Resolve-EnvSecretComponent {
    <#
    .SYNOPSIS
    Deduce el componente del directorio desde el que se ejecuta. Vacío si no se puede.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $hoja = (Split-Path -Leaf ("$Path".TrimEnd('\', '/'))).ToLowerInvariant()
    if ($hoja -in @('db', 'api', 'app')) { return $hoja }

    # Mejor pedirlo que adivinar: publicar la configuración de un componente bajo el nombre de
    # otro no se nota hasta que la app no arranca.
    return ''
}

function New-EnvSecretCommand {
    <#
    .SYNOPSIS
    Argumentos de 'gh' para publicar el secret. El valor va por stdin, no por aquí.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Environment,
        [Parameter(Mandatory = $true)][string]$SecretName
    )

    # Sin '--body': ese argumento deja el secreto en la línea de comandos del proceso, visible
    # para cualquiera que liste procesos. gh lo lee de stdin cuando no se le pasa.
    #
    # Y al environment, no al repositorio: el environment es lo que permite exigir aprobación
    # antes de desplegar (R05, R23). Un secret de repositorio no tiene esa puerta.
    return @('secret', 'set', $SecretName, '--env', $Environment, '--repo', $Repo)
}
