-- Tipos SQL necesarios para pasar colecciones a la función independiente.
CREATE OR REPLACE TYPE tir_fechas AS TABLE OF DATE;
/
CREATE OR REPLACE TYPE tir_valores AS TABLE OF NUMBER;
/

/*
  * Función: calcular_tir_no_per
  *
  * Propósito:
  *   Calcula una tasa efectiva anual no periódica que hace cero el valor
  *   presente neto de los flujos de efectivo fechados.
  *
  * Parámetros:
  *   p_fechas     : Colección de fechas de los flujos (tipo tir_fechas).
  *   p_valores    : Colección de importes correspondientes (tipo tir_valores).
  *   p_convencion : Admite ACT/365, ACT/360 y ACT/ACT, sin distinguir mayúsculas
  *                  y después de retirar espacios exteriores. NULL equivale a
  *                  ACT/365. Una cadena formada solo por espacios es inválida.
  *                  La base efectiva del cálculo es siempre ACT/365; este
  *                  parámetro valida la opción y no modifica el denominador.
  *
  * Datos y validaciones:
  *   Las colecciones deben existir y tener igual longitud. Se excluyen pares
  *   cuya fecha o importe sean NULL. Los restantes se ordenan por fecha y,
  *   para fechas iguales, por posición original; no se agrupan. Se requieren
  *   al menos dos flujos, como máximo uno positivo y exactamente un cambio
  *   de signo. Los valores cero no cuentan como cambio de signo.
  *
  * Cálculo:
  *   t_i = (TRUNC(fecha_i) - TRUNC(fecha_1)) / 365
  *   NPV(r) = SUM(valor_i / (1 + r)^t_i)
  *   Se busca NPV(r) = 0 con Newton-Raphson y reducción del paso; si no se
  *   obtiene convergencia, se utiliza bisección con expansión acotada.
  *
  * Parámetros numéricos:
  *   Semilla: constante 0.000001.
  *   Dominio admitido para la raíz interna: -0.999999 < r < 100.
  *   Máximo: 100 iteraciones por método.
  *   Tolerancia de NPV: SUM(ABS(valor_i)) * 1E-18.
  *   Tolerancia absoluta de tasa: 1E-18.
  *   Newton acepta un residuo cero o exige simultáneamente la tolerancia de
  *   NPV y ABS(NPV / derivada) <= 1E-18. Bisección comprueba el residuo y la
  *   amplitud del intervalo. Los cálculos internos utilizan NUMBER.
  *
  * Retorno:
  *   NUMBER: tasa anual expresada en tanto por uno (por ejemplo, 0.1
  *   representa 10 %). Se retorna directamente la tasa calculada, sin
  *   redondeo final. La precisión efectiva depende de Oracle NUMBER y de
  *   las tolerancias de convergencia; el formato lo define el consumidor.
  *
  * Errores mediante RAISE_APPLICATION_ERROR:
  *   -20001: Convención de días inválida.
  *   -20002: Colecciones NULL o de distinta longitud.
  *   -20004: Menos de dos flujos con fecha y valor no nulos.
  *   -20005: Más de un flujo positivo.
  *   -20006: No existe exactamente un cambio de signo, ignorando ceros.
  *   -20007: No se obtiene una solución admitida por los límites y tolerancias.
  *   -20008: NPV identicamente cero; no se determina una tasa unica.
  *   -20999: Error inesperado; incluye SQLERRM y contexto de ejecución.
  *
  *   Alcances y limitaciones:
  *   La hora interviene en el orden y los empates, pero no en el descuento.
  *   Los ceros cuentan como filas y pueden establecer la fecha base.
  *   El único positivo puede preceder o seguir a los negativos.
  *   Las validaciones no garantizan una raíz dentro del dominio permitido.
  *   La agrupación por día solo diagnostica la identidad NPV(r) = 0.
  *   No se aplica redondeo de salida. Las tolerancias son criterios de
  *   aceptación numérica, no una garantía de decimales exactos.
  */
