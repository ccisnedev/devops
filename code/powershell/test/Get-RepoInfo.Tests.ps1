Describe "Get-RepoInfo" {
    BeforeAll {
        . "$PSScriptRoot/../Functions/Get-RepoInfo.ps1"
        . "$PSScriptRoot/../Private/ConvertFrom-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Test-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateVersion.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateHash.ps1"
        . "$PSScriptRoot/../Private/Resolve-RepoStack.ps1"
        . "$PSScriptRoot/../Private/Get-RepoDeployStatus.ps1"
    }

    Context "Single repo WITH metadata" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                # Repo metadata
                if ($allArgs -match 'repos/cacsi-dev/gabinete_ui --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        'flutter,web'
                        'false'
                        '2026-04-20T10:00:00Z'
                    )
                }

                # deploy.yaml check
                if ($allArgs -match 'repos/cacsi-dev/gabinete_ui/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 0
                    return 'abc123'
                }

                # Workflows listing
                if ($allArgs -match 'repos/cacsi-dev/gabinete_ui/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 0
                    return '[{"name":"deploy.yml","download_url":"https://raw.githubusercontent.com/cacsi-dev/gabinete_ui/main/.github/workflows/deploy.yml"}]'
                }

                # Workflow content for template comparison
                if ($allArgs -match 'https://raw\.githubusercontent\.com') {
                    $script:LASTEXITCODE = 0
                    return "# deploy.web.yml`n# Version: v1.0.0`n# SHA1: abc`nname: Deploy"
                }

                # Git tree for auto-detection
                if ($allArgs -match 'repos/cacsi-dev/gabinete_ui/git/trees') {
                    $script:LASTEXITCODE = 0
                    return '{"tree":[{"path":"pubspec.yaml","type":"blob"},{"path":"lib","type":"tree"},{"path":"web","type":"tree"}]}'
                }

                # Default branch
                if ($allArgs -match 'repos/cacsi-dev/gabinete_ui --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "returns all expected properties" {
            $result = Get-RepoInfo -Name "gabinete_ui"

            $result | Should -Not -BeNullOrEmpty
            $result.Name              | Should -Be "gabinete_ui"
            $result.HasMetadata       | Should -BeTrue
            $result.Type              | Should -Be "flutter-web"
            $result.Stack             | Should -Be "dart"
            $result.RepoType          | Should -Be "legacy"
            $result.GitHubLanguage    | Should -Be "Dart"
            $result.IsArchived        | Should -BeFalse
            $result.DeployStatus      | Should -Be "auto"
            $result.DeployYAMLExists  | Should -BeTrue
            $result.WorkflowExists    | Should -BeTrue
        }

        It "populates URL with org prefix" {
            $result = Get-RepoInfo -Name "gabinete_ui"
            $result.URL | Should -Be "https://github.com/cacsi-dev/gabinete_ui"
        }

        It "populates GitHubTopics as array" {
            $result = Get-RepoInfo -Name "gabinete_ui"
            $result.GitHubTopics | Should -Contain "flutter"
            $result.GitHubTopics | Should -Contain "web"
        }

        It "populates LastPush as datetime" {
            $result = Get-RepoInfo -Name "gabinete_ui"
            $result.LastPush | Should -BeOfType [datetime]
        }

        It "auto-detects stack from repo files" {
            $result = Get-RepoInfo -Name "gabinete_ui"
            $result.AutoDetectedStack | Should -Be "dart"
            $result.SuggestedType     | Should -Be "flutter-web"
        }

        It "stores raw description" {
            $result = Get-RepoInfo -Name "gabinete_ui"
            $result.Description | Should -Be "type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy"
        }
    }

    Context "Single repo WITHOUT metadata" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match 'repos/cacsi-dev/legacy_app --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                if ($allArgs -match 'repos/cacsi-dev/legacy_app --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'A legacy application with no structured metadata'
                        'JavaScript'
                        ''
                        'false'
                        '2026-03-15T08:30:00Z'
                    )
                }

                if ($allArgs -match 'repos/cacsi-dev/legacy_app/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 1
                    return "Not Found"
                }

                if ($allArgs -match 'repos/cacsi-dev/legacy_app/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 1
                    return "Not Found"
                }

                if ($allArgs -match 'repos/cacsi-dev/legacy_app/git/trees') {
                    $script:LASTEXITCODE = 0
                    return '{"tree":[{"path":"package.json","type":"blob"},{"path":"src","type":"tree"},{"path":"tsconfig.json","type":"blob"}]}'
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "sets HasMetadata to false" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.HasMetadata | Should -BeFalse
        }

        It "auto-detects stack as typescript" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.AutoDetectedStack | Should -Be "typescript"
        }

        It "suggests type based on detected stack" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.SuggestedType | Should -Be "node-api"
        }

        It "generates suggested description" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.SuggestedDescription | Should -Match "^type:node-api\|stack:typescript"
        }

        It "sets deploy status to none" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.DeployStatus     | Should -Be "none"
            $result.DeployYAMLExists | Should -BeFalse
            $result.WorkflowExists   | Should -BeFalse
        }

        It "preserves original description" {
            $result = Get-RepoInfo -Name "legacy_app"
            $result.Description | Should -Be "A legacy application with no structured metadata"
        }
    }

    Context "Deploy status detection" {
        It "returns 'partial' when deploy.yaml exists but no workflow" {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match 'repos/cacsi-dev/partial_repo --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                if ($allArgs -match 'repos/cacsi-dev/partial_repo --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        ''
                        'false'
                        '2026-04-01T00:00:00Z'
                    )
                }

                if ($allArgs -match 'repos/cacsi-dev/partial_repo/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 0
                    return 'sha456'
                }

                if ($allArgs -match 'repos/cacsi-dev/partial_repo/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 1
                    return "Not Found"
                }

                if ($allArgs -match 'repos/cacsi-dev/partial_repo/git/trees') {
                    $script:LASTEXITCODE = 0
                    return '{"tree":[{"path":"pubspec.yaml","type":"blob"}]}'
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }

            $result = Get-RepoInfo -Name "partial_repo"
            $result.DeployStatus    | Should -Be "partial"
            $result.DeployYAMLExists | Should -BeTrue
            $result.WorkflowExists   | Should -BeFalse
        }
    }

    Context "Template version and freshness" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match 'repos/cacsi-dev/fresh_repo --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                if ($allArgs -match 'repos/cacsi-dev/fresh_repo --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        ''
                        'false'
                        '2026-04-20T10:00:00Z'
                    )
                }

                if ($allArgs -match 'repos/cacsi-dev/fresh_repo/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 0
                    return 'sha789'
                }

                if ($allArgs -match 'repos/cacsi-dev/fresh_repo/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 0
                    return '[{"name":"deploy.yml","download_url":"https://raw.githubusercontent.com/cacsi-dev/fresh_repo/main/.github/workflows/deploy.yml"}]'
                }

                if ($allArgs -match 'https://raw\.githubusercontent\.com') {
                    $script:LASTEXITCODE = 0
                    # Return content matching the canonical template
                    return "# deploy.web.yml`n# Version: v1.0.0`n# SHA1: abc`nname: Deploy Flutter Web"
                }

                if ($allArgs -match 'repos/cacsi-dev/fresh_repo/git/trees') {
                    $script:LASTEXITCODE = 0
                    return '{"tree":[{"path":"pubspec.yaml","type":"blob"},{"path":"web","type":"tree"}]}'
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "detects template version from workflow content" {
            $result = Get-RepoInfo -Name "fresh_repo"
            $result.TemplateVersion | Should -Be "v1.0.0"
        }

        It "checks template freshness against canonical hash" {
            $result = Get-RepoInfo -Name "fresh_repo"
            $result.TemplateIsCurrent | Should -Not -BeNullOrEmpty
            # TemplateIsCurrent is a boolean
            $result.TemplateIsCurrent | Should -BeOfType [bool]
        }
    }

    Context "Error handling" {
        It "returns error info when repo not found" {
            Mock gh {
                $script:LASTEXITCODE = 1
                return "Could not resolve to a Repository"
            }

            $result = Get-RepoInfo -Name "nonexistent_repo" -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
        }
    }

    Context "-Json output" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match 'repos/cacsi-dev/json_repo --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                if ($allArgs -match 'repos/cacsi-dev/json_repo --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        ''
                        'false'
                        '2026-04-20T10:00:00Z'
                    )
                }

                if ($allArgs -match 'repos/cacsi-dev/json_repo/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 0
                    return 'sha000'
                }

                if ($allArgs -match 'repos/cacsi-dev/json_repo/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 0
                    return '[{"name":"deploy.yml","download_url":"https://raw.githubusercontent.com/cacsi-dev/json_repo/main/.github/workflows/deploy.yml"}]'
                }

                if ($allArgs -match 'https://raw\.githubusercontent\.com') {
                    $script:LASTEXITCODE = 0
                    return "# deploy.web.yml`n# Version: v1.0.0`n# SHA1: abc`nname: Deploy"
                }

                if ($allArgs -match 'repos/cacsi-dev/json_repo/git/trees') {
                    $script:LASTEXITCODE = 0
                    return '{"tree":[{"path":"pubspec.yaml","type":"blob"}]}'
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "returns valid JSON string with -Json switch" {
            $json = Get-RepoInfo -Name "json_repo" -Json
            $json | Should -BeOfType [string]
            $parsed = $json | ConvertFrom-Json
            $parsed.Name | Should -Be "json_repo"
        }
    }

    Context "-List parameter" {
        BeforeAll {
            # Mock for -List: returns repo names, then each repo's metadata
            Mock gh {
                param()
                $allArgs = $args -join ' '

                # Paginated repo listing
                if ($allArgs -match 'orgs/cacsi-dev/repos') {
                    $script:LASTEXITCODE = 0
                    return @('repo_a', 'repo_b')
                }

                # Default branch for any repo
                if ($allArgs -match 'repos/cacsi-dev/repo_[ab] --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                # Metadata for repo_a
                if ($allArgs -match 'repos/cacsi-dev/repo_a --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        ''
                        'false'
                        '2026-04-20T10:00:00Z'
                    )
                }

                # Metadata for repo_b
                if ($allArgs -match 'repos/cacsi-dev/repo_b --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:node-api|stack:typescript|deploy:none|model:monorepo'
                        'TypeScript'
                        ''
                        'false'
                        '2026-04-19T12:00:00Z'
                    )
                }

                # deploy.yaml / workflows / trees — return "not found" for simplicity
                if ($allArgs -match '/contents/' -or $allArgs -match '/git/trees/') {
                    $script:LASTEXITCODE = 1
                    return "Not Found"
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "returns array of repo info objects" {
            $results = Get-RepoInfo -List
            $results | Should -HaveCount 2
            $results[0].Name | Should -Be "repo_a"
            $results[1].Name | Should -Be "repo_b"
        }
    }

    Context "-Filter parameter" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match 'orgs/cacsi-dev/repos') {
                    $script:LASTEXITCODE = 0
                    return @('filter_a', 'filter_b')
                }

                if ($allArgs -match 'repos/cacsi-dev/filter_[ab] --jq .default_branch') {
                    $script:LASTEXITCODE = 0
                    return 'main'
                }

                if ($allArgs -match 'repos/cacsi-dev/filter_a --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy'
                        'Dart'
                        ''
                        'false'
                        '2026-04-20T10:00:00Z'
                    )
                }

                if ($allArgs -match 'repos/cacsi-dev/filter_b --jq') {
                    $script:LASTEXITCODE = 0
                    return @(
                        'type:node-api|stack:typescript|deploy:none|model:monorepo'
                        'TypeScript'
                        ''
                        'false'
                        '2026-04-19T12:00:00Z'
                    )
                }

                if ($allArgs -match '/contents/' -or $allArgs -match '/git/trees/') {
                    $script:LASTEXITCODE = 1
                    return "Not Found"
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "filters by Type" {
            $results = Get-RepoInfo -List -Filter @{ Type = 'flutter-web' }
            $results | Should -HaveCount 1
            $results[0].Type | Should -Be "flutter-web"
        }

        It "filters by HasMetadata" {
            $results = Get-RepoInfo -List -Filter @{ HasMetadata = $true }
            $results | Should -HaveCount 2
        }

        It "filters by Stack" {
            $results = Get-RepoInfo -List -Filter @{ Stack = 'typescript' }
            $results | Should -HaveCount 1
            $results[0].Stack | Should -Be "typescript"
        }
    }
}

