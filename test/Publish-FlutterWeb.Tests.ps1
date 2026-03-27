# Publish-FlutterWeb.Tests.ps1
# Tests Pester para el cmdlet Publish-FlutterWeb (#10)
# Ejecutar: Invoke-Pester ./test/Publish-FlutterWeb.Tests.ps1

BeforeAll {
    Remove-Module PSDevOps -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\PSDevOps.psd1" -Force
}

# ═══════════════════════════════════════════════════════════════
# STEP 1: Legacy renombrado y exports correctos
# ═══════════════════════════════════════════════════════════════
Describe 'Step 1: Legacy renombrado y exports' {

    Context 'Publish-FlutterWebLegacy — función renombrada' {

        # Verifica que la función legacy existe tras el renombrado.
        # Sin esto, los proyectos que usan Publish-FlutterWebLegacy dejarían de funcionar.
        It 'está disponible como función exportada' {
            $cmd = Get-Command Publish-FlutterWebLegacy -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        # El legacy original tenía -server como parámetro obligatorio.
        # El renombrado no debe alterar la firma.
        It 'conserva el parámetro -server del legacy original' {
            $cmd = Get-Command Publish-FlutterWebLegacy
            $cmd.Parameters.Keys | Should -Contain 'server'
        }

        # El archivo fuente debe existir con el nombre nuevo.
        It 'tiene su archivo fuente como Publish-FlutterWebLegacy.ps1' {
            $legacyFile = Join-Path $PSScriptRoot '..\src\Functions\Publish-FlutterWebLegacy.ps1'
            $legacyFile | Should -Exist
        }
    }

    Context 'Archivo legacy antiguo eliminado' {

        # El renombrado debe ser un rename, no una copia.
        # Si ambos coexisten, PSDevOps.psm1 cargaría dos funciones con firmas distintas.
        It 'Publish-FlutterWeb.ps1 ya no existe en src/Functions/' {
            $oldFile = Join-Path $PSScriptRoot '..\src\Functions\Publish-FlutterWeb.ps1'
            $oldFile | Should -Not -Exist
        }
    }

    Context 'Exports del manifest PSDevOps.psd1' {

        # El manifest debe exportar el nombre nuevo para que Import-Module lo exponga.
        It 'exporta Publish-FlutterWebLegacy' {
            $manifest = Test-ModuleManifest "$PSScriptRoot\..\PSDevOps.psd1"
            $manifest.ExportedFunctions.Keys | Should -Contain 'Publish-FlutterWebLegacy'
        }

        # En Step 1 la nueva función aún no existe.
        # Este test se invalidará en Step 3 cuando se cree Publish-FlutterWeb.
        It 'Publish-FlutterWeb (nueva) aún no existe' {
            $cmd = Get-Command Publish-FlutterWeb -ErrorAction SilentlyContinue
            $cmd | Should -BeNullOrEmpty
        }
    }
}
