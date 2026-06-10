Describe "New-DeployWorkflow" {
    BeforeAll {
        . "$PSScriptRoot/../Private/ConvertFrom-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Test-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateVersion.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateHash.ps1"
        . "$PSScriptRoot/../Private/Resolve-RepoStack.ps1"
        . "$PSScriptRoot/../Private/Get-RepoDeployStatus.ps1"
        . "$PSScriptRoot/../Functions/Get-RepoInfo.ps1"
        . "$PSScriptRoot/../Functions/New-DeployWorkflow.ps1"
    }

    Context "5.1 — Generate valid workflow for flutter-web" {
        BeforeAll {
            # Create a fake template in TestDrive
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
            @"
# deploy.web.yml — Template de deploy para Flutter Web
# Version: v1.0.0
# SHA1: abc123
name: Deploy Flutter Web
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: [self-hosted, PCDCTIC01]
    steps:
      - uses: actions/checkout@v4
"@ | Set-Content (Join-Path $templateDir 'deploy.web.yml') -Encoding UTF8

            $outputDir = Join-Path $TestDrive 'repo/.github/workflows'
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null

            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name        = 'gabinete_ui'
                    Description = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata = $true
                    Type        = 'flutter-web'
                    DeployYAMLExists = $true
                }
            }
        }

        It "copies template to output path" {
            $outFile = Join-Path $TestDrive 'repo/.github/workflows/deploy.yml'
            New-DeployWorkflow -Name 'gabinete_ui' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            Test-Path $outFile | Should -Be $true
        }

        It "output content matches template" {
            $outFile = Join-Path $TestDrive 'repo/.github/workflows/deploy.yml'
            New-DeployWorkflow -Name 'gabinete_ui' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $content = Get-Content $outFile -Raw
            $content | Should -Match 'Deploy Flutter Web'
        }

        It "returns a result object with status Success" {
            $outFile = Join-Path $TestDrive 'repo/.github/workflows/deploy.yml'
            $result = New-DeployWorkflow -Name 'gabinete_ui' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $result.Status | Should -Be 'Success'
            $result.TemplateUsed | Should -Be 'deploy.web.yml'
        }
    }

    Context "5.2 — Generated YAML is syntactically valid" {
        BeforeAll {
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
            @"
# deploy.web.yml — Template de deploy para Flutter Web
# Version: v1.0.0
# SHA1: abc123
name: Deploy Flutter Web
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: [self-hosted, PCDCTIC01]
    steps:
      - uses: actions/checkout@v4
"@ | Set-Content (Join-Path $templateDir 'deploy.web.yml') -Encoding UTF8

            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name        = 'gabinete_ui'
                    Description = 'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                    HasMetadata = $true
                    Type        = 'flutter-web'
                    DeployYAMLExists = $true
                }
            }
        }

        It "output is parseable as YAML (powershell-yaml or basic structure)" {
            $outFile = Join-Path $TestDrive 'repo2/.github/workflows/deploy.yml'
            New-Item -Path (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            New-DeployWorkflow -Name 'gabinete_ui' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $content = Get-Content $outFile -Raw
            # Basic YAML structure validation: has 'name:' and 'jobs:'
            $content | Should -Match '(?m)^name:'
            $content | Should -Match '(?m)^jobs:'
        }
    }

    Context "5.3 — Type-to-template mapping is correct" {
        BeforeAll {
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null

            foreach ($tpl in @('deploy.web.yml', 'deploy.api.yml', 'deploy.db.yml')) {
                @"
# $tpl — Template
# Version: v1.0.0
# SHA1: aaa111
name: $tpl
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: [self-hosted]
    steps:
      - uses: actions/checkout@v4
"@ | Set-Content (Join-Path $templateDir $tpl) -Encoding UTF8
            }
        }

        It "flutter-web maps to deploy.web.yml" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'web_repo'; HasMetadata = $true; Type = 'flutter-web'; DeployYAMLExists = $true
                }
            }
            $outFile = Join-Path $TestDrive 'map-web/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            $result = New-DeployWorkflow -Name 'web_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $result.TemplateUsed | Should -Be 'deploy.web.yml'
        }

        It "node-api maps to deploy.api.yml" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'api_repo'; HasMetadata = $true; Type = 'node-api'; DeployYAMLExists = $true
                }
            }
            $outFile = Join-Path $TestDrive 'map-api/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            $result = New-DeployWorkflow -Name 'api_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $result.TemplateUsed | Should -Be 'deploy.api.yml'
        }

        It "sqlserver-db maps to deploy.db.yml" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'db_repo'; HasMetadata = $true; Type = 'sqlserver-db'; DeployYAMLExists = $true
                }
            }
            $outFile = Join-Path $TestDrive 'map-db/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            $result = New-DeployWorkflow -Name 'db_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows')
            $result.TemplateUsed | Should -Be 'deploy.db.yml'
        }
    }

    Context "5.4 — Reject invalid type" {
        BeforeAll {
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
        }

        It "throws on type 'tooling' (no deploy template)" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'tool_repo'; HasMetadata = $true; Type = 'tooling'; DeployYAMLExists = $true
                }
            }
            $outFile = Join-Path $TestDrive 'invalid-type/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            { New-DeployWorkflow -Name 'tool_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows') } |
                Should -Throw "*No deploy template*"
        }

        It "throws on type 'macss' with monorepo message" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'macss_repo'; HasMetadata = $true; Type = 'macss'; DeployYAMLExists = $true
                }
            }
            $outFile = Join-Path $TestDrive 'macss/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            { New-DeployWorkflow -Name 'macss_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows') } |
                Should -Throw "*macss*manual*"
        }

        It "throws when repo has no metadata" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'nomd_repo'; HasMetadata = $false; Type = $null; DeployYAMLExists = $false
                }
            }
            $outFile = Join-Path $TestDrive 'nomd/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            { New-DeployWorkflow -Name 'nomd_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows') } |
                Should -Throw "*metadata*"
        }
    }

    Context "5.5 — Reject when deploy.yaml is missing" {
        BeforeAll {
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
        }

        It "throws when DeployYAMLExists is false" {
            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'nodeploy_repo'; HasMetadata = $true; Type = 'flutter-web'; DeployYAMLExists = $false
                }
            }
            $outFile = Join-Path $TestDrive 'nodeploy/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            { New-DeployWorkflow -Name 'nodeploy_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows') } |
                Should -Throw "*publish.yaml*"
        }
    }

    Context "5.9 — Push switch placeholder" {
        BeforeAll {
            $templateDir = Join-Path $TestDrive 'templates/workflows'
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
            @"
# deploy.web.yml
# Version: v1.0.0
# SHA1: abc123
name: Deploy Flutter Web
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: [self-hosted]
    steps:
      - uses: actions/checkout@v4
"@ | Set-Content (Join-Path $templateDir 'deploy.web.yml') -Encoding UTF8

            Mock Get-RepoInfo {
                [PSCustomObject]@{
                    Name = 'push_repo'; HasMetadata = $true; Type = 'flutter-web'; DeployYAMLExists = $true
                }
            }
        }

        It "accepts -Push switch without error" {
            $outFile = Join-Path $TestDrive 'push/deploy.yml'
            New-Item (Split-Path $outFile) -ItemType Directory -Force | Out-Null
            $result = New-DeployWorkflow -Name 'push_repo' -OutputPath $outFile -TemplatePath (Join-Path $TestDrive 'templates/workflows') -Push
            $result.Status | Should -Be 'Success'
            $result.PushPending | Should -Be $true
        }
    }
}
