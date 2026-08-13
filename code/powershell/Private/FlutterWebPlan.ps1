# FlutterWebPlan.ps1
# Builds the Publish-FlutterWeb deploy plan (local config + live server state + actions) as a
# common plan object (DeployPlan.ps1). Shared by -Plan and -Apply so both render the same plan
# (ADR 0002 §"Confirmation flow" step 1, ADR 0009). The remote probe is read-only.
#
# Split in three so the decision logic is testable without a server:
#   Invoke-FlutterWebProbe   — I/O only: SSH to the server, return the three raw states.
#   ConvertTo-FlutterWebPlan — pure: raw states + local config -> plan object (severities/actions).
#   Get-FlutterWebPlan       — composition of the two; what the cmdlet calls.

function Invoke-FlutterWebProbe {
    <#
    .SYNOPSIS
        Read-only remote probe. Returns the raw server states as an object.
    .DESCRIPTION
        Queries the `current` symlink, whether the target release directory already exists, and
        the nginx site status (exists / port-in-use / will-create). Never mutates the server.
        Unparseable output leaves a field as 'desconocido' rather than guessing.
    .OUTPUTS
        [pscustomobject] with Current, Release and Nginx (all strings).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][int]$SshPort,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)]$Port,
        [Parameter(Mandatory)][string]$RemoteWebRoot
    )

    $reportScript = @"
#!/bin/bash
# Versión actual (symlink current)
if [ -L "$RemoteWebRoot/$AppName/current" ]; then
    CURRENT=`$(readlink "$RemoteWebRoot/$AppName/current" | xargs basename)
    echo "CURRENT:`$CURRENT"
else
    echo "CURRENT:none"
fi

# Release destino ya existe?
if [ -d "$RemoteWebRoot/$AppName/releases/$Release" ]; then
    echo "RELEASE:exists"
else
    echo "RELEASE:new"
fi

# Nginx config. No basta con que exista: si el site no sirve desde <webroot>/<app>/current,
# mover el symlink no cambia nada de cara al usuario y el deploy seria un exito falso.
if [ -f "/etc/nginx/sites-available/$AppName" ]; then
    if grep -Eq "^[^#]*root[[:space:]]+$RemoteWebRoot/$AppName/current[[:space:]]*;" "/etc/nginx/sites-available/$AppName"; then
        echo "NGINX:exists"
    else
        echo "NGINX:root-mismatch"
    fi
    # Puertos que declara el site, para contrastarlos con el de publish.yaml.
    PORTS=`$(grep -Eho "^[^#]*listen[[:space:]]+[0-9]+" "/etc/nginx/sites-available/$AppName" | grep -Eo "[0-9]+`$" | sort -un | paste -sd, -)
    [ -n "`$PORTS" ] && echo "NGINXPORTS:`$PORTS"
else
    if ss -tlnH sport = :$Port | grep -q .; then
        echo "NGINX:port-in-use"
    else
        echo "NGINX:will-create"
    fi
fi
"@

    $tmpLocal = New-UnixTempFile -Content $reportScript -Prefix "psdevops_report_flutterweb_"
    try {
        $remoteName = [IO.Path]::GetFileName($tmpLocal)
        $remotePath = "/tmp/$remoteName"

        Invoke-RemoteCopy -LocalPath $tmpLocal -RemotePath $remotePath `
                          -User $User -IP $IP -Port $SshPort -KeyPath $PrivateKeyPath `
                          -Descripcion 'el sondeo del plan'

        $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
        $output = & ssh -i $PrivateKeyPath -p $SshPort "$($User)@$($IP)" $remoteCmd 2>&1
    }
    finally {
        Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
    }

    $probe = [pscustomobject]@{
        Current = 'desconocido'
        Release = 'desconocido'
        Nginx      = 'desconocido'
        NginxPorts = @()
    }
    foreach ($line in $output) {
        if ($line -match '^CURRENT:(.+)$') { $probe.Current = $Matches[1] }
        if ($line -match '^RELEASE:(.+)$') { $probe.Release = $Matches[1] }
        if ($line -match '^NGINX:(.+)$')      { $probe.Nginx = $Matches[1] }
        if ($line -match '^NGINXPORTS:(.+)$') { $probe.NginxPorts = @($Matches[1] -split ',' | ForEach-Object { [int]$_ }) }
    }
    return $probe
}

