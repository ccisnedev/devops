@{
    RootModule = 'macss-devops.psm1'
    ModuleVersion = '6.5.0'
    GUID = 'fc00a549-8aa9-4b58-b4f8-6e1e5d39e22a'
    Author = 'ccisne.dev'
    CompanyName = 'ccisne.dev'
    Copyright = '(C) 2026 ccisne.dev. All rights reserved.'

    Description = 'Automation and deployment toolkit for DevOps workflows across Flutter, Node.js, SQL Server, and repository governance.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Invoke-FlutterBuild'
        , 'Invoke-SqlPackage'
        , 'Invoke-PgSchema'
        , 'Publish-NodeApi'
        , 'Publish-DockerStack'
        , 'Publish-FlutterWeb'
        , 'Get-RepoInfo'
        , 'Test-RepoHealth'
        , 'New-DeployWorkflow'
        , 'Install-PSDevOpsSkill'
        , 'Get-SQLiteDB'
        , 'Merge-DevToMain'
        , 'Export-FileTree'
        , 'New-Issue'
        , 'New-SshAccess'
        , 'Remove-SshAccess'
    )
    CmdletsToExport = @()
    AliasesToExport = @()
    VariablesToExport = @()

    FileList = @()
    RequiredModules = @()
    RequiredAssemblies = @()

    PrivateData = @{
        PSData = @{
            Tags = @('devops', 'powershell', 'cicd', 'deployment', 'flutter', 'node', 'sqlserver', 'github-actions')
            ProjectUri = 'https://github.com/ccisnedev/PSDevOps'
            ReleaseNotes = 'See CHANGELOG.md. 3.0.0 renames the published module to macss-devops and adds GitHub Actions publication from code/powershell.'
        }
    }

    ModuleToProcess = ''
    NestedModules = @()
}