function Get-RepoInfo {
    <#
    .SYNOPSIS
    Consulta metadata y estado de deploy de repositorios en la organización.

    .DESCRIPTION
    Para repos CON metadata normalizada (type:X|stack:Y|...) parsea la descripción.
    Para repos SIN metadata, auto-detecta stack y sugiere descripción.
    Comprueba deploy.yaml + workflow y determina DeployStatus (auto/partial/none).

    .PARAMETER Name
    Nombre de un repositorio individual.

    .PARAMETER List
    Lista todos los repositorios de la organización.

    .PARAMETER Filter
    Hashtable para filtrar resultados de -List. Keys: Type, HasMetadata, DeployStatus, Stack.

    .PARAMETER Org
    Organización GitHub. Default: cacsi-dev.

    .PARAMETER Json
    Retorna el resultado como JSON string.

    .EXAMPLE
    Get-RepoInfo -Name gabinete_ui
    #>
    [CmdletBinding(DefaultParameterSetName = 'Single')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Single', Position = 0)]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'List')]
        [switch]$List,

        [Parameter(ParameterSetName = 'List')]
        [hashtable]$Filter,

        [string]$Org = 'cacsi-dev',

        [switch]$Json
    )

    if ($PSCmdlet.ParameterSetName -eq 'List') {
        $repoNames = & gh api "orgs/$Org/repos" --paginate -q '.[].name' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to list repos: $repoNames"
            return
        }
        # gh --paginate can return one name per line
        $repoNames = @($repoNames) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $results = foreach ($repoName in $repoNames) {
            Get-SingleRepoInfo -RepoName $repoName -Org $Org
        }
        $results = @($results | Where-Object { $_ })

        # Apply filter
        if ($Filter) {
            if ($Filter.ContainsKey('Type'))        { $results = $results | Where-Object { $_.Type -eq $Filter.Type } }
            if ($Filter.ContainsKey('HasMetadata'))  { $results = $results | Where-Object { $_.HasMetadata -eq $Filter.HasMetadata } }
            if ($Filter.ContainsKey('DeployStatus')) { $results = $results | Where-Object { $_.DeployStatus -eq $Filter.DeployStatus } }
            if ($Filter.ContainsKey('Stack'))        { $results = $results | Where-Object { $_.Stack -eq $Filter.Stack } }
        }

        if ($Json) {
            return $results | ConvertTo-Json -Depth 5
        }
        return $results
    }

    # Single repo
    $result = Get-SingleRepoInfo -RepoName $Name -Org $Org
    if ($Json -and $result) {
        return $result | ConvertTo-Json -Depth 5
    }
    return $result
}

function Get-SingleRepoInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoName,
        [string]$Org = 'cacsi-dev'
    )

    # Get default branch
    $defaultBranch = & gh api "repos/$Org/$RepoName" --jq '.default_branch' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Repo not found: $Org/$RepoName — $defaultBranch"
        return $null
    }

    # Get repo metadata (description, language, topics, archived, pushed_at)
    $meta = & gh api "repos/$Org/$RepoName" --jq '.description,.language,.topics,.archived,.pushed_at' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to get repo metadata: $meta"
        return $null
    }

    $metaLines  = @($meta)
    $description = $metaLines[0]
    $language    = $metaLines[1]
    $topicsRaw   = $metaLines[2]
    $archivedRaw = $metaLines[3]
    $pushedAtRaw = $metaLines[4]

    $topics    = if ($topicsRaw) { @($topicsRaw -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }
    $isArchived = $archivedRaw -eq 'true'
    $lastPush   = if ($pushedAtRaw) { [datetime]::Parse($pushedAtRaw) } else { $null }

    # Parse metadata if present
    $hasMetadata = Test-RepoDescription -Description $description
    $parsed = $null
    $type = $null
    $stack = $null
    $repoType = $null
    if ($hasMetadata) {
        $parsed   = ConvertFrom-RepoDescription -Description $description
        $type     = $parsed.type
        $stack    = $parsed.stack
        $repoType = $parsed.model
    }

    # Auto-detect stack from repo files
    $autoStack = $null
    $suggestedType = $null
    $treeOutput = & gh api "repos/$Org/$RepoName/git/trees/$defaultBranch" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $tree = ($treeOutput -join '') | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($tree -and $tree.tree) {
            $resolved = Resolve-RepoStack -Files $tree.tree
            $autoStack     = $resolved.Stack
            $suggestedType = $resolved.SuggestedType
        }
    }

    # Suggested description for repos without metadata
    $suggestedDescription = $null
    if (-not $hasMetadata -and $suggestedType) {
        $sStack = if ($autoStack) { $autoStack } else { 'generic' }
        $suggestedDescription = "type:$suggestedType|stack:$sStack|deploy:none|model:legacy"
    }

    # Deploy status
    $deploy = Get-RepoDeployStatus -RepoName $RepoName -Org $Org

    # Template freshness
    $templateIsCurrent = $null
    if ($deploy.TemplateHash -and $deploy.TemplateVersion) {
        # Determine canonical template based on type
        $tplType = if ($type) { $type } elseif ($suggestedType) { $suggestedType } else { $null }
        $canonicalHash = Get-CanonicalTemplateHash -Type $tplType
        if ($canonicalHash) {
            $templateIsCurrent = ($deploy.TemplateHash -eq $canonicalHash)
        }
        else {
            $templateIsCurrent = $false
        }
    }

    [PSCustomObject]@{
        Name                 = $RepoName
        URL                  = "https://github.com/$Org/$RepoName"
        Description          = $description
        HasMetadata          = $hasMetadata
        Type                 = $type
        Stack                = $stack
        RepoType             = $repoType
        GitHubLanguage       = $language
        GitHubTopics         = $topics
        IsArchived           = $isArchived
        LastPush             = $lastPush
        AutoDetectedStack    = $autoStack
        SuggestedType        = $suggestedType
        SuggestedDescription = $suggestedDescription
        DeployStatus         = $deploy.DeployStatus
        DeployYAMLExists     = $deploy.DeployYAMLExists
        WorkflowExists       = $deploy.WorkflowExists
        TemplateVersion      = $deploy.TemplateVersion
        TemplateIsCurrent    = $templateIsCurrent
        Notes                = $null
    }
}

function Get-CanonicalTemplateHash {
    <#
    .SYNOPSIS
    Obtiene el hash SHA1 del template canónico según el tipo de repo.
    #>
    [CmdletBinding()]
    param(
        [string]$Type
    )

    $templateMap = @{
        'flutter-web'  = 'deploy.web.yml'
        'node-api'     = 'deploy.api.yml'
        'sqlserver-db' = 'deploy.db.yml'
    }

    $templateFile = $templateMap[$Type]
    if (-not $templateFile) { return $null }

    # Look for canonical templates in the .github repo templates dir
    $searchPaths = @(
        (Join-Path $PSScriptRoot "..\..\..\..\..\.github\templates\workflows\$templateFile")
        (Join-Path $env:USERPROFILE "Code\cacsi-dev\.github\templates\workflows\$templateFile")
    )

    foreach ($path in $searchPaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        if ($resolved -and (Test-Path $resolved)) {
            $content = Get-Content $resolved -Raw -Encoding UTF8
            return Get-TemplateHash -Content $content
        }
    }

    return $null
}