function ConvertTo-FlutterWebPlan {
    <#
    .SYNOPSIS
        Pure: turns the raw probe states plus local config into the common plan object.
    .DESCRIPTION
        No I/O — this is where severity is decided, so it is unit-testable without a server.
        'port-in-use' is the only 'error' level: it means the apply is known to fail, which
        Get-DeployPlanBlocker turns into a hard stop in -Apply.
    .PARAMETER Probe
        Object from Invoke-FlutterWebProbe (Current/Release/Nginx).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Probe,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)]$Port,
        [Parameter(Mandatory)][string]$RemoteWebRoot
    )

    # ─── Server-state rows (with severity levels) ────────
    if ($Probe.Current -eq 'none') {
        $currentRow = New-DeployPlanRow -Text '(primer deploy)' -Level 'warn'
    }
    else {
        $currentRow = New-DeployPlanRow -Text $Probe.Current -Level 'info'
    }

    if ($Probe.Release -eq 'exists') {
        $releaseRow = New-DeployPlanRow -Text "$Release ya existe (se sobreescribirá)" -Level 'warn'
    }
    else {
        $releaseRow = New-DeployPlanRow -Text "$Release (nueva)" -Level 'ok'
    }

    if ($Probe.Nginx -eq 'exists') {
        $nginxRow = New-DeployPlanRow -Text 'config existe (no se modifica)' -Level 'info'
    }
    elseif ($Probe.Nginx -eq 'root-mismatch') {
        $nginxRow = New-DeployPlanRow -Level 'error' `
            -Text "el site no sirve desde '$RemoteWebRoot/$AppName/current' — mover el symlink no cambiaria lo que se ve"
    }
    elseif ($Probe.Nginx -eq 'port-in-use') {
        $nginxRow = New-DeployPlanRow -Text "PUERTO $Port EN USO — el deploy fallará" -Level 'error'
    }
    else {
        $nginxRow = New-DeployPlanRow -Text "se creará config en puerto $Port" -Level 'ok'
    }

    # El puerto declarado en publish.yaml no modifica un site existente, pero sigue usandose para
    # la verificacion final por HTTP: si no coincide, el reporte comprueba algo que no es el sitio.
    $probePorts = @()
    if ($Probe.PSObject.Properties['NginxPorts']) { $probePorts = @($Probe.NginxPorts) }

    $portRow = $null
    if ($probePorts.Count -gt 0) {
        if ($probePorts -contains [int]$Port) {
            $portRow = New-DeployPlanRow -Level 'info' -Text "$Port (coincide con el site)"
        } else {
            $portRow = New-DeployPlanRow -Level 'warn' `
                -Text "publish.yaml declara $Port, pero el site escucha en $($probePorts -join ', ')"
        }
    }

    # ─── Actions -Apply will perform ─────────────────────
    $actions = @(
        'Compilar Flutter Web (Invoke-FlutterBuild -Web)',
        'Comprimir artefactos en zip',
        "Subir zip a ${IP}:/tmp/",
        "Instalar en ${RemoteWebRoot}/${AppName}/releases/${Release}/",
        "Actualizar symlink current → $Release"
    )
    # 'root-mismatch' significa que el site YA existe y apunta a otro sitio: no hay nada que
    # crear, hay que corregirlo a mano. Anunciar una creacion aqui seria describir mal el plan.
    if ($Probe.Nginx -notin @('exists', 'root-mismatch')) {
        $actions += "Crear configuración nginx en puerto $Port"
    }

    $sections = [ordered]@{
        'Configuración local' = [ordered]@{
            'Proyecto' = $AppName
            'Versión'  = $Release
            'Servidor' = "$Server ($IP)"
            'Puerto'   = "$Port"
        }
        'Estado del servidor' = [ordered]@{
            'Current' = $currentRow
            'Release' = $releaseRow
            'Nginx'   = $nginxRow
            'Puerto'  = $portRow
        }
    }

    return New-DeployPlan -Cmdlet 'Publish-FlutterWeb' -Target "$Server ($IP)" `
        -Sections $sections -Actions $actions
}

function Get-FlutterWebPlan {
    <#
    .SYNOPSIS
        Probes the server and returns the Publish-FlutterWeb plan object.
    .DESCRIPTION
        Composition of Invoke-FlutterWebProbe (I/O) and ConvertTo-FlutterWebPlan (pure).
        Called by BOTH -Plan and -Apply so the two render the same plan by construction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][int]$SshPort,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)]$Port,
        [Parameter(Mandatory)][string]$RemoteWebRoot
    )

    $probe = Invoke-FlutterWebProbe -AppName $AppName -Release $Release -User $User -IP $IP `
        -SshPort $SshPort -PrivateKeyPath $PrivateKeyPath -Port $Port -RemoteWebRoot $RemoteWebRoot

    return ConvertTo-FlutterWebPlan -Probe $probe -AppName $AppName -Release $Release `
        -Server $Server -IP $IP -Port $Port -RemoteWebRoot $RemoteWebRoot
}
