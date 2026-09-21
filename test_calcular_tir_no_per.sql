-- Ejecutar después de calcular_tir_no_per.sql en SQLcl o SQL*Plus.
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

DECLARE
  v_tasa NUMBER;
  v_pruebas PLS_INTEGER := 0;

  PROCEDURE comprobar_tasa(
    p_nombre   IN VARCHAR2,
    p_fechas  IN tir_fechas,
    p_valores IN tir_valores,
    p_esperada IN NUMBER
  ) IS
    v_obtenida NUMBER;
  BEGIN
    v_obtenida := calcular_tir_no_per(p_fechas, p_valores);
    IF ABS(v_obtenida - p_esperada) > 1E-18 THEN
      RAISE_APPLICATION_ERROR(-20998, p_nombre || ': tasa inesperada: ' || TO_CHAR(v_obtenida));
    END IF;
    v_pruebas := v_pruebas + 1;
    DBMS_OUTPUT.PUT_LINE('OK: ' || p_nombre);
  END;

  PROCEDURE comprobar_error(
    p_nombre IN VARCHAR2,
    p_fechas IN tir_fechas,
    p_valores IN tir_valores,
    p_codigo IN NUMBER,
    p_convencion IN VARCHAR2 DEFAULT 'ACT/365'
  ) IS
    v_obtenida NUMBER;
  BEGIN
    BEGIN
      v_obtenida := calcular_tir_no_per(p_fechas, p_valores, p_convencion);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE = p_codigo THEN
          v_pruebas := v_pruebas + 1;
          DBMS_OUTPUT.PUT_LINE('OK: ' || p_nombre);
          RETURN;
        END IF;
        RAISE;
    END;
    RAISE_APPLICATION_ERROR(-20998, p_nombre || ': se esperaba el error ' || p_codigo);
  END;
BEGIN
  comprobar_tasa('TIR anual de 10 %',
    tir_fechas(DATE '2023-01-01', DATE '2024-01-01'),
    tir_valores(-1000, 1100), 0.1);

  comprobar_tasa('Ordenación de fechas y pares NULL excluidos',
    tir_fechas(DATE '2024-01-01', NULL, DATE '2023-01-01'),
    tir_valores(1100, 999, -1000), 0.1);

  comprobar_tasa('Cero intermedio no cambia el signo',
    tir_fechas(DATE '2023-01-01', DATE '2023-06-01', DATE '2024-01-01'),
    tir_valores(-1000, 0, 1100), 0.1);

  v_tasa := calcular_tir_no_per(
    tir_fechas(DATE '2023-01-01', DATE '2024-01-01'),
    tir_valores(-1000, 1123.4567890123456789));
  IF ABS(v_tasa - 0.1234567890123456789) > 1E-18
     OR v_tasa = ROUND(v_tasa, 15) THEN
    RAISE_APPLICATION_ERROR(-20998, 'Retorno sin redondeo final: tasa inesperada');
  END IF;
  v_pruebas := v_pruebas + 1;
  DBMS_OUTPUT.PUT_LINE('OK: retorno sin redondeo final');

  comprobar_error('Colección NULL', NULL,
    tir_valores(-1000, 1100), -20002);
  comprobar_error('Longitudes diferentes',
    tir_fechas(DATE '2023-01-01'), tir_valores(-1000, 1100), -20002);
  comprobar_error('Menos de dos pares completos',
    tir_fechas(DATE '2023-01-01', NULL), tir_valores(-1000, 1100), -20004);
  comprobar_error('Más de un positivo',
    tir_fechas(DATE '2023-01-01', DATE '2023-06-01', DATE '2024-01-01'),
    tir_valores(-1000, 500, 600), -20005);
  comprobar_error('Sin cambio de signo',
    tir_fechas(DATE '2023-01-01', DATE '2024-01-01'),
    tir_valores(-1000, -100), -20006);
  comprobar_error('Convención inválida',
    tir_fechas(DATE '2023-01-01', DATE '2024-01-01'),
    tir_valores(-1000, 1100), -20001, 'ACT/366');
  comprobar_error('NPV idénticamente cero',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01'),
    tir_valores(-1000, 1000), -20008);

  DBMS_OUTPUT.PUT_LINE('Pruebas aprobadas: ' || v_pruebas);
END;
/
