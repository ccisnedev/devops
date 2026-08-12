<#
.SYNOPSIS
Publica el env file del proyecto como secret de un GitHub Environment.

.DESCRIPTION
Un runner de CI no tiene el env file: está gitignoreado, así que tras `actions/checkout` no
existe. Pero `Publish-NodeApi -Apply` necesita su contenido, porque lo sube como el `.env` del
release — y eso es justamente lo que da el rollback real: cada release conserva la configuración
con la que se desplegó.

Este cmdlet publica ese archivo como secret del environment. El workflow lo materializa en un
archivo temporal y se lo pasa con `-EnvFile`, que es para lo que existe ese parámetro. El `.env`
que acaba en el release es idéntico al de un despliegue manual.

Se sube el archivo TAL CUAL. El módulo ya quita las claves `MACSS_DEPLOY_*` al instalar el
release; filtrarlas aquí crearía dos configuraciones distintas para el mismo entorno.

Actualizar la configuración de producción pasa a ser un acto deliberado: editas tu archivo,
corres `-Apply`, y queda registrado en el historial del environment.

.PARAMETER Plan
Muestra qué se publicaría —repositorio, environment, nombre del secret y los NOMBRES de las
claves— sin cambiar nada.

.PARAMETER Apply
Publica el secret. Confirma antes (ADR 0002).

.PARAMETER AutoApprove
Omite la confirmación, para uso desatendido.

.PARAMETER EnvFile
Env file de origen. Por defecto `.env`; producción es explícita: `-EnvFile .env.production`.

.PARAMETER Environment
GitHub Environment de destino. Por defecto `production`. Permite restringir el despliegue a la
rama `main` y deja historial por entorno, cosas que un secret de repositorio no da. (No es por
los gates de aprobación: R05, R22 y R23 gobiernan el merge, no el despliegue.)

.PARAMETER SecretName
Nombre del secret. Por defecto `ENV_FILE`.

.PARAMETER Repo
`owner/repo`. Por defecto se deduce del remoto git del directorio actual.

.EXAMPLE
Publish-EnvSecret -Plan -EnvFile .env.production

Muestra si el secret publicado corresponde a tu archivo actual, y qué claves lleva.

.EXAMPLE
Publish-EnvSecret -Apply -EnvFile .env.production

Publica tu .env.production como el secret ENV_FILE del environment production.

.NOTES
El valor nunca viaja en la línea de comandos —eso lo dejaría visible para cualquiera que liste
procesos—: se pasa a `gh` por stdin.

