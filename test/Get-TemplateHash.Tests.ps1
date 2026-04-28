Describe "Get-TemplateHash" {
    BeforeAll {
        . "$PSScriptRoot/../src/Private/Get-TemplateHash.ps1"
    }

    Context "Hash computation" {
        It "returns a 40-character hex string" {
            $hash = Get-TemplateHash -Content "name: Deploy"
            $hash.Length | Should -Be 40
            $hash | Should -Match '^[0-9a-f]{40}$'
        }

        It "produces consistent hash for same content" {
            $content = "name: Deploy`non: push"
            $hash1 = Get-TemplateHash -Content $content
            $hash2 = Get-TemplateHash -Content $content
            $hash1 | Should -Be $hash2
        }

        It "produces different hash for different content" {
            $hash1 = Get-TemplateHash -Content "name: Deploy A"
            $hash2 = Get-TemplateHash -Content "name: Deploy B"
            $hash1 | Should -Not -Be $hash2
        }
    }

    Context "Header exclusion" {
        It "excludes Version line from hash" {
            $withVersion = @"
# Version: v1.0.0
name: Deploy
"@
            $withoutVersion = "name: Deploy"
            $hash1 = Get-TemplateHash -Content $withVersion
            $hash2 = Get-TemplateHash -Content $withoutVersion
            $hash1 | Should -Be $hash2
        }

        It "excludes SHA1 line from hash" {
            $withHash = @"
# SHA1: abc123def456
name: Deploy
"@
            $withoutHash = "name: Deploy"
            $hash1 = Get-TemplateHash -Content $withHash
            $hash2 = Get-TemplateHash -Content $withoutHash
            $hash1 | Should -Be $hash2
        }

        It "excludes both Version and SHA1 lines" {
            $full = @"
# deploy.web.yml
# Version: v1.0.0
# SHA1: abc123
name: Deploy
"@
            $clean = @"
# deploy.web.yml
name: Deploy
"@
            $hash1 = Get-TemplateHash -Content $full
            $hash2 = Get-TemplateHash -Content $clean
            $hash1 | Should -Be $hash2
        }

        It "changing version does not change hash" {
            $v1 = @"
# Version: v1.0.0
# SHA1: old
name: Deploy
"@
            $v2 = @"
# Version: v2.0.0
# SHA1: new
name: Deploy
"@
            $hash1 = Get-TemplateHash -Content $v1
            $hash2 = Get-TemplateHash -Content $v2
            $hash1 | Should -Be $hash2
        }
    }

    Context "Edge cases" {
        It "returns null for empty string" {
            Get-TemplateHash -Content "" | Should -BeNullOrEmpty
        }

        It "returns null for whitespace" {
            Get-TemplateHash -Content "   " | Should -BeNullOrEmpty
        }

        It "handles content with only version and hash lines" {
            $content = @"
# Version: v1.0.0
# SHA1: abc
"@
            $hash = Get-TemplateHash -Content $content
            $hash | Should -Not -BeNullOrEmpty
            $hash.Length | Should -Be 40
        }
    }
}
