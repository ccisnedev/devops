# PSDevOps 🚀

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Version](https://img.shields.io/badge/version-2.0.0-green.svg)](./PSDevOps.psd1)

Módulo de PowerShell con arquitectura modular para automatizar operaciones DevOps: desarrollo, testing, CI/CD y despliegue.

## 📦 Instalación

```powershell
Import-Module PSDevOps
```

## 🏗️ Arquitectura Modular

Este módulo sigue una **estructura modular por función**, donde cada cmdlet tiene sus propios recursos organizados:

```
PSDevOps/
├── src/
│   ├── Functions/           # Cmdlets públicos (exportados)
│   ├── Private/             # Funciones auxiliares (no exportadas)
│   └── Resources/           # Recursos específicos por función
│       └── [Función]/
│           ├── README.md    # Documentación del cmdlet
│           ├── templates/   # Plantillas
│           └── examples/    # Ejemplos funcionales
└── test/                    # Tests
```

📖 **[Guía completa de estructura modular](ESTRUCTURA-MODULAR.md)**

## 🎯 Cmdlets Disponibles

| Cmdlet | Descripción | Documentación |
|--------|-------------|---------------|
| `Invoke-FlutterBuild` | Build de aplicaciones Flutter | `Get-Help Invoke-FlutterBuild` |
| `Invoke-SqlPackage` | Gestión declarativa de BD SQL Server | `Get-Help Invoke-SqlPackage` |
| `Publish-FlutterWeb` | Compilar y desplegar Flutter Web (`-Init`, `-Publish`, `-DeployReport`) | `Get-Help Publish-FlutterWeb` |
| `Publish-NodeApi` | Desplegar API Node.js/TypeScript (`-Init`, `-Publish`, `-DeployReport`) | `Get-Help Publish-NodeApi` |
| `New-Issue` | Crear issues en GitHub desde markdown | [Docs](src/Resources/New-Issue/README.md) |
| `Connect-Server` | Conexión SSH a servidores | `Get-Help Connect-Server` |
| `Copy-FromServer` | Copiar archivos remotos | `Get-Help Copy-FromServer` |
| `Get-SQLiteDB` | Operaciones SQLite | `Get-Help Get-SQLiteDB` |
| `Merge-DevToMain` | Merge automatizado dev→main | `Get-Help Merge-DevToMain` |
| `Export-FileTree` | Exportar árbol de directorios | `Get-Help Export-FileTree` |

```powershell
# Listar todos los cmdlets
Get-Command -Module PSDevOps

# Ver ayuda detallada
Get-Help [Cmdlet] -Detailed
```

## ➕ Agregar Nuevas Funciones

### 1. Crear el cmdlet
```powershell
# src/Functions/New-MiFuncion.ps1
function New-MiFuncion {
    [CmdletBinding()]
    param(...)
    
    # Acceso a recursos del módulo
    $templatePath = Join-Path $PSScriptRoot "..\Resources\New-MiFuncion\templates\template.md"
}
```

### 2. Crear estructura de recursos
```bash
mkdir src/Resources/New-MiFuncion/{templates,examples}
```

### 3. Agregar documentación y recursos
```
src/Resources/New-MiFuncion/
├── README.md              # Documentación completa
├── templates/             # Plantillas reutilizables
│   └── template.md
└── examples/              # Ejemplos funcionales
    └── example.md
```

### 4. Actualizar manifiesto
```powershell
# PSDevOps.psd1
FunctionsToExport = @(
    'New-Issue'
    , 'New-MiFuncion'  # ← Agregar aquí
)
```

### 5. Crear test
```powershell
# test/Test-MiFuncion.ps1
$moduleRoot = Split-Path -Parent $PSScriptRoot
$examplePath = Join-Path $moduleRoot "src\Resources\New-MiFuncion\examples\example.md"

New-MiFuncion -Path $examplePath -WhatIf
```

📖 **[Ver guía detallada](ESTRUCTURA-MODULAR.md#-cómo-agregar-una-nueva-función)**

## 🛠️ Requisitos

- **PowerShell 5.1+**
- Requisitos específicos por función (ver documentación de cada cmdlet)

## 📝 Convenciones

- **Nomenclatura:** Usar [verbos aprobados](valid-verb.md) en formato `Verb-Noun`
- **Funciones públicas:** `src/Functions/` (un archivo por cmdlet)
- **Funciones privadas:** `src/Private/` (helpers compartidos)
- **Recursos:** `src/Resources/[Función]/` (templates, ejemplos, docs)
- **Tests:** `test/Test-[Función].ps1`

## 👤 Autor

**@ccisnedev** | [ccisne.dev](https://ccisne.dev) | [@cacsi-dev](https://github.com/cacsi-dev)

## 📄 Licencia

Copyright © 2024 CCISNEDEV. All rights reserved.

---

**¡Happy DevOps! 🚀**
