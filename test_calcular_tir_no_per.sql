-- Ejecutar despues de calcular_tir_no_per.sql en SQLcl o SQL*Plus.
SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- 1. Validar la instalacion y mostrar errores de compilacion.
DECLARE
  v_validos PLS_INTEGER;
BEGIN
  FOR e IN (SELECT name, type, line, position, text FROM user_errors
             WHERE name IN ('CALCULAR_TIR_NO_PER', 'TIR_FECHAS', 'TIR_VALORES')
               AND attribute = 'ERROR'
             ORDER BY name, sequence) LOOP
    DBMS_OUTPUT.PUT_LINE(e.type || ' ' || e.name || ', linea ' || e.line
      || ', columna ' || e.position || ': ' || e.text);
  END LOOP;
  SELECT COUNT(*) INTO v_validos FROM user_objects
   WHERE status = 'VALID'
     AND ((object_name = 'CALCULAR_TIR_NO_PER' AND object_type = 'FUNCTION')
       OR (object_name IN ('TIR_FECHAS', 'TIR_VALORES') AND object_type = 'TYPE'));
  IF v_validos <> 3 THEN
    RAISE_APPLICATION_ERROR(-20998,
      'Instalacion incompleta o invalida: revisar USER_ERRORS e instalar la funcion y los dos tipos en este esquema.');
  END IF;
END;
/

