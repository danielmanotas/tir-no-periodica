# Cómo contribuir

Las contribuciones deben conservar la claridad del código y permitir comprobar el resultado numérico. Consulta [README.md](README.md) para conocer el comportamiento vigente y [CHANGELOG.md](CHANGELOG.md) para revisar el historial.

## Reportar un problema

Abre una incidencia en [GitHub](https://github.com/danielmanotas/tir-no-periodica/issues) e incluye:

- Versión o commit del proyecto y versión de Oracle o entorno de ejecución.
- Convención utilizada, fechas e importes de un ejemplo mínimo reproducible.
- Resultado esperado, resultado obtenido y mensaje completo ORA/PLS, cuando exista.
- Fuente o procedimiento usado para obtener el valor esperado.

Utiliza datos sintéticos o anonimizados. Los datos financieros privados y los archivos de pruebas particulares no deben incorporarse al repositorio ni a las incidencias públicas.

## Preparar una contribución

1. Crea un fork del repositorio y una rama a partir de `main` actualizado.
2. Limita los cambios al problema que quieres resolver.
3. Mantén la función y sus tipos en `calcular_tir_no_per.sql`, y las pruebas en `test_calcular_tir_no_per.sql`.
4. Actualiza el README cuando cambie el uso, los parámetros o el comportamiento. Registra los cambios funcionales en el changelog, sin duplicar el historial en el README.
5. Abre un pull request contra `main` con una explicación del problema, la solución y las pruebas realizadas.

No reorganices los archivos ni añadas dependencias o scripts auxiliares sin justificar su necesidad. Los cambios de firma, reglas de negocio, tolerancias o convenciones deben describir su impacto en los consumidores existentes.

## Estilo del código

- Sigue la indentación y las convenciones de nombres del archivo existente.
- Mantén juntos los pares de fecha e importe en los casos de prueba.
- Usa literales `DATE 'YYYY-MM-DD'` y números con punto decimal para evitar depender de la configuración regional.
- Explica en los comentarios las decisiones numéricas y los casos límite.
- Conserva el uso de `NUMBER` y el retorno sin redondeo final, salvo que el cambio lo requiera y esté justificado.

## Validar los cambios

Ejecuta los scripts en un esquema destinado a pruebas, con permisos para crear tipos y funciones:

```sql
@calcular_tir_no_per.sql
@test_calcular_tir_no_per.sql
```

La suite de la versión 1.2 espera 30 pruebas funcionales y dos comprobaciones de bisección. Si se añaden casos, actualiza el total documentado. La prueba de bisección crea y elimina una copia temporal de la función.

Para cambios de cálculo, añade casos que fallen con la versión anterior y pasen con la propuesta. Incluye fechas irregulares, años bisiestos o límites del dominio cuando correspondan. Compara los resultados con una referencia independiente; no calcules el valor esperado llamando a la misma función bajo prueba.

No relajes tolerancias para ocultar un fallo. Si necesitas ajustarlas, aporta evidencia del error observado y explica el efecto sobre el resultado.

OneCompiler puede ayudar a reproducir casos cuando admite las características necesarias. Indica siempre dónde ejecutaste las pruebas; una ejecución allí no certifica compatibilidad con todas las versiones de Oracle. No declares como ejecutadas pruebas que solo revisaste estáticamente.

## Contenido del pull request

- Problema resuelto y comportamiento esperado.
- Archivos modificados y motivo de los cambios.
- Entorno, comandos y resultados de las pruebas.
- Limitaciones conocidas o validaciones pendientes.

Evita cambios de formato ajenos al objetivo y no incluyas credenciales, archivos temporales ni salidas privadas de pruebas.
