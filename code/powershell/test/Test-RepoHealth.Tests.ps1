Describe "Test-RepoHealth" {
    BeforeAll {
        . "$PSScriptRoot/../Functions/Test-RepoHealth.ps1"
        . "$PSScriptRoot/../Functions/Get-RepoInfo.ps1"
        . "$PSScriptRoot/../Private/ConvertFrom-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Test-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateVersion.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateHash.ps1"
        . "$PSScriptRoot/../Private/Resolve-RepoStack.ps1"
        . "$PSScriptRoot/../Private/Get-RepoDeployStatus.ps1"
    }

    Context "Healthy repo — all checks PASS" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'healthy_repo'
                    URL                  = 'https://github.com/cacsi-dev/healthy_repo'
                    Description          = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata          = $true
                    Type                 = 'flutter-web'
                    Stack                = 'dart'
                    RepoType             = 'legacy'
                    GitHubLanguage       = 'Dart'
                    GitHubTopics         = @('flutter','web')
                    IsArchived           = $false
                    LastPush             = [datetime]'2026-04-20'
                    AutoDetectedStack    = 'dart'
                    SuggestedType        = 'flutter-web'
                    SuggestedDescription = $null
                    DeployStatus         = 'auto'
                    DeployYAMLExists     = $true
                    WorkflowExists       = $true
                    TemplateVersion      = 'v1.0.0'
                    TemplateIsCurrent    = $true
                    Notes                = $null
                }
            }
        }

        It "returns HealthStatus = healthy" {
            $result = Test-RepoHealth -Name 'healthy_repo'
            $result.HealthStatus | Should -Be 'healthy'
        }

        It "all checks are PASS" {
            $result = Test-RepoHealth -Name 'healthy_repo'
            $result.Checks | ForEach-Object {
                $_.Status | Should -Be 'PASS'
            }
        }

        It "returns 4 checks" {
            $result = Test-RepoHealth -Name 'healthy_repo'
            $result.Checks.Count | Should -Be 4
        }

        It "returns empty Actions list" {
            $result = Test-RepoHealth -Name 'healthy_repo'
            $result.Actions.Count | Should -Be 0
        }

        It "returns the repo Name" {
            $result = Test-RepoHealth -Name 'healthy_repo'
            $result.Name | Should -Be 'healthy_repo'
        }
    }

    Context "Repo without metadata — needs-automation" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'no_meta_repo'
                    URL                  = 'https://github.com/cacsi-dev/no_meta_repo'
                    Description          = 'An old app without metadata'
                    HasMetadata          = $false
                    Type                 = $null
                    Stack                = $null
                    RepoType             = $null
                    GitHubLanguage       = 'JavaScript'
                    GitHubTopics         = @()
                    IsArchived           = $false
                    LastPush             = [datetime]'2026-03-15'
                    AutoDetectedStack    = 'typescript'
                    SuggestedType        = 'node-api'
                    SuggestedDescription = 'type:node-api|stack:typescript|deploy:none|model:legacy'
                    DeployStatus         = 'none'
                    DeployYAMLExists     = $false
                    WorkflowExists       = $false
                    TemplateVersion      = $null
                    TemplateIsCurrent    = $null
                    Notes                = $null
                }
            }
        }

        It "returns HealthStatus = needs-automation" {
            $result = Test-RepoHealth -Name 'no_meta_repo'
            $result.HealthStatus | Should -Be 'needs-automation'
        }

        It "metadata check is FAIL with suggestion" {
            $result = Test-RepoHealth -Name 'no_meta_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Has valid metadata description' }
            $check.Status     | Should -Be 'FAIL'
            $check.Suggestion | Should -Not -BeNullOrEmpty
        }

        It "includes suggested description in suggestion" {
            $result = Test-RepoHealth -Name 'no_meta_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Has valid metadata description' }
            $check.Suggestion | Should -Match 'type:node-api'
        }

        It "Actions list includes steps to remediate" {
            $result = Test-RepoHealth -Name 'no_meta_repo'
            $result.Actions.Count | Should -BeGreaterThan 0
        }
    }

    Context "Repo with invalid deploy.yaml — misconfigured" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'bad_deploy_repo'
                    URL                  = 'https://github.com/cacsi-dev/bad_deploy_repo'
                    Description          = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata          = $true
                    Type                 = 'flutter-web'
                    Stack                = 'dart'
                    RepoType             = 'legacy'
                    GitHubLanguage       = 'Dart'
                    GitHubTopics         = @()
                    IsArchived           = $false
                    LastPush             = [datetime]'2026-04-10'
                    AutoDetectedStack    = 'dart'
                    SuggestedType        = 'flutter-web'
                    SuggestedDescription = $null
                    DeployStatus         = 'auto'
                    DeployYAMLExists     = $true
                    WorkflowExists       = $true
                    TemplateVersion      = 'v0.5.0'
                    TemplateIsCurrent    = $false
                    Notes                = $null
                }
            }
        }

        It "returns HealthStatus = misconfigured" {
            $result = Test-RepoHealth -Name 'bad_deploy_repo'
            $result.HealthStatus | Should -Be 'misconfigured'
        }

        It "template check is FAIL" {
            $result = Test-RepoHealth -Name 'bad_deploy_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Template version is current' }
            $check.Status | Should -Be 'FAIL'
        }

        It "Actions list includes template update step" {
            $result = Test-RepoHealth -Name 'bad_deploy_repo'
            $result.Actions | Should -Not -BeNullOrEmpty
            ($result.Actions -join "`n") | Should -Match 'template|workflow'
        }
    }

    Context "Archived repo — skip checks" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'archived_repo'
                    URL                  = 'https://github.com/cacsi-dev/archived_repo'
                    Description          = 'type:archived|stack:generic|deploy:none|model:legacy'
                    HasMetadata          = $true
                    Type                 = 'archived'
                    Stack                = 'generic'
                    RepoType             = 'legacy'
                    GitHubLanguage       = $null
                    GitHubTopics         = @()
                    IsArchived           = $true
                    LastPush             = [datetime]'2025-01-01'
                    AutoDetectedStack    = $null
                    SuggestedType        = $null
                    SuggestedDescription = $null
                    DeployStatus         = 'none'
                    DeployYAMLExists     = $false
                    WorkflowExists       = $false
                    TemplateVersion      = $null
                    TemplateIsCurrent    = $null
                    Notes                = $null
                }
            }
        }

        It "returns HealthStatus = archived" {
            $result = Test-RepoHealth -Name 'archived_repo'
            $result.HealthStatus | Should -Be 'archived'
        }

        It "returns empty Checks array" {
            $result = Test-RepoHealth -Name 'archived_repo'
            $result.Checks.Count | Should -Be 0
        }

        It "returns empty Actions array" {
            $result = Test-RepoHealth -Name 'archived_repo'
            $result.Actions.Count | Should -Be 0
        }
    }

    Context "Repo with metadata but missing deploy — needs-automation" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'partial_repo'
                    URL                  = 'https://github.com/cacsi-dev/partial_repo'
                    Description          = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata          = $true
                    Type                 = 'flutter-web'
                    Stack                = 'dart'
                    RepoType             = 'legacy'
                    GitHubLanguage       = 'Dart'
                    GitHubTopics         = @()
                    IsArchived           = $false
                    LastPush             = [datetime]'2026-04-01'
                    AutoDetectedStack    = 'dart'
                    SuggestedType        = 'flutter-web'
                    SuggestedDescription = $null
                    DeployStatus         = 'none'
                    DeployYAMLExists     = $false
                    WorkflowExists       = $false
                    TemplateVersion      = $null
                    TemplateIsCurrent    = $null
                    Notes                = $null
                }
            }
        }

        It "returns HealthStatus = needs-automation" {
            $result = Test-RepoHealth -Name 'partial_repo'
            $result.HealthStatus | Should -Be 'needs-automation'
        }

        It "metadata check is PASS" {
            $result = Test-RepoHealth -Name 'partial_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Has valid metadata description' }
            $check.Status | Should -Be 'PASS'
        }

        It "deploy.yaml check is FAIL" {
            $result = Test-RepoHealth -Name 'partial_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Publish.yaml exists and is valid' }
            $check.Status | Should -Be 'FAIL'
        }

        It "workflow check is FAIL" {
            $result = Test-RepoHealth -Name 'partial_repo'
            $check = $result.Checks | Where-Object { $_.Check -eq 'Workflow file exists' }
            $check.Status | Should -Be 'FAIL'
        }
    }

    Context "-Fix switch throws not implemented" {
        BeforeAll {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name                 = 'any_repo'
                    URL                  = 'https://github.com/cacsi-dev/any_repo'
                    Description          = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata          = $true
                    Type                 = 'flutter-web'
                    Stack                = 'dart'
                    RepoType             = 'legacy'
                    GitHubLanguage       = 'Dart'
                    GitHubTopics         = @()
                    IsArchived           = $false
                    LastPush             = [datetime]'2026-04-20'
                    AutoDetectedStack    = 'dart'
                    SuggestedType        = 'flutter-web'
                    SuggestedDescription = $null
                    DeployStatus         = 'auto'
                    DeployYAMLExists     = $true
                    WorkflowExists       = $true
                    TemplateVersion      = 'v1.0.0'
                    TemplateIsCurrent    = $true
                    Notes                = $null
                }
            }
        }

        It "throws 'Not implemented' when -Fix is used" {
            { Test-RepoHealth -Name 'any_repo' -Fix } | Should -Throw '*Not implemented*'
        }
    }
}