Describe "Resolve-RepoStack" {
    BeforeAll {
        . "$PSScriptRoot/../Private/Resolve-RepoStack.ps1"
    }

    It "detects dart/flutter-web from pubspec.yaml + web/" {
        $files = @(
            @{ path = 'pubspec.yaml'; type = 'blob' }
            @{ path = 'web'; type = 'tree' }
            @{ path = 'lib'; type = 'tree' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "dart"
        $result.SuggestedType | Should -Be "flutter-web"
    }

    It "detects dart/flutter-apk from pubspec.yaml + android/ without web/" {
        $files = @(
            @{ path = 'pubspec.yaml'; type = 'blob' }
            @{ path = 'android'; type = 'tree' }
            @{ path = 'lib'; type = 'tree' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "dart"
        $result.SuggestedType | Should -Be "flutter-apk"
    }

    It "detects typescript/node-api from package.json + tsconfig" {
        $files = @(
            @{ path = 'package.json'; type = 'blob' }
            @{ path = 'tsconfig.json'; type = 'blob' }
            @{ path = 'src'; type = 'tree' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "typescript"
        $result.SuggestedType | Should -Be "node-api"
    }

    It "detects javascript from package.json without tsconfig" {
        $files = @(
            @{ path = 'package.json'; type = 'blob' }
            @{ path = 'src'; type = 'tree' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "javascript"
        $result.SuggestedType | Should -Be "node-api"
    }

    It "detects sql/sqlserver-db from .sqlproj" {
        $files = @(
            @{ path = 'MyDb.sqlproj'; type = 'blob' }
            @{ path = 'Tables'; type = 'tree' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "sql"
        $result.SuggestedType | Should -Be "sqlserver-db"
    }

    It "detects csharp from .csproj" {
        $files = @(
            @{ path = 'MyApp.csproj'; type = 'blob' }
            @{ path = 'Program.cs'; type = 'blob' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "csharp"
        $result.SuggestedType | Should -Be "unknown"
    }

    It "returns generic/unknown for unrecognized repos" {
        $files = @(
            @{ path = 'README.md'; type = 'blob' }
        )
        $result = Resolve-RepoStack -Files $files
        $result.Stack        | Should -Be "generic"
        $result.SuggestedType | Should -Be "unknown"
    }
}

Describe "Get-RepoDeployStatus" {
    BeforeAll {
        . "$PSScriptRoot/../Private/Get-RepoDeployStatus.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateVersion.ps1"
        . "$PSScriptRoot/../Private/Get-TemplateHash.ps1"
    }

    Context "auto — deploy.yaml + workflow present" {
        BeforeAll {
            Mock gh {
                param()
                $allArgs = $args -join ' '

                if ($allArgs -match '/contents/deploy\.yaml') {
                    $script:LASTEXITCODE = 0
                    return 'sha-deploy'
                }

                if ($allArgs -match '/contents/\.github/workflows') {
                    $script:LASTEXITCODE = 0
                    return '[{"name":"deploy.yml","download_url":"https://example.com/deploy.yml"}]'
                }

                if ($allArgs -match 'https://example\.com') {
                    $script:LASTEXITCODE = 0
                    return "# deploy.web.yml`n# Version: v1.0.0`n# SHA1: abc`nname: Deploy"
                }

                $script:LASTEXITCODE = 1
                return "Not found"
            }
        }

        It "returns auto status" {
            $result = Get-RepoDeployStatus -RepoName "test_repo" -Org "cacsi-dev"
            $result.DeployStatus    | Should -Be "auto"
            $result.DeployYAMLExists | Should -BeTrue
            $result.WorkflowExists   | Should -BeTrue
        }

        It "extracts template version" {
            $result = Get-RepoDeployStatus -RepoName "test_repo" -Org "cacsi-dev"
            $result.TemplateVersion | Should -Be "v1.0.0"
        }
    }

    Context "none — neither present" {
        BeforeAll {
            Mock gh {
                $script:LASTEXITCODE = 1
                return "Not Found"
            }
        }

        It "returns none status" {
            $result = Get-RepoDeployStatus -RepoName "empty_repo" -Org "cacsi-dev"
            $result.DeployStatus     | Should -Be "none"
            $result.DeployYAMLExists | Should -BeFalse
            $result.WorkflowExists   | Should -BeFalse
            $result.TemplateVersion  | Should -BeNullOrEmpty
        }
    }
}
