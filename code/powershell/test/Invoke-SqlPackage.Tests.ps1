# Invoke-SqlPackage.Tests.ps1
# Tests Pester para el cmdlet Invoke-SqlPackage
# Ejecutar: Invoke-Pester ./test/Invoke-SqlPackage.Tests.ps1

BeforeAll {
    # Recargar módulo
    # Remove-Module por nombre quita UNA version. Si el modulo publicado esta instalado en
    # PSModulePath, puede quedar cargado junto al del repo y ganar la resolucion de nombres: la
    # suite pasaria a medir el modulo instalado en vez del codigo bajo prueba. -All las quita todas.
    Get-Module 'macss-devops' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 1: Scaffolding e infraestructura
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 1: Infraestructura del módulo' {

    It 'El módulo macss-devops se importa sin errores' {
        $module = Get-Module 'macss-devops'
        $module | Should -Not -BeNullOrEmpty
        $module.Name | Should -Be 'macss-devops'
    }

    It 'El cmdlet Invoke-SqlPackage existe' {
        $cmd = Get-Command Invoke-SqlPackage -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    It 'Tiene 7 ParameterSets: Init, Apply, Plan, Script, Extract, Export, Import (ADR 0002)' {
        $cmd = Get-Command Invoke-SqlPackage
        $expectedSets = @('Init', 'Apply', 'Plan', 'Script', 'Extract', 'Export', 'Import')
        $actualSets = $cmd.ParameterSets | Select-Object -ExpandProperty Name
        foreach ($set in $expectedSets) {
            $actualSets | Should -Contain $set
        }
    }

    It 'Get-Help retorna documentación con Synopsis' {
        $help = Get-Help Invoke-SqlPackage
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'El ParameterSet por defecto es Apply (ADR 0002)' {
        $cmd = Get-Command Invoke-SqlPackage
        $defaultSet = $cmd.ParameterSets | Where-Object { $_.IsDefault }
        $defaultSet.Name | Should -Be 'Apply'
    }

    It 'Cada acción es un switch Mandatory en su ParameterSet' {
        $cmd = Get-Command Invoke-SqlPackage
        $switchParams = @('Init', 'Apply', 'Plan', 'Script', 'Extract', 'Export', 'Import')
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
    }

    # ADR 0013: el despliegue no administra cuentas de la instancia. Las tres propiedades van
    # juntas: proteger al usuario sin proteger sus permisos y sus roles lo deja sin acceso igual.
    It 'El sqlpackage.yaml protege las cuentas de la instancia por defecto' {
        $yamlPath = Join-Path $script:testDir "sqlpackage.yaml"
        $parsed = ConvertFrom-Yaml (Get-Content $yamlPath -Raw)
        $parsed.properties.DropPermissionsNotInSource | Should -BeFalse
        $parsed.properties.DropRoleMembersNotInSource | Should -BeFalse
        $parsed.properties.DoNotDropObjectTypes | Should -Be 'Logins;Users'
    }

    # sqlpackage rechaza DoNotDropObjectTypes si DropObjectsNotInSource es false, y rechaza
    # RoleMembership dentro de la lista mientras DropRoleMembersNotInSource sea true. La
    # plantilla no puede generar ninguna de esas dos combinaciones.
    It 'La plantilla no genera una combinacion que sqlpackage rechaza' {
        $yamlPath = Join-Path $script:testDir "sqlpackage.yaml"
        $parsed = ConvertFrom-Yaml (Get-Content $yamlPath -Raw)
        if ($parsed.properties.ContainsKey('DoNotDropObjectTypes')) {
            $parsed.properties.DropObjectsNotInSource | Should -BeTrue
            if ($parsed.properties.DoNotDropObjectTypes -match 'RoleMembership') {
                $parsed.properties.DropRoleMembersNotInSource | Should -BeFalse
            }
        }
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
        . "$PSScriptRoot\..\Private\SqlPackageHelpers.ps1"
        . "$PSScriptRoot\..\Private\PublishHelpers.ps1"

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

        # DeployReport con alertas de pérdida de datos.
        # Copia literal (recortada) del reporte que produjo el despliegue de impulsa del
        # 2026-08-10: tres columnas de CanastaPersona que existen en prod y no en el código.
        # SqlPackage NO pone esa información en el <Item>: la deja en <Alerts> y enlaza por Id.
        @'
<?xml version="1.0" encoding="utf-8"?>
<DeploymentReport xmlns="http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02">
  <Alerts>
    <Alert Name="DataIssue">
      <Issue Value="The column [dbo].[CanastaPersona].[cambioTipoCanasta] is being dropped, data loss could occur." Id="1" />
      <Issue Value="The column [dbo].[CanastaPersona].[fechaCambio] is being dropped, data loss could occur." Id="2" />
      <Issue Value="The column [dbo].[CanastaPersona].[idcanastaAnterior] is being dropped, data loss could occur." Id="3" />
    </Alert>
  </Alerts>
  <Operations>
    <Operation Name="Alter">
      <Item Value="[dbo].[CanastaPersona]" Type="SqlTable">
        <Issue Id="1" />
        <Issue Id="2" />
        <Issue Id="3" />
      </Item>
      <Item Value="[motores].[sp_ValidarMontos]" Type="SqlProcedure" />
    </Operation>
  </Operations>
</DeploymentReport>
'@ | Set-Content (Join-Path $script:helpersDir "dataloss_report.xml")

        # DeployReport con una alerta que ningún <Item> referencia, y una de otra clase.
        @'
<?xml version="1.0" encoding="utf-8"?>
<DeploymentReport xmlns="http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02">
  <Alerts>
    <Alert Name="DataIssue">
      <Issue Value="The table [dbo].[Huerfana] is being dropped, data loss could occur." Id="7" />
    </Alert>
    <Alert Name="OtherIssue">
      <Issue Value="Algo que no es pérdida de datos." Id="8" />
    </Alert>
  </Alerts>
  <Operations>
    <Operation Name="Alter">
      <Item Value="[dbo].[Otra]" Type="SqlTable">
        <Issue Id="8" />
      </Item>
    </Operation>
  </Operations>
</DeploymentReport>
'@ | Set-Content (Join-Path $script:helpersDir "orphan_alert_report.xml")
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
            $args = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac"
            $args | Should -Contain "/Action:Publish"
            $args | Should -Contain "/SourceFile:.\test.dacpac"
            $args | Should -Contain "/TargetServerName:10.0.0.1"
            $args | Should -Contain "/TargetDatabaseName:TestDB"
            $args | Should -Contain "/TargetUser:testuser"
            $args | Should -Contain "/TargetPassword:testpass123"
            $args | Should -Contain "/p:BlockOnPossibleDataLoss=True"
            $args | Should -Contain "/p:DropObjectsNotInSource=True"
        }

        It 'Genera argumentos correctos para Extract (sin /p: properties)' {
            $args = Build-SqlPackageArgs -Action 'Extract' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -OutputPath ".\snapshot.dacpac"
            $args | Should -Contain "/Action:Extract"
            $args | Should -Contain "/SourceServerName:10.0.0.1"
            $args | Should -Contain "/TargetFile:.\snapshot.dacpac"
            # Extract NO debe tener /p: properties
            $propsArgs = $args | Where-Object { $_ -like "/p:*" }
            $propsArgs | Should -BeNullOrEmpty
        }

        It 'Genera argumentos correctos para Import con sourcePath' {
            $args = Build-SqlPackageArgs -Action 'Import' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -SourcePath ".\backup.bacpac"
            $args | Should -Contain "/Action:Import"
            $args | Should -Contain "/SourceFile:.\backup.bacpac"
            $args | Should -Contain "/TargetServerName:10.0.0.1"
        }

        It 'Lanza error si faltan variables en .env' {
            $badEnv = @{ DB_SERVER = "host"; DB_NAME = "db" }
            { Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $badEnv -Database 'TestDB' -DacpacPath ".\t.dacpac" } | Should -Throw "*DB_USER*"
        }

        It 'Lanza error si Publish no recibe DacpacPath' {
            { Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' } | Should -Throw "*DacpacPath*"
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

    # El resumen del plan mostraba "Alter → [dbo].[CanastaPersona]" y nada más: quien lo leía
    # antes de teclear "y" no tenía forma de saber que ese Alter borraba tres columnas. La
    # información sí estaba en el XML, en <Alerts>, y el parser nunca la miraba.
    Context 'Get-DeployReportAlert' {
        It 'Indexa las alertas por Id' {
            [xml]$xml = Get-Content (Join-Path $script:helpersDir "dataloss_report.xml")
            $alerts = Get-DeployReportAlert -Report $xml
            $alerts.Count | Should -Be 3
            $alerts['1'].Message | Should -Match 'cambioTipoCanasta'
            $alerts['1'].Kind | Should -Be 'DataIssue'
        }

        It 'Un reporte sin alertas produce un índice vacío' {
            [xml]$xml = Get-Content (Join-Path $script:helpersDir "test_report.xml")
            (Get-DeployReportAlert -Report $xml).Count | Should -Be 0
        }

        It 'Distingue la clase de cada alerta' {
            [xml]$xml = Get-Content (Join-Path $script:helpersDir "orphan_alert_report.xml")
            $alerts = Get-DeployReportAlert -Report $xml
            $alerts['7'].Kind | Should -Be 'DataIssue'
            $alerts['7'].IsDataLoss | Should -BeTrue
            $alerts['8'].Kind | Should -Be 'OtherIssue'
            $alerts['8'].IsDataLoss | Should -BeFalse
        }
    }

    Context 'Show-DeployReport — alertas de pérdida de datos' {

        BeforeAll {
            # Show-DeployReport escribe con Write-Host: para afirmar sobre lo IMPRESO hay que
            # leer el stream 6 y quedarse solo con los InformationRecord. Si se usara
            # `6>&1 | Out-String` también entrarían los objetos retornados, y un test de
            # "lo imprime" pasaría por lo que la función devuelve, no por lo que muestra.
            function Get-PrintedOutput {
                param([string]$Path)
                $records = Show-DeployReport -ReportPath $Path 6>&1 |
                    Where-Object { $_ -is [System.Management.Automation.InformationRecord] }
                ($records | ForEach-Object { $_.MessageData.Message }) -join "`n"
            }
        }

        It 'Adjunta al objeto afectado cada alerta que lo referencia' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "dataloss_report.xml") 6>$null
            $tabla = $results | Where-Object { $_.Object -eq '[dbo].[CanastaPersona]' }
            @($tabla.Issues).Count | Should -Be 3
            $tabla.Issues -join ' ' | Should -Match 'cambioTipoCanasta'
            $tabla.Issues -join ' ' | Should -Match 'fechaCambio'
            $tabla.Issues -join ' ' | Should -Match 'idcanastaAnterior'
        }

        It 'Marca con HasDataLoss solo al objeto que pierde datos' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "dataloss_report.xml") 6>$null
            ($results | Where-Object { $_.Object -eq '[dbo].[CanastaPersona]' }).HasDataLoss | Should -BeTrue
            ($results | Where-Object { $_.Object -eq '[motores].[sp_ValidarMontos]' }).HasDataLoss | Should -BeFalse
        }

        It 'No contamina con alertas ajenas al objeto limpio' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "dataloss_report.xml") 6>$null
            $sp = $results | Where-Object { $_.Object -eq '[motores].[sp_ValidarMontos]' }
            @($sp.Issues).Count | Should -Be 0
        }

        It 'Un reporte sin alertas deja Issues vacío y HasDataLoss en falso' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "test_report.xml") 6>$null
            foreach ($r in $results) {
                @($r.Issues).Count | Should -Be 0
                $r.HasDataLoss | Should -BeFalse
            }
        }

        It 'Imprime cada columna que se elimina, debajo de su objeto' {
            $printed = Get-PrintedOutput (Join-Path $script:helpersDir "dataloss_report.xml")
            $printed | Should -Match 'cambioTipoCanasta'
            $printed | Should -Match 'fechaCambio'
            $printed | Should -Match 'idcanastaAnterior'
        }

        It 'Rotula la pérdida de datos con esas palabras, no con jerga de SqlPackage' {
            $printed = Get-PrintedOutput (Join-Path $script:helpersDir "dataloss_report.xml")
            $printed | Should -Match 'PÉRDIDA DE DATOS'
        }

        It 'Cierra con un resumen que cuenta las advertencias y los objetos' {
            $printed = Get-PrintedOutput (Join-Path $script:helpersDir "dataloss_report.xml")
            $printed | Should -Match '3 advertencia'
            $printed | Should -Match '1 objeto'
        }

        It 'Un plan sin pérdida de datos no inventa el resumen' {
            $printed = Get-PrintedOutput (Join-Path $script:helpersDir "test_report.xml")
            $printed | Should -Not -Match 'PÉRDIDA DE DATOS'
        }

        # Una alerta que ningún <Item> referencia no puede desaparecer: era exactamente el modo
        # de falla que se está corrigiendo, solo que en la otra rama del XML.
        It 'No silencia una alerta que ningún objeto referencia' {
            $printed = Get-PrintedOutput (Join-Path $script:helpersDir "orphan_alert_report.xml")
            $printed | Should -Match 'sin objeto asociado'
            $printed | Should -Match 'Huerfana'
        }

        It 'Una alerta que no es de pérdida de datos se adjunta sin ese rótulo' {
            $results = Show-DeployReport -ReportPath (Join-Path $script:helpersDir "orphan_alert_report.xml") 6>$null
            $otra = $results | Where-Object { $_.Object -eq '[dbo].[Otra]' }
            @($otra.Issues).Count | Should -Be 1
            $otra.Issues[0] | Should -Match 'no es pérdida de datos'
            $otra.HasDataLoss | Should -BeFalse
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
        "<Project><PropertyGroup><Name>test</Name></PropertyGroup></Project>" | Set-Content (Join-Path $script:noEnvDir "test.sqlproj")
        "properties:`n  BlockOnPossibleDataLoss: true" | Set-Content (Join-Path $script:noEnvDir "sqlpackage.yaml")

        $script:noYamlDir = Join-Path $env:TEMP "PSDevOps_NoYaml_$(Get-Random)"
        New-Item -Path $script:noYamlDir -ItemType Directory -Force | Out-Null
        "<Project><PropertyGroup><Name>test</Name></PropertyGroup></Project>" | Set-Content (Join-Path $script:noYamlDir "test.sqlproj")
        "DB_SERVER=x" | Set-Content (Join-Path $script:noYamlDir ".env")
    }

    AfterAll {
        Remove-Item $script:noEnvDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:noYamlDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '-Plan falla sin .env' {
        Push-Location $script:noEnvDir
        try {
            { Invoke-SqlPackage -Plan } | Should -Throw "*.env*"
        }
        finally { Pop-Location }
    }

    It '-Plan falla sin sqlpackage.yaml' {
        Push-Location $script:noYamlDir
        try {
            { Invoke-SqlPackage -Plan } | Should -Throw "*sqlpackage.yaml*"
        }
        finally { Pop-Location }
    }

    It '-Apply falla sin .sqlproj' {
        $emptyDir = Join-Path $env:TEMP "PSDevOps_NoPrj2_$(Get-Random)"
        New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
        Push-Location $emptyDir
        try {
            { Invoke-SqlPackage -Apply -AutoApprove } | Should -Throw "*sqlproj*"
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

    It '-Import falla sin sqlpackage.yaml' {
        Push-Location $script:noYamlDir
        try {
            { Invoke-SqlPackage -Import } | Should -Throw "*sqlpackage.yaml*"
        }
        finally { Pop-Location }
    }

    It '-Plan crea outputDir automáticamente si no existe' {
        $baseDir = Join-Path $env:TEMP "PSDevOps_DRDir_$(Get-Random)"
        New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
        $outputDir = Join-Path $baseDir "deploy_reports"
        "<Project><PropertyGroup><Name>test</Name></PropertyGroup></Project>" | Set-Content (Join-Path $baseDir "test.sqlproj")
        "DB_SERVER=x`nDB_NAME=y`nDB_USER=u`nDB_PASSWORD=p" | Set-Content (Join-Path $baseDir ".env")
        @"
properties:
  BlockOnPossibleDataLoss: true
deployReport:
            outputDir: '$outputDir'
"@ | Set-Content (Join-Path $baseDir "sqlpackage.yaml")
        Push-Location $baseDir
        try {
            # El directorio no debe existir aún
            Test-Path $outputDir | Should -BeFalse
            # La llamada fallará por sqlpackage.exe no disponible, pero el dir debe crearse antes
            try { Invoke-SqlPackage -Plan } catch {}
            Test-Path $outputDir | Should -BeTrue
        }
        finally {
            Pop-Location
            Remove-Item $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '-Script crea outputDir automáticamente si no existe' {
        $baseDir = Join-Path $env:TEMP "PSDevOps_ScriptDir_$(Get-Random)"
        New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
        $outputDir = Join-Path $baseDir "deploy_scripts"
        "<Project><PropertyGroup><Name>test</Name></PropertyGroup></Project>" | Set-Content (Join-Path $baseDir "test.sqlproj")
        "DB_SERVER=x`nDB_NAME=y`nDB_USER=u`nDB_PASSWORD=p" | Set-Content (Join-Path $baseDir ".env")
        @"
properties:
  BlockOnPossibleDataLoss: true
script:
            outputDir: '$outputDir'
"@ | Set-Content (Join-Path $baseDir "sqlpackage.yaml")
        Push-Location $baseDir
        try {
            # El directorio no debe existir aún
            Test-Path $outputDir | Should -BeFalse
            # La llamada fallará por sqlpackage.exe no disponible, pero el dir debe crearse antes
            try { Invoke-SqlPackage -Script } catch {}
            Test-Path $outputDir | Should -BeTrue
        }
        finally {
            Pop-Location
            Remove-Item $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# ETAPA 5: Acciones destructivas (Publish, Import)
# ═══════════════════════════════════════════════════════════════
Describe 'Etapa 5: Flujo de acciones destructivas' {

    BeforeAll {
        . "$PSScriptRoot\..\Private\SqlPackageHelpers.ps1"
        . "$PSScriptRoot\..\Private\PublishHelpers.ps1"
    }

    Context 'Build-SqlPackageArgs — seguridad en acciones destructivas' {

        BeforeAll {
            $script:config = @{
                properties = @{
                    BlockOnPossibleDataLoss    = $true
                    DropObjectsNotInSource     = $true
                    DropPermissionsNotInSource = $true
                    DropRoleMembersNotInSource = $true
                }
            }
            $script:envVars = @{
                DB_SERVER   = "10.0.0.1"
                DB_NAME     = "testdb"
                DB_USER     = "sa"
                DB_PASSWORD = "Pass123!"
            }
        }

        It 'Publish incluye todas las propiedades de seguridad' {
            $args = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac"
            $args | Should -Contain "/p:BlockOnPossibleDataLoss=True"
            $args | Should -Contain "/p:DropObjectsNotInSource=True"
            $args | Should -Contain "/p:DropPermissionsNotInSource=True"
            $args | Should -Contain "/p:DropRoleMembersNotInSource=True"
        }

        It 'Import NO incluye /p: properties (no aplican)' {
            $args = Build-SqlPackageArgs -Action 'Import' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -SourcePath ".\backup.bacpac"
            $propsArgs = $args | Where-Object { $_ -like "/p:*" }
            $propsArgs | Should -BeNullOrEmpty
        }

        It 'Export NO incluye /p: properties' {
            $args = Build-SqlPackageArgs -Action 'Export' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -OutputPath ".\out.bacpac"
            $propsArgs = $args | Where-Object { $_ -like "/p:*" }
            $propsArgs | Should -BeNullOrEmpty
        }

        It 'DeployReport incluye las mismas properties que Publish' {
            $publishArgs = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac"
            $reportArgs = Build-SqlPackageArgs -Action 'DeployReport' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac" -OutputPath ".\report.xml"

            $publishProps = $publishArgs | Where-Object { $_ -like "/p:*" } | Sort-Object
            $reportProps = $reportArgs | Where-Object { $_ -like "/p:*" } | Sort-Object

            $publishProps | Should -Be $reportProps
        }

        It 'La contraseña se incluye en los argumentos de conexión' {
            $args = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac"
            $args | Should -Contain "/TargetPassword:Pass123!"
        }

        It 'Conexión siempre usa TrustServerCertificate y EncryptConnection' {
            $args = Build-SqlPackageArgs -Action 'Publish' -Config $script:config -EnvVars $script:envVars -Database 'TestDB' -DacpacPath ".\test.dacpac"
            $args | Should -Contain "/TargetTrustServerCertificate:True"
            $args | Should -Contain "/TargetEncryptConnection:True"
        }
    }

    Context 'Import — validación de sourcePath' {

        BeforeAll {
            $script:importDir = Join-Path $env:TEMP "PSDevOps_Import_$(Get-Random)"
            New-Item -Path $script:importDir -ItemType Directory -Force | Out-Null
            "<Project><PropertyGroup><Name>test</Name></PropertyGroup></Project>" | Set-Content (Join-Path $script:importDir "test.sqlproj")

            # .env válido
            @"
DB_SERVER=10.0.0.1
DB_NAME=testdb
DB_USER=sa
DB_PASSWORD=Pass123!
"@ | Set-Content (Join-Path $script:importDir ".env")

            # sqlpackage.yaml SIN sourcePath configurado
            @"
properties:
  BlockOnPossibleDataLoss: true
import: {}
"@ | Set-Content (Join-Path $script:importDir "sqlpackage.yaml")
        }

        AfterAll {
            Remove-Item $script:importDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It '-Import falla si sourcePath no está configurado' {
            Push-Location $script:importDir
            try {
                { Invoke-SqlPackage -Import } | Should -Throw "*sourcePath*"
            }
            finally { Pop-Location }
        }
    }

    Context 'Publish — estructura de argumentos completa' {

        It 'Script genera argumentos con /p: (misma categoría que Publish)' {
            $config = @{ properties = @{ BlockOnPossibleDataLoss = $true } }
            $envVars = @{ DB_SERVER = "srv"; DB_NAME = "db"; DB_USER = "u"; DB_PASSWORD = "p" }
            $args = Build-SqlPackageArgs -Action 'Script' -Config $config -EnvVars $envVars -Database 'TestDB' -DacpacPath ".\t.dacpac" -OutputPath ".\out.sql"
            $args | Should -Contain "/Action:Script"
            $args | Should -Contain "/p:BlockOnPossibleDataLoss=True"
            $args | Should -Contain "/OutputPath:.\out.sql"
        }
    }
}
