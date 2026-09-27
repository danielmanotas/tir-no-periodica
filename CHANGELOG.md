# Historial de versiones

Este archivo registra los cambios funcionales del proyecto. La instalación, el uso y las reglas vigentes se documentan en [README.md](README.md).

## 1.2

### Funcionalidad

- `p_convencion` determina la fracción de año utilizada en el cálculo: `ACT/365`, `ACT/360` o `ACT/ACT` (variante ISDA).
- `ACT/ACT` divide el intervalo por años calendario y aplica 365 o 366 días a cada tramo.
- Omitir la convención o enviar `NULL` conserva `ACT/365` como valor predeterminado.

### Pruebas

- Sustitución de las pruebas que verificaban una base fija para todas las convenciones por pruebas del efecto de cada convención.
- Cobertura de años bisiestos, cruces de año, tramos parciales, los años 2000 y 2100, normalización del parámetro y valor predeterminado.
- Suite integrada de 30 pruebas funcionales y dos comprobaciones del uso real de bisección.

[Código de referencia de la versión 1.2](https://github.com/danielmanotas/tir-no-periodica/tree/87b6a9e3e9bc2d44e7b229ac3b5ec5a59e7613fc).

## 1.1

### Cálculo

- Expansión de ambos extremos del intervalo de bisección, limitada por el dominio permitido.
- Máximo de 160 iteraciones de bisección; Newton conserva 100.
- Registro del número de expansión en el contexto del error de búsqueda.
- Rechazo del resultado al agotar la bisección sin satisfacer los criterios de convergencia.

### Pruebas y documentación

- Caso de fechas irregulares con referencia independiente de alta precisión.
- Casos de positivo inicial, tasa negativa, error `-20007`, fallback a bisección y raíz próxima al límite inferior.
- Aserciones que rechazan resultados `NULL` y muestran información del caso fallido.
- Verificación de compilación e instrumentación temporal para confirmar el método utilizado.
- Suite integrada de 20 pruebas funcionales y dos comprobaciones de bisección.
- Advertencia de que las convenciones utilizaban base 365 en esta versión, y documentación del coste del ordenamiento.

## Versión inicial

- Función independiente `calcular_tir_no_per` y tipos SQL `tir_fechas` y `tir_valores`.
- Cálculo de TIR no periódica con Newton-Raphson y fallback a bisección.
- Validaciones de flujos, detección de TIR indeterminada y errores con contexto.
- Retorno `NUMBER` sin redondeo final y suite inicial de 11 pruebas.

[Publicación inicial](https://github.com/danielmanotas/tir-no-periodica/commit/40a44c3e0afcd2ac97c393f757e99b3bc8c89e1e).

Las tolerancias se mantienen en `1E-18`. El ordenamiento por inserción no ha sido sustituido. Los enlaces identifican commits de referencia, no etiquetas ni releases de GitHub.
