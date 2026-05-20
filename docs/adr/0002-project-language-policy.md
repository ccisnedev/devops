# ADR 0002: Política de idioma del proyecto

**Estado:** Aceptado

## Contexto

PSDevOps busca aportar a la comunidad hispanohablante de DevOps y servir como
material público, documentación técnica y base para charlas y presentaciones en
eventos de la región.

Al mismo tiempo, el módulo vive dentro de ecosistemas como PowerShell, DevOps,
CI/CD, GitHub Actions y despliegue, donde los nombres estándar, los
identificadores técnicos y muchas convenciones del tooling se expresan en
inglés.

Necesitamos una política explícita para evitar mezclar idiomas sin criterio y
mantener claridad tanto para usuarios hispanohablantes como para la
interoperabilidad técnica del proyecto.

## Decisión

- La documentación canónica del proyecto se escribe en español.
- Los comentarios del código, cuando sean necesarios, se escriben en español.
- El código fuente usa inglés para nombres estándar e identificadores técnicos: funciones, cmdlets, parámetros, variables, tipos, archivos, claves de configuración, nombres de stacks y conceptos definidos por herramientas o estándares externos.
- No se traducen nombres definidos por el ecosistema o por especificaciones externas.
- Si en el futuro se agrega material en inglés, será una capa secundaria de descubrimiento; la fuente de verdad documental seguirá siendo el español.

## Consecuencias

- El proyecto conserva una identidad clara para la comunidad hispanohablante.
- La API, los nombres públicos y la interoperabilidad técnica se mantienen alineados con el ecosistema.
- La documentación y los comentarios deben priorizar español neutro y terminología consistente.
- Las contribuciones nuevas deben respetar esta separación: prosa en español, nombres estándar en inglés.