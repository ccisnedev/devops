<#
.SYNOPSIS
Copia la base de datos SQLite de una aplicación Android al directorio actual en la computadora.

.DESCRIPTION
El cmdlet `Get-SQliteDB` se conecta a un dispositivo Android usando `adb` (Android Debug Bridge) y copia la base de datos SQLite de una aplicación específica al directorio actual en la computadora. La función lee el nombre de la aplicación desde el archivo `pubspec.yaml` y construye el nombre del paquete de la aplicación. Luego, usa `adb` para copiar la base de datos desde el dispositivo Android a la computadora.

.EXAMPLE
Get-SQliteDB
Copia la base de datos SQLite de la aplicación Android al directorio actual en la computadora.

.NOTES
Versión: 1.0.0
Autor: @ccisnedev
#>
function Get-SQliteDB {
    # Leer el archivo pubspec.yaml
    $content = Get-Content -Path ./pubspec.yaml

    #Buscar la línea que contiene el nombre de la aplicación
    $nameLine = $content | Where-Object { $_ -match "name:" }

    # Extraer el nombre de la aplicación
    $name = $nameLine -replace "name: ", "" -replace '"', ''

    # Nombre del paquete de la aplicación
    # $PACKAGE_NAME = "com.example." + $name + "_client"
    $PACKAGE_NAME = "com.example." + $name

    # Ruta de la base de datos en el dispositivo: /data/user/0/com.example.micro/databases/appMicro.db
    $DB_PATH = "/data/user/0/$PACKAGE_NAME/databases/$name.db"

    # Ruta de destino en el dispositivo (carpeta de descargas)
    $DEST_PATH = "/storage/emulated/0/Download/$name.db"

    # Borra primero el archivo en la carpeta descargas
    adb -s R92W6083AVP shell rm $DEST_PATH

    # Usa adb para copiar la base de datos a la carpeta de descargas
    adb -s R92W6083AVP shell "run-as $PACKAGE_NAME cp $DB_PATH $DEST_PATH"

    # Usa adb para copiar la base de datos de la carpeta de descargas al directorio especificado en la computadora
    # adb pull $DEST_PATH "E:/Documents/DB/appMicro.db"
    adb -s R92W6083AVP pull $DEST_PATH "./$name.db"

    # Opcional: Elimina la base de datos de la carpeta de descargas si lo deseas
    # adb shell rm $DEST_PATH

    # Write-Host "Base de datos copiada exitosamente a E:/Documents/DB/appMicro.db"
    Write-Host "Base de datos copiada exitosamente a ./$name.db"
}