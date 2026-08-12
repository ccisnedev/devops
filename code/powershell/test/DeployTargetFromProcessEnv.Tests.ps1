# DeployTargetFromProcessEnv.Tests.ps1
# El destino del despliegue admite variable de entorno, con precedencia dotenv (issue #75).
#
# La ADR 0004 decidió que el destino sale del env file gitignoreado y no del archivo versionado.
# Resolvió dónde NO debe estar; no resolvió de dónde lo toma un ejecutor que no es una persona
# con su ~/.ssh/config. Un job de CI no tiene el archivo --está gitignoreado, así que tras
# actions/checkout no existe-- y falla en la primera línea útil.
#
# La ADR 0011 del handbook adopta dotenv como estándar, y de su semántica lo que aplica aquí es
# la precedencia: NINGUNA implementación de dotenv sobrescribe una variable que ya existe en el
# proceso. El archivo es un default para cuando el entorno no dijo nada.
#
# Escribir el archivo desde el workflow --la alternativa obvia-- es materializar un archivo para
# leerlo de vuelta: exactamente lo contrario de lo que la práctica dotenv resuelve.
#
# El riesgo es real y por eso el origen se imprime SIEMPRE: una variable exportada y olvidada en
# una sesión puede redirigir un despliegue manual, y eso sería peor que el problema que resuelve.