Un secret no se puede leer de vuelta, así que junto a él se publica una huella SHA-256 del
contenido como VARIABLE del environment. Es lo que permite que `-Plan` diga si lo publicado
sigue siendo tu archivo. El hash de un archivo de decenas de líneas no revela su contenido.
#>
function Publish-EnvSecret {

    [CmdletBinding(DefaultParameterSetName = 'Apply')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Plan',
            HelpMessage = "Dry-run: show what -Apply would publish, without making changes")]
        [switch]$Plan,

        [Parameter(Mandatory, ParameterSetName = 'Apply',
            HelpMessage = "Publish the env file as the environment secret")]
        [switch]$Apply,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Skip the confirmation prompt for unattended/CI use (ADR 0002)")]
        [switch]$AutoApprove,

        [Parameter(ParameterSetName = 'Apply',
            HelpMessage = "Env file to publish (default .env); prod is explicit: -EnvFile .env.production")]
        [Parameter(ParameterSetName = 'Plan',
            HelpMessage = "Env file to publish (default .env)")]
        [string]$EnvFile = '.env',

        [Parameter(ParameterSetName = 'Apply', HelpMessage = "GitHub Environment (default production)")]
        [Parameter(ParameterSetName = 'Plan', HelpMessage = "GitHub Environment (default production)")]
        [string]$Environment = 'production',

        [Parameter(ParameterSetName = 'Apply', HelpMessage = "Component: db | api | app (default: from the current directory)")]
        [Parameter(ParameterSetName = 'Plan', HelpMessage = "Component: db | api | app (default: from the current directory)")]
        [ValidateSet('db', 'api', 'app')]
        [string]$Component,

        [Parameter(ParameterSetName = 'Apply', HelpMessage = "Secret name (default ENV_FILE_<COMPONENT>)")]
        [Parameter(ParameterSetName = 'Plan', HelpMessage = "Secret name (default ENV_FILE_<COMPONENT>)")]
        [string]$SecretName,

        [Parameter(ParameterSetName = 'Apply', HelpMessage = "owner/repo (default: from the git remote)")]
        [Parameter(ParameterSetName = 'Plan', HelpMessage = "owner/repo (default: from the git remote)")]
        [string]$Repo
    )

    begin {
        $ErrorActionPreference = 'Stop'
    }

    process {
        Show-MacssBanner -Title 'Publish-EnvSecret'

        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw "No se encontró 'gh' (GitHub CLI). Es lo que publica el secret: instálelo y autentíquese con 'gh auth login'."
        }

        $cwd = (Get-Location).Path
        $envPath = if ([IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $cwd $EnvFile }
        if (-not (Test-Path -LiteralPath $envPath)) {
            throw "No se encontró el env file '$EnvFile' en $cwd. Es el archivo que se va a publicar."
        }

        # El repositorio sale del remoto, como todo lo demás en el módulo: escribirlo a mano es
        # una forma de publicar la configuración de un proyecto en otro.
        if (-not $Repo) {
            $remoto = (& git -C $cwd remote get-url origin 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $remoto) {
                throw "No se pudo deducir el repositorio: no hay remoto 'origin' en $cwd. Indíquelo con -Repo <owner/repo>."
            }
            if ("$remoto" -notmatch '[:/]([^/:]+/[^/]+?)(\.git)?$') {
                throw "No se pudo interpretar el remoto '$remoto'. Indique el repositorio con -Repo <owner/repo>."
            }
            $Repo = $Matches[1]
        }

        # db, api y app se despliegan por separado y cada uno tiene su propio env file. El
        # componente sale del directorio, igual que se invoca a Publish-NodeApi desde code/api.
        if (-not $SecretName) {
            if (-not $Component) {
                $Component = Resolve-EnvSecretComponent -Path $cwd
                if (-not $Component) {
                    throw "No se pudo deducir el componente desde '$cwd'. Ejecute el comando desde code/db, code/api o code/app, o indíquelo con -Component <db|api|app>."
                }
            }
            $SecretName = Resolve-EnvSecretName -Component $Component
        }

        $lineas = @(Get-Content -LiteralPath $envPath)
        $payload = ConvertTo-SecretPayload -Lines $lineas
        $huellaLocal = Get-ContentFingerprint -Text $payload
        $claves = Get-DotEnvKeys -Lines $lineas
        $varHuella = "${SecretName}_SHA256"

        # La huella publicada vive como variable del environment. Si no existe, gh falla y eso
        # significa 'nunca se publicó', no un error.
        $huellaRemota = ''
        $vr = & gh variable get $varHuella --env $Environment --repo $Repo 2>$null
        if ($LASTEXITCODE -eq 0 -and $vr) { $huellaRemota = "$vr".Trim() }
        # Que la variable no exista es informacion, no un fallo. Sin limpiar el codigo, el
        # cmdlet termina bien y aun asi el shell devuelve 1: un paso de workflow fallaria
        # despues de un despliegue correcto.
        $global:LASTEXITCODE = 0

        $estado = ConvertTo-EnvSecretPlan -LocalFingerprint $huellaLocal -RemoteFingerprint $huellaRemota

        Write-Host "  Repositorio:  $Repo" -ForegroundColor Cyan
        Write-Host "  Environment:  $Environment" -ForegroundColor Cyan
        Write-Host "  Secret:       $SecretName" -ForegroundColor Cyan
        Write-Host "  Origen:       $EnvFile ($($claves.Count) claves)" -ForegroundColor Cyan
        Write-Host ""

        # Nombres, nunca valores: este cmdlet publica secretos, no los muestra.
        Write-Host "  ─── Claves que se publican ───" -ForegroundColor Cyan
        Write-Host "  $($claves -join ', ')" -ForegroundColor DarkGray
        Write-Host ""

        switch ($estado.Level) {
            'ok'   { Write-Host "  $($estado.Text)" -ForegroundColor Green }
            'warn' { Write-Host "  AVISO: $($estado.Text)" -ForegroundColor Yellow }
            default { Write-Host "  $($estado.Text)" -ForegroundColor White }
        }
        Write-Host ""

        if ($Plan) {
            if ($estado.Action -ne 'sin-cambios') {
                Write-Host "  -Apply publicará el secret y la huella '$varHuella' en el environment." -ForegroundColor White
                Write-Host ""
            }
            return
        }

        if ($estado.Action -eq 'sin-cambios') {
            Write-Host "  Nada que hacer." -ForegroundColor Green
            Write-Host ""
            return
        }

        if (-not (Confirm-MacssChange -Action "Publicar '$EnvFile' como secret '$SecretName' del environment '$Environment' en $Repo" -AutoApprove:$AutoApprove)) {
            Write-Host "  Cancelado." -ForegroundColor Yellow
            return
        }

        # El environment tiene que existir antes de colgarle un secret. Crearlo es un cambio
        # visible en el repositorio, así que se dice.
        & gh api "repos/$Repo/environments/$Environment" *> $null
        $faltaEnvironment = ($LASTEXITCODE -ne 0)
        $global:LASTEXITCODE = 0
        if ($faltaEnvironment) {
            Write-Host "  El environment '$Environment' no existe; se crea." -ForegroundColor Yellow
            & gh api -X PUT "repos/$Repo/environments/$Environment" *> $null
            if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el environment '$Environment' en $Repo." }
        }

        # Por stdin: '--body <valor>' dejaría el secreto en los argumentos del proceso.
        $payload | & gh @(New-EnvSecretCommand -Repo $Repo -Environment $Environment -SecretName $SecretName) 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "gh no pudo publicar el secret '$SecretName' (exit $LASTEXITCODE)." }

        & gh variable set $varHuella --env $Environment --repo $Repo --body $huellaLocal *> $null
        if ($LASTEXITCODE -ne 0) {
            # El secret ya está publicado: sin la huella, el plan siguiente dirá que difiere y se
            # volverá a subir. Es molesto, no peligroso, pero hay que decirlo.
            Write-Warning "El secret se publicó, pero no se pudo guardar la huella '$varHuella'. -Plan no podrá afirmar si el secret corresponde a su archivo."
        }

        Write-Host "  Secret '$SecretName' publicado en el environment '$Environment' de $Repo." -ForegroundColor Green
        Write-Host "  El despliegue siguiente lo usará; los releases ya desplegados no cambian." -ForegroundColor DarkGray
        Write-Host ""
    }
}
