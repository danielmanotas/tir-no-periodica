# TIR no periódica en Oracle PL/SQL

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

Las dos colecciones deben tener igual cantidad de elementos. Cada fecha corresponde al importe de la misma posición. Los pares con fecha o importe `NULL` se excluyen. Los demás se ordenan por fecha; las fechas iguales conservan el orden de entrada. El cálculo descuenta por días enteros sobre una base de 365 días.

El tercer parámetro opcional, `p_convencion`, acepta `ACT/365`, `ACT/360` y `ACT/ACT`. la base de 365 días se usa por defecto.

El resultado está en tanto por uno: `0.1` significa 10 %. No se aplica `ROUND`; la cantidad de cifras que muestra cada cliente depende de su formato, y la precisión efectiva depende de `NUMBER` y de las tolerancias numéricas. La documentación dentro del script detalla las validaciones, el dominio de la tasa y los códigos de error.

## Reglas de negocio

- Se requieren al menos dos flujos con fecha e importe no nulos. Los pares incompletos se excluyen antes de contar y calcular.
- Se admite **como máximo un importe positivo** y debe existir **exactamente un cambio de signo** en la secuencia ordenada. Los importes cero cuentan como filas, pero no como cambios de signo; pueden establecer la fecha base si aparecen primero.
- Los flujos se ordenan por fecha completa. Cuando comparten fecha y hora, se conserva su posición de entrada. No se agrupan para calcular la tasa.
- La hora interviene en el orden. Para el descuento se usa `TRUNC(fecha)`, por lo que dos flujos del mismo día tienen el mismo tiempo financiero.
- El único positivo puede estar antes o después de los negativos. Estas reglas no garantizan que exista una raíz en el dominio permitido.
- Si la suma de los importes es cero **en cada día**, el NPV es cero para cualquier tasa y se rechaza como TIR indeterminada. La agrupación diaria se usa solo para este diagnóstico.

## Cálculo y límites

La fecha base es el día del primer flujo ordenado. Para cada flujo, `t_i = (TRUNC(fecha_i) - TRUNC(fecha_1)) / 365` y `NPV(r) = SUM(valor_i / (1 + r)^t_i)`. Se busca `NPV(r) = 0` mediante Newton-Raphson con reducción de paso; si no converge, se intenta bisección con expansión acotada.

La semilla es `0.000001`; la raíz debe cumplir `-0.999999 < r < 100`. Cada método tiene un máximo de 100 iteraciones. La tolerancia monetaria es `SUM(ABS(valor_i)) * 1E-18` y la tolerancia absoluta de tasa es `1E-18`. Newton acepta un residuo exactamente cero o exige simultáneamente la tolerancia monetaria y `ABS(NPV / derivada) <= 1E-18`. Bisección comprueba el residuo y el ancho del intervalo. Estas tolerancias son criterios de aceptación numérica, no una garantía de decimales exactos.

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

El script comprueba tasas esperadas, el retorno sin redondeo, la ordenación, los flujos cero, la exclusión de pares incompletos y los errores principales. Imprime `Pruebas aprobadas: 11` si todo pasa y termina con error SQL ante un fallo. Necesita `DBMS_OUTPUT` habilitado, lo que hace el propio script con `SET SERVEROUTPUT ON`.
