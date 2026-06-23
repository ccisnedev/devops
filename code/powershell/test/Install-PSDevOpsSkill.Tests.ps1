BeforeAll {
    . "$PSScriptRoot\..\Functions\Install-PSDevOpsSkill.ps1"
}

Describe 'Install-PSDevOpsSkill' {

    Context 'Copies SKILL.md to destination' {

        It 'Should copy SKILL.md to the destination as psdevops.md' {
            $dest = Join-Path $TestDrive 'prompts'
            $result = Install-PSDevOpsSkill -Destination $dest
            $result.Success | Should -BeTrue
            $target = Join-Path $dest 'psdevops.md'
            Test-Path $target | Should -BeTrue
        }

        It 'Should create destination directory if it does not exist' {
            $dest = Join-Path $TestDrive 'new\nested\prompts'
            Test-Path $dest | Should -BeFalse
            $result = Install-PSDevOpsSkill -Destination $dest
            $result.Success | Should -BeTrue
            Test-Path $dest | Should -BeTrue
        }

        It 'Should return a success object with Source and Destination' {
            $dest = Join-Path $TestDrive 'prompts2'
            $result = Install-PSDevOpsSkill -Destination $dest
            $result.Source | Should -Not -BeNullOrEmpty
            $result.Destination | Should -BeLike '*psdevops.md'
            $result.Message | Should -BeLike '*installed*'
        }

        It 'Should overwrite an existing psdevops.md' {
            $dest = Join-Path $TestDrive 'prompts3'
            New-Item -Path $dest -ItemType Directory -Force | Out-Null
            'old content' | Set-Content (Join-Path $dest 'psdevops.md')
            $result = Install-PSDevOpsSkill -Destination $dest
            $result.Success | Should -BeTrue
            $content = Get-Content (Join-Path $dest 'psdevops.md') -Raw
            $content | Should -BeLike '*PSDevOps*'
        }

        It 'Copied file content should match source SKILL.md' {
            $dest = Join-Path $TestDrive 'prompts4'
            $result = Install-PSDevOpsSkill -Destination $dest
            $sourceContent = Get-Content $result.Source -Raw
            $destContent = Get-Content $result.Destination -Raw
            $destContent | Should -Be $sourceContent
        }
    }
}
