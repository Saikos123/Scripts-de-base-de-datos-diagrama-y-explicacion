-- Migración incremental del alcance Proyecto 1 [Alpha].
-- Aplicar una sola vez sobre una copia de respaldo de la base ya existente.
-- No elimina ni reescribe datos históricos de obras, compras o movimientos.
BEGIN;

CREATE TABLE IF NOT EXISTS contactos_proveedor (
    id SERIAL PRIMARY KEY,
    proveedor_id INT NOT NULL REFERENCES proveedores(id) ON DELETE RESTRICT,
    nombre VARCHAR(150) NOT NULL CHECK (length(trim(nombre)) > 0),
    cargo VARCHAR(100),
    correo VARCHAR(254),
    telefono VARCHAR(30),
    es_principal BOOLEAN NOT NULL DEFAULT FALSE,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (correo IS NULL OR correo ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_contacto_principal_proveedor
    ON contactos_proveedor(proveedor_id) WHERE es_principal AND activo;
CREATE INDEX IF NOT EXISTS idx_contactos_proveedor
    ON contactos_proveedor(proveedor_id, activo);

CREATE TABLE IF NOT EXISTS cuentas_bancarias_proveedor (
    id SERIAL PRIMARY KEY,
    proveedor_id INT NOT NULL REFERENCES proveedores(id) ON DELETE RESTRICT,
    titular VARCHAR(150) NOT NULL CHECK (length(trim(titular)) > 0),
    rut_titular VARCHAR(12),
    banco VARCHAR(100) NOT NULL CHECK (length(trim(banco)) > 0),
    tipo_cuenta VARCHAR(40) NOT NULL CHECK (length(trim(tipo_cuenta)) > 0),
    numero_cuenta VARCHAR(80) NOT NULL CHECK (length(trim(numero_cuenta)) > 0),
    es_principal BOOLEAN NOT NULL DEFAULT FALSE,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (rut_titular IS NULL OR (
        rut_titular = UPPER(TRIM(rut_titular))
        AND rut_titular ~ '^[0-9]{7,8}-[0-9K]$'
        AND fn_validar_rut_chileno(rut_titular)
    ))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cuenta_principal_proveedor
    ON cuentas_bancarias_proveedor(proveedor_id) WHERE es_principal AND activo;
CREATE INDEX IF NOT EXISTS idx_cuentas_bancarias_proveedor
    ON cuentas_bancarias_proveedor(proveedor_id, activo);

CREATE TABLE IF NOT EXISTS clientes (
    id SERIAL PRIMARY KEY,
    rut VARCHAR(12) UNIQUE,
    razon_social VARCHAR(150) NOT NULL CHECK (length(trim(razon_social)) > 0),
    giro VARCHAR(150),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (rut IS NULL OR (
        rut = UPPER(TRIM(rut))
        AND rut ~ '^[0-9]{7,8}-[0-9K]$'
        AND fn_validar_rut_chileno(rut)
    ))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cliente_sin_rut
    ON clientes (lower(trim(razon_social))) WHERE rut IS NULL;

ALTER TABLE obras
    ADD COLUMN IF NOT EXISTS cliente_id INT REFERENCES clientes(id) ON DELETE RESTRICT;

INSERT INTO clientes (razon_social)
SELECT DISTINCT trim(o.cliente)
FROM obras o
WHERE o.cliente IS NOT NULL AND length(trim(o.cliente)) > 0
ON CONFLICT DO NOTHING;

UPDATE obras o
SET cliente_id = c.id
FROM clientes c
WHERE o.cliente_id IS NULL
  AND o.cliente IS NOT NULL
  AND lower(trim(o.cliente)) = lower(trim(c.razon_social));

ALTER TABLE facturas_proveedor
    ADD COLUMN IF NOT EXISTS documento_origen_id INT
    REFERENCES facturas_proveedor(id) ON DELETE RESTRICT;

ALTER TABLE facturas_proveedor
    DROP CONSTRAINT IF EXISTS chk_documento_origen_tipo;
ALTER TABLE facturas_proveedor
    ADD CONSTRAINT chk_documento_origen_tipo CHECK (
        (documento_origen_id IS NULL OR tipo_documento IN ('FACTURA', 'NOTA_CREDITO'))
        AND (tipo_documento <> 'GUIA_DESPACHO' OR documento_origen_id IS NULL)
    );

CREATE UNIQUE INDEX IF NOT EXISTS uq_factura_por_guia
    ON facturas_proveedor(documento_origen_id)
    WHERE tipo_documento = 'FACTURA' AND documento_origen_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documentos_origen
    ON facturas_proveedor(documento_origen_id) WHERE documento_origen_id IS NOT NULL;

ALTER TABLE detalle_factura
    ADD COLUMN IF NOT EXISTS detalle_guia_id INT
    REFERENCES detalle_factura(id) ON DELETE RESTRICT;
ALTER TABLE detalle_factura
    ADD COLUMN IF NOT EXISTS detalle_documento_origen_id INT
    REFERENCES detalle_factura(id) ON DELETE RESTRICT;
ALTER TABLE detalle_factura
    DROP CONSTRAINT IF EXISTS chk_detalle_origenes_mutuamente_excluyentes;
ALTER TABLE detalle_factura
    ADD CONSTRAINT chk_detalle_origenes_mutuamente_excluyentes CHECK (
        detalle_guia_id IS NULL OR detalle_documento_origen_id IS NULL
    );

CREATE UNIQUE INDEX IF NOT EXISTS uq_detalle_factura_guia
    ON detalle_factura(detalle_guia_id) WHERE detalle_guia_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_detalle_factura_factura
    ON detalle_factura(factura_id);
CREATE INDEX IF NOT EXISTS idx_detalle_factura_documento_origen
    ON detalle_factura(detalle_documento_origen_id)
    WHERE detalle_documento_origen_id IS NOT NULL;

ALTER TABLE cardex DROP CONSTRAINT IF EXISTS cardex_tipo_movimiento_check;
ALTER TABLE cardex ADD CONSTRAINT cardex_tipo_movimiento_check
    CHECK (tipo_movimiento IN (
        'SALDO_INICIAL', 'ENTRADA_COMPRA', 'SALIDA_OBRA', 'AJUSTE_MERMA',
        'DEVOLUCION_OBRA', 'DEVOLUCION_PROVEEDOR', 'USO_INTERNO',
        'AJUSTE_ENTRADA', 'AJUSTE_SALIDA', 'AJUSTE_VALORIZACION'
    ));
ALTER TABLE cardex DROP CONSTRAINT IF EXISTS chk_cardex_movimiento_coherente;
ALTER TABLE cardex ADD CONSTRAINT chk_cardex_movimiento_coherente CHECK (
    (
        tipo_movimiento IN ('SALDO_INICIAL', 'ENTRADA_COMPRA', 'DEVOLUCION_OBRA', 'AJUSTE_ENTRADA')
        AND cantidad_entrada > 0 AND cantidad_salida = 0
    ) OR (
        tipo_movimiento IN ('SALIDA_OBRA', 'AJUSTE_MERMA', 'DEVOLUCION_PROVEEDOR', 'USO_INTERNO', 'AJUSTE_SALIDA')
        AND cantidad_salida > 0 AND cantidad_entrada = 0
    ) OR (
        tipo_movimiento = 'AJUSTE_VALORIZACION'
        AND cantidad_entrada = 0 AND cantidad_salida = 0
    )
);

CREATE TABLE IF NOT EXISTS devoluciones_proveedor (
    id SERIAL PRIMARY KEY,
    nota_credito_id INT NOT NULL REFERENCES facturas_proveedor(id) ON DELETE RESTRICT,
    detalle_nota_id INT NOT NULL UNIQUE REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    detalle_compra_origen_id INT NOT NULL REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    movimiento_cardex_id INT NOT NULL UNIQUE REFERENCES cardex(id) ON DELETE RESTRICT,
    cantidad DECIMAL(12,3) NOT NULL CHECK (cantidad > 0),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS auditoria_cuentas_bancarias (
    id BIGSERIAL PRIMARY KEY,
    cuenta_id INT NOT NULL,
    proveedor_id INT NOT NULL,
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    accion VARCHAR(10) NOT NULL CHECK (accion IN ('CREAR', 'ACTUALIZAR')),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Definiciones de funciones sincronizadas desde el script fuente.
CREATE OR REPLACE FUNCTION fn_validar_detalle_documento_origen()
RETURNS TRIGGER AS $$
DECLARE
    v_tipo_documento VARCHAR(20);
    v_documento_origen_id INT;
    v_tipo_guia VARCHAR(20);
    v_estado_guia VARCHAR(12);
    v_articulo_guia INT;
    v_cantidad_guia DECIMAL(12,3);
    v_factura_origen_id INT;
    v_articulo_compra INT;
    v_cantidad_compra DECIMAL(12,3);
BEGIN
    SELECT tipo_documento, documento_origen_id
    INTO v_tipo_documento, v_documento_origen_id
    FROM facturas_proveedor
    WHERE id = NEW.factura_id;

    IF v_tipo_documento = 'FACTURA' AND v_documento_origen_id IS NOT NULL THEN
        SELECT g.tipo_documento, g.estado, gd.articulo_id, gd.cantidad, gd.factura_id
        INTO v_tipo_guia, v_estado_guia, v_articulo_guia, v_cantidad_guia, v_factura_origen_id
        FROM detalle_factura gd
        JOIN facturas_proveedor g ON g.id = gd.factura_id
        WHERE gd.id = NEW.detalle_guia_id;

        IF NEW.detalle_guia_id IS NULL OR NOT FOUND
           OR v_tipo_guia <> 'GUIA_DESPACHO'
           OR v_estado_guia <> 'REGISTRADA'
           OR v_documento_origen_id IS DISTINCT FROM v_factura_origen_id
           OR NEW.articulo_id <> v_articulo_guia
           OR NEW.cantidad <> v_cantidad_guia THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: El detalle de factura no coincide con su detalle de guía.';
        END IF;
    ELSIF v_tipo_documento = 'NOTA_CREDITO' THEN
        SELECT factura_id, articulo_id, cantidad
        INTO v_factura_origen_id, v_articulo_compra, v_cantidad_compra
        FROM detalle_factura
        WHERE id = NEW.detalle_documento_origen_id;

        IF NEW.detalle_documento_origen_id IS NULL OR NOT FOUND
           OR v_documento_origen_id IS DISTINCT FROM v_factura_origen_id
           OR NEW.articulo_id <> v_articulo_compra
           OR NEW.cantidad > v_cantidad_compra THEN
            RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: El detalle de nota no coincide con su compra de origen.';
        END IF;
    ELSIF NEW.detalle_guia_id IS NOT NULL
       OR NEW.detalle_documento_origen_id IS NOT NULL
       OR (v_tipo_documento = 'FACTURA' AND v_documento_origen_id IS NOT NULL)
       OR v_tipo_documento = 'NOTA_CREDITO' THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: El documento requiere un detalle de origen válido.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_generar_hash_cardex()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));
    NEW.hash_integridad := fn_calcular_hash_cardex(
        NEW.articulo_id, NEW.usuario_id, NEW.tipo_movimiento,
        NEW.cantidad_entrada, NEW.cantidad_salida, NEW.saldo_stock,
        NEW.costo_unitario, NEW.saldo_valorizado, NEW.factura_detalle_id,
        NEW.detalle_egreso_id, NEW.obra_id, NEW.reversa_de_id,
        NEW.tecnico_receptor_id, NEW.motivo, NEW.referencia_externa,
        NEW.documento_referencia, NEW.fecha_registro
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

DROP TRIGGER IF EXISTS trg_generar_hash_cardex ON cardex;
CREATE TRIGGER trg_generar_hash_cardex
BEFORE INSERT ON cardex
FOR EACH ROW EXECUTE FUNCTION fn_generar_hash_cardex();

CREATE OR REPLACE FUNCTION fn_verificar_integridad_cardex()
RETURNS TABLE (
    integro BOOLEAN,
    primer_movimiento_id INT,
    hash_esperado VARCHAR(64),
    hash_registrado VARCHAR(64)
) AS $$
DECLARE
    v_movimiento cardex%ROWTYPE;
    v_hash_previo VARCHAR(64) := 'GENESIS_FYAG_ALPHA_2026';
    v_hash_esperado VARCHAR(64);
    v_payload TEXT;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    FOR v_movimiento IN SELECT * FROM cardex ORDER BY id
    LOOP
        v_payload := v_hash_previo || '|' || jsonb_build_object(
            'articulo_id', v_movimiento.articulo_id,
            'usuario_id', v_movimiento.usuario_id,
            'tipo_movimiento', v_movimiento.tipo_movimiento,
            'cantidad_entrada', v_movimiento.cantidad_entrada,
            'cantidad_salida', v_movimiento.cantidad_salida,
            'saldo_stock', v_movimiento.saldo_stock,
            'costo_unitario', v_movimiento.costo_unitario,
            'saldo_valorizado', v_movimiento.saldo_valorizado,
            'factura_detalle_id', v_movimiento.factura_detalle_id,
            'detalle_egreso_id', v_movimiento.detalle_egreso_id,
            'obra_id', v_movimiento.obra_id,
            'reversa_de_id', v_movimiento.reversa_de_id,
            'tecnico_receptor_id', v_movimiento.tecnico_receptor_id,
            'motivo', v_movimiento.motivo,
            'referencia_externa', v_movimiento.referencia_externa,
            'documento_referencia', v_movimiento.documento_referencia,
            'fecha_utc', to_char(
                v_movimiento.fecha_registro AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.US'
            )
        )::TEXT;
        v_hash_esperado := encode(digest(v_payload, 'sha256'), 'hex');

        IF v_movimiento.hash_integridad IS DISTINCT FROM v_hash_esperado THEN
            RETURN QUERY SELECT
                FALSE, v_movimiento.id, v_hash_esperado, v_movimiento.hash_integridad;
            RETURN;
        END IF;

        v_hash_previo := v_movimiento.hash_integridad;
    END LOOP;

    RETURN QUERY SELECT TRUE, NULL::INT, NULL::VARCHAR(64), NULL::VARCHAR(64);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION fn_stock_pendiente_guia(p_articulo_id INT)
RETURNS DECIMAL(12,3) AS $$
    SELECT COALESCE(SUM(gd.cantidad - COALESCE((
        SELECT SUM(fd.cantidad)
        FROM detalle_factura fd
        JOIN facturas_proveedor f ON f.id = fd.factura_id
        WHERE fd.detalle_guia_id = gd.id
          AND f.estado = 'REGISTRADA'
    ), 0)), 0)::DECIMAL(12,3)
    FROM detalle_factura gd
    JOIN facturas_proveedor g ON g.id = gd.factura_id
    WHERE g.tipo_documento = 'GUIA_DESPACHO'
      AND g.estado = 'REGISTRADA'
      AND gd.articulo_id = p_articulo_id
$$ LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_proteger_stock_guia_pendiente()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_actual < OLD.stock_actual
       AND NEW.stock_actual < fn_stock_pendiente_guia(OLD.id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-STOCK]: El stock no puede quedar por debajo de las cantidades reservadas por guías sin factura.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_registrar_recepcion_guia(
    p_guia_id INT,
    p_lineas JSONB
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_guia facturas_proveedor%ROWTYPE;
    v_linea JSONB;
    v_articulo_id INT;
    v_cantidad DECIMAL(12,3);
    v_precio DECIMAL(12,2);
    v_descuento_1 DECIMAL(5,2);
    v_descuento_2 DECIMAL(5,2);
    v_descuento_3 DECIMAL(5,2);
    v_precio_neto DECIMAL(12,2);
    v_detalle_id INT;
    v_stock DECIMAL(12,3);
    v_costo DECIMAL(12,2);
    v_nuevo_stock DECIMAL(12,3);
    v_nuevo_pmp DECIMAL(12,2);
    v_saldo_valorizado DECIMAL(12,2);
    v_fecha TIMESTAMPTZ;
    v_hash VARCHAR(64);
    v_bruto DECIMAL(12,2) := 0;
    v_neto DECIMAL(12,2) := 0;
    v_descuento DECIMAL(12,2);
    v_documento_referencia VARCHAR(100);
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    IF p_guia_id IS NULL OR p_lineas IS NULL
       OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Se requiere una guía y líneas en formato array.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Se requiere una guía y al menos una línea válida.';
    END IF;

    SELECT * INTO v_guia
    FROM facturas_proveedor
    WHERE id = p_guia_id
    FOR UPDATE;

    IF NOT FOUND OR v_guia.tipo_documento <> 'GUIA_DESPACHO'
       OR v_guia.documento_origen_id IS NOT NULL
       OR v_guia.estado <> 'BORRADOR'
       OR v_guia.usuario_id <> v_actor_id THEN
        RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Guía inexistente, no está en borrador o no pertenece al actor.';
    END IF;
    IF EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_guia_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-GUIA]: La guía ya contiene líneas.';
    END IF;

    v_fecha := clock_timestamp();
    v_documento_referencia := 'GUIA_DESPACHO:' || v_guia.numero_factura;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        v_articulo_id := (v_linea ->> 'articulo_id')::INT;
        v_cantidad := (v_linea ->> 'cantidad')::DECIMAL(12,3);
        v_precio := (v_linea ->> 'precio_unitario')::DECIMAL(12,2);
        v_descuento_1 := COALESCE((v_linea ->> 'descuento_1_pct')::DECIMAL(5,2), 0);
        v_descuento_2 := COALESCE((v_linea ->> 'descuento_2_pct')::DECIMAL(5,2), 0);
        v_descuento_3 := COALESCE((v_linea ->> 'descuento_3_pct')::DECIMAL(5,2), 0);

        IF v_articulo_id IS NULL OR v_cantidad IS NULL OR v_cantidad <= 0
           OR v_precio IS NULL OR v_precio < 0
           OR v_descuento_1 NOT BETWEEN 0 AND 100
           OR v_descuento_2 NOT BETWEEN 0 AND 100
           OR v_descuento_3 NOT BETWEEN 0 AND 100 THEN
            RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Cantidad, costo provisional o descuentos inválidos.';
        END IF;

        v_precio_neto := ROUND(
            v_precio * (1 - v_descuento_1 / 100)
            * (1 - v_descuento_2 / 100) * (1 - v_descuento_3 / 100), 2
        );

        SELECT stock_actual, costo_promedio_ponderado
        INTO v_stock, v_costo
        FROM articulos
        WHERE id = v_articulo_id AND activo
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Artículo inexistente o inactivo (%).', v_articulo_id;
        END IF;

        INSERT INTO detalle_factura (
            factura_id, articulo_id, cantidad, precio_unitario,
            precio_unitario_neto, subtotal, subtotal_neto, descuento_1_pct,
            descuento_2_pct, descuento_3_pct
        ) VALUES (
            p_guia_id, v_articulo_id, v_cantidad, v_precio,
            v_precio_neto, ROUND(v_cantidad * v_precio, 2),
            ROUND(v_cantidad * v_precio_neto, 2),
            v_descuento_1, v_descuento_2, v_descuento_3
        ) RETURNING id INTO v_detalle_id;

        v_nuevo_stock := v_stock + v_cantidad;
        v_nuevo_pmp := ROUND(
            ((v_stock * v_costo) + (v_cantidad * v_precio_neto)) / v_nuevo_stock, 2
        );
        v_saldo_valorizado := ROUND(v_nuevo_stock * v_nuevo_pmp, 2);

        UPDATE articulos
        SET stock_actual = v_nuevo_stock, costo_promedio_ponderado = v_nuevo_pmp
        WHERE id = v_articulo_id;

        v_hash := fn_calcular_hash_cardex(
            v_articulo_id, v_actor_id, 'ENTRADA_COMPRA', v_cantidad, 0,
            v_nuevo_stock, v_precio_neto, v_saldo_valorizado, v_detalle_id,
            NULL, NULL, NULL, NULL, 'Recepción provisional por guía', NULL,
            v_documento_referencia, v_fecha
        );

        INSERT INTO cardex (
            articulo_id, usuario_id, factura_detalle_id, fecha_registro,
            tipo_movimiento, cantidad_entrada, cantidad_salida, saldo_stock,
            costo_unitario, saldo_valorizado, documento_referencia, motivo,
            hash_integridad
        ) VALUES (
            v_articulo_id, v_actor_id, v_detalle_id, v_fecha,
            'ENTRADA_COMPRA', v_cantidad, 0, v_nuevo_stock, v_precio_neto,
            v_saldo_valorizado, v_documento_referencia,
            'Recepción provisional por guía', v_hash
        );

        v_bruto := v_bruto + ROUND(v_cantidad * v_precio, 2);
        v_neto := v_neto + ROUND(v_cantidad * v_precio_neto, 2);
    END LOOP;

    v_descuento := v_bruto - v_neto;
    IF v_guia.monto_bruto <> v_bruto
       OR v_guia.descuento_cascada <> v_descuento
       OR v_guia.monto_neto <> v_neto
       OR v_guia.iva <> ROUND(v_neto * v_guia.tasa_iva_pct / 100, 2)
       OR v_guia.monto_total <> v_neto + v_guia.iva THEN
        RAISE EXCEPTION 'ERROR [FYAG-GUIA]: Los totales de la guía no cuadran con sus líneas.';
    END IF;

    UPDATE facturas_proveedor SET estado = 'REGISTRADA'
    WHERE id = p_guia_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION fn_guardar_cuenta_bancaria_proveedor(
    p_proveedor_id INT,
    p_titular VARCHAR(150),
    p_rut_titular VARCHAR(12),
    p_banco VARCHAR(100),
    p_tipo_cuenta VARCHAR(40),
    p_numero_cuenta VARCHAR(80),
    p_es_principal BOOLEAN DEFAULT FALSE,
    p_cuenta_id INT DEFAULT NULL
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_cuenta_id INT;
    v_accion VARCHAR(10);
BEGIN
    v_actor_id := fn_exigir_permiso('proveedores.administrar');
    IF p_proveedor_id IS NULL OR p_titular IS NULL OR length(trim(p_titular)) = 0
       OR p_banco IS NULL OR length(trim(p_banco)) = 0
       OR p_tipo_cuenta IS NULL OR length(trim(p_tipo_cuenta)) = 0
       OR p_numero_cuenta IS NULL OR length(trim(p_numero_cuenta)) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-PROVEEDOR]: Faltan datos obligatorios de la cuenta bancaria.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id = p_proveedor_id AND activo) THEN
        RAISE EXCEPTION 'ERROR [FYAG-PROVEEDOR]: Proveedor inexistente o inactivo (%).', p_proveedor_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('fyag_proveedor_banco_' || p_proveedor_id::TEXT));
    IF COALESCE(p_es_principal, FALSE) THEN
        INSERT INTO auditoria_cuentas_bancarias (
            cuenta_id, proveedor_id, usuario_id, accion
        )
        SELECT id, proveedor_id, v_actor_id, 'ACTUALIZAR'
        FROM cuentas_bancarias_proveedor
        WHERE proveedor_id = p_proveedor_id
          AND es_principal
          AND id IS DISTINCT FROM p_cuenta_id;

        UPDATE cuentas_bancarias_proveedor
        SET es_principal = FALSE
        WHERE proveedor_id = p_proveedor_id AND es_principal;
    END IF;

    IF p_cuenta_id IS NULL THEN
        INSERT INTO cuentas_bancarias_proveedor (
            proveedor_id, titular, rut_titular, banco, tipo_cuenta,
            numero_cuenta, es_principal
        ) VALUES (
            p_proveedor_id, trim(p_titular), NULLIF(trim(p_rut_titular), ''),
            trim(p_banco), trim(p_tipo_cuenta), trim(p_numero_cuenta),
            COALESCE(p_es_principal, FALSE)
        ) RETURNING id INTO v_cuenta_id;
        v_accion := 'CREAR';
    ELSE
        UPDATE cuentas_bancarias_proveedor
        SET titular = trim(p_titular),
            rut_titular = NULLIF(trim(p_rut_titular), ''),
            banco = trim(p_banco),
            tipo_cuenta = trim(p_tipo_cuenta),
            numero_cuenta = trim(p_numero_cuenta),
            es_principal = COALESCE(p_es_principal, FALSE),
            activo = TRUE
        WHERE id = p_cuenta_id AND proveedor_id = p_proveedor_id
        RETURNING id INTO v_cuenta_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-PROVEEDOR]: Cuenta no encontrada para el proveedor indicado.';
        END IF;
        v_accion := 'ACTUALIZAR';
    END IF;

    INSERT INTO auditoria_cuentas_bancarias (
        cuenta_id, proveedor_id, usuario_id, accion
    ) VALUES (v_cuenta_id, p_proveedor_id, v_actor_id, v_accion);
    RETURN v_cuenta_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_listar_cuentas_bancarias_proveedor(p_proveedor_id INT)
RETURNS TABLE (
    id INT,
    proveedor_id INT,
    titular VARCHAR(150),
    rut_titular VARCHAR(12),
    banco VARCHAR(100),
    tipo_cuenta VARCHAR(40),
    numero_cuenta VARCHAR(80),
    es_principal BOOLEAN,
    activo BOOLEAN,
    creado_en TIMESTAMPTZ
) AS $$
BEGIN
    PERFORM fn_exigir_permiso('proveedores.administrar');
    RETURN QUERY
    SELECT c.id, c.proveedor_id, c.titular, c.rut_titular, c.banco,
           c.tipo_cuenta, c.numero_cuenta, c.es_principal, c.activo, c.creado_en
    FROM cuentas_bancarias_proveedor c
    WHERE c.proveedor_id = p_proveedor_id
    ORDER BY c.es_principal DESC, c.id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_crear_factura_proveedor(
    p_proveedor_id INT,
    p_tipo_documento VARCHAR(20),
    p_numero_documento VARCHAR(50),
    p_fecha_emision DATE,
    p_monto_bruto DECIMAL(12,2),
    p_descuento DECIMAL(12,2),
    p_monto_neto DECIMAL(12,2),
    p_tasa_iva DECIMAL(5,2),
    p_iva DECIMAL(12,2),
    p_monto_total DECIMAL(12,2),
    p_datos_dte JSONB DEFAULT '{}'::jsonb
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_factura_id INT;
    v_proveedor_rut VARCHAR(12);
    v_proveedor_nombre VARCHAR(150);
    v_documento_origen_id INT;
    v_tipo_origen VARCHAR(20);
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    SELECT rut, razon_social
    INTO v_proveedor_rut, v_proveedor_nombre
    FROM proveedores
    WHERE id = p_proveedor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Proveedor inexistente (%).', p_proveedor_id;
    END IF;
    IF p_tipo_documento = 'NOTA_CREDITO'
       OR (p_tipo_documento = 'FACTURA'
           AND COALESCE(p_datos_dte, '{}'::jsonb) ? 'documento_origen_id') THEN
        BEGIN
            v_documento_origen_id :=
                NULLIF(p_datos_dte ->> 'documento_origen_id', '')::INT;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: documento_origen_id debe ser un entero.';
        END;

        IF v_documento_origen_id IS NULL THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: El documento requiere documento_origen_id.';
        END IF;

        SELECT tipo_documento INTO v_tipo_origen
        FROM facturas_proveedor
        WHERE id = v_documento_origen_id
          AND proveedor_id = p_proveedor_id
          AND estado = 'REGISTRADA'
        FOR UPDATE;

        IF NOT FOUND
           OR (p_tipo_documento = 'NOTA_CREDITO'
               AND v_tipo_origen NOT IN ('FACTURA', 'BOLETA'))
           OR (p_tipo_documento = 'FACTURA'
               AND v_tipo_origen <> 'GUIA_DESPACHO') THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Documento de origen inexistente, no registrado o de tipo incompatible.';
        END IF;
    END IF;
    INSERT INTO facturas_proveedor (
        proveedor_id, proveedor_rut_documento, proveedor_razon_social_documento,
        usuario_id, tipo_documento, documento_origen_id, numero_factura,
        fecha_emision, monto_bruto, descuento_cascada, monto_neto,
        tasa_iva_pct, iva, monto_total, datos_dte
    ) VALUES (
        p_proveedor_id, v_proveedor_rut, v_proveedor_nombre,
        v_actor_id, p_tipo_documento, v_documento_origen_id, p_numero_documento,
        p_fecha_emision, p_monto_bruto, p_descuento, p_monto_neto,
        p_tasa_iva, p_iva, p_monto_total, COALESCE(p_datos_dte, '{}'::jsonb)
    ) RETURNING id INTO v_factura_id;
    RETURN v_factura_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_asociar_factura_guia(
    p_factura_id INT,
    p_guia_id INT
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_factura facturas_proveedor%ROWTYPE;
    v_guia facturas_proveedor%ROWTYPE;
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    SELECT * INTO v_factura
    FROM facturas_proveedor
    WHERE id = p_factura_id
    FOR UPDATE;
    SELECT * INTO v_guia
    FROM facturas_proveedor
    WHERE id = p_guia_id
    FOR UPDATE;

    IF v_factura.id IS NULL OR v_guia.id IS NULL
       OR v_factura.tipo_documento <> 'FACTURA'
       OR v_factura.estado <> 'BORRADOR'
       OR v_factura.usuario_id <> v_actor_id
       OR v_factura.documento_origen_id IS NOT NULL
       OR v_guia.tipo_documento <> 'GUIA_DESPACHO'
       OR v_guia.estado <> 'REGISTRADA'
       OR v_factura.proveedor_id <> v_guia.proveedor_id
       OR EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_factura_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: No se puede asociar la factura a esa guía.';
    END IF;

    UPDATE facturas_proveedor
    SET documento_origen_id = p_guia_id
    WHERE id = p_factura_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_asociar_nota_credito(
    p_nota_credito_id INT,
    p_factura_origen_id INT
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_nota facturas_proveedor%ROWTYPE;
    v_compra facturas_proveedor%ROWTYPE;
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    SELECT * INTO v_nota FROM facturas_proveedor
    WHERE id = p_nota_credito_id FOR UPDATE;
    SELECT * INTO v_compra FROM facturas_proveedor
    WHERE id = p_factura_origen_id FOR SHARE;

    IF v_nota.id IS NULL OR v_compra.id IS NULL
       OR v_nota.tipo_documento <> 'NOTA_CREDITO'
       OR v_nota.estado <> 'BORRADOR'
       OR v_nota.usuario_id <> v_actor_id
       OR v_nota.documento_origen_id IS NOT NULL
       OR v_compra.tipo_documento NOT IN ('FACTURA', 'BOLETA')
       OR v_compra.estado <> 'REGISTRADA'
       OR v_nota.proveedor_id <> v_compra.proveedor_id
       OR EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_nota_credito_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: No se puede asociar la nota a esa compra.';
    END IF;

    UPDATE facturas_proveedor
    SET documento_origen_id = p_factura_origen_id
    WHERE id = p_nota_credito_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_registrar_ingreso_compra(
    p_factura_id INT,
    p_lineas JSONB
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_factura facturas_proveedor%ROWTYPE;
    v_linea JSONB;
    v_articulo_id INT;
    v_cantidad DECIMAL(12,3);
    v_precio DECIMAL(12,2);
    v_descuento_1 DECIMAL(5,2);
    v_descuento_2 DECIMAL(5,2);
    v_descuento_3 DECIMAL(5,2);
    v_precio_neto DECIMAL(12,2);
    v_detalle_id INT;
    v_stock DECIMAL(12,3);
    v_costo DECIMAL(12,2);
    v_nuevo_stock DECIMAL(12,3);
    v_nuevo_pmp DECIMAL(12,2);
    v_saldo_valorizado DECIMAL(12,2);
    v_fecha TIMESTAMPTZ;
    v_hash VARCHAR(64);
    v_bruto DECIMAL(12,2) := 0;
    v_neto DECIMAL(12,2) := 0;
    v_descuento DECIMAL(12,2) := 0;
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));
    IF p_factura_id IS NULL OR p_lineas IS NULL
       OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Se requiere una factura y líneas en formato array.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Se requiere una factura y al menos una línea.';
    END IF;

    SELECT * INTO v_factura
    FROM facturas_proveedor
    WHERE id = p_factura_id
    FOR UPDATE;

    IF NOT FOUND OR v_factura.estado <> 'BORRADOR' OR v_factura.usuario_id <> v_actor_id THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La factura no existe, no está en borrador o no pertenece al actor.';
    END IF;
    IF v_factura.tipo_documento IN ('NOTA_CREDITO', 'GUIA_DESPACHO') THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Use el flujo específico para registrar guías o notas de crédito.';
    END IF;
    IF v_factura.tipo_documento = 'FACTURA'
       AND v_factura.documento_origen_id IS NOT NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La factura asociada a una guía debe conciliarse con fn_vincular_factura_guia para no duplicar existencias.';
    END IF;
    IF EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_factura_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La factura ya contiene líneas.';
    END IF;

    v_fecha := clock_timestamp();
    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        v_articulo_id := (v_linea ->> 'articulo_id')::INT;
        v_cantidad := (v_linea ->> 'cantidad')::DECIMAL(12,3);
        v_precio := (v_linea ->> 'precio_unitario')::DECIMAL(12,2);
        v_descuento_1 := COALESCE((v_linea ->> 'descuento_1_pct')::DECIMAL(5,2), 0);
        v_descuento_2 := COALESCE((v_linea ->> 'descuento_2_pct')::DECIMAL(5,2), 0);
        v_descuento_3 := COALESCE((v_linea ->> 'descuento_3_pct')::DECIMAL(5,2), 0);

        IF v_articulo_id IS NULL OR v_cantidad IS NULL OR v_cantidad <= 0
           OR v_precio IS NULL OR v_precio < 0
           OR v_descuento_1 NOT BETWEEN 0 AND 100
           OR v_descuento_2 NOT BETWEEN 0 AND 100
           OR v_descuento_3 NOT BETWEEN 0 AND 100 THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Línea inválida: cantidad, precio o descuentos fuera de rango.';
        END IF;

        v_precio_neto := ROUND(
            v_precio * (1 - v_descuento_1 / 100)
            * (1 - v_descuento_2 / 100) * (1 - v_descuento_3 / 100), 2
        );
        INSERT INTO detalle_factura (
            factura_id, articulo_id, cantidad, precio_unitario,
            precio_unitario_neto, subtotal, subtotal_neto, descuento_1_pct,
            descuento_2_pct, descuento_3_pct
        ) VALUES (
            p_factura_id, v_articulo_id, v_cantidad, v_precio,
            v_precio_neto, ROUND(v_cantidad * v_precio, 2),
            ROUND(v_cantidad * v_precio_neto, 2), v_descuento_1,
            v_descuento_2, v_descuento_3
        ) RETURNING id INTO v_detalle_id;

        SELECT stock_actual, costo_promedio_ponderado
        INTO v_stock, v_costo
        FROM articulos
        WHERE id = v_articulo_id AND activo
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Artículo inexistente o inactivo (%).', v_articulo_id;
        END IF;

        v_nuevo_stock := v_stock + v_cantidad;
        v_nuevo_pmp := ROUND(
            ((v_stock * v_costo) + (v_cantidad * v_precio_neto)) / v_nuevo_stock, 2
        );
        v_saldo_valorizado := ROUND(v_nuevo_stock * v_nuevo_pmp, 2);
        UPDATE articulos
        SET stock_actual = v_nuevo_stock, costo_promedio_ponderado = v_nuevo_pmp
        WHERE id = v_articulo_id;

        v_hash := fn_calcular_hash_cardex(
            v_articulo_id, v_actor_id, 'ENTRADA_COMPRA', v_cantidad, 0,
            v_nuevo_stock, v_precio_neto, v_saldo_valorizado, v_detalle_id,
            NULL, NULL, NULL, NULL, 'Compra registrada', NULL,
            v_factura.tipo_documento || ':' || v_factura.numero_factura, v_fecha
        );
        INSERT INTO cardex (
            articulo_id, usuario_id, factura_detalle_id, fecha_registro,
            tipo_movimiento, cantidad_entrada, cantidad_salida, saldo_stock,
            costo_unitario, saldo_valorizado, documento_referencia, motivo,
            hash_integridad
        ) VALUES (
            v_articulo_id, v_actor_id, v_detalle_id, v_fecha,
            'ENTRADA_COMPRA', v_cantidad, 0, v_nuevo_stock, v_precio_neto,
            v_saldo_valorizado, v_factura.tipo_documento || ':' || v_factura.numero_factura,
            'Compra registrada', v_hash
        );

        v_bruto := v_bruto + ROUND(v_cantidad * v_precio, 2);
        v_neto := v_neto + ROUND(v_cantidad * v_precio_neto, 2);
    END LOOP;

    v_descuento := v_bruto - v_neto;
    IF v_factura.monto_bruto <> v_bruto
       OR v_factura.descuento_cascada <> v_descuento
       OR v_factura.monto_neto <> v_neto
       OR v_factura.iva <> ROUND(v_neto * v_factura.tasa_iva_pct / 100, 2)
       OR v_factura.monto_total <> v_neto + v_factura.iva THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Los totales del encabezado no cuadran con sus líneas, descuentos e IVA.';
    END IF;

    UPDATE facturas_proveedor SET estado = 'REGISTRADA' WHERE id = p_factura_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION fn_ajustar_valorizacion_factura(
   p_factura_id INT,
   p_articulo_id INT
) RETURNS VOID AS $$
DECLARE
   v_actor_id INT;
   v_factura facturas_proveedor%ROWTYPE;
   v_ajuste DECIMAL(12,2);
   v_stock DECIMAL(12,3);
   v_costo DECIMAL(12,2);
   v_nuevo_pmp DECIMAL(12,2);
   v_saldo_valorizado DECIMAL(12,2);
   v_fecha TIMESTAMPTZ;
   v_hash VARCHAR(64);
   v_documento_referencia VARCHAR(100);
BEGIN
   v_actor_id := fn_exigir_permiso('facturas.ingresar');
   PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

   SELECT * INTO v_factura
   FROM facturas_proveedor
   WHERE id = p_factura_id
     AND tipo_documento = 'FACTURA'
     AND estado = 'BORRADOR'
     AND usuario_id = v_actor_id
   FOR UPDATE;

   IF NOT FOUND OR v_factura.documento_origen_id IS NULL THEN
       RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La factura no está en conciliación o no tiene guía asociada.';
   END IF;

   SELECT COALESCE(SUM(fd.subtotal_neto - gd.subtotal_neto), 0)::DECIMAL(12,2)
   INTO v_ajuste
   FROM detalle_factura fd
   JOIN detalle_factura gd ON gd.id = fd.detalle_guia_id
   WHERE fd.factura_id = p_factura_id
     AND gd.articulo_id = p_articulo_id;

   IF NOT FOUND OR NOT EXISTS (
       SELECT 1 FROM detalle_factura
       WHERE factura_id = p_factura_id
         AND articulo_id = p_articulo_id
   ) THEN
       RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: No hay detalle de factura para el artículo %.', p_articulo_id;
   END IF;

   SELECT stock_actual, costo_promedio_ponderado
   INTO v_stock, v_costo
   FROM articulos
   WHERE id = p_articulo_id AND activo
   FOR UPDATE;

   IF NOT FOUND OR v_stock <= 0
      OR v_stock < fn_stock_pendiente_guia(p_articulo_id) THEN
       RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Stock insuficiente para valorizar la guía del artículo %.', p_articulo_id;
   END IF;

   IF ROUND(v_stock * v_costo, 2) + v_ajuste < 0 THEN
       RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: El ajuste produciría una valorización negativa para artículo %.', p_articulo_id;
   END IF;

   IF v_ajuste = 0 THEN
       RETURN;
   END IF;

   v_nuevo_pmp := ROUND((ROUND(v_stock * v_costo, 2) + v_ajuste) / v_stock, 2);
   v_saldo_valorizado := ROUND(v_stock * v_nuevo_pmp, 2);
   v_fecha := clock_timestamp();
   v_documento_referencia := 'FACTURA:' || p_factura_id::TEXT
       || ':GUIA:' || v_factura.documento_origen_id::TEXT;

   UPDATE articulos
   SET costo_promedio_ponderado = v_nuevo_pmp
   WHERE id = p_articulo_id;

   v_hash := fn_calcular_hash_cardex(
       p_articulo_id, v_actor_id, 'AJUSTE_VALORIZACION', 0, 0,
       v_stock, v_nuevo_pmp, v_saldo_valorizado, NULL, NULL,
       NULL, NULL, NULL, 'Ajuste de costo por factura asociada a guía',
       NULL, v_documento_referencia, v_fecha
   );

   INSERT INTO cardex (
       articulo_id, usuario_id, fecha_registro, tipo_movimiento,
       cantidad_entrada, cantidad_salida, saldo_stock, costo_unitario,
       saldo_valorizado, documento_referencia, motivo, hash_integridad
   ) VALUES (
       p_articulo_id, v_actor_id, v_fecha, 'AJUSTE_VALORIZACION',
       0, 0, v_stock, v_nuevo_pmp, v_saldo_valorizado,
       v_documento_referencia, 'Ajuste de costo por factura asociada a guía', v_hash
   );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION fn_vincular_factura_guia(
    p_factura_id INT,
    p_guia_id INT,
    p_lineas JSONB
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_factura facturas_proveedor%ROWTYPE;
    v_guia facturas_proveedor%ROWTYPE;
    v_linea JSONB;
    v_detalle_guia detalle_factura%ROWTYPE;
    v_detalle_guia_id INT;
    v_precio DECIMAL(12,2);
    v_descuento_1 DECIMAL(5,2);
    v_descuento_2 DECIMAL(5,2);
    v_descuento_3 DECIMAL(5,2);
    v_precio_neto DECIMAL(12,2);
    v_bruto DECIMAL(12,2) := 0;
    v_neto DECIMAL(12,2) := 0;
    v_descuento DECIMAL(12,2);
    v_articulo_id INT;
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Las líneas de conciliación deben ser un array.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Se requieren líneas de conciliación en formato array.';
    END IF;

    SELECT * INTO v_factura
    FROM facturas_proveedor
    WHERE id = p_factura_id
    FOR UPDATE;

    SELECT * INTO v_guia
    FROM facturas_proveedor
    WHERE id = p_guia_id
    FOR UPDATE;

    IF NOT FOUND OR v_guia.tipo_documento <> 'GUIA_DESPACHO'
       OR v_guia.estado <> 'REGISTRADA'
       OR v_factura.id IS NULL
       OR v_factura.tipo_documento <> 'FACTURA'
       OR v_factura.documento_origen_id IS DISTINCT FROM v_guia.id
       OR v_factura.estado <> 'BORRADOR'
       OR v_factura.usuario_id <> v_actor_id
       OR v_factura.proveedor_id <> v_guia.proveedor_id THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Factura o guía no válida para conciliación.';
    END IF;

    IF EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_factura_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La factura ya contiene líneas.';
    END IF;

    IF jsonb_array_length(p_lineas) <> (
        SELECT count(*) FROM detalle_factura WHERE factura_id = p_guia_id
    ) OR (
        SELECT count(DISTINCT value ->> 'detalle_guia_id')
        FROM jsonb_array_elements(p_lineas)
    ) <> jsonb_array_length(p_lineas) THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: La conciliación debe incluir exactamente una línea por cada detalle de la guía.';
    END IF;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        v_detalle_guia_id := (v_linea ->> 'detalle_guia_id')::INT;
        v_precio := (v_linea ->> 'precio_unitario')::DECIMAL(12,2);
        v_descuento_1 := COALESCE((v_linea ->> 'descuento_1_pct')::DECIMAL(5,2), 0);
        v_descuento_2 := COALESCE((v_linea ->> 'descuento_2_pct')::DECIMAL(5,2), 0);
        v_descuento_3 := COALESCE((v_linea ->> 'descuento_3_pct')::DECIMAL(5,2), 0);

        IF v_detalle_guia_id IS NULL OR v_precio IS NULL OR v_precio < 0
           OR v_descuento_1 NOT BETWEEN 0 AND 100
           OR v_descuento_2 NOT BETWEEN 0 AND 100
           OR v_descuento_3 NOT BETWEEN 0 AND 100 THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Precio o descuentos de factura fuera de rango.';
        END IF;

        SELECT * INTO v_detalle_guia
        FROM detalle_factura
        WHERE id = v_detalle_guia_id AND factura_id = p_guia_id
        FOR SHARE;

        IF NOT FOUND OR EXISTS (
            SELECT 1 FROM detalle_factura
            WHERE detalle_guia_id = v_detalle_guia_id
        ) THEN
            RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Detalle de guía inexistente o ya conciliado (%).', v_detalle_guia_id;
        END IF;

        v_precio_neto := ROUND(
            v_precio * (1 - v_descuento_1 / 100)
            * (1 - v_descuento_2 / 100) * (1 - v_descuento_3 / 100), 2
        );

        INSERT INTO detalle_factura (
            factura_id, detalle_guia_id, articulo_id, cantidad, precio_unitario,
            precio_unitario_neto, subtotal, subtotal_neto, descuento_1_pct,
            descuento_2_pct, descuento_3_pct
        ) VALUES (
            p_factura_id, v_detalle_guia_id, v_detalle_guia.articulo_id,
            v_detalle_guia.cantidad, v_precio, v_precio_neto,
            ROUND(v_detalle_guia.cantidad * v_precio, 2),
            ROUND(v_detalle_guia.cantidad * v_precio_neto, 2),
            v_descuento_1, v_descuento_2, v_descuento_3
        );

        v_bruto := v_bruto + ROUND(v_detalle_guia.cantidad * v_precio, 2);
        v_neto := v_neto + ROUND(v_detalle_guia.cantidad * v_precio_neto, 2);
    END LOOP;

    v_descuento := v_bruto - v_neto;
    IF v_factura.monto_bruto <> v_bruto
       OR v_factura.descuento_cascada <> v_descuento
       OR v_factura.monto_neto <> v_neto
       OR v_factura.iva <> ROUND(v_neto * v_factura.tasa_iva_pct / 100, 2)
       OR v_factura.monto_total <> v_neto + v_factura.iva THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Totales de factura no cuadran con las líneas conciliadas.';
    END IF;

    FOR v_articulo_id IN
        SELECT DISTINCT gd.articulo_id
        FROM detalle_factura fd
        JOIN detalle_factura gd ON gd.id = fd.detalle_guia_id
        WHERE fd.factura_id = p_factura_id
        GROUP BY gd.articulo_id
        ORDER BY gd.articulo_id
    LOOP
        PERFORM fn_ajustar_valorizacion_factura(p_factura_id, v_articulo_id);
    END LOOP;

    UPDATE facturas_proveedor SET estado = 'REGISTRADA'
    WHERE id = p_factura_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE FUNCTION fn_registrar_devolucion_proveedor(
    p_nota_credito_id INT,
    p_lineas JSONB
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_nota facturas_proveedor%ROWTYPE;
    v_compra facturas_proveedor%ROWTYPE;
    v_linea JSONB;
    v_detalle_origen detalle_factura%ROWTYPE;
    v_detalle_nota_id INT;
    v_movimiento_origen_id INT;
    v_movimiento_id INT;
    v_cantidad DECIMAL(12,3);
    v_precio DECIMAL(12,2);
    v_descuento_1 DECIMAL(5,2);
    v_descuento_2 DECIMAL(5,2);
    v_descuento_3 DECIMAL(5,2);
    v_precio_neto DECIMAL(12,2);
    v_bruto DECIMAL(12,2) := 0;
    v_neto DECIMAL(12,2) := 0;
    v_descuento DECIMAL(12,2);
    v_motivo TEXT;
BEGIN
    v_actor_id := fn_exigir_permiso('devoluciones.registrar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: Se requiere una nota de crédito y líneas en formato array.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: Se requiere una nota de crédito y al menos una línea.';
    END IF;
    IF (
        SELECT count(DISTINCT value ->> 'factura_detalle_id')
        FROM jsonb_array_elements(p_lineas)
    ) <> jsonb_array_length(p_lineas) THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: No repita detalles de la factura en la misma nota.';
    END IF;

    SELECT * INTO v_nota
    FROM facturas_proveedor
    WHERE id = p_nota_credito_id
    FOR UPDATE;

    IF NOT FOUND OR v_nota.tipo_documento <> 'NOTA_CREDITO'
       OR v_nota.estado <> 'BORRADOR'
       OR v_nota.usuario_id <> v_actor_id
       OR v_nota.documento_origen_id IS NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: Nota de crédito inexistente, registrada o sin factura de origen.';
    END IF;

    SELECT * INTO v_compra
    FROM facturas_proveedor
    WHERE id = v_nota.documento_origen_id
      AND proveedor_id = v_nota.proveedor_id
      AND tipo_documento IN ('FACTURA', 'BOLETA')
      AND estado = 'REGISTRADA'
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: La factura original no existe o no está registrada.';
    END IF;

    IF EXISTS (SELECT 1 FROM detalle_factura WHERE factura_id = p_nota_credito_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: La nota de crédito ya tiene líneas.';
    END IF;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        v_detalle_origen := NULL;
        v_detalle_nota_id := NULL;
        v_movimiento_origen_id := NULL;
        v_cantidad := (v_linea ->> 'cantidad')::DECIMAL(12,3);
        v_precio := (v_linea ->> 'precio_unitario')::DECIMAL(12,2);
        v_descuento_1 := COALESCE((v_linea ->> 'descuento_1_pct')::DECIMAL(5,2), 0);
        v_descuento_2 := COALESCE((v_linea ->> 'descuento_2_pct')::DECIMAL(5,2), 0);
        v_descuento_3 := COALESCE((v_linea ->> 'descuento_3_pct')::DECIMAL(5,2), 0);
        v_motivo := NULLIF(trim(v_linea ->> 'motivo'), '');

        IF v_cantidad IS NULL OR v_cantidad <= 0 OR v_precio IS NULL OR v_precio < 0
           OR v_descuento_1 NOT BETWEEN 0 AND 100
           OR v_descuento_2 NOT BETWEEN 0 AND 100
           OR v_descuento_3 NOT BETWEEN 0 AND 100
           OR v_motivo IS NULL THEN
            RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: Cantidad, precio, descuentos y motivo son obligatorios.';
        END IF;

        SELECT * INTO v_detalle_origen
        FROM detalle_factura
        WHERE id = (v_linea ->> 'factura_detalle_id')::INT
          AND factura_id = v_compra.id
        FOR SHARE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: El detalle de origen no pertenece a la factura indicada.';
        END IF;

        SELECT id INTO v_movimiento_origen_id
        FROM cardex
        WHERE factura_detalle_id = COALESCE(
            v_detalle_origen.detalle_guia_id, v_detalle_origen.id
        )
          AND tipo_movimiento = 'ENTRADA_COMPRA'
        ORDER BY id
        LIMIT 1
        FOR SHARE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: No se encontró el movimiento de ingreso del detalle original (%).',
                v_detalle_origen.id;
        END IF;

        v_precio_neto := ROUND(
            v_precio * (1 - v_descuento_1 / 100)
            * (1 - v_descuento_2 / 100) * (1 - v_descuento_3 / 100), 2
        );

        INSERT INTO detalle_factura (
            factura_id, detalle_documento_origen_id, articulo_id, cantidad,
            precio_unitario, precio_unitario_neto, subtotal, subtotal_neto,
            descuento_1_pct, descuento_2_pct, descuento_3_pct
        ) VALUES (
            p_nota_credito_id, v_detalle_origen.id, v_detalle_origen.articulo_id,
            v_cantidad, v_precio, v_precio_neto,
            ROUND(v_cantidad * v_precio, 2),
            ROUND(v_cantidad * v_precio_neto, 2),
            v_descuento_1, v_descuento_2, v_descuento_3
        ) RETURNING id INTO v_detalle_nota_id;

        v_movimiento_id := fn_registrar_movimiento_inventario(
            v_detalle_origen.articulo_id, 'DEVOLUCION_PROVEEDOR', v_cantidad,
            v_motivo, 'NOTA_CREDITO:' || p_nota_credito_id::TEXT
                || ':DETALLE:' || v_detalle_nota_id::TEXT,
            NULL, NULL, v_movimiento_origen_id, NULL
        );

        INSERT INTO devoluciones_proveedor (
            nota_credito_id, detalle_nota_id, detalle_compra_origen_id,
            movimiento_cardex_id, cantidad
        ) VALUES (
            p_nota_credito_id, v_detalle_nota_id, v_detalle_origen.id,
            v_movimiento_id, v_cantidad
        );

        v_bruto := v_bruto + ROUND(v_cantidad * v_precio, 2);
        v_neto := v_neto + ROUND(v_cantidad * v_precio_neto, 2);
    END LOOP;

    v_descuento := v_bruto - v_neto;
    IF v_nota.monto_bruto <> v_bruto
       OR v_nota.descuento_cascada <> v_descuento
       OR v_nota.monto_neto <> v_neto
       OR v_nota.iva <> ROUND(v_neto * v_nota.tasa_iva_pct / 100, 2)
       OR v_nota.monto_total <> v_neto + v_nota.iva THEN
        RAISE EXCEPTION 'ERROR [FYAG-DEVOLUCION]: Totales de nota de crédito no cuadran con sus líneas.';
    END IF;

    UPDATE facturas_proveedor SET estado = 'REGISTRADA'
    WHERE id = p_nota_credito_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

CREATE OR REPLACE VIEW vw_stock_despachable AS
SELECT
    a.id AS articulo_id,
    a.codigo_sku,
    a.descripcion,
    a.stock_actual,
    fn_stock_pendiente_guia(a.id) AS reservado_guia_pendiente,
    a.stock_actual - fn_stock_pendiente_guia(a.id) AS disponible_despacho
FROM articulos a;

DROP TRIGGER IF EXISTS trg_validar_detalle_documento_origen ON detalle_factura;
CREATE TRIGGER trg_validar_detalle_documento_origen
BEFORE INSERT OR UPDATE OF factura_id, articulo_id, cantidad,
    detalle_guia_id, detalle_documento_origen_id
ON detalle_factura
FOR EACH ROW EXECUTE FUNCTION fn_validar_detalle_documento_origen();

DROP TRIGGER IF EXISTS trg_proteger_stock_guia_pendiente ON articulos;
CREATE TRIGGER trg_proteger_stock_guia_pendiente
BEFORE UPDATE OF stock_actual ON articulos
FOR EACH ROW EXECUTE FUNCTION fn_proteger_stock_guia_pendiente();

DROP TRIGGER IF EXISTS trg_no_update_delete_auditoria_cuentas ON auditoria_cuentas_bancarias;
CREATE TRIGGER trg_no_update_delete_auditoria_cuentas
BEFORE UPDATE OR DELETE ON auditoria_cuentas_bancarias
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios_auditoria();
DROP TRIGGER IF EXISTS trg_no_truncate_auditoria_cuentas ON auditoria_cuentas_bancarias;
CREATE TRIGGER trg_no_truncate_auditoria_cuentas
BEFORE TRUNCATE ON auditoria_cuentas_bancarias
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

DO $$
DECLARE
    v_tabla TEXT;
BEGIN
    FOREACH v_tabla IN ARRAY ARRAY[
        'contactos_proveedor', 'clientes', 'devoluciones_proveedor'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_auditoria_operaciones ON %I', v_tabla);
        EXECUTE format(
            'CREATE TRIGGER trg_auditoria_operaciones AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_auditar_operacion()',
            v_tabla
        );
    END LOOP;
END $$;

REVOKE ALL ON TABLE cuentas_bancarias_proveedor, auditoria_cuentas_bancarias
    FROM PUBLIC, anon, authenticated, service_role, alpha_backend;
REVOKE ALL ON SEQUENCE cuentas_bancarias_proveedor_id_seq,
    auditoria_cuentas_bancarias_id_seq, contactos_proveedor_id_seq,
    clientes_id_seq, devoluciones_proveedor_id_seq
    FROM PUBLIC, anon, authenticated, service_role, alpha_backend;
REVOKE ALL ON TABLE contactos_proveedor, clientes, devoluciones_proveedor,
    vw_stock_despachable
    FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON contactos_proveedor, clientes, devoluciones_proveedor,
    vw_stock_despachable TO alpha_backend;
GRANT INSERT, UPDATE ON contactos_proveedor, clientes TO alpha_backend;
GRANT USAGE, SELECT ON SEQUENCE contactos_proveedor_id_seq, clientes_id_seq
    TO alpha_backend;

REVOKE EXECUTE ON FUNCTION fn_generar_hash_cardex(),
    fn_verificar_integridad_cardex(),
    fn_stock_pendiente_guia(INT),
    fn_proteger_stock_guia_pendiente(),
    fn_validar_detalle_documento_origen(),
    fn_registrar_recepcion_guia(INT, JSONB),
    fn_registrar_devolucion_proveedor(INT, JSONB),
    fn_ajustar_valorizacion_factura(INT, INT),
    fn_vincular_factura_guia(INT, INT, JSONB),
    fn_asociar_factura_guia(INT, INT),
    fn_asociar_nota_credito(INT, INT),
    fn_guardar_cuenta_bancaria_proveedor(INT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, INT),
    fn_listar_cuentas_bancarias_proveedor(INT)
    FROM PUBLIC, anon, authenticated, service_role, alpha_backend;

GRANT EXECUTE ON FUNCTION fn_verificar_integridad_cardex(),
    fn_registrar_recepcion_guia(INT, JSONB),
    fn_registrar_devolucion_proveedor(INT, JSONB),
    fn_vincular_factura_guia(INT, INT, JSONB),
    fn_asociar_factura_guia(INT, INT),
    fn_asociar_nota_credito(INT, INT),
    fn_guardar_cuenta_bancaria_proveedor(INT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, INT),
    fn_listar_cuentas_bancarias_proveedor(INT)
    TO alpha_backend;

COMMIT;
