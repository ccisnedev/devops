@{
    # Módulo general
    ModuleVersion = '2.0.0'                       # Versión del módulo
    GUID = '25f10f0c-b26c-4238-9782-7c8a68c15681'  # Identificador único del módulo
    Author = '@ccisnedev'                           # Autor del módulo
    CompanyName = 'ccisne.dev'                    # Nombre de la compañía (opcional)
    Copyright = '(C) 2024 CCISNEDEV. All rights reserved.' # Derechos de autor

    # Descripción e información
    Description = 'Este módulo proporciona herramientas para automatizar el desarrollo, pruebas, CI/CD y despliegue de aplicaciones Flutter.'
    PowerShellVersion = '5.1'                      # Versión mínima de PowerShell requerida (5.1 es común para módulos modernos)
    
    # Funcionalidad
    FunctionsToExport = @(
        # Funciones principales
        'Invoke-FlutterBuild'
        , 'Invoke-SqlPackage'
        , 'Publish-NodeApi'
        , 'Publish-FlutterWeb'
        
        # cmdlets legados (a eliminar en futuras versiones)
        , 'Connect-Server'
        , 'Publish-FlutterWebLegacy'
        , 'Publish-ShelfApi'
        , 'Get-SQLiteDB'
        , 'Merge-DevToMain'
        , 'Export-FileTree'
        , 'Copy-FromServer'
        , 'New-Issue'
    )
    CmdletsToExport = @()                          # En este caso no hay cmdlets, pero si existieran se listarían aquí
    AliasesToExport = @('server')                  # Aliases que exporta el módulo (si los hay)
    VariablesToExport = @()                        # Variables que el módulo exporta

    # Scripts a cargar
    FileList = @()                                 # Listado de archivos que el módulo necesita para su funcionamiento (opcional)
    RootModule = 'PSDevOps.psm1'              # Archivo principal del módulo

    # Dependencias y Compatibilidad
    RequiredModules = @('powershell-yaml')          # powershell-yaml: parseo YAML anidado (ref: issue #1)
    RequiredAssemblies = @()                       # Lista de ensamblados .NET requeridos (rara vez se usa en módulos simples)

    # Información adicional
    PrivateData = @{}                              # Datos específicos del módulo, no exportados (opcional)

    # Visibilidad y compatibilidad
    ModuleToProcess = ''                           # (Normalmente se deja en blanco para módulos de script)
    NestedModules = @()                            # Módulos que deben ser cargados junto con el módulo principal (normalmente en blanco)
}
