Describe "Test-RepoDescription" {
    BeforeAll {
        . "$PSScriptRoot/../Private/ConvertFrom-RepoDescription.ps1"
        . "$PSScriptRoot/../Private/Test-RepoDescription.ps1"
    }

    Context "Valid descriptions" {
        It "accepts minimal required keys" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy" | Should -BeTrue
        }

        It "accepts all keys" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy|ci:github-actions|criticality:high" | Should -BeTrue
        }

        It "accepts semver with prerelease" {
            Test-RepoDescription "type:node-api|stack:typescript|deploy:v1.5.0-beta.1|model:monorepo" | Should -BeTrue
        }

        It "accepts deploy:none" {
            Test-RepoDescription "type:documentation|stack:generic|deploy:none|model:legacy" | Should -BeTrue
        }

        It "accepts archived type" {
            Test-RepoDescription "type:archived|stack:generic|deploy:none|model:legacy" | Should -BeTrue
        }

        It "accepts ci only (no criticality)" {
            Test-RepoDescription "type:tooling|stack:generic|deploy:v0.3.2|model:monorepo|ci:manual" | Should -BeTrue
        }

        It "accepts all type values" {
            @('flutter-web', 'flutter-apk', 'node-api', 'sqlserver-db', 'macss', 'tooling', 'documentation', 'archived', 'unknown') | ForEach-Object {
                Test-RepoDescription "type:$_|stack:generic|deploy:none|model:legacy" | Should -BeTrue -Because "type:$_ should be valid"
            }
        }

        It "accepts macss monorepo" {
            Test-RepoDescription "type:macss|stack:dart|deploy:v1.0.0|model:monorepo|ci:github-actions|criticality:high" | Should -BeTrue
        }

        It "accepts flutter-apk" {
            Test-RepoDescription "type:flutter-apk|stack:dart|deploy:none|model:legacy" | Should -BeTrue
        }

        It "accepts all stack values" {
            @('dart', 'javascript', 'typescript', 'sql', 'csharp', 'generic') | ForEach-Object {
                Test-RepoDescription "type:tooling|stack:$_|deploy:none|model:legacy" | Should -BeTrue -Because "stack:$_ should be valid"
            }
        }

        It "accepts all model values" {
            @('legacy', 'monorepo') | ForEach-Object {
                Test-RepoDescription "type:tooling|stack:generic|deploy:none|model:$_" | Should -BeTrue -Because "model:$_ should be valid"
            }
        }
    }

    Context "Invalid descriptions" {
        It "rejects missing required key (no model)" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23" | Should -BeFalse
        }

        It "rejects invalid type value" {
            Test-RepoDescription "type:mobile-app|stack:dart|deploy:v2.30.23|model:legacy" | Should -BeFalse
        }

        It "rejects invalid stack value" {
            Test-RepoDescription "type:flutter-web|stack:kotlin|deploy:v2.30.23|model:legacy" | Should -BeFalse
        }

        It "rejects invalid model value" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:hybrid" | Should -BeFalse
        }

        It "rejects malformed semver (missing patch)" {
            Test-RepoDescription "type:node-api|stack:typescript|deploy:v1.5|model:monorepo" | Should -BeFalse
        }

        It "rejects invalid ci value" {
            Test-RepoDescription "type:tooling|stack:generic|deploy:v0.3.2|model:monorepo|ci:circleci" | Should -BeFalse
        }

        It "rejects invalid criticality value" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy|criticality:urgent" | Should -BeFalse
        }

        It "rejects spaces around delimiters" {
            Test-RepoDescription "type:flutter-web | stack:dart | deploy:v2.30.23 | model:legacy" | Should -BeFalse
        }

        It "rejects wrong key order" {
            Test-RepoDescription "stack:dart|type:flutter-web|deploy:v2.30.23|model:legacy" | Should -BeFalse
        }
    }

    Context "Edge cases" {
        It "rejects empty string" {
            Test-RepoDescription "" | Should -BeFalse
        }

        It "rejects plain text description" {
            Test-RepoDescription "Flutter web application for gabinete" | Should -BeFalse
        }

        It "rejects malformed pair (missing value)" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy|model:legacy" | Should -BeFalse
        }

        It "rejects extra pipe at end" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy|" | Should -BeFalse
        }

        It "rejects deploy without v prefix" {
            Test-RepoDescription "type:flutter-web|stack:dart|deploy:2.30.23|model:legacy" | Should -BeFalse
        }
    }
}
