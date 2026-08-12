# EnvSecret.Tests.ps1
# Publicar el env file como secret de un GitHub Environment, para que CI pueda desplegar
# conservando el .env por release.
#
# Por qué así y no con el .env en shared/
# ---------------------------------------
# Cada release tiene hoy SU PROPIO .env, subido en el momento del despliegue. Volver el symlink
# 'current' a un release anterior devuelve ese código CON su configuración: es un rollback real,
# y funciona. Con un shared/.env el rollback devolvería el código viejo con la configuración de
# hoy, que no es lo mismo ni de lejos.
#
# Así que la configuración sigue viajando en el paquete. Lo único que cambia es de dónde la toma
# el ejecutor: de un archivo en la máquina del operador, o de un secret del environment cuando
# quien despliega es un runner. El archivo se materializa en el job y se pasa con -EnvFile, que
# es exactamente para lo que existe ese parámetro.
#
# Consecuencia buscada: el .env que acaba en el release es IDÉNTICO al de un despliegue manual.
# El secret es el mismo archivo, no una versión distinta de la configuración.
#
# La huella
# ---------
# Un secret no se puede leer de vuelta. Sin nada más, nunca sabrías si el que está en GitHub
# corresponde a tu archivo actual o a uno de hace tres meses. Por eso se publica junto al secret
# una huella SHA-256 del contenido, como VARIABLE (no secret), y el plan la compara. Un hash de
# un archivo de 67 líneas no revela su contenido.

BeforeAll {
    . "$PSScriptRoot/../Private/EnvSecret.ps1"
}

Describe "ConvertTo-SecretPayload — qué se sube exactamente" {

    It "junta las líneas con LF" {
        # El servidor es Linux y el archivo acaba siendo el .env de un release: un CRLF ahí
        # mete un retorno de carro dentro del valor de la última variable de cada línea.
        $p = ConvertTo-SecretPayload -Lines @('A=1', 'B=2')
        $p | Should -Be "A=1`nB=2`n"
    }

    It "normaliza un archivo que venía con CRLF" {
        (ConvertTo-SecretPayload -Lines @("A=1`r", "B=2`r")) | Should -Be "A=1`nB=2`n"
    }

    It "termina en salto de línea" {
        (ConvertTo-SecretPayload -Lines @('A=1')) | Should -Match "`n$"
    }

    It "no altera el contenido: sube el archivo tal cual" {
        # Incluidas las claves MACSS_DEPLOY_*. El módulo ya las quita al instalar el release, así
        # que el .env que acaba en el servidor es idéntico al de un despliegue manual. Filtrarlas
        # aquí crearía dos configuraciones distintas para el mismo entorno.
        $p = ConvertTo-SecretPayload -Lines @('MACSS_DEPLOY_SSH_ALIAS=prod', 'PORT=3050')
        $p | Should -Match 'MACSS_DEPLOY_SSH_ALIAS=prod'
    }

    It "conserva comentarios y líneas en blanco" {
        (ConvertTo-SecretPayload -Lines @('# nota', '', 'A=1')) | Should -Be "# nota`n`nA=1`n"
    }
}