CREATE OR REPLACE FUNCTION calcular_tir_no_per (
    p_fechas     IN tir_fechas,
    p_valores    IN tir_valores,
    p_convencion IN VARCHAR2 DEFAULT 'ACT/365'
) RETURN NUMBER IS
    -- Colecciones paralelas de fechas e importes, indexadas en el mismo orden.
    TYPE t_fecha IS TABLE OF DATE INDEX BY PLS_INTEGER;
    TYPE t_valor IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

    v_fechas        t_fecha;
    v_valores       t_valor;
    v_n             PLS_INTEGER := 0;
    v_fecha_tmp     DATE;
    v_valor_tmp     NUMBER;
    v_j             PLS_INTEGER;
    v_base_date     DATE;
    v_convencion    VARCHAR2(32767);
    v_positivos     PLS_INTEGER := 0;
    -- Identifica las excepciones de negocio emitidas por esta función.
    v_error_negocio BOOLEAN := FALSE;
    v_escala_flujos NUMBER := 0;
    v_tol_npv       NUMBER;
    v_rate          NUMBER;
    v_ok            BOOLEAN := FALSE;
    v_cambios_signo PLS_INTEGER := 0;
    v_ultimo_signo  NUMBER := 0;
    v_tiempos      t_valor;
    v_suma_dia     NUMBER := 0;
    v_dia          DATE;
    v_identidad    BOOLEAN := TRUE;
    e_pf_overflow EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_pf_overflow, -1426);
    v_metodo       VARCHAR2(20) := 'VALIDACION';
    v_iteracion    PLS_INTEGER := 0;

    -- Semilla, tolerancias y límites para la búsqueda de la raíz.
    c_guess         CONSTANT NUMBER      := 0.000001;
    c_tol_rate      CONSTANT NUMBER      := 1E-18;
    c_tol_npv_rel   CONSTANT NUMBER      := 1E-18;
    c_max_iter      CONSTANT PLS_INTEGER := 100;
    c_rate_min      CONSTANT NUMBER      := -0.999999;
    c_rate_max      CONSTANT NUMBER      := 100.0;

    /*
     * Calcula el NPV para la tasa p_r usando fechas sin componente horario.
     * El primer flujo determina la fecha base. Si 1 + p_r <= 0, devuelve
     * el valor centinela 1E30; los métodos de búsqueda restringen las tasas
     * al dominio en el que 1 + p_r es positivo.
     *
     *   Entrada: p_r, tasa anual en tanto por uno.
     *   Usa v_n, v_valores y v_tiempos precalculados en la función principal.
     *   Retorna un residuo monetario firmado; omite importes cero.
     *   Cada evaluación recorre la colección completa.
     */
    FUNCTION f_npv(p_r IN NUMBER) RETURN NUMBER IS
      v_sum  NUMBER := 0;
      v_base NUMBER := 1 + p_r;
      v_t_i  NUMBER;
    BEGIN
      IF v_base <= 0 THEN
        RETURN 1E30;
      END IF;

      FOR i IN 1 .. v_n LOOP
        v_t_i := v_tiempos(i);
        IF v_valores(i) <> 0 THEN
          v_sum := v_sum + v_valores(i) / POWER(v_base, v_t_i);
        END IF;
      END LOOP;

      RETURN v_sum;
    END f_npv;

    /*
     * Calcula la derivada del NPV respecto a r:
     *   SUM(-t_i * valor_i / (1 + r)^(t_i + 1)).
     * Devuelve el centinela -1E30 cuando 1 + p_r <= 0.
     *
     *   Entrada: p_r, tasa anual en tanto por uno.
     *   Retorna la variación del NPV por unidad de tasa.
     *   Los tiempos cero no aportan derivada: su valor presente es constante.
     *   También se omiten los importes cero.
     */
    FUNCTION f_der(p_r IN NUMBER) RETURN NUMBER IS
      v_sum  NUMBER := 0;
      v_base NUMBER := 1 + p_r;
      v_t_i  NUMBER;
    BEGIN
      IF v_base <= 0 THEN
        RETURN -1E30;
      END IF;

      FOR i IN 1 .. v_n LOOP
        v_t_i := v_tiempos(i);
        IF v_valores(i) <> 0 AND v_t_i <> 0 THEN
          v_sum := v_sum - v_t_i * v_valores(i) / POWER(v_base, v_t_i + 1);
        END IF;
      END LOOP;

      RETURN v_sum;
    END f_der;

    /*
     * Evalúa si un candidato satisface los criterios de convergencia.
     * p_f: residuo de la ecuación; p_der: derivada en el candidato;
     * p_tol: tolerancia del residuo, calculada a partir de los importes.
     * Acepta un residuo exactamente cero. En los demás casos exige residuo
     * dentro de tolerancia y corrección estimada ABS(p_f / p_der) <= c_tol_rate.
     * Retorna FALSE ante datos insuficientes o derivada cero con residuo no cero.
     *
     *   La corrección p_f / p_der estima localmente el error de tasa.
     *   Esta rutina no comprueba la pertenencia de la tasa al dominio.
     */
    FUNCTION f_convergio(p_f NUMBER, p_der NUMBER, p_tol NUMBER)
      RETURN BOOLEAN IS
    BEGIN
      IF p_f IS NULL OR p_tol IS NULL THEN
        RETURN FALSE;
      END IF;
      IF p_f = 0 THEN
        RETURN TRUE;
      END IF;
      IF p_der IS NULL OR p_der = 0 THEN
        RETURN FALSE;
      END IF;
      RETURN ABS(p_f) <= p_tol AND ABS(p_f / p_der) <= c_tol_rate;
    END f_convergio;

    /*
     * Busca una raíz desde p_seed. Si la semilla queda fuera de los límites,
     * utiliza c_guess. En cada iteración intenta hasta 20 candidatos del
     * paso, aceptándolo solo si la tasa está en rango y disminuye ABS(NPV).
     * Retorna el último candidato; p_ok indica si satisface la convergencia.
     *
     *   Paso: r_nuevo = r - lambda * NPV(r) / NPV'(r).
     *   Los 20 intentos incluyen el paso completo inicial, con lambda = 1.
     *   Cada intento fallido divide lambda por dos.
     *   Termina si la derivada es cero o no encuentra un paso aceptable.
     *   Captura división por cero y desbordamiento -1426: puede reducir el
     *   paso o devolver p_ok = FALSE para habilitar la bisección.
     *   El candidato retornado solo es solución si p_ok es TRUE.
     */
    FUNCTION f_newton(
        p_seed IN NUMBER,
        p_ok   OUT BOOLEAN
    ) RETURN NUMBER IS
      v_r        NUMBER := p_seed;
      v_npv      NUMBER;
      v_der      NUMBER;
      v_step     NUMBER;
      v_new_r    NUMBER;
      v_new_npv  NUMBER;
      v_lambda   NUMBER;
      v_step_ok  BOOLEAN;
    BEGIN
      p_ok := FALSE;
      v_metodo := 'NEWTON';
      v_iteracion := 0;

      IF v_r <= c_rate_min OR v_r >= c_rate_max THEN
        v_r := c_guess;
      END IF;

      FOR iter IN 1 .. c_max_iter LOOP
        v_iteracion := iter;
        v_npv := f_npv(v_r);

        v_der := f_der(v_r);
        IF f_convergio(v_npv, v_der, v_tol_npv) THEN
          p_ok := TRUE;
          RETURN v_r;
        END IF;

        IF v_der = 0 THEN
          EXIT;
        END IF;

        v_step    := v_npv / v_der;
        v_lambda  := 1.0;
        v_step_ok := FALSE;

        FOR intento IN 1 .. 20 LOOP
          BEGIN
          v_new_r := v_r - v_lambda * v_step;

          IF v_new_r > c_rate_min AND v_new_r < c_rate_max THEN
            v_new_npv := f_npv(v_new_r);

            IF ABS(v_new_npv) < ABS(v_npv) THEN
              v_step_ok := TRUE;
              EXIT;
            END IF;
          END IF;

          EXCEPTION WHEN ZERO_DIVIDE OR e_pf_overflow THEN NULL;
          END;
          v_lambda := v_lambda * 0.5;
        END LOOP;

        IF NOT v_step_ok THEN
          EXIT;
        END IF;

        IF f_convergio(v_new_npv, f_der(v_new_r), v_tol_npv) THEN
          p_ok := TRUE;
          RETURN v_new_r;
        END IF;

        v_r := v_new_r;
      END LOOP;

      p_ok := f_convergio(f_npv(v_r), f_der(v_r), v_tol_npv);
      RETURN v_r;
    EXCEPTION
      WHEN ZERO_DIVIDE OR e_pf_overflow THEN
        p_ok := FALSE;
        RETURN v_r;
    END f_newton;

    /*
     * Busca una raíz por bisección desde el intervalo [-0.99, 2]. Evalúa los
     * extremos y realiza hasta 15 expansiones, limitadas por c_rate_min y
     * c_rate_max, para obtener residuos de signos opuestos.
     * Retorna NULL con p_ok = FALSE si no consigue ese intervalo.
     * Durante la bisección acepta residuo cero o exige simultáneamente
     * semiancho <= c_tol_rate y ABS(NPV) <= v_tol_npv.
     *
     *   Los extremos se comprueban mediante f_convergio.
     *   La expansión mueve el extremo con menor magnitud de residuo;
     *   en caso de empate expande el superior.
     *   Puede evaluar los límites, pero el llamador exige una raíz interior.
     *   No captura localmente excepciones numéricas.
     */
    FUNCTION f_bisection(p_ok OUT BOOLEAN) RETURN NUMBER IS
      v_lo     NUMBER := -0.99;
      v_hi     NUMBER := 2.0;
      v_flo    NUMBER;
      v_fhi    NUMBER;
      v_mid    NUMBER;
      v_fmid   NUMBER;
      v_expand PLS_INTEGER := 0;
    BEGIN
      p_ok  := FALSE;
      v_metodo := 'BISECCION';
      v_iteracion := 0;
      v_flo := f_npv(v_lo);
      v_fhi := f_npv(v_hi);

      IF f_convergio(v_flo, f_der(v_lo), v_tol_npv) THEN
        p_ok := TRUE;
        RETURN v_lo;
      ELSIF f_convergio(v_fhi, f_der(v_hi), v_tol_npv) THEN
        p_ok := TRUE;
        RETURN v_hi;
      END IF;

      WHILE SIGN(v_flo) = SIGN(v_fhi) AND v_expand < 15 LOOP
        IF ABS(v_flo) < ABS(v_fhi) THEN
          v_lo  := GREATEST(c_rate_min, v_lo - (1 + v_lo) * 0.5);
          v_flo := f_npv(v_lo);
        ELSE
          v_hi  := LEAST(c_rate_max, v_hi * 2.0);
          v_fhi := f_npv(v_hi);
        END IF;

        IF f_convergio(v_flo, f_der(v_lo), v_tol_npv) THEN
          p_ok := TRUE;
          RETURN v_lo;
        ELSIF f_convergio(v_fhi, f_der(v_hi), v_tol_npv) THEN
          p_ok := TRUE;
          RETURN v_hi;
        END IF;

        v_expand := v_expand + 1;
      END LOOP;

      IF SIGN(v_flo) = SIGN(v_fhi) THEN
        RETURN NULL;
      END IF;

      FOR iter IN 1 .. c_max_iter LOOP
        v_iteracion := iter;
        v_mid  := v_lo + (v_hi - v_lo) / 2.0;
        v_fmid := f_npv(v_mid);

        IF v_fmid = 0 OR ((v_hi - v_lo) / 2 <= c_tol_rate
           AND ABS(v_fmid) <= v_tol_npv) THEN
          p_ok := TRUE;
          RETURN v_mid;
        END IF;

        IF SIGN(v_fmid) = SIGN(v_flo) THEN
          v_lo  := v_mid;
          v_flo := v_fmid;
        ELSE
          v_hi  := v_mid;
          v_fhi := v_fmid;
        END IF;
      END LOOP;

      p_ok := v_fmid = 0 OR ((v_hi - v_lo) <= 2 * c_tol_rate
              AND ABS(v_fmid) <= v_tol_npv);
      RETURN v_mid;
    END f_bisection;
  BEGIN

    -- Validar la convención; la ecuación utiliza siempre una base de 365 días.
    v_convencion := UPPER(TRIM(NVL(p_convencion, 'ACT/365')));

    IF v_convencion IS NULL OR v_convencion NOT IN ('ACT/365', 'ACT/360', 'ACT/ACT') THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(
        -20001,
        'Convencion de dias no soportada: ' || NVL(SUBSTR(p_convencion, 1, 100), '<NULL>')
      );
    END IF;

    -- Validar las colecciones y conservar solamente los pares completos.
    IF p_fechas IS NULL OR p_valores IS NULL THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20002, 'TIR: las colecciones de fechas y valores no pueden ser NULL.');
    END IF;
    IF p_fechas.COUNT <> p_valores.COUNT THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20002, 'TIR: fechas y valores deben tener igual cantidad de elementos.');
    END IF;

    FOR i IN 1 .. p_fechas.COUNT LOOP
      IF p_fechas(i) IS NOT NULL AND p_valores(i) IS NOT NULL THEN
        v_n := v_n + 1;
        v_fechas(v_n) := p_fechas(i);
        v_valores(v_n) := p_valores(i);
      END IF;
    END LOOP;

    -- Ordenación estable: ante fechas iguales se conserva la posición de entrada.
    FOR i IN 2 .. v_n LOOP
      v_fecha_tmp := v_fechas(i);
      v_valor_tmp := v_valores(i);
      v_j := i - 1;
      WHILE v_j >= 1 LOOP
        EXIT WHEN v_fechas(v_j) <= v_fecha_tmp;
        v_fechas(v_j + 1) := v_fechas(v_j);
        v_valores(v_j + 1) := v_valores(v_j);
        v_j := v_j - 1;
      END LOOP;
      v_fechas(v_j + 1) := v_fecha_tmp;
      v_valores(v_j + 1) := v_valor_tmp;
    END LOOP;

    -- Comprobar el número de flujos y establecer la fecha de referencia.
    IF v_n < 2 THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20004, 'TIR: se requieren al menos dos flujos con fecha y valor validos.');
    END IF;

    v_base_date := TRUNC(v_fechas(1));

    -- Medir la escala monetaria y contar positivos y cambios de signo.
    FOR i IN 1 .. v_n LOOP
      IF v_valores(i) > 0 THEN
        v_positivos := v_positivos + 1;
      END IF;
      v_escala_flujos := v_escala_flujos + ABS(v_valores(i));

      IF v_valores(i) <> 0 THEN
        IF v_ultimo_signo <> 0
           AND SIGN(v_valores(i)) <> v_ultimo_signo THEN
          v_cambios_signo := v_cambios_signo + 1;
        END IF;

        v_ultimo_signo := SIGN(v_valores(i));
      END IF;
    END LOOP;

    IF v_positivos > 1 THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20005, 'TIR: se admite como maximo un flujo positivo.');
    END IF;
    IF v_cambios_signo = 0 THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20006, 'TIR: debe existir un cambio de signo, ignorando ceros.');
    ELSIF v_cambios_signo > 1 THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20006, 'TIR: no se admite mas de un cambio de signo, ignorando ceros.');
    END IF;

    -- Agrupacion SOLO diagnostica: detectar NPV identicamente cero por fecha
    -- truncada. Los flujos originales y su orden siguen intactos para el calculo.
    v_dia := TRUNC(v_fechas(1));
    FOR i IN 1 .. v_n LOOP
      v_tiempos(i) := (TRUNC(v_fechas(i)) - v_base_date) / 365.0;
      IF TRUNC(v_fechas(i)) <> v_dia THEN
        IF v_suma_dia <> 0 THEN v_identidad := FALSE; END IF;
        v_suma_dia := 0;
        v_dia := TRUNC(v_fechas(i));
      END IF;
      v_suma_dia := v_suma_dia + v_valores(i);
    END LOOP;
    IF v_suma_dia <> 0 THEN v_identidad := FALSE; END IF;
    IF v_identidad THEN
      v_error_negocio := TRUE;
      RAISE_APPLICATION_ERROR(-20008, 'TIR indeterminada: NPV cero para cualquier tasa.');
    END IF;

    -- La tolerancia de NPV es proporcional a la suma de importes absolutos.
    v_tol_npv := v_escala_flujos * c_tol_npv_rel;

    -- Resolver con Newton y recurrir a bisección si no hay convergencia.
    v_rate := f_newton(c_guess, v_ok);

    IF NOT v_ok OR v_rate IS NULL THEN
      v_rate := f_bisection(v_ok);
    END IF;

    -- Validar el candidato y devolver la tasa sin redondeo final.
    IF v_ok
       AND v_rate IS NOT NULL
       AND v_rate > c_rate_min
       AND v_rate < c_rate_max
       AND ABS(f_npv(v_rate)) <= v_tol_npv THEN
      RETURN v_rate;
    END IF;

    v_error_negocio := TRUE;
    RAISE_APPLICATION_ERROR(-20007, 'TIR: no se obtuvo una solucion valida dentro de los limites y tolerancias establecidos. Metodo=' || v_metodo || ', Iter=' || v_iteracion);
  EXCEPTION
    WHEN OTHERS THEN
      -- Propagar los errores propios; envolver los inesperados con su contexto.
      IF v_error_negocio OR SQLCODE = -20999 THEN
        RAISE;
      END IF;

      RAISE_APPLICATION_ERROR(
        -20999,
        SUBSTRB(
          'Error en calcular_tir_no_per: '
          || SQLERRM || ' | Metodo:' || v_metodo || ', Iter:' || v_iteracion || ' | Backtrace: ' || DBMS_UTILITY.format_error_backtrace,
          1,
          1900
        ),
        TRUE
      );
END calcular_tir_no_per;
/