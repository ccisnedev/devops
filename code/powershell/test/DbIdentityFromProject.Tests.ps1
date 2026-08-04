# DbIdentityFromProject.Tests.ps1
# Tests de la identidad de la base de datos (ADR 0011).
#
# ADR 0010 movió el DESTINO al env file, porque un alias o una IP cambian por entorno. ADR 0011
# mueve la IDENTIDAD en dirección contraria: el nombre de la base no es dónde despliegas, es qué
# despliegas, y por eso vive en el archivo de proyecto versionado.
#
#   SQL Server  -> <Name> del .sqlproj        (DB_NAME queda como override explícito)
#   PostgreSQL  -> database: de pgschema.yaml (PGDATABASE en el env falla)
#
# La resolución es pura: se testea con directorios temporales, sin servidor ni sqlpackage.
#
# Cubre REQ-1 a REQ-8 de ADR 0011.

BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"

    function New-SqlProject {
        param([string]$Name, [string]$EnvContent)
        $root = Join-Path ([IO.Path]::GetTempPath()) ("macss_dbid_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $proj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build">
  <PropertyGroup>
    <Name>$Name</Name>
    <DSP>Microsoft.Data.Tools.Schema.Sql.Sql150DatabaseSchemaProvider</DSP>
  </PropertyGroup>
</Project>
"@
        Set-Content -Path (Join-Path $root "$Name.sqlproj") -Value $proj -Encoding UTF8
        if ($PSBoundParameters.ContainsKey('EnvContent')) {
            Set-Content -Path (Join-Path $root '.env') -Value $EnvContent -Encoding UTF8
        }
        return $root
    }

    function New-PgProject {
        param([string]$YamlContent, [string]$EnvContent)
        $root = Join-Path ([IO.Path]::GetTempPath()) ("macss_pgid_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -Path (Join-Path $root 'pgschema.yaml') -Value $YamlContent -Encoding UTF8
        if ($PSBoundParameters.ContainsKey('EnvContent')) {
            Set-Content -Path (Join-Path $root '.env') -Value $EnvContent -Encoding UTF8
        }
        return $root
    }

    function Get-ThrownMessage {
        param([scriptblock]$Action)
        try { & $Action | Out-Null; return $null } catch { return $_.Exception.Message }
    }

    # Impide que un `Should -Throw` se ponga verde por CommandNotFoundException mientras la
    # función todavía no existe. Ver la nota equivalente en ResolveDeployTargetFromEnv.Tests.ps1.
    function Get-ValidationError {
        param([scriptblock]$Action)
        $msg = Get-ThrownMessage $Action
        if ($null -eq $msg) { throw "Se esperaba un error de validación y no se lanzó ninguno." }
        if ($msg -match 'is not recognized as a name of a cmdlet|no se reconoce como') {
            throw "Falló por comando inexistente, no por la validación esperada: $msg"
        }
        return $msg
    }
}

Describe "Resolve-DbIdentity — los helpers existen" {

    It "<Name> está disponible tras cargar PublishHelpers" -ForEach @(
        @{ Name = 'Resolve-SqlDbIdentity' }
        @{ Name = 'Resolve-PgDbIdentity' }
    ) {
        Get-Command $Name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "SQL Server — REQ-1: el nombre sale del .sqlproj" {

    It "deriva <Name> cuando el env no declara DB_NAME" {
        $root = New-SqlProject -Name 'feature_flags' -EnvContent "DB_SERVER=10.0.0.1"
        (Resolve-SqlDbIdentity -ProjectRoot $root).Name | Should -Be 'feature_flags'
    }

    It "no marca override cuando el nombre vino del proyecto" {
        $root = New-SqlProject -Name 'encuestas' -EnvContent "DB_SERVER=10.0.0.1"
        (Resolve-SqlDbIdentity -ProjectRoot $root).IsOverride | Should -BeFalse
    }
}

Describe "SQL Server — REQ-2: un DB_NAME distinto es override explícito" {

    # El caso real: DB Tier-1 desechables (dev_<nombre>), donde el mismo dacpac se publica a una
    # base con otro nombre. Derivar a secas eliminaria ese flujo.
    It "honra el override" {
        $root = New-SqlProject -Name 'impulsa' -EnvContent "DB_NAME=dev_carlos"
        (Resolve-SqlDbIdentity -ProjectRoot $root).Name | Should -Be 'dev_carlos'
    }

    It "lo marca como override para que el plan pueda mostrarlo" {
        $root = New-SqlProject -Name 'impulsa' -EnvContent "DB_NAME=dev_carlos"
        (Resolve-SqlDbIdentity -ProjectRoot $root).IsOverride | Should -BeTrue
    }

    It "expone también el nombre del proyecto, para poder contrastarlos" {
        $root = New-SqlProject -Name 'impulsa' -EnvContent "DB_NAME=dev_carlos"
        (Resolve-SqlDbIdentity -ProjectRoot $root).ProjectName | Should -Be 'impulsa'
    }
}

Describe "SQL Server — REQ-3: un DB_NAME redundante falla" {

    It "lanza cuando DB_NAME repite el nombre del proyecto" {
        $root = New-SqlProject -Name 'encuestas' -EnvContent "DB_NAME=encuestas"
        Get-ValidationError { Resolve-SqlDbIdentity -ProjectRoot $root } | Should -Not -BeNullOrEmpty
    }

    It "el mensaje pide borrarlo y nombra el archivo del que se lee" {
        $root = New-SqlProject -Name 'encuestas' -EnvContent "DB_NAME=encuestas"
        $msg = Get-ThrownMessage { Resolve-SqlDbIdentity -ProjectRoot $root }
        $msg | Should -Match 'DB_NAME'
        $msg | Should -Match '\.sqlproj'
    }
}

Describe "SQL Server — REQ-4: la diferencia de mayúsculas la resuelve una persona" {

    # Caso real: contratos.sqlproj declara 'contratos' y publica sobre 'CONTRATOS'. En una
    # collation case-insensitive da igual; en una case-sensitive, no. Adivinar seria cambiar el
    # objetivo de un despliegue de produccion en silencio.
    It "lanza cuando difiere solo en mayúsculas" {
        $root = New-SqlProject -Name 'contratos' -EnvContent "DB_NAME=CONTRATOS"
        Get-ValidationError { Resolve-SqlDbIdentity -ProjectRoot $root } | Should -Not -BeNullOrEmpty
    }

    It "el mensaje nombra las dos grafías para que se pueda decidir" {
        $root = New-SqlProject -Name 'contratos' -EnvContent "DB_NAME=CONTRATOS"
        $msg = Get-ThrownMessage { Resolve-SqlDbIdentity -ProjectRoot $root }
        $msg | Should -Match 'contratos'
        $msg | Should -Match 'CONTRATOS'
    }
}

Describe "SQL Server — REQ-7: fail-fast si el proyecto no declara identidad" {

    It "lanza con mensaje accionable si el .sqlproj no tiene <Name>" {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("macss_dbid_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -Path (Join-Path $root 'roto.sqlproj') -Value '<Project></Project>' -Encoding UTF8
        $msg = Get-ValidationError { Resolve-SqlDbIdentity -ProjectRoot $root }
        $msg | Should -Match 'Name'
    }
}

Describe "PostgreSQL — REQ-5: el nombre sale de pgschema.yaml" {

    It "lee la clave database:" {
        $root = New-PgProject -YamlContent "database: analytics`nschemas:`n  - public" `
                              -EnvContent "PGHOST=10.0.0.1"
        (Resolve-PgDbIdentity -ProjectRoot $root).Name | Should -Be 'analytics'
    }
}

Describe "PostgreSQL — REQ-6: PGDATABASE en el env falla" {

    It "lanza cuando el env todavía declara PGDATABASE" {
        $root = New-PgProject -YamlContent "database: analytics`nschemas:`n  - public" `
                              -EnvContent "PGHOST=10.0.0.1`nPGDATABASE=analytics"
        Get-ValidationError { Resolve-PgDbIdentity -ProjectRoot $root } | Should -Not -BeNullOrEmpty
    }

    It "el mensaje indica moverlo a pgschema.yaml" {
        $root = New-PgProject -YamlContent "database: analytics`nschemas:`n  - public" `
                              -EnvContent "PGDATABASE=analytics"
        $msg = Get-ThrownMessage { Resolve-PgDbIdentity -ProjectRoot $root }
        $msg | Should -Match 'PGDATABASE'
        $msg | Should -Match 'pgschema\.yaml'
    }
}

Describe "PostgreSQL — REQ-7: fail-fast si falta database:" {

    It "lanza con mensaje accionable si pgschema.yaml no declara database:" {
        $root = New-PgProject -YamlContent "schemas:`n  - public"
        $msg = Get-ValidationError { Resolve-PgDbIdentity -ProjectRoot $root }
        $msg | Should -Match 'database'
        $msg | Should -Match 'pgschema\.yaml'
    }
}

Describe "REQ-8: los templates y -Init siguen la nueva frontera" {

    It "el template de pgschema.yaml declara database:" {
        $t = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\Resources') -Recurse -Filter 'pgschema.yaml' -ErrorAction SilentlyContinue |
             Select-Object -First 1
        $t | Should -Not -BeNullOrEmpty
        (Get-Content $t.FullName -Raw -Encoding UTF8) -match '(?m)^\s*database\s*:' | Should -BeTrue
    }

    # La aserción va contra PgSchemaHelpers.ps1 y no contra Invoke-PgSchema.ps1: `-Init` delega en
    # `New-PgSchemaConfig`, y ahí es donde vive la plantilla del .env. Apuntar al cmdlet daba un
    # verde falso, porque el archivo que se estaba mirando nunca tuvo la clave.
    It "New-PgSchemaConfig no siembra PGDATABASE en el .env que genera" {
        $src = Get-Content (Join-Path $PSScriptRoot '..\Private\PgSchemaHelpers.ps1') -Raw -Encoding UTF8
        [bool]($src -match '(?m)^\s*PGDATABASE\s*=') | Should -BeFalse
    }

    It "el nombre de la base ya no se exige desde el env" {
        $src = Get-Content (Join-Path $PSScriptRoot '..\Private\PgSchemaHelpers.ps1') -Raw -Encoding UTF8
        [bool]($src -match "Falta PGDATABASE en \.env") | Should -BeFalse
    }
}
