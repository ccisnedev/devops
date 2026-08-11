# NodeServiceProbe.ps1
# Estado del servicio para `Publish-NodeApi -Plan` (issue #78).
#
# El plan informaba "Servicio: se creará (pm2)" sobre un servidor donde la API llevaba 4 h 34 min
# corriendo. El reporte se ejecuta por SSH no interactivo; pm2 vive bajo el gestor de versiones
# de Node, que solo se carga en shells interactivos; la invocación fallaba y el `else` concluía
# que no había servicio.
#
# El despliegue nunca tuvo el defecto: Manage-NodeProcess.sh carga nvm antes de llamar a pm2.
# Eran dos formas distintas de resolver el mismo binario, y por eso plan y apply discrepaban.
#
# Se corrigen las dos cosas:
#   - el sondeo resuelve pm2 como lo hace el despliegue;
#   - y si aun así no puede ejecutarlo, dice 'unknown' en vez de inventar 'not-configured'.
#
# La segunda es la que no se puede negociar: un plan existe para que se le crea, y afirmar un
# estado que no se pudo comprobar gasta esa credibilidad sin dar nada a cambio. Es la misma
# distinción que el módulo ya aplica en la verificación web, donde la ausencia de version.json
# es 'warn' y no 'error'.

function New-NodeServiceProbeScript {
    <#
    .SYNOPSIS
    Genera el bash que consulta el estado del servicio en el servidor.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('pm2', 'systemd')][string]$ProcessManager,
        [Parameter(Mandatory = $true)][string]$AppName
    )

    if ($ProcessManager -eq 'systemd') {
        # Si systemctl no está, este servidor no gestiona nada con systemd: afirmar que no hay
        # servicio sería tan falso como en el otro caso.
        return @"
if ! command -v systemctl >/dev/null 2>&1; then
    echo "SERVICE:unknown"
elif systemctl is-active --quiet $AppName 2>/dev/null; then
    echo "SERVICE:running"
elif systemctl is-enabled --quiet $AppName 2>/dev/null; then
    echo "SERVICE:stopped"
else
    echo "SERVICE:not-configured"
fi
"@
    }

    # Las dos primeras líneas son las mismas que Manage-NodeProcess.sh: si el despliegue cambia
    # su forma de resolver el binario, el sondeo tiene que cambiar con él o vuelve la
    # discrepancia. Hay una prueba que compara ambos archivos.
    return @"
export NVM_DIR="`$HOME/.nvm"
[ -s "`$NVM_DIR/nvm.sh" ] && . "`$NVM_DIR/nvm.sh" 2>/dev/null || true

if ! command -v pm2 >/dev/null 2>&1; then
    # No se pudo ejecutar pm2. No dice nada sobre si el servicio existe.
    echo "SERVICE:unknown"
elif pm2 describe $AppName >/dev/null 2>&1; then
    STATUS=`$(pm2 describe $AppName 2>/dev/null | grep -i status | head -1 | awk '{print `$4}')
    [ -z "`$STATUS" ] && STATUS="unknown"
    echo "SERVICE:`$STATUS"
else
    echo "SERVICE:not-configured"
fi
"@
}

function ConvertTo-NodeServiceState {
    <#
    .SYNOPSIS
    Traduce el estado sondeado a lo que el plan anuncia.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Status,
        [Parameter(Mandatory = $true)][string]$ProcessManager
    )

    $s = "$Status".Trim().ToLowerInvariant()

    # 'online' es la palabra de pm2 para 'running'. Pasarla tal cual mandaba un servicio
    # perfectamente arriba a la rama de estado desconocido, en amarillo.
    switch -Regex ($s) {
        '^(running|online)$' {
            return [pscustomobject]@{ Level = 'ok';   Text = "$ProcessManager activo (se reiniciará)" }
        }
        '^stopped$' {
            return [pscustomobject]@{ Level = 'info'; Text = "$ProcessManager detenido (se iniciará)" }
        }
        '^not-configured$' {
            return [pscustomobject]@{ Level = 'ok';   Text = "se creará ($ProcessManager)" }
        }
        '^errored$' {
            return [pscustomobject]@{ Level = 'error'; Text = "$ProcessManager reporta el servicio en estado errored" }
        }
        '^(unknown|desconocido|)$' {
            # El motivo va en el texto: un 'desconocido' sin causa manda a alguien a mirar el
            # servidor a ciegas.
            return [pscustomobject]@{
                Level = 'warn'
                Text  = "no se pudo comprobar el estado del servicio ($ProcessManager no se pudo ejecutar en la sesión no interactiva)"
            }
        }
        default {
            return [pscustomobject]@{ Level = 'warn'; Text = "estado no previsto: $s ($ProcessManager)" }
        }
    }
}
