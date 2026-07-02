# macss-devops 🚀

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Version](https://img.shields.io/badge/version-3.0.0-green.svg)](./code/powershell/macss-devops.psd1)

Módulo de PowerShell publicado como macss-devops para automatizar operaciones DevOps: desarrollo, testing, CI/CD y despliegue.

## 📦 Instalación

```powershell
Install-Module macss-devops -Repository PSGallery -Scope CurrentUser
Import-Module macss-devops
```

Desarrollo local desde este repo:

```powershell
Import-Module .\code\powershell\macss-devops.psd1 -Force
```

## 🏗️ Arquitectura Modular

Este módulo sigue una **estructura modular por función**, donde cada cmdlet tiene sus propios recursos organizados:

```
PSDevOps/
├── code/
│   └── powershell/
│       ├── Functions/       # Cmdlets públicos (exportados)
│       ├── Private/         # Funciones auxiliares (no exportadas)
│       ├── Resources/       # Recursos específicos por función
│       │   └── [Función]/
│       │       ├── README.md
│       │       ├── templates/
│       │       └── examples/
│       ├── macss-devops.psd1
│       ├── macss-devops.psm1
│       └── test/            # Tests Pester
```

📖 **[Guía completa de estructura modular](ESTRUCTURA-MODULAR.md)**

## 🎯 Cmdlets Disponibles

| Cmdlet | Descripción | Documentación |
|--------|-------------|---------------|
| `Invoke-FlutterBuild` | Build de aplicaciones Flutter | `Get-Help Invoke-FlutterBuild` |
| `Invoke-SqlPackage` | Gestión declarativa de BD SQL Server | `Get-Help Invoke-SqlPackage` |
| `Publish-FlutterWeb` | Compilar y desplegar Flutter Web (`-Init`, `-Publish`, `-DeployReport`) | `Get-Help Publish-FlutterWeb` |
| `Publish-NodeApi` | Desplegar API Node.js/TypeScript (`-Init`, `-Publish`, `-DeployReport`) | `Get-Help Publish-NodeApi` |
| `Publish-DockerStack` | Desplegar un stack Docker Compose a un servidor remoto vía SSH (`-Init`, `-Plan`, `-Apply`) | [Docs](code/powershell/Resources/Publish-DockerStack/README.md) |
| `New-Issue` | Crear issues en GitHub desde markdown | [Docs](code/powershell/Resources/New-Issue/README.md) |
| `Get-SQLiteDB` | Operaciones SQLite | `Get-Help Get-SQLiteDB` |
| `Merge-DevToMain` | Merge automatizado dev→main | `Get-Help Merge-DevToMain` |
| `Export-FileTree` | Exportar árbol de directorios | `Get-Help Export-FileTree` |

```powershell
# Listar todos los cmdlets
Get-Command -Module macss-devops

# Ver ayuda detallada
Get-Help [Cmdlet] -Detailed
```

## ➕ Agregar Nuevas Funciones

### 1. Crear el cmdlet
```powershell
# code/powershell/Functions/New-MiFuncion.ps1
function New-MiFuncion {
    [CmdletBinding()]
    param(...)
    
    # Acceso a recursos del módulo
    $templatePath = Join-Path $PSScriptRoot "..\Resources\New-MiFuncion\templates\template.md"
}
```

### 2. Crear estructura de recursos
```bash
mkdir code/powershell/Resources/New-MiFuncion/{templates,examples}
```

### 3. Agregar documentación y recursos
```
code/powershell/Resources/New-MiFuncion/
├── README.md              # Documentación completa
├── templates/             # Plantillas reutilizables
│   └── template.md
└── examples/              # Ejemplos funcionales
    └── example.md
```

### 4. Actualizar manifiesto
```powershell
# code/powershell/macss-devops.psd1
FunctionsToExport = @(
    'New-Issue'
    , 'New-MiFuncion'  # ← Agregar aquí
)
```

### 5. Crear test
```powershell
# code/powershell/test/Test-MiFuncion.ps1
$moduleRoot = Split-Path -Parent $PSScriptRoot
$examplePath = Join-Path $moduleRoot "Resources\New-MiFuncion\examples\example.md"

New-MiFuncion -Path $examplePath -WhatIf
```

📖 **[Ver guía detallada](ESTRUCTURA-MODULAR.md#-cómo-agregar-una-nueva-función)**

## 🛠️ Requisitos

- **PowerShell 5.1+**
- Requisitos específicos por función (ver documentación de cada cmdlet)

## 📝 Convenciones

- **Nomenclatura:** Usar [verbos aprobados](valid-verb.md) en formato `Verb-Noun`
- **Funciones públicas:** `code/powershell/Functions/` (un archivo por cmdlet)
- **Funciones privadas:** `code/powershell/Private/` (helpers compartidos)
- **Recursos:** `code/powershell/Resources/[Función]/` (templates, ejemplos, docs)
- **Tests:** `code/powershell/test/*.Tests.ps1`

## 👤 Autor

**@ccisnedev** | [ccisne.dev](https://ccisne.dev) | [@cacsi-dev](https://github.com/cacsi-dev)

## 📄 Licencia

Copyright © 2024 CCISNEDEV. All rights reserved.

---

**¡Happy DevOps! 🚀**
