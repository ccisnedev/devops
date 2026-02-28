# Invoke-SqlPackage.Tests.ps1
# Tests Pester para el cmdlet Invoke-SqlPackage
# Ejecutar: Invoke-Pester ./test/Invoke-SqlPackage.Tests.ps1

BeforeAll {
    # Recargar módulo
    Remove-Module PSDevOps -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\PSDevOps.psd1" -Force
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 1: Scaffolding e infraestructura
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 1: Infraestructura del módulo' {

    It 'El módulo PSDevOps se importa sin errores' {
        $module = Get-Module PSDevOps
        $module | Should -Not -BeNullOrEmpty
        $module.Name | Should -Be 'PSDevOps'
    }

    It 'El cmdlet Invoke-SqlPackage existe' {
        $cmd = Get-Command Invoke-SqlPackage -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    It 'Tiene 7 ParameterSets: Init, Publish, DeployReport, Script, Extract, Export, Import' {
        $cmd = Get-Command Invoke-SqlPackage
        $expectedSets = @('Init', 'Publish', 'DeployReport', 'Script', 'Extract', 'Export', 'Import')
        $actualSets = $cmd.ParameterSets | Select-Object -ExpandProperty Name
        foreach ($set in $expectedSets) {
            $actualSets | Should -Contain $set
        }
    }

    It 'Get-Help retorna documentación con Synopsis' {
        $help = Get-Help Invoke-SqlPackage
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'El ParameterSet por defecto es Publish' {
        $cmd = Get-Command Invoke-SqlPackage
        $defaultSet = $cmd.ParameterSets | Where-Object { $_.IsDefault }
        $defaultSet.Name | Should -Be 'Publish'
    }

    It 'Cada acción es un switch Mandatory en su ParameterSet' {
        $cmd = Get-Command Invoke-SqlPackage
        $switchParams = @('Init', 'Publish', 'DeployReport', 'Script', 'Extract', 'Export', 'Import')
        foreach ($paramName in $switchParams) {
            $param = $cmd.Parameters[$paramName]
            $param | Should -Not -BeNullOrEmpty -Because "Parámetro -$paramName debe existir"
            $param.ParameterType.Name | Should -Be 'SwitchParameter' -Because "-$paramName debe ser switch"
        }
    }

    It 'La dependencia powershell-yaml está disponible' {
        $yaml = Get-Module powershell-yaml -ListAvailable
        $yaml | Should -Not -BeNullOrEmpty
    }
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 2: -Init (generación de plantillas)
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 2: Invoke-SqlPackage -Init' {

    BeforeAll {
        # Crear directorio temporal con un .sqlproj fake
        $script:testDir = Join-Path $env:TEMP "PSDevOps_Test_$(Get-Random)"
        New-Item -Path $script:testDir -ItemType Directory -Force | Out-Null
        # Crear .sqlproj mínimo
        @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build">
  <Sdk Name="Microsoft.Build.Sql" Version="1.0.0" />
  <PropertyGroup>
    <Name>TestProject</Name>
  </PropertyGroup>
</Project>
'@ | Set-Content (Join-Path $script:testDir "TestProject.sqlproj")
    }

    AfterAll {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '-Init crea sqlpackage.yaml en el directorio' {
        Push-Location $script:testDir
        try {
            Invoke-SqlPackage -Init
            Test-Path (Join-Path $script:testDir "sqlpackage.yaml") | Should -BeTrue
        }
        finally { Pop-Location }
    }

    It '-Init crea .env en el directorio' {
        Push-Location $script:testDir
        try {
            # Ya se creó en el test anterior, verificar que existe
            Test-Path (Join-Path $script:testDir ".env") | Should -BeTrue
        }
        finally { Pop-Location }
    }

    It 'El sqlpackage.yaml generado es YAML válido' {
        $yamlPath = Join-Path $script:testDir "sqlpackage.yaml"
        $raw = Get-Content $yamlPath -Raw
        $parsed = ConvertFrom-Yaml $raw
        $parsed | Should -Not -BeNullOrEmpty
        $parsed.properties | Should -Not -BeNullOrEmpty
    }

    It 'El sqlpackage.yaml tiene las propiedades de seguridad por defecto' {
        $yamlPath = Join-Path $script:testDir "sqlpackage.yaml"
        $raw = Get-Content $yamlPath -Raw
        $parsed = ConvertFrom-Yaml $raw
        $parsed.properties.BlockOnPossibleDataLoss | Should -BeTrue
        $parsed.properties.DropObjectsNotInSource | Should -BeTrue
        $parsed.properties.DropPermissionsNotInSource | Should -BeTrue
        $parsed.properties.DropRoleMembersNotInSource | Should -BeTrue
    }

    It '-Init NO sobrescribe archivos existentes' {
        Push-Location $script:testDir
        try {
            # Escribir contenido personalizado
            "custom_content" | Set-Content (Join-Path $script:testDir "sqlpackage.yaml")
            Invoke-SqlPackage -Init
            $content = Get-Content (Join-Path $script:testDir "sqlpackage.yaml") -Raw
            $content.Trim() | Should -Be "custom_content"
        }
        finally { Pop-Location }
    }

    It '-Init falla sin .sqlproj' {
        $emptyDir = Join-Path $env:TEMP "PSDevOps_Empty_$(Get-Random)"
        New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
        Push-Location $emptyDir
        try {
            { Invoke-SqlPackage -Init } | Should -Throw "*sqlproj*"
        }
        finally {
            Pop-Location
            Remove-Item $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 3: Helpers de lectura y construcción de argumentos
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 3: SqlPackageHelpers' {

    BeforeAll {
        # Dot-source helpers para acceso directo
        . "$PSScriptRoot\..\src\Private\SqlPackageHelpers.ps1"
        . "$PSScriptRoot\..\src\Private\PublishHelpers.ps1"

        # Crear directorio temporal con archivos de prueba
        $script:helpersDir = Join-Path $env:TEMP "PSDevOps_Helpers_$(Get-Random)"
        New-Item -Path $script:helpersDir -ItemType Directory -Force | Out-Null

        # sqlpackage.yaml de prueba
        @'
properties:
  BlockOnPossibleDataLoss: true
  DropObjectsNotInSource: true
deployReport:
  outputDir: "./reports"
script:
  outputDir: "./scripts"
extract:
  outputDir: "./snapshots"
'@ | Set-Content (Join-Path $script:helpersDir "sqlpackage.yaml")

        # .sqlproj fake
        @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build">
  <PropertyGroup><Name>mydb</Name></PropertyGroup>
</Project>
'@ | Set-Content (Join-Path $script:helpersDir "mydb.sqlproj")

        # .env de prueba
        @'
DB_SERVER=10.0.0.1
DB_NAME=mydb
DB_USER=testuser
DB_PASSWORD=testpass123
'@ | Set-Content (Join-Path $script:helpersDir ".env")

        # DeployReport XML de prueba
        @'
<?xml version="1.0" encoding="utf-8"?>
<DeploymentReport xmlns="http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02">
  <Alerts />
  <Operations>
    <Operation Name="Create">
      <Item Value="[dbo].[sp_Test]" Type="SqlProcedure" />
    </Operation>
    <Operation Name="Alter">
      <Item Value="[dbo].[MyTable]" Type="SqlTable" />
    </Operation>
  </Operations>
</DeploymentReport>
'@ | Set-Content (Join-Path $script:helpersDir "test_report.xml")

        # DeployReport vacío
        @'
<?xml version="1.0" encoding="utf-8"?>
<DeploymentReport xmlns="http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02">
  <Alerts />
  <Operations />
</DeploymentReport>
'@ | Set-Content (Join-Path $script:helpersDir "empty_report.xml")
    }

    AfterAll {
        Remove-Item $script:helpersDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Read-SqlPackageConfig' {
        It 'Parsea un YAML válido y retorna properties' {
            $config = Read-SqlPackageConfig -Path (Join-Path $script:helpersDir "sqlpackage.yaml")
            $config | Should -Not -BeNullOrEmpty
            $config.properties | Should -Not -BeNullOrEmpty
            $config.properties.BlockOnPossibleDataLoss | Should -BeTrue
        }

        It 'Lanza error si falta la sección properties' {
            $badYaml = Join-Path $script:helpersDir "bad.yaml"
            "deployReport:`n  outputDir: `.`"" | Set-Content $badYaml
            { Read-SqlPackageConfig -Path $badYaml } | Should -Throw "*properties*"
        }

        It 'Lanza error si el archivo no existe' {
            { Read-SqlPackageConfig -Path ".\no_existe.yaml" } | Should -Throw
        }
    }

    Context 'Find-DacpacPath' {
        It 'Encuentra la ruta correcta del .dacpac desde .sqlproj' {
            Push-Location $script:helpersDir
            try {
                $path = Find-DacpacPath
                $path | Should -BeLike "*bin\Debug\mydb.dacpac"
            }
            finally { Pop-Location }
        }

        It 'Lanza error si no hay .sqlproj' {
            $emptyDir = Join-Path $env:TEMP "PSDevOps_NoPrj_$(Get-Random)"
            New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
            Push-Location $emptyDir
            try {
                { Find-DacpacPath } | Should -Throw "*sqlproj*"
            }
            finally {
                Pop-Location
                Remove-Item $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Build-SqlPackageArgs' {
        BeforeAll {
            $script:config = Read-SqlPackageConfig -Path (Join-Path $script:helpersDir "sqlpackage.yaml")
            $script:envConfig = Read-DotEnv -Path (Join-Path $script:helpersDir ".env")
            $script:envVars = $script:envConfig.Env
        }

        It 'Genera argumentos correctos para Publish' {
            $args = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -DacpacPath ".\test.dacpac"
            $args | Should -Contain "/Action:Publish"
            $args | Should -Contain "/SourceFile:.\test.dacpac"
            $args | Should -Contain "/TargetServerName:10.0.0.1"
            $args | Should -Contain "/TargetDatabaseName:mydb"
            $args | Should -Contain "/TargetUser:testuser"
            $args | Should -Contain "/TargetPassword:testpass123"
            $args | Should -Contain "/p:BlockOnPossibleDataLoss=True"
            $args | Should -Contain "/p:DropObjectsNotInSource=True"
        }

        It 'Genera argumentos correctos para Extract (sin /p: properties)' {
            $args = Build-SqlPackageArgs -Action 'Extract' -Config $script:config -EnvVars $script:envVars -OutputPath ".\snapshot.dacpac"
            $args | Should -Contain "/Action:Extract"
            $args | Should -Contain "/SourceServerName:10.0.0.1"
            $args | Should -Contain "/TargetFile:.\snapshot.dacpac"
            # Extract NO debe tener /p: properties
            $propsArgs = $args | Where-Object { $_ -like "/p:*" }
            $propsArgs | Should -BeNullOrEmpty
        }

        It 'Genera argumentos correctos para Import con sourcePath' {
            $args = Build-SqlPackageArgs -Action 'Import' -Config $script:config -EnvVars $script:envVars -SourcePath ".\backup.bacpac"
            $args | Should -Contain "/Action:Import"
            $args | Should -Contain "/SourceFile:.\backup.bacpac"
            $args | Should -Contain "/TargetServerName:10.0.0.1"
        }

        It 'Lanza error si faltan variables en .env' {
            $badEnv = @{ DB_SERVER = "host"; DB_NAME = "db" }
            { Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $badEnv -DacpacPath ".\t.dacpac" } | Should -Throw "*DB_USER*"
        }

        It 'Lanza error si Publish no recibe DacpacPath' {
            { Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars } | Should -Throw "*DacpacPath*"
        }
    }

    Context 'Show-DeployReport' {
        It 'Parsea un reporte con operaciones y retorna resultados' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "test_report.xml")
            $results | Should -Not -BeNullOrEmpty
            $results.Count | Should -Be 2
            $results[0].Operation | Should -Be 'Create'
            $results[0].Object | Should -Be '[dbo].[sp_Test]'
            $results[1].Operation | Should -Be 'Alter'
        }

        It 'Retorna $null cuando no hay cambios' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "empty_report.xml")
            $results | Should -BeNullOrEmpty
        }

        It 'Lanza error si el archivo no existe' {
            { Show-DeployReport -ReportPath ".\no_existe.xml" } | Should -Throw
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 4: Acciones de solo lectura (validación de flujos)
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 4: Validaciones de prerequisitos' {

    BeforeAll {
        $script:noEnvDir = Join-Path $env:TEMP "PSDevOps_NoEnv_$(Get-Random)"
        New-Item -Path $script:noEnvDir -ItemType Directory -Force | Out-Null
        # Crear .sqlproj y sqlpackage.yaml pero NO .env
        "<Project/>" | Set-Content (Join-Path $script:noEnvDir "test.sqlproj")
        "properties:`n  BlockOnPossibleDataLoss: true" | Set-Content (Join-Path $script:noEnvDir "sqlpackage.yaml")

        $script:noYamlDir = Join-Path $env:TEMP "PSDevOps_NoYaml_$(Get-Random)"
        New-Item -Path $script:noYamlDir -ItemType Directory -Force | Out-Null
        "<Project/>" | Set-Content (Join-Path $script:noYamlDir "test.sqlproj")
        "DB_SERVER=x" | Set-Content (Join-Path $script:noYamlDir ".env")
    }

    AfterAll {
        Remove-Item $script:noEnvDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:noYamlDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '-DeployReport falla sin .env' {
        Push-Location $script:noEnvDir
        try {
            { Invoke-SqlPackage -DeployReport } | Should -Throw "*.env*"
        }
        finally { Pop-Location }
    }

    It '-DeployReport falla sin sqlpackage.yaml' {
        Push-Location $script:noYamlDir
        try {
            { Invoke-SqlPackage -DeployReport } | Should -Throw "*sqlpackage.yaml*"
        }
        finally { Pop-Location }
    }

    It '-Publish falla sin .sqlproj' {
        $emptyDir = Join-Path $env:TEMP "PSDevOps_NoPrj2_$(Get-Random)"
        New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
        Push-Location $emptyDir
        try {
            { Invoke-SqlPackage -Publish } | Should -Throw "*sqlproj*"
        }
        finally {
            Pop-Location
            Remove-Item $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '-Extract falla sin .env' {
        Push-Location $script:noEnvDir
        try {
            { Invoke-SqlPackage -Extract } | Should -Throw "*.env*"
        }
        finally { Pop-Location }
    }
}