-- 2. Pruebas funcionales: 30 casos.
DECLARE
  v_tasa NUMBER;
  v_pruebas PLS_INTEGER := 0;

  PROCEDURE comprobar_tasa(
    p_nombre   IN VARCHAR2,
    p_fechas  IN tir_fechas,
    p_valores IN tir_valores,
    p_esperada IN NUMBER,
    p_convencion IN VARCHAR2 DEFAULT 'ACT/365'
  ) IS
    v_obtenida NUMBER;
  BEGIN
    v_obtenida := calcular_tir_no_per(p_fechas, p_valores, p_convencion);
    IF v_obtenida IS NULL OR ABS(v_obtenida - p_esperada) > 1E-18 THEN
      RAISE_APPLICATION_ERROR(-20998, p_nombre
        || ': obtenida=' || NVL(TO_CHAR(v_obtenida, 'TM9'), 'NULL')
        || '; esperada=' || TO_CHAR(p_esperada, 'TM9')
        || '; error absoluto=' || NVL(TO_CHAR(ABS(v_obtenida - p_esperada), 'TM9'), 'NULL')
        || '; tolerancia=1E-18');
    END IF;
    v_pruebas := v_pruebas + 1;
    DBMS_OUTPUT.PUT_LINE('OK: ' || p_nombre || '; error absoluto=' || TO_CHAR(ABS(v_obtenida - p_esperada)));
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FALLO: ' || p_nombre || ': ' || SQLERRM);
    RAISE;
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
          IF p_codigo = -20007 AND NOT REGEXP_LIKE(SQLERRM,
              'Metodo=(NEWTON|BISECCION), Iter=[0-9]+') THEN
            RAISE_APPLICATION_ERROR(-20998, p_nombre || ': falta contexto: ' || SQLERRM);
          END IF;
          v_pruebas := v_pruebas + 1;
          DBMS_OUTPUT.PUT_LINE('OK: ' || p_nombre);
          RETURN;
        END IF;
        DBMS_OUTPUT.PUT_LINE('FALLO: ' || p_nombre || '; codigo esperado='
          || p_codigo || '; recibido=' || SQLERRM);
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
  IF v_tasa IS NULL OR ABS(v_tasa - 0.1234567890123456789) > 1E-18
     OR v_tasa = ROUND(v_tasa, 15) THEN
    RAISE_APPLICATION_ERROR(-20998, 'Retorno sin redondeo final: obtenida='
      || NVL(TO_CHAR(v_tasa, 'TM9'), 'NULL') || '; esperada=0.1234567890123456789');
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


  -- REQ-01: referencia Decimal (80 cifras), generada por referencia_precision.py.
  comprobar_tasa('Fechas irregulares: dias 0, 47, 203, 400',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01' + 47,
               DATE '2023-01-01' + 203, DATE '2023-01-01' + 400),
    tir_valores(-1000, -200, -300, 1800),
    0.20634960252626207745418017008051606868);

  comprobar_tasa('Unico positivo al inicio',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01' + 365, DATE '2023-01-01' + 730),
    tir_valores(1000, -500, -660), 0.1);
  comprobar_tasa('Perdida neta: tasa negativa',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01' + 365),
    tir_valores(-1000, 900), -0.1);
  comprobar_tasa('Fallback por derivada cero en la semilla',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01' + 365, DATE '2023-01-01' + 730),
    tir_valores(0, 2, -1.000001), -0.4999995);
  comprobar_tasa('Raiz proxima al limite inferior',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01' + 365, DATE '2023-01-01' + 730),
    tir_valores(0, 1, -0.0000011), -0.9999989);

  -- NPV constante -100: pasa las reglas de negocio, pero no tiene raiz.
  comprobar_error('Sin raiz: residuo constante y contexto del error',
    tir_fechas(DATE '2023-01-01', DATE '2023-01-01'),
    tir_valores(-1000, 900), -20007);

  -- Convenciones: referencias independientes calculadas con Decimal a 80 cifras.
  comprobar_tasa('ACT/365 explicito en anio bisiesto',
    tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
    tir_valores(-1000, 1100), 0.099713585934141241287216920352387027, 'ACT/365');

  comprobar_tasa('NULL conserva ACT/365',
    tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
    tir_valores(-1000, 1100), 0.099713585934141241287216920352387027, NULL);

  comprobar_tasa('ACT/360: 360 dias',
    tir_fechas(DATE '2023-01-01', DATE '2023-12-27'),
    tir_valores(-1000, 1100), 0.100000000000000000000000000000000000, 'ACT/360');

  comprobar_tasa('Convencion con espacios y minusculas',
    tir_fechas(DATE '2023-01-01', DATE '2023-12-27'),
    tir_valores(-1000, 1100), 0.100000000000000000000000000000000000, ' act/360 ');

  comprobar_tasa('ACT/360 en anio bisiesto',
    tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
    tir_valores(-1000, 1100), 0.098282633848621054858808597435844066, 'ACT/360');

  comprobar_tasa('ACT/ACT: anio bisiesto completo',
    tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
    tir_valores(-1000, 1100), 0.100000000000000000000000000000000000, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: varios anios y tramos parciales',
    tir_fechas(DATE '2023-07-01', DATE '2025-07-01'),
    tir_valores(-1000, 1210), 0.100000000000000000000000000000000000, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: cruce de anio con febrero bisiesto',
    tir_fechas(DATE '2023-12-31', DATE '2024-03-01'),
    tir_valores(-1000, 1100), 0.771515501312532738710093969962185185, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: incluye 29 de febrero',
    tir_fechas(DATE '2024-02-28', DATE '2024-03-01'),
    tir_valores(-1000, 1010), 5.177480771011434760433076230349015494, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: siglo 2100 no bisiesto',
    tir_fechas(DATE '2100-01-01', DATE '2101-01-01'),
    tir_valores(-1000, 1100), 0.100000000000000000000000000000000000, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: siglo 2000 bisiesto',
    tir_fechas(DATE '2000-01-01', DATE '2001-01-01'),
    tir_valores(-1000, 1100), 0.100000000000000000000000000000000000, 'ACT/ACT');

  comprobar_tasa('ACT/ACT: tramo dentro de anio bisiesto',
    tir_fechas(DATE '2024-03-01', DATE '2024-12-31'),
    tir_valores(-1000, 1100), 0.121169364140602282717273261774604134, 'ACT/ACT');

  -- La llamada sin tercer argumento debe seguir utilizando ACT/365.
  v_tasa := calcular_tir_no_per(
    tir_fechas(DATE '2024-01-01', DATE '2025-01-01'),
    tir_valores(-1000, 1100));
  IF v_tasa IS NULL OR ABS(v_tasa - 0.099713585934141241287216920352387027) > 1E-18 THEN
    RAISE_APPLICATION_ERROR(-20998, 'La convencion omitida debe utilizar ACT/365');
  END IF;
  v_pruebas := v_pruebas + 1;
  DBMS_OUTPUT.PUT_LINE('OK: convencion omitida conserva ACT/365');

  DBMS_OUTPUT.PUT_LINE('Pruebas aprobadas: ' || v_pruebas);
END;
/

