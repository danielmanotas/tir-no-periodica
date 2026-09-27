# TIR no periódica en Oracle PL/SQL

**Versión 1.2**

`calcular_tir_no_per` calcula la tasa efectiva anual de flujos fechados mediante Newton-Raphson y, si hace falta, bisección. Recibe fechas e importes como parámetros. Devuelve un `NUMBER` sin redondeo final.

## Requisitos

- Oracle Database con soporte para tipos de colección SQL y PL/SQL.
- Permisos para crear tipos y funciones en el esquema de instalación.

## Instalación

Ejecuta [`calcular_tir_no_per.sql`](calcular_tir_no_per.sql) en SQLcl, SQL*Plus o una herramienta compatible con el separador `/` de PL/SQL. El script crea los tipos `tir_fechas` y `tir_valores`, y después la función.

```sql
@calcular_tir_no_per.sql
```

## Uso

```sql
SELECT calcular_tir_no_per(
         tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
         tir_valores(-1000, 1100)
       ) AS tasa_anual
FROM dual;
```

Las dos colecciones deben tener igual cantidad de elementos. Cada fecha corresponde al importe de la misma posición. Los pares con fecha o importe `NULL` se excluyen. Los demás se ordenan por fecha; las fechas iguales conservan el orden de entrada. El cálculo descuenta por días enteros según la convención seleccionada; por defecto usa ACT/365.

El tercer parámetro opcional, `p_convencion`, determina la fracción de año:

| Convención | Cálculo de `t_i` |
| --- | --- |
| `ACT/365` (predeterminada) | Días reales entre la fecha base y el flujo, divididos entre 365. |
| `ACT/360` | Días reales entre la fecha base y el flujo, divididos entre 360. |
| `ACT/ACT` | Variante ISDA: suma de los días de cada año divididos entre 365 o 366, según corresponda. |

Omitir el parámetro o pasar `NULL` utiliza `ACT/365`. Se admiten minúsculas y espacios exteriores. Una cadena formada solo por espacios es inválida. ACT/ACT utiliza el calendario gregoriano, incluye el día inicial y excluye el final; no requiere fechas de cupón. Se utiliza la variante [Actual/Actual ISDA](https://www.isda.org/book/actualactual-day-count-fraction/).

```sql
SELECT calcular_tir_no_per(
         tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
         tir_valores(-1000, 1100),
         'ACT/ACT'
       ) AS tasa_anual
FROM dual;
```

En este ejemplo ACT/ACT usa `366/366` y produce una tasa anual de `0.1`; ACT/365 usa `366/365` y ACT/360 usa `366/360`.

El resultado está en tanto por uno: `0.1` significa 10 %. No se aplica `ROUND`; la cantidad de cifras que muestra cada cliente depende de su formato, y la precisión efectiva depende de `NUMBER` y de las tolerancias numéricas. La documentación dentro del script detalla las validaciones, el dominio de la tasa y los códigos de error.

## Reglas de negocio

- Se requieren al menos dos flujos con fecha e importe no nulos. Los pares incompletos se excluyen antes de contar y calcular.
- Se admite **como máximo un importe positivo** y debe existir **exactamente un cambio de signo** en la secuencia ordenada. Los importes cero cuentan como filas, pero no como cambios de signo; pueden establecer la fecha base si aparecen primero.
- Los flujos se ordenan por fecha completa. Cuando comparten fecha y hora, se conserva su posición de entrada. No se agrupan para calcular la tasa.
- La hora interviene en el orden. Para el descuento se usa `TRUNC(fecha)`, por lo que dos flujos del mismo día tienen el mismo tiempo financiero.
- El único positivo puede estar antes o después de los negativos. Estas reglas no garantizan que exista una raíz en el dominio permitido.
- Si la suma de los importes es cero **en cada día**, el NPV es cero para cualquier tasa y se rechaza como TIR indeterminada. La agrupación diaria se usa solo para este diagnóstico.

## Cálculo y límites

La fecha base es el día del primer flujo ordenado. Para cada flujo, `t_i` es la fracción de año desde la fecha base según `p_convencion`, y `NPV(r) = SUM(valor_i / (1 + r)^t_i)`. Se busca `NPV(r) = 0` mediante Newton-Raphson con reducción de paso; si no converge, se intenta bisección con expansión acotada.

La semilla es `0.000001`; la raíz debe cumplir `-0.999999 < r < 100`. Newton admite 100 iteraciones y bisección 160. La tolerancia monetaria es `SUM(ABS(valor_i)) * 1E-18` y la tolerancia absoluta de tasa es `1E-18`. Newton acepta un residuo exactamente cero o exige simultáneamente la tolerancia monetaria y `ABS(NPV / derivada) <= 1E-18`. Bisección comprueba el residuo y el ancho del intervalo. Parte de `[-0.99, 2]` y amplía ambos extremos hasta obtener signos opuestos, con un máximo de 15 expansiones acotadas por el dominio. Estas tolerancias son criterios de aceptación numérica, no una garantía de decimales exactos.

## Errores de negocio

| Código | Motivo |
| --- | --- |
| `-20001` | Convención de días inválida. |
| `-20002` | Colecciones nulas o de distinta longitud. |
| `-20004` | Menos de dos pares con fecha e importe válidos. |
| `-20005` | Más de un flujo positivo. |
| `-20006` | No hay exactamente un cambio de signo, ignorando ceros. |
| `-20007` | No se encuentra una raíz válida dentro de los límites y tolerancias. |
| `-20008` | NPV idénticamente cero; la tasa es indeterminada. |
| `-20999` | Error inesperado, con contexto del método y la iteración. |

## Pruebas

Después de instalar la función, ejecuta [`test_calcular_tir_no_per.sql`](test_calcular_tir_no_per.sql) en SQLcl o SQL*Plus:

```sql
@test_calcular_tir_no_per.sql
```

El archivo de pruebas contiene toda la suite y no necesita scripts auxiliares. Primero comprueba los objetos instalados y muestra los errores de compilación. Después ejecuta 30 pruebas funcionales y dos comprobaciones del método de bisección. Ante un error SQL, termina con `FAILURE ROLLBACK`.

La confirmación de bisección crea una copia temporal de la función con un nombre aleatorio `TIR_BIS_...`, añade una aserción del método al retorno y elimina la copia al terminar. Requiere permiso para crear funciones. No modifica la función original. Si la sesión se interrumpe, podría quedar el objeto temporal.

El mensaje final esperado es `Suite completa aprobada: 30 pruebas funcionales y 2 de biseccion.` Los archivos SQL deben ejecutarse como scripts.

## Estructura del proyecto

```text
README.md
calcular_tir_no_per.sql
test_calcular_tir_no_per.sql
```

## Precisión numérica

La suite compara cuatro flujos en los días 0, 47, 203 y 400, con importes `[-1000, -200, -300, 1800]`, contra una referencia independiente calculada con Python Decimal a 80 cifras:

```text
0.20634960252626207745418017008051606867665613233880907503848730263627277864514603
```

La comparación utiliza una tolerancia absoluta de tasa de `1E-18` e informa el error observado. La referencia independiente no sustituye las pruebas en la versión de Oracle de destino.

## Volumen de entrada

El ordenamiento estable por inserción tiene complejidad O(n²). Como recomendación conservadora, utiliza hasta 1.000 pares por llamada antes de medir rendimiento en el entorno destino. No es una restricción impuesta por la función ni un umbral validado por benchmark. Para volúmenes mayores, deben evaluarse tanto el ordenamiento como las evaluaciones del NPV.
