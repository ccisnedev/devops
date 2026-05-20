Describe "Get-TemplateVersion" {
    BeforeAll {
        . "$PSScriptRoot/../Private/Get-TemplateVersion.ps1"
    }

    Context "Valid version headers" {
        It "extracts v1.0.0 from standard header" {
            $content = @"
# deploy.web.yml — Template
# Version: v1.0.0
# SHA1: abc123
name: Deploy
"@
            Get-TemplateVersion -Content $content | Should -Be "v1.0.0"
        }

        It "extracts higher version numbers" {
            $content = "# Version: v12.34.56"
            Get-TemplateVersion -Content $content | Should -Be "v12.34.56"
        }

        It "finds version even if not on first line" {
            $content = @"
# Some comment
# Another line
# Version: v2.1.0
rest of file
"@
            Get-TemplateVersion -Content $content | Should -Be "v2.1.0"
        }
    }

    Context "Missing or invalid version" {
        It "returns null for empty string" {
            Get-TemplateVersion -Content "" | Should -BeNullOrEmpty
        }

        It "returns null for whitespace" {
            Get-TemplateVersion -Content "   " | Should -BeNullOrEmpty
        }

        It "returns null when no version line exists" {
            $content = @"
# deploy.web.yml
name: Deploy
on: push
"@
            Get-TemplateVersion -Content $content | Should -BeNullOrEmpty
        }

        It "returns null for malformed version" {
            $content = "# Version: 1.0.0"
            Get-TemplateVersion -Content $content | Should -BeNullOrEmpty
        }

        It "returns null for version without patch" {
            $content = "# Version: v1.0"
            Get-TemplateVersion -Content $content | Should -BeNullOrEmpty
        }
    }

    Context "Edge cases" {
        It "matches first version line only" {
            $content = @"
# Version: v1.0.0
# Version: v2.0.0
"@
            Get-TemplateVersion -Content $content | Should -Be "v1.0.0"
        }

        It "handles extra whitespace after colon" {
            $content = "# Version:   v3.0.0"
            Get-TemplateVersion -Content $content | Should -Be "v3.0.0"
        }
    }
}