Describe "El destino del despliegue admite variable de entorno (#75)" {
BeforeAll {
    . "$PSScriptRoot/../Private/PublishHelpers.ps1"

    function New-ProyectoConEnv {
        param([string]$Contenido, [string]$Nombre = '.env')
        $raiz = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $raiz -Force | Out-Null
        if ($PSBoundParameters.ContainsKey('Contenido')) {
            Set-Content -LiteralPath (Join-Path $raiz $Nombre) -Value $Contenido
        }
        return $raiz
    }
}

BeforeEach {
    # La suite no puede depender de lo que el operador tenga exportado: sin esto, un
    # MACSS_DEPLOY_SSH_ALIAS en la sesión haría pasar en verde pruebas que deben fallar.
    $script:AliasPrevio = $env:MACSS_DEPLOY_SSH_ALIAS
    $script:LegacyPrevio = $env:MACSS_DEPLOY_SERVER
    Remove-Item Env:MACSS_DEPLOY_SSH_ALIAS -ErrorAction SilentlyContinue
    Remove-Item Env:MACSS_DEPLOY_SERVER -ErrorAction SilentlyContinue
}

AfterEach {
    if ($script:AliasPrevio) { $env:MACSS_DEPLOY_SSH_ALIAS = $script:AliasPrevio }
    else { Remove-Item Env:MACSS_DEPLOY_SSH_ALIAS -ErrorAction SilentlyContinue }
    if ($script:LegacyPrevio) { $env:MACSS_DEPLOY_SERVER = $script:LegacyPrevio }
    else { Remove-Item Env:MACSS_DEPLOY_SERVER -ErrorAction SilentlyContinue }
}

Context "Resolve-DeployTargetSource — la precedencia, sin tocar disco" {

    It "sin entorno, manda el archivo" {
        $r = Resolve-DeployTargetSource -FromFile 'uat' -FromProcess '' -EnvFile '.env'
        $r.Alias  | Should -Be 'uat'
        $r.Origin | Should -Be 'archivo'
    }

    It "sin archivo, manda el entorno: es el caso del runner" {
        $r = Resolve-DeployTargetSource -FromFile '' -FromProcess 'prod' -EnvFile '.env'
        $r.Alias  | Should -Be 'prod'
        $r.Origin | Should -Be 'entorno'
    }

    It "con ambos, gana el entorno" {
        # Es la semántica dotenv, no una preferencia: el archivo no sobrescribe lo que el
        # proceso ya declaró.
        $r = Resolve-DeployTargetSource -FromFile 'uat' -FromProcess 'prod' -EnvFile '.env'
        $r.Alias  | Should -Be 'prod'
        $r.Origin | Should -Be 'entorno'
    }

    It "si ambos existen y difieren, el texto nombra el valor descartado" {
        # Que gane el entorno en silencio sobre un archivo que dice otra cosa es justo el
        # accidente a evitar. Quien lea la salida tiene que poder ver que había un conflicto.
        $r = Resolve-DeployTargetSource -FromFile 'uat' -FromProcess 'prod' -EnvFile '.env.production'
        $r.Text | Should -Match 'uat'
        $r.Text | Should -Match 'prod'
    }

    It "si coinciden, no inventa un conflicto" {
        $r = Resolve-DeployTargetSource -FromFile 'prod' -FromProcess 'prod' -EnvFile '.env'
        $r.Text | Should -Not -Match 'declara'
    }

    It "el texto del caso normal nombra el archivo de donde salió" {
        (Resolve-DeployTargetSource -FromFile 'uat' -FromProcess '' -EnvFile '.env.production').Text |
            Should -Match '\.env\.production'
    }

    It "el texto del caso de entorno lo dice con esas palabras" {
        (Resolve-DeployTargetSource -FromFile '' -FromProcess 'prod' -EnvFile '.env').Text |
            Should -Match 'variable de entorno'
    }

    It "sin ninguno de los dos no hay destino" {
        (Resolve-DeployTargetSource -FromFile '' -FromProcess '' -EnvFile '.env').Alias |
            Should -BeNullOrEmpty
    }

    It "un valor con espacios no cuenta como destino" {
        (Resolve-DeployTargetSource -FromFile '   ' -FromProcess '' -EnvFile '.env').Alias |
            Should -BeNullOrEmpty
    }
}

Context "Resolve-DeployTargetFromEnv — el runner sin archivo" {

    It "resuelve el destino sin env file, desde la variable de entorno" {
        # El caso entero de #75: tras actions/checkout no hay archivo.
        $env:MACSS_DEPLOY_SSH_ALIAS = 'prod'
        $raiz = New-ProyectoConEnv
        Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' 6>$null |
            Should -Be 'prod'
    }

    It "la variable de entorno pisa al archivo" {
        $env:MACSS_DEPLOY_SSH_ALIAS = 'prod'
        $raiz = New-ProyectoConEnv -Contenido "MACSS_DEPLOY_SSH_ALIAS=uat"
        Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' 6>$null |
            Should -Be 'prod'
    }

    It "sin variable, el archivo sigue mandando como siempre" {
        $raiz = New-ProyectoConEnv -Contenido "MACSS_DEPLOY_SSH_ALIAS=uat"
        Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' 6>$null |
            Should -Be 'uat'
    }
}

Context "Resolve-DeployTargetFromEnv — el origen se imprime siempre" {
    # Es una obligación de la ADR 0011, no una mejora de presentación: sin esto, una variable
    # olvidada redirige un despliegue sin que nadie lo vea.

    It "dice que vino del entorno cuando vino del entorno" {
        $env:MACSS_DEPLOY_SSH_ALIAS = 'prod'
        $raiz = New-ProyectoConEnv
        $salida = Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' 6>&1
        "$salida" | Should -Match 'variable de entorno'
    }

    It "dice de qué archivo vino cuando vino del archivo" {
        $raiz = New-ProyectoConEnv -Contenido "MACSS_DEPLOY_SSH_ALIAS=uat" -Nombre '.env.production'
        $salida = Resolve-DeployTargetFromEnv -ProjectRoot $raiz -EnvFile '.env.production' `
                                              -Cmdlet 'Publish-NodeApi' 6>&1
        "$salida" | Should -Match '\.env\.production'
    }

    It "avisa cuando el archivo declaraba otro destino" {
        $env:MACSS_DEPLOY_SSH_ALIAS = 'prod'
        $raiz = New-ProyectoConEnv -Contenido "MACSS_DEPLOY_SSH_ALIAS=uat"
        $salida = Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' 6>&1
        "$salida" | Should -Match 'uat'
    }
}

Context "Resolve-DeployTargetFromEnv — la ausencia sigue siendo un error" {

    It "sin archivo y sin variable, falla" {
        # ADR 0012: fallar fuerte. Que no haya destino no habilita un valor por defecto.
        $raiz = New-ProyectoConEnv
        { Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' } | Should -Throw
    }

    It "el error nombra los DOS orígenes posibles" {
        # Decirle a alguien que le falta una clave en un archivo que no puede existir --porque
        # está gitignoreado y esto es un runner-- lo manda por el camino equivocado.
        $raiz = New-ProyectoConEnv
        $msg = try { Resolve-DeployTargetFromEnv -ProjectRoot $raiz -EnvFile '.env.production' -Cmdlet 'Publish-NodeApi' }
               catch { $_.Exception.Message }
        $msg | Should -Match '\.env\.production'
        $msg | Should -Match 'variable de entorno|MACSS_DEPLOY_SSH_ALIAS'
    }
}

Context "Publish-FlutterWeb — el cmdlet completo, como lo invoca un runner" {
    # La regla se prueba arriba en aislamiento; esto prueba que un cmdlet real la use. Sin
    # servidor no se puede llegar más lejos, pero sí lo suficiente: con un alias que no existe
    # en ~/.ssh/config, el cmdlet tiene que pasar la resolución del destino y morir DESPUÉS, al
    # buscar la conexión. Si muriera antes, seguiría exigiendo el archivo que en CI no existe.
    #
    # Es Publish-FlutterWeb y no Publish-NodeApi porque la web no necesita el env file para nada
    # más: el puerto sale de publish.yaml y no sube configuración de runtime. La API todavía lo
    # necesita para PORT, y eso se cierra en el issue #83.

    BeforeAll {
        Import-Module "$PSScriptRoot\..\macss-devops.psd1" -Force

        function New-ProyectoFlutter {
            $raiz = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $raiz -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $raiz 'pubspec.yaml') -Value @('name: demo_app', 'version: 1.2.3+45')
            Set-Content -LiteralPath (Join-Path $raiz 'publish.yaml') -Value 'port: 8099'
            return $raiz
        }
    }

    It "sin env file, el cmdlet resuelve el destino y llega hasta la conexión" {
        $env:MACSS_DEPLOY_SSH_ALIAS = 'alias-que-no-existe-en-ssh-config'
        $raiz = New-ProyectoFlutter
        Push-Location $raiz
        try {
            $msg = try { Publish-FlutterWeb -Plan 6>$null | Out-Null; '' } catch { $_.Exception.Message }
        } finally { Pop-Location }

        # Falla —no hay tal servidor— pero por el motivo correcto: el destino ya se resolvió.
        $msg | Should -Not -Match 'no hay destino de despliegue'
        $msg | Should -Match 'alias-que-no-existe-en-ssh-config'
    }

    It "sin env file y sin variable, sigue fallando por falta de destino" {
        $raiz = New-ProyectoFlutter
        Push-Location $raiz
        try {
            $msg = try { Publish-FlutterWeb -Plan 6>$null | Out-Null; '' } catch { $_.Exception.Message }
        } finally { Pop-Location }

        $msg | Should -Match 'no hay destino de despliegue'
    }
}

Context "Resolve-DeployTargetFromEnv — la clave vieja tampoco se acepta por el entorno" {

    It "MACSS_DEPLOY_SERVER exportado falla igual que en el archivo" {
        # Si no, un runner puede exportar el nombre viejo y quedarse sin destino sin entender
        # por qué: el módulo lo ignoraría en silencio.
        $env:MACSS_DEPLOY_SERVER = 'prod'
        $raiz = New-ProyectoConEnv
        { Resolve-DeployTargetFromEnv -ProjectRoot $raiz -Cmdlet 'Publish-NodeApi' } |
            Should -Throw -ExpectedMessage '*MACSS_DEPLOY_SERVER*'
    }
}
}
