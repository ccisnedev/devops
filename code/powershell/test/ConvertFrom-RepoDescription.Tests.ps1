Describe "ConvertFrom-RepoDescription" {
    BeforeAll {
        . "$PSScriptRoot/../Private/ConvertFrom-RepoDescription.ps1"
    }

    Context "Required keys only" {
        It "parses all 4 required keys" {
            $result = ConvertFrom-RepoDescription "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy"

            $result.type  | Should -Be "flutter-web"
            $result.stack | Should -Be "dart"
            $result.deploy | Should -Be "v2.30.23"
            $result.model | Should -Be "legacy"
        }

        It "defaults ci to github-actions" {
            $result = ConvertFrom-RepoDescription "type:node-api|stack:typescript|deploy:v1.5.0|model:monorepo"
            $result.ci | Should -Be "github-actions"
        }

        It "defaults criticality to medium" {
            $result = ConvertFrom-RepoDescription "type:tooling|stack:generic|deploy:v0.3.2|model:monorepo"
            $result.criticality | Should -Be "medium"
        }
    }

    Context "Optional keys" {
        It "parses ci and criticality when present" {
            $result = ConvertFrom-RepoDescription "type:documentation|stack:generic|deploy:none|model:legacy|ci:manual|criticality:low"

            $result.ci          | Should -Be "manual"
            $result.criticality | Should -Be "low"
        }

        It "parses ci alone" {
            $result = ConvertFrom-RepoDescription "type:node-api|stack:typescript|deploy:v1.0.0|model:monorepo|ci:none"
            $result.ci          | Should -Be "none"
            $result.criticality | Should -Be "medium"
        }

        It "parses criticality alone" {
            $result = ConvertFrom-RepoDescription "type:sqlserver-db|stack:sql|deploy:none|model:legacy|criticality:high"
            $result.ci          | Should -Be "github-actions"
            $result.criticality | Should -Be "high"
        }
    }

    Context "Extensibility" {
        It "ignores unknown keys and stores them in _extra" {
            $result = ConvertFrom-RepoDescription "type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy|future-key:value"

            $result.type        | Should -Be "flutter-web"
            $result._extra.Keys | Should -Contain "future-key"
            $result._extra['future-key'] | Should -Be "value"
        }
    }

    Context "Preserves raw input" {
        It "stores original string in _raw" {
            $desc = "type:flutter-web|stack:dart|deploy:v2.0.0|model:legacy"
            $result = ConvertFrom-RepoDescription $desc
            $result._raw | Should -Be $desc
        }
    }

    Context "Edge cases" {
        It "returns null for empty string" {
            $result = ConvertFrom-RepoDescription ""
            $result | Should -BeNullOrEmpty
        }

        It "returns null for whitespace" {
            $result = ConvertFrom-RepoDescription "   "
            $result | Should -BeNullOrEmpty
        }

        It "handles deploy:none" {
            $result = ConvertFrom-RepoDescription "type:documentation|stack:generic|deploy:none|model:legacy"
            $result.deploy | Should -Be "none"
        }

        It "handles semver with prerelease" {
            $result = ConvertFrom-RepoDescription "type:node-api|stack:typescript|deploy:v1.5.0-beta.1|model:monorepo"
            $result.deploy | Should -Be "v1.5.0-beta.1"
        }
    }

    Context "Output shape" {
        It "returns PSCustomObject with all expected properties" {
            $result = ConvertFrom-RepoDescription "type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy"
            $props = $result.PSObject.Properties.Name

            $props | Should -Contain "type"
            $props | Should -Contain "stack"
            $props | Should -Contain "deploy"
            $props | Should -Contain "model"
            $props | Should -Contain "ci"
            $props | Should -Contain "criticality"
            $props | Should -Contain "_raw"
            $props | Should -Contain "_extra"
        }
    }

    Context "Length constraint" {
        It "typical description is well under 350 chars" {
            $desc = "type:flutter-web|stack:dart|deploy:v2.30.23|model:legacy|ci:github-actions|criticality:high"
            $desc.Length | Should -BeLessThan 350
        }
    }
}