-- 3. Confirmar el camino real de biseccion: 2 casos.
DECLARE
  v_original CLOB;
  v_renamed CLOB;
  v_source CLOB;
  -- Identificador de 30 caracteres, compatible con Oracle 11g.
  v_name VARCHAR2(30) := 'TIR_BIS_' || SUBSTR(RAWTOHEX(SYS_GUID()), 1, 22);
  v_count PLS_INTEGER;
  v_created BOOLEAN := FALSE;
  v_rate NUMBER;
  v_return_pattern CONSTANT VARCHAR2(100) :=
    'RETURN[[:space:]]+v_rate[[:space:]]*;';

  PROCEDURE mostrar_errores IS
  BEGIN
    FOR e IN (SELECT line, position, text FROM user_errors
               WHERE name = v_name AND type = 'FUNCTION' AND attribute = 'ERROR'
               ORDER BY sequence) LOOP
      DBMS_OUTPUT.PUT_LINE(v_name || ', linea ' || e.line
        || ', columna ' || e.position || ': ' || e.text);
    END LOOP;
  END;

  PROCEDURE liberar(p_lob IN OUT NOCOPY CLOB) IS
  BEGIN
    IF DBMS_LOB.ISTEMPORARY(p_lob) = 1 THEN
      DBMS_LOB.FREETEMPORARY(p_lob);
    END IF;
  END;

  PROCEDURE limpiar IS
  BEGIN
    IF v_created THEN
      BEGIN
        EXECUTE IMMEDIATE 'DROP FUNCTION ' || v_name;
        v_created := FALSE;
      EXCEPTION WHEN OTHERS THEN
        IF SQLCODE <> -4043 THEN
          DBMS_OUTPUT.PUT_LINE('No se pudo eliminar ' || v_name || ': ' || SQLERRM);
        END IF;
      END;
    END IF;
    liberar(v_source);
    liberar(v_renamed);
    liberar(v_original);
  END;

  PROCEDURE comprobar(
    p_nombre VARCHAR2, p_importe NUMBER, p_final NUMBER, p_expected NUMBER
  ) IS
  BEGIN
    EXECUTE IMMEDIATE
      'SELECT ' || v_name || '('
      || 'tir_fechas(DATE ''2023-01-01'', DATE ''2023-01-01''+365, DATE ''2023-01-01''+730),'
      || 'tir_valores(0, :a, :b)) FROM dual'
      INTO v_rate USING p_importe, p_final;
    IF v_rate IS NULL OR ABS(v_rate - p_expected) > 1E-18 THEN
      RAISE_APPLICATION_ERROR(-20998, p_nombre
        || ': obtenida=' || NVL(TO_CHAR(v_rate, 'TM9'), 'NULL')
        || '; esperada=' || TO_CHAR(p_expected, 'TM9'));
    END IF;
    DBMS_OUTPUT.PUT_LINE('OK: ' || p_nombre
      || '; metodo BISECCION confirmado; tasa=' || TO_CHAR(v_rate, 'TM9'));
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FALLO: ' || p_nombre || ': ' || SQLERRM);
    RAISE;
  END;
BEGIN
  SELECT COUNT(*) INTO v_count FROM user_objects WHERE object_name = v_name;
  IF v_count <> 0 THEN
    RAISE_APPLICATION_ERROR(-20998, 'El objeto temporal ya existe: ' || v_name);
  END IF;
  DBMS_LOB.CREATETEMPORARY(v_original, TRUE);
  FOR fila IN (SELECT text FROM user_source
               WHERE name = 'CALCULAR_TIR_NO_PER' AND type = 'FUNCTION' ORDER BY line) LOOP
    IF fila.text IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(v_original, LENGTH(fila.text), fila.text);
    END IF;
  END LOOP;
  -- Fallar expresamente si la versión instalada tiene una estructura diferente.
  IF DBMS_LOB.GETLENGTH(v_original) = 0
     OR REGEXP_COUNT(v_original, v_return_pattern, 1, 'i') <> 1 THEN
    RAISE_APPLICATION_ERROR(-20998, 'Se requiere exactamente un retorno de v_rate para instrumentar la funcion.');
  END IF;
  v_renamed := REGEXP_REPLACE(v_original, 'calcular_tir_no_per', v_name, 1, 0, 'i');
  v_source := REGEXP_REPLACE(v_renamed, v_return_pattern,
    'IF v_metodo <> ''BISECCION'' THEN '
    || 'RAISE_APPLICATION_ERROR(-20998, ''Se esperaba fallback real a BISECCION''); '
    || 'END IF; RETURN v_rate;', 1, 1, 'i');
  -- CREATE sin OR REPLACE impide sobrescribir un objeto existente.
  BEGIN
    EXECUTE IMMEDIATE 'CREATE ' || v_source;
    v_created := TRUE;
  EXCEPTION WHEN OTHERS THEN
    -- ORA-24344 deja el objeto creado pero inválido. Otros errores de DDL
    -- no autorizan a eliminar un objeto con el mismo nombre.
    IF SQLCODE = -24344 THEN v_created := TRUE; END IF;
    RAISE;
  END;
  SELECT COUNT(*) INTO v_count FROM user_objects
   WHERE object_name = v_name AND object_type = 'FUNCTION' AND status = 'VALID';
  IF v_count <> 1 THEN
    RAISE_APPLICATION_ERROR(-20998, 'La copia de prueba no compilo correctamente.');
  END IF;
  comprobar('Derivada cero en la semilla', 2, -1.000001, -0.4999995);
  comprobar('Raiz proxima al limite inferior', 1, -0.0000011, -0.9999989);
  limpiar;
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('FALLO en test_biseccion: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
  mostrar_errores;
  limpiar;
  RAISE;
END;
/
