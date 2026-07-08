<#
.SYNOPSIS
ADR 0004 — End-to-end container test of Invoke-SqlPackage's -EnvFile against a REAL SQL Server.

.DESCRIPTION
Proves the environment-selection behavior against a live database, not just param binding:
  1. Spins up SQL Server 2022 in a container (the deploy TARGET).
  2. Builds a real SQL project (dotnet + Microsoft.Build.Sql) and runs
     `Invoke-SqlPackage -Apply -EnvFile .env.container` -> deploys table dbo.Persona.
  3. POSITIVE: asserts dbo.Persona now exists in the container DB (so -EnvFile drove the
     connection to the server named in .env.container).
  4. NEGATIVE: `Invoke-SqlPackage -Plan` with the DEFAULT .env (a wrong/dead server) must
     FAIL to connect — proving -EnvFile genuinely selects the file/target, not a hard-coded .env.

Opt-in (not auto-discovered by the CI Pester run, like the *.container.test.sh scripts).

.PARAMETER ModulePath
Path to macss-devops.psd1. Default: resolved relative to this script.

.NOTES
Requires: docker, dotnet SDK, sqlpackage (dotnet tool), sqlcmd. Uses host port 14330.
#>
[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\macss-devops.psd1')
)

$ErrorActionPreference = 'Stop'
$CONTAINER = 'macss-sqltest'
$PORT      = 14330
$SRV       = "localhost,$PORT"
$SA_PW     = 'P@ssw0rd-Str0ng!2026'   # test-only; throwaway container
$DB        = 'TestDb'
$workDir   = Join-Path ([IO.Path]::GetTempPath()) "sqlpkg-ctr-$([guid]::NewGuid().ToString('N').Substring(0,8))"

function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; throw $msg }

# ── Preflight ──────────────────────────────────────────────────────────────
foreach ($tool in 'docker', 'dotnet', 'sqlpackage', 'sqlcmd') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "Falta '$tool' en el PATH." }
}

try {
    # ── 1. SQL Server container ────────────────────────────────────────────
    docker rm -f $CONTAINER 2>$null | Out-Null
    Write-Host "==> Arrancando SQL Server 2022 ($SRV)..." -ForegroundColor Cyan
    docker run -d --name $CONTAINER -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$SA_PW" `
        -e 'MSSQL_PID=Developer' -p "${PORT}:1433" mcr.microsoft.com/mssql/server:2022-latest | Out-Null

    $ready = $false
    foreach ($i in 1..40) {
        $out = sqlcmd -S $SRV -U sa -P $SA_PW -C -l 3 -Q 'SELECT 1' 2>&1
        if ($LASTEXITCODE -eq 0 -and ($out -match '1')) { $ready = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $ready) { docker logs --tail 20 $CONTAINER; Fail 'SQL Server no quedó listo.' }
    sqlcmd -S $SRV -U sa -P $SA_PW -C -Q "IF DB_ID('$DB') IS NULL CREATE DATABASE [$DB];" | Out-Null
    Write-Host "    SQL Server listo, base '$DB' creada." -ForegroundColor Green

    # ── 2. SQL project + env files ─────────────────────────────────────────
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    Set-Content -Path (Join-Path $workDir 'TestDb.sqlproj') -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.Build.Sql/1.0.0">
  <PropertyGroup>
    <Name>TestDb</Name>
    <DSP>Microsoft.Data.Tools.Schema.Sql.Sql160DatabaseSchemaProvider</DSP>
    <ModelCollation>1033, CI</ModelCollation>
  </PropertyGroup>
</Project>
'@
    Set-Content -Path (Join-Path $workDir 'dbo.Persona.sql') -Encoding UTF8 -Value @'
CREATE TABLE [dbo].[Persona]
(
    [Id]     INT           NOT NULL PRIMARY KEY,
    [Nombre] NVARCHAR(100) NOT NULL
);
'@
    # env files: .env.container = target REAL; .env (default) = server MUERTO (para el negativo)
    Set-Content -Path (Join-Path $workDir '.env.container') -Encoding UTF8 `
        -Value "DB_SERVER=$SRV`nDB_NAME=$DB`nDB_USER=sa`nDB_PASSWORD=$SA_PW"
    Set-Content -Path (Join-Path $workDir '.env') -Encoding UTF8 `
        -Value "DB_SERVER=localhost,15999`nDB_NAME=$DB`nDB_USER=sa`nDB_PASSWORD=$SA_PW"

    Import-Module $ModulePath -Force
    Push-Location $workDir
    try {
        Invoke-SqlPackage -Init 2>&1 | Out-Null       # genera sqlpackage.yaml (no pisa .env existente)

        # ── 3. POSITIVO: deploy vía -EnvFile .env.container ────────────────
        Write-Host "==> APPLY -EnvFile .env.container (target = contenedor)..." -ForegroundColor Cyan
        Invoke-SqlPackage -Apply -EnvFile .env.container -AutoApprove 2>&1 | Out-Null

        $found = sqlcmd -S $SRV -U sa -P $SA_PW -C -d $DB -h -1 -W `
            -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name='Persona';" 2>&1
        if ("$found".Trim() -notmatch '^1') { Fail "dbo.Persona NO existe en el contenedor tras el Apply (got '$found')." }
        Write-Host "    OK: dbo.Persona existe en el contenedor -> -EnvFile dirigió la conexión al target correcto." -ForegroundColor Green

        # ── 4. NEGATIVO: -Plan con .env default (server muerto) debe fallar ─
        Write-Host "==> PLAN con .env por defecto (server muerto) — debe fallar..." -ForegroundColor Cyan
        $threw = $false
        try { Invoke-SqlPackage -Plan 2>&1 | Out-Null } catch { $threw = $true }
        if (-not $threw) { Fail "-Plan con el .env por defecto (server inexistente) NO falló — -EnvFile no estaría seleccionando el archivo." }
        Write-Host "    OK: falló al conectar con el .env default -> -EnvFile selecciona el archivo/target realmente." -ForegroundColor Green
    }
    finally { Pop-Location }

    Write-Host "`nPASS: Invoke-SqlPackage -EnvFile validado e2e contra SQL Server en contenedor." -ForegroundColor Green
}
finally {
    docker rm -f $CONTAINER 2>$null | Out-Null
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
}