Describe "Get-ContentFingerprint — saber si el secret sigue siendo el tuyo" {

    It "el mismo contenido da la misma huella" {
        (Get-ContentFingerprint -Text "A=1`n") | Should -Be (Get-ContentFingerprint -Text "A=1`n")
    }

    It "un cambio mínimo cambia la huella" {
        (Get-ContentFingerprint -Text "A=1`n") | Should -Not -Be (Get-ContentFingerprint -Text "A=2`n")
    }

    It "es un sha256 en hexadecimal" {
        (Get-ContentFingerprint -Text "A=1`n") | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe "ConvertTo-EnvSecretPlan — qué va a pasar" {

    It "sin huella remota, el secret nunca se publicó" {
        $p = ConvertTo-EnvSecretPlan -LocalFingerprint 'abc' -RemoteFingerprint ''
        $p.Action | Should -Be 'crear'
    }

    It "huellas iguales: no hay nada que hacer" {
        $p = ConvertTo-EnvSecretPlan -LocalFingerprint 'abc' -RemoteFingerprint 'abc'
        $p.Action | Should -Be 'sin-cambios'
        $p.Level  | Should -Be 'ok'
    }

    It "huellas distintas: se actualiza" {
        $p = ConvertTo-EnvSecretPlan -LocalFingerprint 'abc' -RemoteFingerprint 'xyz'
        $p.Action | Should -Be 'actualizar'
    }

    It "cuando difiere, lo dice sin ambigüedad" {
        # Es el caso que importa: alguien despliega desde CI creyendo que va lo que tiene en su
        # máquina, y va otra cosa.
        (ConvertTo-EnvSecretPlan -LocalFingerprint 'abc' -RemoteFingerprint 'xyz').Text |
            Should -Match 'difiere|distinto'
    }

    It "ningún texto lleva la huella completa, que no aporta nada a quien lee" {
        $p = ConvertTo-EnvSecretPlan -LocalFingerprint ('a' * 64) -RemoteFingerprint ('b' * 64)
        $p.Text | Should -Not -Match ('a' * 64)
    }
}

Describe "El componente: db, api y app tienen cada uno su configuración" {
    # Los tres se despliegan por separado y cada uno tiene su propio .env / .env.production:
    # credenciales de SqlPackage en db, configuración de runtime en api, destino en app. Un solo
    # secret por environment los mezclaría, y el despliegue de uno se llevaría la config de otro.

    It "cada componente tiene su propio secret" {
        Resolve-EnvSecretName -Component 'db'  | Should -Be 'ENV_FILE_DB'
        Resolve-EnvSecretName -Component 'api' | Should -Be 'ENV_FILE_API'
        Resolve-EnvSecretName -Component 'app' | Should -Be 'ENV_FILE_APP'
    }

    It "los tres nombres son distintos entre sí" {
        $n = 'db', 'api', 'app' | ForEach-Object { Resolve-EnvSecretName -Component $_ }
        ($n | Sort-Object -Unique).Count | Should -Be 3
    }

    It "se deduce del directorio desde el que se ejecuta" {
        # Se corre desde code/api, como Publish-NodeApi. Pedir el componente a mano cuando el
        # directorio ya lo dice es una oportunidad de equivocarse sin ganar nada.
        Resolve-EnvSecretComponent -Path 'C:\repos\impulsa\code\api' | Should -Be 'api'
        Resolve-EnvSecretComponent -Path '/home/x/impulsa/code/db'   | Should -Be 'db'
    }

    It "no se deduce nada desde un directorio que no es un componente" {
        # Mejor pedirlo que adivinar: publicar la configuración de un componente bajo el nombre
        # de otro es de los errores que no se ven hasta que la app no arranca.
        Resolve-EnvSecretComponent -Path 'C:\repos\impulsa' | Should -BeNullOrEmpty
    }

    It "tolera mayúsculas en el nombre del directorio" {
        Resolve-EnvSecretComponent -Path 'C:\repos\impulsa\code\API' | Should -Be 'api'
    }
}

Describe "New-EnvSecretCommand — cómo se invoca gh" {

    It "el valor del secret NO viaja en la línea de comandos" {
        # 'gh secret set --body <valor>' deja el secreto en los argumentos del proceso, visibles
        # para cualquiera que liste procesos en la máquina. Se pasa por stdin.
        $args = New-EnvSecretCommand -Repo 'cacsi-dev/impulsa' -Environment 'production' -SecretName 'ENV_FILE'
        ($args -join ' ') | Should -Not -Match '--body'
    }

    It "lo publica en el environment indicado, no a nivel de repositorio" {
        # El environment es lo que permite exigir aprobación antes de desplegar (R05, R23). Un
        # secret de repositorio no tiene esa puerta.
        $args = New-EnvSecretCommand -Repo 'cacsi-dev/impulsa' -Environment 'production' -SecretName 'ENV_FILE'
        $args | Should -Contain '--env'
        $args | Should -Contain 'production'
    }

    It "nombra el repositorio explícitamente" {
        $args = New-EnvSecretCommand -Repo 'cacsi-dev/impulsa' -Environment 'production' -SecretName 'ENV_FILE'
        $args | Should -Contain 'cacsi-dev/impulsa'
    }

    It "usa el nombre de secret que se le da" {
        $args = New-EnvSecretCommand -Repo 'o/r' -Environment 'production' -SecretName 'OTRO_NOMBRE'
        $args | Should -Contain 'OTRO_NOMBRE'
    }
}
