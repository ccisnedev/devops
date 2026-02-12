# 🎫 Crear Issues en GitHub con New-Issue

## Descripción

El cmdlet `New-Issue` permite crear issues en GitHub de forma automatizada usando archivos markdown con formato frontmatter YAML.

## Formato del Archivo

Los archivos de issue deben seguir este formato:

```markdown
---
title: 🐛 [Bug] Título descriptivo del problema
labels: bug,enhancement,documentation
---

# Descripción

Descripción detallada del problema o feature request.

## Contexto adicional

Información adicional, screenshots, logs, etc.
```

### Campos del Frontmatter

- **title** (REQUERIDO): Título de la issue
- **labels** (OPCIONAL): Labels separados por coma

## Uso

### Ejemplo básico

```powershell
New-Issue -Path .dev/issues/bug-login.md
```

### Especificar repositorio

```powershell
New-Issue -Path .dev/issues/feature-dark-mode.md -Repository "usuario/proyecto"
```

### Preview sin crear (WhatIf)

```powershell
New-Issue -Path .dev/issues/bug-performance.md -WhatIf
```

### Con verbose

```powershell
New-Issue -Path .dev/issues/enhancement-ui.md -Verbose
```

## Labels Comunes

Basados en los labels estándar de GitHub:

- `bug` - Algo no funciona correctamente
- `documentation` - Mejoras o adiciones a la documentación
- `duplicate` - Esta issue o PR ya existe
- `enhancement` - Nueva característica o solicitud
- `good first issue` - Bueno para principiantes
- `help wanted` - Se necesita ayuda extra
- `invalid` - Esto no parece correcto
- `question` - Se solicita más información
- `wontfix` - Esto no se trabajará

## Tips

### Usar emojis en títulos

Los emojis ayudan a identificar rápidamente el tipo de issue:

- 🐛 `:bug:` - Bugs
- ✨ `:sparkles:` - Nuevas características
- 📚 `:books:` - Documentación
- 🔥 `:fire:` - Critical issues
- 🚀 `:rocket:` - Performance
- 🎨 `:art:` - UI/UX
- 🔒 `:lock:` - Security

### Organización de archivos

Recomendamos crear una estructura como:

```
.dev/
  issues/
    bugs/
    features/
    docs/
  issue-template.md
```

## Requisitos

- **GitHub CLI** (`gh`) instalado y autenticado
  ```powershell
  winget install GitHub.cli
  gh auth login
  ```

- Estar en un repositorio Git (si no se especifica `-Repository`)

## Validaciones

El cmdlet realiza las siguientes validaciones:

✅ Verifica que GitHub CLI esté instalado y autenticado  
✅ Valida la estructura del archivo markdown  
✅ Verifica que existan los campos requeridos  
✅ Valida el formato de los labels  
✅ Confirma que estás en un repositorio Git (si aplica)

## Ejemplos de Archivos

Revisa los ejemplos en:
- `.dev/issue-template.md` - Plantilla básica
- `.dev/issues/example-bug-pingcontroller.md` - Ejemplo de bug report

## Troubleshooting

### Error: "GitHub CLI no está instalado"

```powershell
winget install GitHub.cli
```

### Error: "No estás autenticado"

```powershell
gh auth login
```

### Error: "Formato de frontmatter inválido"

Verifica que:
1. El archivo comience con `---`
2. Haya un segundo `---` cerrando el frontmatter
3. El campo `title` esté presente
4. El formato sea `campo: valor`
