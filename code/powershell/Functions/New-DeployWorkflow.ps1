function New-DeployWorkflow {
    <#
    .SYNOPSIS
    Genera un workflow de deploy copiando el template canónico según el tipo de repo.

    .DESCRIPTION
    Lee la metadata del repo vía Get-RepoInfo, determina el template correcto
    según el type (flutter-web → deploy.web.yml, node-api → deploy.api.yml,
    sqlserver-db → deploy.db.yml), y lo copia al OutputPath.

    .PARAMETER Name
    Nombre del repositorio.

    .PARAMETER OutputPath
    Ruta completa donde escribir el workflow (e.g. .github/workflows/deploy.yml).

    .PARAMETER TemplatePath
    Directorio donde buscar los templates canónicos. Si no se especifica,
    busca en: $env:PSDEVOPS_TEMPLATES, developer machine path, runner path.

    .PARAMETER Push
    Placeholder: indica que se debería hacer git add + commit + push tras copiar.

    .EXAMPLE
    New-DeployWorkflow -Name gabinete_ui -OutputPath .github/workflows/deploy.yml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$TemplatePath,

        [switch]$Push
    )

    # 1. Get repo info
    $repo = Get-RepoInfo -Name $Name

    if (-not $repo) {
        throw "Repository '$Name' not found."
    }

    # 2. Validate metadata
    if (-not $repo.HasMetadata) {
        throw "Repository '$Name' has no valid metadata description. Run Get-RepoInfo to see suggested description."
    }

    # 3. Validate deploy.yaml
    if (-not $repo.DeployYAMLExists) {
        throw "Repository '$Name' is missing deploy.yaml. Create it before generating the workflow."
    }

    # 4. Resolve type → template
    $type = $repo.Type
    $templateMap = @{
        'flutter-web'  = 'deploy.web.yml'
        'flutter-apk'  = 'deploy.web.yml'
        'node-api'     = 'deploy.api.yml'
        'sqlserver-db' = 'deploy.db.yml'
    }

    if ($type -eq 'macss') {
        throw "macss repos require manual workflow configuration — they need deploy.web.yml + deploy.api.yml + deploy.db.yml"
    }

    $templateFile = $templateMap[$type]
    if (-not $templateFile) {
        throw "No deploy template available for type '$type'. Only flutter-web, flutter-apk, node-api, and sqlserver-db are supported."
    }

    # 5. Resolve template directory
    $resolvedTemplatePath = Resolve-TemplatePath -TemplatePath $TemplatePath -FileName $templateFile

    if (-not $resolvedTemplatePath) {
        throw "Template '$templateFile' not found in any search path."
    }

    # 6. Copy template to output
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $resolvedTemplatePath -Destination $OutputPath -Force

    # 7. Build result
    [PSCustomObject]@{
        Status       = 'Success'
        Repository   = $Name
        Type         = $type
        TemplateUsed = $templateFile
        OutputPath   = $OutputPath
        PushPending  = [bool]$Push
    }
}


function Resolve-TemplatePath {
    <#
    .SYNOPSIS
    Resuelve la ruta completa al archivo de template.
    Busca en: TemplatePath explícito, $env:PSDEVOPS_TEMPLATES, developer path, runner path.
    #>
    [CmdletBinding()]
    param(
        [string]$TemplatePath,
        [Parameter(Mandatory)]
        [string]$FileName
    )

    $searchPaths = @()

    if ($TemplatePath) {
        $searchPaths += $TemplatePath
    }

    if ($env:PSDEVOPS_TEMPLATES) {
        $searchPaths += $env:PSDEVOPS_TEMPLATES
    }

    $searchPaths += Join-Path $env:USERPROFILE 'Code\cacsi-dev\.github\templates\workflows'
    $searchPaths += '/opt/.github/templates/workflows'

    foreach ($dir in $searchPaths) {
        $candidate = Join-Path $dir $FileName
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}
