# FlutterWebPlan.ps1
# Builds the Publish-FlutterWeb deploy plan (local config + live server state + actions) as a
# common plan object (DeployPlan.ps1). Shared by -Plan and -Apply so both render the same plan
# (ADR 0002 §"Confirmation flow" step 1, ADR 0009). The remote probe is read-only.

function Get-FlutterWebPlan {
    <#
    .SYNOPSIS
        Probes the server and returns the Publish-FlutterWeb plan object.
    .DESCRIPTION
        Read-only: queries the `current` symlink, whether the target release already exists,
        and the nginx site status (exists / port-in-use / will-create). Never mutates.
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

    # ─── Remote probe (read-only) ────────────────────────
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

# Nginx config
if [ -f "/etc/nginx/sites-available/$AppName" ]; then
    echo "NGINX:exists"
else
    if ss -tlnH sport = :$Port | grep -q .; then
        echo "NGINX:port-in-use"
    else
        echo "NGINX:will-create"
    fi
fi
"@

    $currentVersion = 'desconocido'
    $releaseStatus = 'desconocido'
    $nginxStatus = 'desconocido'

    $tmpLocal = New-UnixTempFile -Content $reportScript -Prefix "psdevops_report_flutterweb_"
    try {
        $remoteName = [IO.Path]::GetFileName($tmpLocal)
        $remotePath = "/tmp/$remoteName"

        & scp -i $PrivateKeyPath -P $SshPort $tmpLocal "$($User)@$($IP):$remotePath" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Error al conectar con el servidor (scp exit: $LASTEXITCODE)" }

        $remoteCmd = "bash $remotePath ; rc=`$?; rm -f $remotePath; exit `$rc"
        $output = & ssh -i $PrivateKeyPath -p $SshPort "$($User)@$($IP)" $remoteCmd 2>&1
    }
    finally {
        Remove-Item -LiteralPath $tmpLocal -ErrorAction SilentlyContinue
    }

    foreach ($line in $output) {
        if ($line -match '^CURRENT:(.+)$') { $currentVersion = $Matches[1] }
        if ($line -match '^RELEASE:(.+)$') { $releaseStatus = $Matches[1] }
        if ($line -match '^NGINX:(.+)$') { $nginxStatus = $Matches[1] }
    }

    # ─── Server-state rows (with severity levels) ────────
    if ($currentVersion -eq 'none') {
        $currentRow = New-DeployPlanRow -Text '(primer deploy)' -Level 'warn'
    }
    else {
        $currentRow = New-DeployPlanRow -Text $currentVersion -Level 'info'
    }

    if ($releaseStatus -eq 'exists') {
        $releaseRow = New-DeployPlanRow -Text "$Release ya existe (se sobreescribirá)" -Level 'warn'
    }
    else {
        $releaseRow = New-DeployPlanRow -Text "$Release (nueva)" -Level 'ok'
    }

    if ($nginxStatus -eq 'exists') {
        $nginxRow = New-DeployPlanRow -Text 'config existe (no se modifica)' -Level 'info'
    }
    elseif ($nginxStatus -eq 'port-in-use') {
        $nginxRow = New-DeployPlanRow -Text "PUERTO $Port EN USO — el deploy fallará" -Level 'error'
    }
    else {
        $nginxRow = New-DeployPlanRow -Text "se creará config en puerto $Port" -Level 'ok'
    }

    # ─── Actions -Apply will perform ─────────────────────
    $actions = @(
        'Compilar Flutter Web (Invoke-FlutterBuild -Web)',
        'Comprimir artefactos en zip',
        "Subir zip a ${IP}:/tmp/",
        "Instalar en ${RemoteWebRoot}/${AppName}/releases/${Release}/",
        "Actualizar symlink current → $Release"
    )
    if ($nginxStatus -ne 'exists') {
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
        }
    }

    return New-DeployPlan -Cmdlet 'Publish-FlutterWeb' -Target "$Server ($IP)" `
        -Sections $sections -Actions $actions
}
