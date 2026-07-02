# Architecture

## Propósito

macss-devops se organiza como un monorepo orientado a productos y artefactos
complementarios. El proyecto no se limita al módulo de PowerShell: busca
convertirse en una base pública para documentar, enseñar y materializar una
forma práctica de hacer DevOps en español.

La arquitectura debe permitir:

- mantener un artefacto publicable y estable para PowerShell;
- mantener documentación técnica y narrativa dentro del repositorio;
- agregar artefactos nuevos sin acoplarlos al módulo principal;
- compartir filosofía, convenciones y recursos reutilizables entre artefactos.

## Topología del repositorio

La carpeta code contiene los artefactos ejecutables o publicables del proyecto.
Cada artefacto vive en su propio subárbol y puede evolucionar con su propio
ciclo de release.

| Ruta | Estado | Responsabilidad |
|------|--------|-----------------|
| code/powershell/ | Actual | Módulo macss-devops publicado en PowerShell Gallery. Contiene cmdlets, helpers privados, recursos y tests. |
| docs/ | Actual | Documentación arquitectónica, ADR, roadmap y material interno de diseño. |
| skills/ | Actual | Skill de soporte para flujos asistidos relacionados con el proyecto. |

## Principios de separación

### 1. Artefactos primero

El repositorio se divide por artefacto entregable, no por capas técnicas
genéricas. Esto evita forzar una arquitectura de aplicación genérica que no
describe la realidad del proyecto.

### 2. Núcleo operativo en PowerShell

El corazón operativo actual vive en code/powershell/. Allí residen la lógica de
automatización, los recursos reutilizables, las validaciones y los contratos que
ya materializan una parte de la filosofía DevOps del proyecto.

### 3. Documentación centralizada en docs/

Mientras no exista otro artefacto documental real, la documentación canónica del
proyecto vive en docs/ y en los archivos de entrada del repositorio. Allí deben
quedar la filosofía, la motivación, la instalación, la arquitectura y el
roadmap, sin duplicar contratos técnicos definidos por el módulo.

### 4. Extensión progresiva

Nuevos subárboles dentro de code/ solo se crean cuando exista una necesidad
clara, sostenida y distinta del módulo actual. No se documentan como parte de la
arquitectura base hasta que realmente existan.

### 5. Contratos compartidos antes que acoplamiento

Cuando varios artefactos necesiten compartir información, deben hacerlo mediante
archivos, plantillas, metadatos o contratos explícitos. No se debe asumir que
un artefacto futuro puede importar directamente código interno del módulo.

## Arquitectura por artefacto

## code/powershell

### Responsabilidad

Entregar el módulo publicable y reusable del proyecto.

### Estructura interna

| Subruta | Responsabilidad |
|---------|-----------------|
| Functions/ | Cmdlets públicos exportados por el módulo. |
| Private/ | Helpers y utilidades internas no exportadas. |
| Resources/ | Templates, ejemplos y documentación asociada a cmdlets concretos. |
| test/ | Tests Pester y fixtures de validación. |
| macss-devops.psd1 / .psm1 | Manifiesto, bootstrap del módulo y superficie pública. |

### Regla de dependencia

Functions puede depender de Private y Resources.
Private no debe depender de tests.
Resources no contiene lógica ejecutable de negocio.
Tests validan contratos públicos y helpers críticos.

## docs

### Responsabilidad

Concentrar la documentación canónica del proyecto mientras no exista otro
artefacto documental real.

### Contenido esperado

- filosofía y motivación del proyecto;
- propuesta de valor del módulo;
- instalación desde PowerShell Gallery;
- guías y ejemplos por caso de uso;
- explicación de la arquitectura del repositorio;
- enlaces a ADR, changelog, roadmap y research relevante.

### Regla de diseño

docs/ debe explicar el módulo y las decisiones del proyecto sin inventar
superficies que todavía no existen.

## skills

### Responsabilidad

Agrupar assets de soporte para flujos asistidos relacionados con el proyecto.

### Regla de diseño

Los skills no son el producto principal ni la documentación canónica; son apoyo
operativo para tareas concretas.

## Flujo de relación entre artefactos

```text
docs/            -> decisiones, arquitectura, roadmap, ADR
code/powershell/ -> automatización y contratos operativos
skills/          -> soporte a flujos asistidos
```

## Precedencia de verdad

- La lógica operativa vive en code/powershell/.
- Las decisiones de diseño viven en docs/adr/ y en esta arquitectura.
- docs/ concentra la documentación canónica mientras no exista otro artefacto
	documental real.

## Concerns transversales

- Idioma: prosa y documentación canónica en español; nombres técnicos y API en
	inglés, según la política del proyecto.
- Versionado: cada artefacto puede tener su propio ciclo de release, pero el
	módulo PowerShell sigue siendo el entregable principal actual.
- Reutilización: plantillas, ejemplos y metadatos deben diseñarse para ser
	consumibles por otros artefactos.
- Publicación: el módulo se publica mediante su flujo hacia PowerShell Gallery.
- Evolución: nuevas carpetas en code/ solo se agregan cuando existe una
	responsabilidad diferenciada y sostenida.

## Próximas decisiones arquitectónicas

- Definir un criterio formal para incorporar nuevos artefactos dentro de code/.
- Definir la estructura mínima de documentación pública dentro de docs/ y del
	README.
- Formalizar contratos compartidos entre artefactos, especialmente metadatos,
	ejemplos y documentación generada.
