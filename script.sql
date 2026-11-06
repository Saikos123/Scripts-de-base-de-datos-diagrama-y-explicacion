-- ============================================================================
-- PROYECTO ALPHA (FYAG SpA) - ESQUEMA POSTGRESQL 
-- ============================================================================

-- Ejecutar en la base de datos de desarrollo prevista para Alpha. Este script
-- crea el esquema inicial; IF NOT EXISTS no migra tablas de versiones previas.
-- Las fechas se almacenan como TIMESTAMPTZ. La aplicación debe convertirlas
-- a America/Santiago al mostrarlas; no se cambia la configuración global de Supabase.
-- El backend debe validar el JWT y los permisos del usuario, y establecer
-- app.current_user_id con SET LOCAL dentro de cada transacción. Esta identidad
-- de sesión no autentica por sí sola al usuario: alpha_backend solo debe usarse
-- desde el backend confiable y nunca desde el navegador.
-- Las funciones SECURITY DEFINER incluyen public en su search_path; no conceder
-- CREATE en ese esquema a roles no confiables.
-- Los JSONB de evidencia/DTE almacenan metadatos y rutas de Supabase Storage,
-- no archivos binarios ni URLs firmadas de corta duración. Definir retención
-- legalmente antes de anonimizar datos; la operación no modifica respaldos.

-- Necesaria para calcular SHA-256 y generar una contraseña aleatoria al anonimizar.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

BEGIN;

-- ============================================================================
-- PASO 0: FUNCIÓN GLOBAL DE VALIDACIÓN DE RUT CHILENO (ALGORITMO MÓDULO 11)
-- ============================================================================

-- Comprueba el formato y el dígito verificador chileno con Módulo 11.
CREATE OR REPLACE FUNCTION fn_validar_rut_chileno(p_rut TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_rut_clean TEXT;
    v_cuerpo INT;
    v_dv CHAR(1);
    v_factor INT := 2;
    v_suma INT := 0;
    v_resto INT;
    v_dv_esperado CHAR(1);
    v_digit INT;
BEGIN
    IF p_rut IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Limpiar caracteres no alfanuméricos y convertir a mayúsculas
    v_rut_clean := UPPER(REGEXP_REPLACE(p_rut, '[^0-9Kk]', '', 'g'));

    IF v_rut_clean !~ '^[0-9]{7,8}[0-9K]$' THEN
        RETURN FALSE;
    END IF;

    v_cuerpo := CAST(SUBSTRING(v_rut_clean FROM 1 FOR LENGTH(v_rut_clean) - 1) AS INT);

    -- Bloquear RUTs espurios o ficticios como 00000000-0
    IF v_cuerpo < 100000 THEN
        RETURN FALSE;
    END IF;

    v_dv := RIGHT(v_rut_clean, 1);

    -- Algoritmo Módulo 11 oficial
    WHILE v_cuerpo > 0 LOOP
        v_digit := v_cuerpo % 10;
        v_suma := v_suma + (v_digit * v_factor);
        v_cuerpo := v_cuerpo / 10;
        v_factor := CASE WHEN v_factor = 7 THEN 2 ELSE v_factor + 1 END;
    END LOOP;

    v_resto := 11 - (v_suma % 11);
    IF v_resto = 11 THEN
        v_dv_esperado := '0';
    ELSIF v_resto = 10 THEN
        v_dv_esperado := 'K';
    ELSE
        v_dv_esperado := CAST(v_resto AS CHAR(1));
    END IF;

    RETURN v_dv = v_dv_esperado;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ============================================================================
-- PASO 1: SISTEMA DE SEGURIDAD, ROLES, PERMISOS Y AUDITORÍA DE USUARIOS
-- ============================================================================

-- Perfiles funcionales disponibles para las cuentas del sistema.
CREATE TABLE IF NOT EXISTS roles (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(50) UNIQUE NOT NULL,
    descripcion TEXT,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_nombre_rol_upper CHECK (nombre = UPPER(TRIM(nombre)))
);

-- Acciones concretas que se pueden conceder a uno o más roles.
CREATE TABLE IF NOT EXISTS permisos (
    id SERIAL PRIMARY KEY,
    codigo VARCHAR(100) UNIQUE NOT NULL,
    descripcion TEXT,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_codigo_permiso_lower CHECK (codigo = LOWER(TRIM(codigo)))
);

-- Relación muchos-a-muchos entre roles y permisos.
CREATE TABLE IF NOT EXISTS roles_permisos (
    rol_id INT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permiso_id INT NOT NULL REFERENCES permisos(id) ON DELETE CASCADE,
    PRIMARY KEY (rol_id, permiso_id)
);

-- Roles base. ON CONFLICT permite volver a ejecutar esta carga sin duplicarlos.
INSERT INTO roles (nombre, descripcion) VALUES
    ('ADMIN', 'Acceso total al sistema y administración de usuarios'),
    ('FINANZAS', 'Gestión de facturas, costos y reportes contables'),
    ('BODEGA', 'Control de inventario, ingresos, egresos y mermas'),
    ('SUPERVISOR', 'Consulta de reportes, visores de Kardex y auditoría')
ON CONFLICT (nombre) DO NOTHING;

-- Cuentas del sistema, su estado de acceso y la información necesaria para login.
CREATE TABLE IF NOT EXISTS usuarios (
    id SERIAL PRIMARY KEY,
    rut VARCHAR(12),
    nombre VARCHAR(100) NOT NULL,
    correo VARCHAR(150) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    rol_id INT NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    activo BOOLEAN NOT NULL DEFAULT TRUE,

    intentos_fallidos INT NOT NULL DEFAULT 0 CHECK (intentos_fallidos >= 0),
    bloqueado_hasta TIMESTAMPTZ,
    ultimo_ingreso TIMESTAMPTZ,
    password_modificado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_correo_limpio CHECK (correo = LOWER(TRIM(correo))),
    CONSTRAINT chk_rut_limpio CHECK (rut IS NULL OR rut = UPPER(TRIM(rut))),
    CONSTRAINT chk_rut_formato_regex CHECK (rut IS NULL OR rut ~ '^[0-9]{7,8}-[0-9Kk]$'),
    CONSTRAINT chk_rut_valido_mod11 CHECK (rut IS NULL OR fn_validar_rut_chileno(rut)),
    CONSTRAINT chk_correo_formato_regex CHECK (correo ~ '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
);

-- No se crea un administrador con una contraseña conocida. El primer usuario
-- debe aprovisionarse por un flujo seguro que almacene un hash bcrypt.
CREATE UNIQUE INDEX IF NOT EXISTS idx_usuarios_correo_unique ON usuarios (LOWER(TRIM(correo)));
CREATE UNIQUE INDEX IF NOT EXISTS idx_usuarios_rut_unique ON usuarios (UPPER(TRIM(rut)));
CREATE INDEX IF NOT EXISTS idx_usuarios_rol ON usuarios(rol_id);

-- JTI de JWT invalidados antes de expirar; el backend debe consultarlos al validar.
CREATE TABLE IF NOT EXISTS tokens_revocados (
    jti VARCHAR(255) PRIMARY KEY,
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    expira_en TIMESTAMPTZ NOT NULL,
    revocado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Índice estándar compatible para búsquedas de expiración
CREATE INDEX IF NOT EXISTS idx_tokens_revocados_expiracion ON tokens_revocados(expira_en);

-- Historial de altas, cambios de rol/estado y bajas de cuentas.
CREATE TABLE IF NOT EXISTS auditoria_usuarios (
    id SERIAL PRIMARY KEY,
    usuario_id INT NOT NULL,
    accion VARCHAR(20) NOT NULL,
    datos_anteriores JSONB,
    datos_nuevos JSONB,
    ejecutado_por VARCHAR(150) NOT NULL,
    fecha TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_auditoria_usuario_id ON auditoria_usuarios(usuario_id);
CREATE INDEX IF NOT EXISTS idx_auditoria_fecha ON auditoria_usuarios(fecha);

-- Guarda cambios de cuenta sin copiar correo, RUT ni contraseña a la auditoría.
-- app.current_user_id identifica al actor si el backend lo establece en la transacción.
CREATE OR REPLACE FUNCTION fn_auditar_cambios_usuarios()
RETURNS TRIGGER AS $$
DECLARE
    v_usuario_app VARCHAR(150);
BEGIN
    v_usuario_app := COALESCE(NULLIF(current_setting('app.current_user_id', true), ''), SESSION_USER::text);

    IF (TG_OP = 'INSERT') THEN
        INSERT INTO auditoria_usuarios (usuario_id, accion, datos_nuevos, ejecutado_por)
        VALUES (
            NEW.id,
            'INSERT',
            jsonb_build_object('rol_id', NEW.rol_id, 'activo', NEW.activo),
            v_usuario_app
        );
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO auditoria_usuarios (usuario_id, accion, datos_anteriores, datos_nuevos, ejecutado_por)
        VALUES (
            OLD.id,
            'UPDATE',
            jsonb_build_object('rol_id', OLD.rol_id, 'activo', OLD.activo),
            jsonb_build_object('rol_id', NEW.rol_id, 'activo', NEW.activo),
            v_usuario_app
        );
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO auditoria_usuarios (usuario_id, accion, datos_anteriores, ejecutado_por)
        VALUES (
            OLD.id,
            'DELETE',
            jsonb_build_object('rol_id', OLD.rol_id, 'activo', OLD.activo),
            v_usuario_app
        );
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

-- Devuelve el usuario de la transacción o aborta si no tiene el permiso solicitado.
CREATE OR REPLACE FUNCTION fn_exigir_permiso(p_codigo VARCHAR)
RETURNS INT AS $$
DECLARE
    v_usuario_id INT;
BEGIN
    v_usuario_id := NULLIF(current_setting('app.current_user_id', true), '')::INT;
    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-AUTH]: El backend no estableció el usuario autenticado para esta transacción.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM usuarios u
        JOIN roles_permisos rp ON rp.rol_id = u.rol_id
        JOIN permisos p ON p.id = rp.permiso_id
        WHERE u.id = v_usuario_id AND u.activo AND p.codigo = p_codigo
    ) THEN
        RAISE EXCEPTION 'ERROR [FYAG-AUTH]: El usuario no tiene el permiso requerido (%).', p_codigo;
    END IF;

    RETURN v_usuario_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

-- Sustituye datos identificatorios y desactiva la cuenta sin romper el historial.
-- No elimina datos retenidos en respaldos ni en otros sistemas.
CREATE OR REPLACE FUNCTION fn_anonimizar_usuario(p_usuario_id INT)
RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
BEGIN
    v_actor_id := NULLIF(current_setting('app.current_user_id', true), '')::INT;
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-AUTH]: Falta el actor autenticado.';
    END IF;
    IF v_actor_id <> p_usuario_id THEN
        PERFORM fn_exigir_permiso('usuarios.administrar');
    END IF;

    UPDATE usuarios
    SET rut = NULL,
        nombre = 'Usuario anonimizado #' || id::TEXT,
        correo = 'anonimizado+' || id::TEXT || '@invalid.local',
        password_hash = crypt(encode(gen_random_bytes(32), 'hex'), gen_salt('bf')),
        activo = FALSE,
        intentos_fallidos = 0,
        bloqueado_hasta = NULL
    WHERE id = p_usuario_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-PRIVACIDAD]: Usuario inexistente (%).', p_usuario_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

DROP TRIGGER IF EXISTS trg_auditoria_usuarios ON usuarios;
CREATE TRIGGER trg_auditoria_usuarios
AFTER INSERT OR UPDATE OR DELETE ON usuarios
FOR EACH ROW EXECUTE FUNCTION fn_auditar_cambios_usuarios();

-- Función común para impedir cambios y truncado de ambas tablas de auditoría.
CREATE OR REPLACE FUNCTION fn_bloquear_cambios_auditoria()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ERROR [FYAG-AUDITORIA]: El historial de auditoría es inalterable.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_no_update_delete_auditoria_usuarios ON auditoria_usuarios;
CREATE TRIGGER trg_no_update_delete_auditoria_usuarios
BEFORE UPDATE OR DELETE ON auditoria_usuarios
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

DROP TRIGGER IF EXISTS trg_no_truncate_auditoria_usuarios ON auditoria_usuarios;
CREATE TRIGGER trg_no_truncate_auditoria_usuarios
BEFORE TRUNCATE ON auditoria_usuarios
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

-- Registro de cambios en tablas operativas; se excluyen datos personales y adjuntos.
CREATE TABLE IF NOT EXISTS auditoria_operaciones (
    id BIGSERIAL PRIMARY KEY,
    tabla VARCHAR(100) NOT NULL,
    registro_id TEXT NOT NULL,
    accion VARCHAR(10) NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
    datos_anteriores JSONB,
    datos_nuevos JSONB,
    ejecutado_por VARCHAR(150) NOT NULL,
    fecha TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_auditoria_operaciones_tabla_registro
    ON auditoria_operaciones(tabla, registro_id);
CREATE INDEX IF NOT EXISTS idx_auditoria_operaciones_fecha
    ON auditoria_operaciones(fecha);

-- Registra INSERT/UPDATE/DELETE de tablas operativas y omite columnas sensibles.
CREATE OR REPLACE FUNCTION fn_auditar_operacion()
RETURNS TRIGGER AS $$
DECLARE
    v_anterior JSONB;
    v_nuevo JSONB;
    v_registro_id TEXT;
    v_usuario_app VARCHAR(150);
BEGIN
    v_usuario_app := COALESCE(NULLIF(current_setting('app.current_user_id', true), ''), SESSION_USER::text);

    IF TG_OP = 'INSERT' THEN
        v_nuevo := to_jsonb(NEW) - ARRAY[
            'rut', 'nombre', 'correo', 'password_hash', 'cliente',
            'responsable_obra', 'tecnico_receptor_id', 'proveedor_rut_documento',
            'proveedor_razon_social_documento', 'evidencia_adjunta', 'datos_dte'
        ];
        v_registro_id := v_nuevo ->> 'id';
    ELSIF TG_OP = 'UPDATE' THEN
        v_anterior := to_jsonb(OLD) - ARRAY[
            'rut', 'nombre', 'correo', 'password_hash', 'cliente',
            'responsable_obra', 'tecnico_receptor_id', 'proveedor_rut_documento',
            'proveedor_razon_social_documento', 'evidencia_adjunta', 'datos_dte'
        ];
        v_nuevo := to_jsonb(NEW) - ARRAY[
            'rut', 'nombre', 'correo', 'password_hash', 'cliente',
            'responsable_obra', 'tecnico_receptor_id', 'proveedor_rut_documento',
            'proveedor_razon_social_documento', 'evidencia_adjunta', 'datos_dte'
        ];
        v_registro_id := v_nuevo ->> 'id';
    ELSE
        v_anterior := to_jsonb(OLD) - ARRAY[
            'rut', 'nombre', 'correo', 'password_hash', 'cliente',
                'responsable_obra', 'tecnico_receptor_id', 'proveedor_rut_documento',
                'proveedor_razon_social_documento', 'evidencia_adjunta', 'datos_dte'
        ];
        v_registro_id := v_anterior ->> 'id';
    END IF;

    INSERT INTO auditoria_operaciones (
        tabla, registro_id, accion, datos_anteriores, datos_nuevos, ejecutado_por
    ) VALUES (
        TG_TABLE_NAME, v_registro_id, TG_OP, v_anterior, v_nuevo, v_usuario_app
    );
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_no_update_delete_auditoria_operaciones ON auditoria_operaciones;
CREATE TRIGGER trg_no_update_delete_auditoria_operaciones
BEFORE UPDATE OR DELETE ON auditoria_operaciones
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

DROP TRIGGER IF EXISTS trg_no_truncate_auditoria_operaciones ON auditoria_operaciones;
CREATE TRIGGER trg_no_truncate_auditoria_operaciones
BEFORE TRUNCATE ON auditoria_operaciones
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

-- ============================================================================
-- PASO 2: MÓDULO CORE DE INVENTARIO, BODEGA, DTEs (JSONB) Y KARDEX INALTERABLE
-- ============================================================================

-- Catálogo editable de categorías para clasificar artículos.
CREATE TABLE IF NOT EXISTS categorias_articulo (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL UNIQUE,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Datos actuales del proveedor; las facturas guardan además una copia histórica.
CREATE TABLE IF NOT EXISTS proveedores (
    id SERIAL PRIMARY KEY,
    rut VARCHAR(12) NOT NULL UNIQUE,
    razon_social VARCHAR(150) NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    giro VARCHAR(150),
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_rut_proveedor_limpio CHECK (rut = UPPER(TRIM(rut))),
    CONSTRAINT chk_rut_proveedor_formato CHECK (rut ~ '^[0-9]{7,8}-[0-9K]$'),
    CONSTRAINT chk_rut_proveedor_valido_mod11 CHECK (fn_validar_rut_chileno(rut))
);

-- Catálogo y saldo actual. El Cardex es la fuente del historial de movimientos.
CREATE TABLE IF NOT EXISTS articulos (
    id SERIAL PRIMARY KEY,
    codigo_sku VARCHAR(50) NOT NULL UNIQUE,
    codigo_barras VARCHAR(100) UNIQUE,
    descripcion VARCHAR(255) NOT NULL,
    categoria_id INT REFERENCES categorias_articulo(id) ON DELETE RESTRICT,
    unidad_medida VARCHAR(30) NOT NULL DEFAULT 'UNIDAD',
    ubicacion VARCHAR(100),
    sector_bodega VARCHAR(50),
    stock_actual DECIMAL(12,3) NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    stock_minimo DECIMAL(12,3) NOT NULL DEFAULT 5 CHECK (stock_minimo >= 0),
    costo_promedio_ponderado DECIMAL(12, 2) NOT NULL DEFAULT 0.00 CHECK (costo_promedio_ponderado >= 0),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    especificaciones_tecnicas JSONB DEFAULT '{}'::jsonb NOT NULL,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_articulos_especificaciones_gin ON articulos USING GIN (especificaciones_tecnicas jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_articulos_categoria ON articulos(categoria_id);

-- Obliga a crear artículos sin saldo; el saldo inicial se registra en el Cardex.
CREATE OR REPLACE FUNCTION fn_validar_stock_inicial_articulo()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_actual <> 0 OR NEW.costo_promedio_ponderado <> 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-STOCK]: Un artículo nuevo debe iniciar sin stock ni costo; registre el saldo inicial mediante el Cardex.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_stock_inicial_articulo ON articulos;
CREATE TRIGGER trg_stock_inicial_articulo
BEFORE INSERT ON articulos
FOR EACH ROW EXECUTE FUNCTION fn_validar_stock_inicial_articulo();

-- Obras que reciben materiales y concentran sus egresos.
CREATE TABLE IF NOT EXISTS obras (
    id SERIAL PRIMARY KEY,
    codigo_obra VARCHAR(50) NOT NULL UNIQUE,
    nombre VARCHAR(150) NOT NULL,
    cliente VARCHAR(150),
    numero_presupuesto VARCHAR(50),
    estado VARCHAR(20) NOT NULL DEFAULT 'EN_PROCESO'
        CHECK (estado IN ('EN_PROCESO', 'FINALIZADA', 'SUSPENDIDA', 'CANCELADA')),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Encabezado de compra con totales, proveedor, usuario y metadatos DTE opcionales.
CREATE TABLE IF NOT EXISTS facturas_proveedor (
    id SERIAL PRIMARY KEY,
    proveedor_id INT NOT NULL REFERENCES proveedores(id) ON DELETE RESTRICT,
    proveedor_rut_documento VARCHAR(12) NOT NULL,
    proveedor_razon_social_documento VARCHAR(150) NOT NULL,
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    tipo_documento VARCHAR(20) NOT NULL DEFAULT 'FACTURA'
        CHECK (tipo_documento IN ('FACTURA', 'BOLETA', 'GUIA_DESPACHO', 'NOTA_CREDITO')),
    numero_factura VARCHAR(50) NOT NULL,
    fecha_emision DATE NOT NULL,
    monto_bruto DECIMAL(12, 2) NOT NULL CHECK (monto_bruto >= 0),
    descuento_cascada DECIMAL(12, 2) NOT NULL DEFAULT 0.00 CHECK (descuento_cascada >= 0),
    monto_neto DECIMAL(12, 2) NOT NULL CHECK (monto_neto >= 0),
    tasa_iva_pct DECIMAL(5, 2) NOT NULL DEFAULT 19.00 CHECK (tasa_iva_pct BETWEEN 0 AND 100),
    iva DECIMAL(12, 2) NOT NULL CHECK (iva >= 0),
    monto_total DECIMAL(12, 2) NOT NULL CHECK (monto_total >= 0),
    estado VARCHAR(12) NOT NULL DEFAULT 'BORRADOR'
        CHECK (estado IN ('BORRADOR', 'REGISTRADA')),
    datos_dte JSONB DEFAULT '{}'::jsonb NOT NULL CHECK (jsonb_typeof(datos_dte) = 'object'),
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_cuadrado_contable CHECK (
        monto_total = monto_neto + iva
        AND iva = ROUND(monto_neto * tasa_iva_pct / 100, 2)
        AND monto_neto = monto_bruto - descuento_cascada
    ),
    CONSTRAINT uq_documento_proveedor UNIQUE (proveedor_id, tipo_documento, numero_factura)
);

CREATE INDEX IF NOT EXISTS idx_facturas_dte_gin ON facturas_proveedor USING GIN (datos_dte jsonb_path_ops);

-- Líneas de compra; las restricciones comprueban subtotales y descuentos.
CREATE TABLE IF NOT EXISTS detalle_factura (
    id SERIAL PRIMARY KEY,
    factura_id INT NOT NULL REFERENCES facturas_proveedor(id) ON DELETE CASCADE,
    articulo_id INT NOT NULL REFERENCES articulos(id) ON DELETE RESTRICT,
    cantidad DECIMAL(12,3) NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(12, 2) NOT NULL CHECK (precio_unitario >= 0),
    precio_unitario_neto DECIMAL(12, 2) NOT NULL CHECK (precio_unitario_neto >= 0),
    subtotal DECIMAL(12, 2) NOT NULL CHECK (subtotal >= 0),
    subtotal_neto DECIMAL(12, 2) NOT NULL CHECK (subtotal_neto >= 0),
    descuento_1_pct DECIMAL(5, 2) NOT NULL DEFAULT 0 CHECK (descuento_1_pct BETWEEN 0 AND 100),
    descuento_2_pct DECIMAL(5, 2) NOT NULL DEFAULT 0 CHECK (descuento_2_pct BETWEEN 0 AND 100),
    descuento_3_pct DECIMAL(5, 2) NOT NULL DEFAULT 0 CHECK (descuento_3_pct BETWEEN 0 AND 100),
    CONSTRAINT chk_subtotal_calculado CHECK (subtotal = ROUND(cantidad * precio_unitario, 2)),
    CONSTRAINT chk_subtotal_neto_calculado CHECK (
        subtotal_neto = ROUND(cantidad * precio_unitario_neto, 2)
    ),
    CONSTRAINT chk_precio_neto_calculado CHECK (
        precio_unitario_neto = ROUND(
            precio_unitario * (1 - descuento_1_pct / 100)
            * (1 - descuento_2_pct / 100) * (1 - descuento_3_pct / 100), 2
        )
    )
);

-- Impide editar documentos registrados y sus líneas; solo permite pasar de borrador
-- a registrado sin cambiar otros datos del encabezado.
CREATE OR REPLACE FUNCTION fn_proteger_documentos_registrados()
RETURNS TRIGGER AS $$
DECLARE
    v_factura_registrada BOOLEAN;
BEGIN
    IF TG_TABLE_NAME = 'facturas_proveedor' THEN
        IF OLD.estado = 'REGISTRADA' THEN
            RAISE EXCEPTION 'ERROR [FYAG-DOCUMENTO]: Una factura registrada es inalterable; use un documento correctivo.';
        END IF;
        IF TG_OP = 'UPDATE' THEN
            IF NEW.estado <> OLD.estado
               AND (NEW.estado <> 'REGISTRADA' OR
                    (to_jsonb(NEW) - 'estado') <> (to_jsonb(OLD) - 'estado')) THEN
                RAISE EXCEPTION 'ERROR [FYAG-DOCUMENTO]: Solo se permite cambiar el estado a REGISTRADA.';
            END IF;
        END IF;
    ELSE
        IF TG_OP = 'DELETE' THEN
            SELECT EXISTS (
                SELECT 1 FROM facturas_proveedor
                WHERE id = OLD.factura_id AND estado = 'REGISTRADA'
            ) INTO v_factura_registrada;
        ELSE
            SELECT EXISTS (
                SELECT 1 FROM facturas_proveedor
                WHERE id IN (OLD.factura_id, NEW.factura_id)
                  AND estado = 'REGISTRADA'
            ) INTO v_factura_registrada;
        END IF;
        IF v_factura_registrada THEN
            RAISE EXCEPTION 'ERROR [FYAG-DOCUMENTO]: No se pueden alterar líneas de una factura registrada.';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_inmutable_factura_registrada ON facturas_proveedor;
CREATE TRIGGER trg_inmutable_factura_registrada
BEFORE UPDATE OR DELETE ON facturas_proveedor
FOR EACH ROW EXECUTE FUNCTION fn_proteger_documentos_registrados();

DROP TRIGGER IF EXISTS trg_inmutable_detalle_factura_registrada ON detalle_factura;
CREATE TRIGGER trg_inmutable_detalle_factura_registrada
BEFORE UPDATE OR DELETE ON detalle_factura
FOR EACH ROW EXECUTE FUNCTION fn_proteger_documentos_registrados();

-- Encabezado de entrega de materiales a una obra, con receptor y evidencia opcional.
CREATE TABLE IF NOT EXISTS egresos_obra (
    id SERIAL PRIMARY KEY,
    obra_id INT NOT NULL REFERENCES obras(id) ON DELETE RESTRICT,
    fecha_salida TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    responsable_obra VARCHAR(100) NOT NULL,
    tecnico_receptor_id VARCHAR(50) NOT NULL,
    motivo TEXT NOT NULL CHECK (length(trim(motivo)) > 0),
    estado VARCHAR(12) NOT NULL DEFAULT 'BORRADOR'
        CHECK (estado IN ('BORRADOR', 'REGISTRADO')),
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    evidencia_adjunta JSONB DEFAULT '{}'::jsonb NOT NULL
        CHECK (jsonb_typeof(evidencia_adjunta) = 'object'),
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_egresos_evidencia_gin ON egresos_obra USING GIN (evidencia_adjunta jsonb_path_ops);

-- Artículos y cantidades solicitados en cada egreso.
CREATE TABLE IF NOT EXISTS detalle_egreso (
    id SERIAL PRIMARY KEY,
    egreso_id INT NOT NULL REFERENCES egresos_obra(id) ON DELETE CASCADE,
    articulo_id INT NOT NULL REFERENCES articulos(id) ON DELETE RESTRICT,
    cantidad_solicitada DECIMAL(12,3) NOT NULL CHECK (cantidad_solicitada > 0)
);

-- Libro de movimientos de inventario. Se conserva cada movimiento y su eventual reversa.
CREATE TABLE IF NOT EXISTS cardex (
    id SERIAL PRIMARY KEY,
    articulo_id INT NOT NULL REFERENCES articulos(id) ON DELETE RESTRICT,
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    factura_detalle_id INT REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    detalle_egreso_id INT REFERENCES detalle_egreso(id) ON DELETE RESTRICT,
    obra_id INT REFERENCES obras(id) ON DELETE RESTRICT,
    reversa_de_id INT REFERENCES cardex(id) ON DELETE RESTRICT,
    tecnico_receptor_id VARCHAR(50),
    motivo TEXT NOT NULL CHECK (length(trim(motivo)) > 0),
    referencia_externa VARCHAR(100),
    fecha_registro TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    tipo_movimiento VARCHAR(24) NOT NULL
        CHECK (tipo_movimiento IN (
            'SALDO_INICIAL', 'ENTRADA_COMPRA', 'SALIDA_OBRA', 'AJUSTE_MERMA',
            'DEVOLUCION_OBRA', 'DEVOLUCION_PROVEEDOR', 'USO_INTERNO',
            'AJUSTE_ENTRADA', 'AJUSTE_SALIDA'
        )),
    cantidad_entrada DECIMAL(12,3) NOT NULL DEFAULT 0 CHECK (cantidad_entrada >= 0),
    cantidad_salida DECIMAL(12,3) NOT NULL DEFAULT 0 CHECK (cantidad_salida >= 0),
    saldo_stock DECIMAL(12,3) NOT NULL CHECK (saldo_stock >= 0),
    costo_unitario DECIMAL(12, 2) NOT NULL CHECK (costo_unitario >= 0),
    saldo_valorizado DECIMAL(12, 2) NOT NULL CHECK (saldo_valorizado >= 0),
    documento_referencia VARCHAR(100) NOT NULL,
    hash_integridad VARCHAR(64) NOT NULL CHECK (hash_integridad ~ '^[0-9a-f]{64}$'),
    CONSTRAINT chk_cardex_movimiento_coherente CHECK (
        (
            tipo_movimiento IN ('SALDO_INICIAL', 'ENTRADA_COMPRA', 'DEVOLUCION_OBRA', 'AJUSTE_ENTRADA')
            AND cantidad_entrada > 0 AND cantidad_salida = 0
        ) OR (
            tipo_movimiento IN ('SALIDA_OBRA', 'AJUSTE_MERMA', 'DEVOLUCION_PROVEEDOR', 'USO_INTERNO', 'AJUSTE_SALIDA')
            AND cantidad_salida > 0 AND cantidad_entrada = 0
        )
    ),
    CONSTRAINT chk_cardex_documento_coherente CHECK (
        (tipo_movimiento = 'ENTRADA_COMPRA' AND factura_detalle_id IS NOT NULL AND detalle_egreso_id IS NULL)
        OR (tipo_movimiento = 'SALIDA_OBRA' AND detalle_egreso_id IS NOT NULL AND factura_detalle_id IS NULL)
        OR (tipo_movimiento NOT IN ('ENTRADA_COMPRA', 'SALIDA_OBRA')
            AND factura_detalle_id IS NULL AND detalle_egreso_id IS NULL)
    ),
    CONSTRAINT chk_cardex_receptor_obra CHECK (
        (tipo_movimiento = 'SALIDA_OBRA' AND obra_id IS NOT NULL AND tecnico_receptor_id IS NOT NULL)
        OR tipo_movimiento <> 'SALIDA_OBRA'
    )
);

CREATE INDEX IF NOT EXISTS idx_cardex_articulo ON cardex(articulo_id);
CREATE INDEX IF NOT EXISTS idx_cardex_obra ON cardex(obra_id);
CREATE INDEX IF NOT EXISTS idx_cardex_fecha ON cardex(fecha_registro);
CREATE INDEX IF NOT EXISTS idx_cardex_factura_detalle ON cardex(factura_detalle_id);
CREATE INDEX IF NOT EXISTS idx_cardex_detalle_egreso ON cardex(detalle_egreso_id);
CREATE INDEX IF NOT EXISTS idx_cardex_reversa_de ON cardex(reversa_de_id);

-- Tras el primer movimiento conserva los datos históricos clave del artículo.
CREATE OR REPLACE FUNCTION fn_proteger_articulo_con_movimientos()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM cardex WHERE articulo_id = OLD.id) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'ERROR [FYAG-ARTICULO]: No se puede eliminar un artículo con movimientos.';
        END IF;
        IF ROW(NEW.codigo_sku, NEW.descripcion, NEW.unidad_medida)
           IS DISTINCT FROM
           ROW(OLD.codigo_sku, OLD.descripcion, OLD.unidad_medida) THEN
            RAISE EXCEPTION 'ERROR [FYAG-ARTICULO]: SKU, descripción y unidad son históricos tras el primer movimiento.';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_inmutable_articulo_con_movimientos ON articulos;
CREATE TRIGGER trg_inmutable_articulo_con_movimientos
BEFORE UPDATE OR DELETE ON articulos
FOR EACH ROW EXECUTE FUNCTION fn_proteger_articulo_con_movimientos();

-- Protege los datos históricos de una obra que ya tiene movimientos.
CREATE OR REPLACE FUNCTION fn_proteger_obra_con_movimientos()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM cardex WHERE obra_id = OLD.id) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'ERROR [FYAG-OBRA]: No se puede eliminar una obra con movimientos.';
        END IF;
        IF ROW(NEW.codigo_obra, NEW.nombre, NEW.cliente, NEW.numero_presupuesto)
           IS DISTINCT FROM
           ROW(OLD.codigo_obra, OLD.nombre, OLD.cliente, OLD.numero_presupuesto) THEN
            RAISE EXCEPTION 'ERROR [FYAG-OBRA]: Los datos de una obra con movimientos son históricos e inalterables.';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_inmutable_obra_con_movimientos ON obras;
CREATE TRIGGER trg_inmutable_obra_con_movimientos
BEFORE UPDATE OR DELETE ON obras
FOR EACH ROW EXECUTE FUNCTION fn_proteger_obra_con_movimientos();

-- Una vez que el egreso generó movimientos, bloquea cambios en el documento y líneas.
CREATE OR REPLACE FUNCTION fn_proteger_egreso_registrado()
RETURNS TRIGGER AS $$
DECLARE
    v_tiene_movimiento BOOLEAN;
BEGIN
    IF TG_TABLE_NAME = 'egresos_obra' THEN
        IF TG_OP = 'UPDATE' THEN
            IF OLD.estado = 'BORRADOR' AND NEW.estado = 'REGISTRADO'
               AND (to_jsonb(NEW) - 'estado') = (to_jsonb(OLD) - 'estado') THEN
                RETURN NEW;
            END IF;
        END IF;
        SELECT EXISTS (
            SELECT 1
            FROM detalle_egreso de
            JOIN cardex c ON c.detalle_egreso_id = de.id
            WHERE de.egreso_id = OLD.id
        ) INTO v_tiene_movimiento;
    ELSE
        SELECT EXISTS (
            SELECT 1 FROM cardex WHERE detalle_egreso_id = OLD.id
        ) INTO v_tiene_movimiento;
    END IF;
    IF v_tiene_movimiento THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: No se pueden alterar documentos con movimientos ya registrados.';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_inmutable_egreso_registrado ON egresos_obra;
CREATE TRIGGER trg_inmutable_egreso_registrado
BEFORE UPDATE OR DELETE ON egresos_obra
FOR EACH ROW EXECUTE FUNCTION fn_proteger_egreso_registrado();

DROP TRIGGER IF EXISTS trg_inmutable_detalle_egreso_registrado ON detalle_egreso;
CREATE TRIGGER trg_inmutable_detalle_egreso_registrado
BEFORE UPDATE OR DELETE ON detalle_egreso
FOR EACH ROW EXECUTE FUNCTION fn_proteger_egreso_registrado();

-- El Cardex solo admite inserciones; las correcciones se registran como reversas.
CREATE OR REPLACE FUNCTION fn_bloquear_cardex()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ERROR [FYAG-CARDEX]: Operación denegada. El Cardex es inalterable y de solo inserción (Append-Only).';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_no_update_cardex ON cardex;
CREATE TRIGGER trg_no_update_cardex
BEFORE UPDATE OR DELETE ON cardex
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cardex();

-- TRUNCATE no dispara triggers por fila, por eso se bloquea por separado.
CREATE OR REPLACE FUNCTION fn_bloquear_truncate_cardex()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ERROR [FYAG-CARDEX]: No se permite truncar el Cardex.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_no_truncate_cardex ON cardex;
CREATE TRIGGER trg_no_truncate_cardex
BEFORE TRUNCATE ON cardex
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_truncate_cardex();

DO $$
DECLARE
    v_tabla TEXT;
BEGIN
    FOREACH v_tabla IN ARRAY ARRAY[
        'categorias_articulo', 'proveedores', 'articulos', 'obras',
        'facturas_proveedor', 'detalle_factura', 'egresos_obra', 'detalle_egreso'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_auditoria_operaciones ON %I', v_tabla);
        EXECUTE format(
            'CREATE TRIGGER trg_auditoria_operaciones AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION fn_auditar_operacion()',
            v_tabla
        );
    END LOOP;
END $$;


-- ============================================================================
-- PASO 3: VISTAS ANALÍTICAS Y DATOS SEMILLA (SEED DATA)
-- ============================================================================

-- Artículos cuyo stock llegó o bajó del mínimo definido.
CREATE OR REPLACE VIEW vw_stock_critico AS
SELECT
    id AS articulo_id,
    codigo_sku,
    descripcion,
    stock_actual,
    stock_minimo,
    (stock_minimo - stock_actual) AS unidades_faltantes,
    costo_promedio_ponderado,
    (stock_actual * costo_promedio_ponderado) AS valor_inventario_total,
    especificaciones_tecnicas
FROM articulos
WHERE stock_actual <= stock_minimo;

-- Consulta movimientos con sus documentos, proveedor, obra y valores de inventario.
CREATE OR REPLACE VIEW vw_kardex_valorizado AS
SELECT
    k.id AS kardex_id,
    k.fecha_registro,
    a.codigo_sku,
    a.descripcion AS producto,
    a.unidad_medida,
    u.nombre AS realizado_por,
    f.proveedor_rut_documento,
    f.proveedor_razon_social_documento AS proveedor,
    f.tipo_documento,
    f.numero_factura,
    o.codigo_obra,
    o.nombre AS obra,
    o.cliente,
    k.tecnico_receptor_id,
    eo.responsable_obra AS receptor_nombre,
    k.motivo,
    k.referencia_externa,
    k.tipo_movimiento,
    k.cantidad_entrada,
    k.cantidad_salida,
    k.saldo_stock,
    k.costo_unitario,
    k.saldo_valorizado,
    k.documento_referencia,
    k.reversa_de_id,
    k.hash_integridad
FROM cardex k
JOIN articulos a ON k.articulo_id = a.id
JOIN usuarios u ON k.usuario_id = u.id
LEFT JOIN obras o ON k.obra_id = o.id
LEFT JOIN detalle_factura df ON k.factura_detalle_id = df.id
LEFT JOIN facturas_proveedor f ON df.factura_id = f.id
LEFT JOIN detalle_egreso de ON k.detalle_egreso_id = de.id
LEFT JOIN egresos_obra eo ON de.egreso_id = eo.id
ORDER BY k.fecha_registro DESC;

-- Permisos disponibles para las funciones y pantallas del backend.
INSERT INTO permisos (codigo, descripcion) VALUES
    ('inventario.consultar', 'Permite ver el catálogo y existencias de stock'),
    ('inventario.crear', 'Permite crear nuevos artículos en el catálogo'),
    ('egresos.registrar', 'Permite registrar salidas de materiales hacia obras'),
    ('mermas.registrar', 'Permite registrar mermas justificadas'),
    ('facturas.ingresar', 'Permite ingresar compras de proveedores y calcular IVA'),
    ('devoluciones.registrar', 'Permite registrar devoluciones de obra o proveedor'),
    ('uso_interno.registrar', 'Permite registrar consumo interno de materiales'),
    ('inventario.ajustar', 'Permite registrar ajustes documentados de inventario'),
    ('proveedores.administrar', 'Permite administrar datos de proveedores'),
    ('obras.administrar', 'Permite crear y actualizar obras'),
    ('reportes.exportar', 'Permite descargar informes en PDF y Excel'),
    ('cardex.consultar', 'Permite consultar el historial inalterable de movimientos'),
    ('obras.consultar', 'Permite consultar obras y destinos de materiales'),
    ('usuarios.administrar', 'Permite gestionar perfiles, roles y accesos')
ON CONFLICT (codigo) DO NOTHING;

-- Asigna permisos por nombre de rol, sin depender de IDs SERIAL fijos.
INSERT INTO roles_permisos (rol_id, permiso_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permisos p
WHERE
    (r.nombre = 'ADMIN')
    OR (r.nombre = 'FINANZAS' AND p.codigo IN (
        'inventario.consultar', 'facturas.ingresar', 'reportes.exportar',
        'devoluciones.registrar', 'proveedores.administrar',
        'obras.administrar', 'cardex.consultar', 'obras.consultar'
    ))
    OR (r.nombre = 'BODEGA' AND p.codigo IN (
        'inventario.consultar', 'inventario.crear', 'egresos.registrar',
        'mermas.registrar', 'devoluciones.registrar', 'uso_interno.registrar',
        'inventario.ajustar', 'cardex.consultar', 'obras.consultar'
    ))
    OR (r.nombre = 'SUPERVISOR' AND p.codigo IN (
        'inventario.consultar', 'reportes.exportar', 'cardex.consultar',
        'obras.consultar'
    ))
ON CONFLICT DO NOTHING;

-- Categorías iniciales de ejemplo; se pueden agregar o desactivar desde la aplicación.
INSERT INTO categorias_articulo (nombre) VALUES
    ('REFRIGERACION'),
    ('ELECTRICIDAD'),
    ('AIRE ACONDICIONADO'),
    ('REPUESTOS'),
    ('FITTING'),
    ('FERRETERIA'),
    ('HERRAMIENTAS'),
    ('OTROS')
ON CONFLICT (nombre) DO NOTHING;


-- ============================================================================
-- PASO 4: FUNCIONES TRANSACCIONALES DE NEGOCIO, CÁLCULO PMP Y HASH SHA-256 CON LOCK
-- ============================================================================

-- Calcula SHA-256 incluyendo el hash anterior. El lock serializa la construcción
-- de la cadena cuando varias operaciones de inventario coinciden.
CREATE OR REPLACE FUNCTION fn_calcular_hash_cardex(
    p_articulo_id INT,
    p_usuario_id INT,
    p_tipo_movimiento TEXT,
    p_cant_in DECIMAL(12,3),
    p_cant_out DECIMAL(12,3),
    p_saldo DECIMAL(12,3),
    p_costo DECIMAL,
    p_saldo_valorizado DECIMAL,
    p_factura_detalle_id INT,
    p_detalle_egreso_id INT,
    p_obra_id INT,
    p_reversa_de_id INT,
    p_tecnico_receptor_id TEXT,
    p_motivo TEXT,
    p_referencia_externa TEXT,
    p_doc_referencia TEXT,
    p_fecha TIMESTAMPTZ
) RETURNS VARCHAR(64) AS $$
DECLARE
    v_hash_previo VARCHAR(64) := 'GENESIS_FYAG_ALPHA_2026';
    v_payload TEXT;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));

    SELECT hash_integridad INTO v_hash_previo
    FROM cardex
    ORDER BY id DESC
    LIMIT 1;
    v_hash_previo := COALESCE(v_hash_previo, 'GENESIS_FYAG_ALPHA_2026');

    v_payload := v_hash_previo || '|' || jsonb_build_object(
        'articulo_id', p_articulo_id,
        'usuario_id', p_usuario_id,
        'tipo_movimiento', p_tipo_movimiento,
        'cantidad_entrada', p_cant_in,
        'cantidad_salida', p_cant_out,
        'saldo_stock', p_saldo,
        'costo_unitario', p_costo,
        'saldo_valorizado', p_saldo_valorizado,
        'factura_detalle_id', p_factura_detalle_id,
        'detalle_egreso_id', p_detalle_egreso_id,
        'obra_id', p_obra_id,
        'reversa_de_id', p_reversa_de_id,
        'tecnico_receptor_id', p_tecnico_receptor_id,
        'motivo', p_motivo,
        'referencia_externa', p_referencia_externa,
        'documento_referencia', p_doc_referencia,
        'fecha_utc', to_char(p_fecha AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')
    )::TEXT;

    RETURN encode(digest(v_payload, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

-- Crea el encabezado en borrador y copia los datos del proveedor al documento.
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
BEGIN
    v_actor_id := fn_exigir_permiso('facturas.ingresar');
    SELECT rut, razon_social
    INTO v_proveedor_rut, v_proveedor_nombre
    FROM proveedores
    WHERE id = p_proveedor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: Proveedor inexistente (%).', p_proveedor_id;
    END IF;
    INSERT INTO facturas_proveedor (
        proveedor_id, proveedor_rut_documento, proveedor_razon_social_documento,
        usuario_id, tipo_documento, numero_factura,
        fecha_emision, monto_bruto, descuento_cascada, monto_neto,
        tasa_iva_pct, iva, monto_total, datos_dte
    ) VALUES (
        p_proveedor_id, v_proveedor_rut, v_proveedor_nombre,
        v_actor_id, p_tipo_documento, p_numero_documento,
        p_fecha_emision, p_monto_bruto, p_descuento, p_monto_neto,
        p_tasa_iva, p_iva, p_monto_total, COALESCE(p_datos_dte, '{}'::jsonb)
    ) RETURNING id INTO v_factura_id;
    RETURN v_factura_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

-- Inserta las líneas, calcula descuentos/IVA, actualiza stock y costo promedio,
-- y registra el Cardex antes de cerrar la factura como registrada.
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
        RAISE EXCEPTION 'ERROR [FYAG-COMPRA]: El tipo de documento requiere un flujo distinto al ingreso de compra.';
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

-- Crea un egreso en borrador tras validar actor, obra y datos de recepción.
CREATE OR REPLACE FUNCTION fn_crear_egreso_obra(
    p_obra_id INT,
    p_tecnico_receptor_id VARCHAR(50),
    p_responsable_obra VARCHAR(100),
    p_motivo TEXT,
    p_evidencia JSONB DEFAULT '{}'::jsonb
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_egreso_id INT;
BEGIN
    v_actor_id := fn_exigir_permiso('egresos.registrar');
    IF p_tecnico_receptor_id IS NULL OR length(trim(p_tecnico_receptor_id)) = 0
       OR p_responsable_obra IS NULL OR length(trim(p_responsable_obra)) = 0
       OR p_motivo IS NULL OR length(trim(p_motivo)) = 0
       OR jsonb_typeof(p_evidencia) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: Receptor, responsable, motivo y evidencia válida son requeridos.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM obras WHERE id = p_obra_id AND estado = 'EN_PROCESO') THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: La obra no existe o no está en proceso.';
    END IF;
    INSERT INTO egresos_obra (
        obra_id, responsable_obra, tecnico_receptor_id, motivo,
        usuario_id, evidencia_adjunta
    ) VALUES (
        p_obra_id, p_responsable_obra, p_tecnico_receptor_id, p_motivo,
        v_actor_id, p_evidencia
    ) RETURNING id INTO v_egreso_id;
    RETURN v_egreso_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

-- Registra todas las líneas en una sola transacción; si falla una, PostgreSQL
-- revierte también los cambios previos de stock, detalle y Cardex.
CREATE OR REPLACE FUNCTION fn_registrar_egreso_obra(
    p_egreso_id INT,
    p_lineas JSONB
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_obra_id INT;
    v_tecnico_id VARCHAR(50);
    v_motivo TEXT;
    v_estado VARCHAR(12);
    v_linea JSONB;
    v_articulo_id INT;
    v_cantidad DECIMAL(12,3);
    v_detalle_egreso_id INT;
    v_doc_referencia VARCHAR(100);
    v_stock DECIMAL(12,3);
    v_costo DECIMAL(12,2);
    v_nuevo_stock DECIMAL(12,3);
    v_saldo_valorizado DECIMAL(12,2);
    v_fecha TIMESTAMPTZ;
    v_hash VARCHAR(64);
BEGIN
    v_actor_id := fn_exigir_permiso('egresos.registrar');
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));
    v_fecha := clock_timestamp();
    IF p_egreso_id IS NULL OR p_lineas IS NULL
       OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: Se requiere un egreso y líneas en formato array.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: Se requiere un egreso y al menos una línea.';
    END IF;

    SELECT eo.obra_id, eo.tecnico_receptor_id, eo.motivo, eo.estado
    INTO v_obra_id, v_tecnico_id, v_motivo, v_estado
    FROM egresos_obra eo
    JOIN obras o ON o.id = eo.obra_id AND o.estado = 'EN_PROCESO'
    WHERE eo.id = p_egreso_id AND eo.usuario_id = v_actor_id
    FOR UPDATE OF eo, o;
    IF NOT FOUND OR v_estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: Egreso inexistente, ya registrado, de otro actor o con obra no disponible.';
    END IF;
    v_doc_referencia := 'EGRESO:' || p_egreso_id::TEXT;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        v_articulo_id := (v_linea ->> 'articulo_id')::INT;
        v_cantidad := (v_linea ->> 'cantidad')::DECIMAL(12,3);
        IF v_articulo_id IS NULL OR v_cantidad IS NULL OR v_cantidad <= 0 THEN
            RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: Cada línea requiere artículo y cantidad positiva.';
        END IF;
        SELECT stock_actual, costo_promedio_ponderado
        INTO v_stock, v_costo
        FROM articulos
        WHERE id = v_articulo_id AND activo
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ERROR [FYAG-EGRESO]: El artículo no existe o está inactivo (%).', v_articulo_id;
        END IF;
        IF v_stock < v_cantidad THEN
            RAISE EXCEPTION 'ERROR [FYAG-STOCK]: Artículo %, disponible %, solicitado %.',
                v_articulo_id, v_stock, v_cantidad;
        END IF;

        v_nuevo_stock := v_stock - v_cantidad;
        v_saldo_valorizado := ROUND(v_nuevo_stock * v_costo, 2);
        INSERT INTO detalle_egreso (egreso_id, articulo_id, cantidad_solicitada)
        VALUES (p_egreso_id, v_articulo_id, v_cantidad)
        RETURNING id INTO v_detalle_egreso_id;
        UPDATE articulos SET stock_actual = v_nuevo_stock WHERE id = v_articulo_id;

        v_hash := fn_calcular_hash_cardex(
            v_articulo_id, v_actor_id, 'SALIDA_OBRA', 0, v_cantidad,
            v_nuevo_stock, v_costo, v_saldo_valorizado, NULL,
            v_detalle_egreso_id, v_obra_id, NULL, v_tecnico_id, v_motivo,
            NULL, v_doc_referencia, v_fecha
        );
        INSERT INTO cardex (
            articulo_id, usuario_id, detalle_egreso_id, obra_id,
            tecnico_receptor_id, motivo, fecha_registro, tipo_movimiento,
            cantidad_entrada, cantidad_salida, saldo_stock, costo_unitario,
            saldo_valorizado, documento_referencia, hash_integridad
        ) VALUES (
            v_articulo_id, v_actor_id, v_detalle_egreso_id, v_obra_id,
            v_tecnico_id, v_motivo, v_fecha, 'SALIDA_OBRA',
            0, v_cantidad, v_nuevo_stock, v_costo,
            v_saldo_valorizado, v_doc_referencia, v_hash
        );
    END LOOP;
    UPDATE egresos_obra SET estado = 'REGISTRADO' WHERE id = p_egreso_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

-- Registra saldo inicial, mermas, devoluciones, uso interno y ajustes.
-- Actualiza el artículo y añade el movimiento al Cardex en la misma transacción.
CREATE OR REPLACE FUNCTION fn_registrar_movimiento_inventario(
    p_articulo_id INT,
    p_tipo VARCHAR(24),
    p_cantidad DECIMAL(12,3),
    p_motivo TEXT,
    p_documento_referencia VARCHAR(100),
    p_obra_id INT DEFAULT NULL,
    p_referencia_externa VARCHAR(100) DEFAULT NULL,
    p_origen_id INT DEFAULT NULL,
    p_costo_unitario DECIMAL(12,2) DEFAULT NULL
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_permiso VARCHAR(100);
    v_entrada BOOLEAN;
    v_stock DECIMAL(12,3);
    v_costo DECIMAL(12,2);
    v_nuevo_stock DECIMAL(12,3);
    v_nuevo_pmp DECIMAL(12,2);
    v_saldo_valorizado DECIMAL(12,2);
    v_costo_entrada DECIMAL(12,2);
    v_origen cardex%ROWTYPE;
    v_reversa_id INT;
    v_fecha TIMESTAMPTZ;
    v_hash VARCHAR(64);
    v_movimiento_id INT;
BEGIN
    v_permiso := CASE p_tipo
        WHEN 'SALDO_INICIAL' THEN 'inventario.ajustar'
        WHEN 'AJUSTE_MERMA' THEN 'mermas.registrar'
        WHEN 'DEVOLUCION_OBRA' THEN 'devoluciones.registrar'
        WHEN 'DEVOLUCION_PROVEEDOR' THEN 'devoluciones.registrar'
        WHEN 'USO_INTERNO' THEN 'uso_interno.registrar'
        WHEN 'AJUSTE_ENTRADA' THEN 'inventario.ajustar'
        WHEN 'AJUSTE_SALIDA' THEN 'inventario.ajustar'
        ELSE NULL
    END;
    IF v_permiso IS NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: Tipo de movimiento no permitido por esta operación.';
    END IF;
    v_actor_id := fn_exigir_permiso(v_permiso);
    PERFORM pg_advisory_xact_lock(hashtext('fyag_kardex_chain_lock'));
    v_fecha := clock_timestamp();
    IF p_cantidad IS NULL OR p_cantidad <= 0
       OR p_motivo IS NULL OR length(trim(p_motivo)) = 0
       OR p_documento_referencia IS NULL OR length(trim(p_documento_referencia)) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: Cantidad, motivo y documento de referencia son obligatorios.';
    END IF;

    v_entrada := p_tipo IN ('SALDO_INICIAL', 'DEVOLUCION_OBRA', 'AJUSTE_ENTRADA');
    IF p_origen_id IS NOT NULL AND p_tipo NOT IN (
        'DEVOLUCION_OBRA', 'DEVOLUCION_PROVEEDOR', 'AJUSTE_ENTRADA', 'AJUSTE_SALIDA'
    ) THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: Este tipo no admite un movimiento de origen.';
    END IF;
    IF p_tipo IN ('DEVOLUCION_OBRA', 'DEVOLUCION_PROVEEDOR') AND p_origen_id IS NULL THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: La devolución debe vincularse al movimiento original.';
    END IF;
    IF p_tipo = 'SALDO_INICIAL' AND
       (p_origen_id IS NOT NULL OR p_costo_unitario IS NULL OR p_costo_unitario < 0) THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: El saldo inicial requiere costo unitario y no admite origen.';
    END IF;
    IF p_tipo = 'AJUSTE_ENTRADA' AND p_origen_id IS NULL
       AND (p_costo_unitario IS NULL OR p_costo_unitario < 0) THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: El ajuste de entrada requiere costo unitario u origen.';
    END IF;
    IF p_origen_id IS NOT NULL THEN
        SELECT * INTO v_origen FROM cardex WHERE id = p_origen_id FOR SHARE;
        IF NOT FOUND OR v_origen.articulo_id <> p_articulo_id
           OR (p_tipo = 'DEVOLUCION_OBRA' AND
               (v_origen.tipo_movimiento <> 'SALIDA_OBRA' OR v_origen.obra_id IS DISTINCT FROM p_obra_id))
           OR (p_tipo = 'AJUSTE_ENTRADA' AND v_origen.tipo_movimiento = 'SALIDA_OBRA'
               AND v_origen.obra_id IS DISTINCT FROM p_obra_id)
           OR (p_tipo = 'DEVOLUCION_PROVEEDOR' AND v_origen.tipo_movimiento <> 'ENTRADA_COMPRA')
           OR (p_tipo IN ('AJUSTE_ENTRADA', 'DEVOLUCION_OBRA') AND v_origen.cantidad_salida = 0)
           OR (p_tipo IN ('AJUSTE_SALIDA', 'DEVOLUCION_PROVEEDOR') AND v_origen.cantidad_entrada = 0) THEN
            RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: El origen no coincide con artículo o dirección del movimiento.';
        END IF;
        IF COALESCE((
            SELECT SUM(cantidad_entrada + cantidad_salida)
            FROM cardex WHERE reversa_de_id = p_origen_id
        ), 0) + p_cantidad > v_origen.cantidad_entrada + v_origen.cantidad_salida THEN
            RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: La cantidad acumulada excede el movimiento original.';
        END IF;
        v_reversa_id := p_origen_id;
        IF p_tipo = 'DEVOLUCION_OBRA' THEN
            p_obra_id := v_origen.obra_id;
        END IF;
    END IF;

    SELECT stock_actual, costo_promedio_ponderado
    INTO v_stock, v_costo
    FROM articulos WHERE id = p_articulo_id AND activo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: Artículo inexistente o inactivo (%).', p_articulo_id;
    END IF;
    IF p_tipo = 'SALDO_INICIAL' AND
       (v_stock <> 0 OR EXISTS (SELECT 1 FROM cardex WHERE articulo_id = p_articulo_id)) THEN
        RAISE EXCEPTION 'ERROR [FYAG-MOVIMIENTO]: El artículo ya tiene saldo o movimientos; no admite saldo inicial.';
    END IF;
    IF NOT v_entrada AND v_stock < p_cantidad THEN
        RAISE EXCEPTION 'ERROR [FYAG-STOCK]: Disponible %, solicitado %.', v_stock, p_cantidad;
    END IF;

    v_nuevo_stock := v_stock + CASE WHEN v_entrada THEN p_cantidad ELSE -p_cantidad END;
    IF v_entrada THEN
        v_costo_entrada := CASE WHEN p_origen_id IS NOT NULL
            THEN v_origen.costo_unitario ELSE COALESCE(p_costo_unitario, v_costo) END;
        v_nuevo_pmp := ROUND(((v_stock * v_costo) + (p_cantidad * v_costo_entrada)) / v_nuevo_stock, 2);
        v_costo := v_costo_entrada;
    ELSE
        v_nuevo_pmp := v_costo;
    END IF;
    v_saldo_valorizado := ROUND(v_nuevo_stock * v_nuevo_pmp, 2);
    UPDATE articulos
    SET stock_actual = v_nuevo_stock, costo_promedio_ponderado = v_nuevo_pmp
    WHERE id = p_articulo_id;

    v_hash := fn_calcular_hash_cardex(
        p_articulo_id, v_actor_id, p_tipo::TEXT,
        CASE WHEN v_entrada THEN p_cantidad ELSE 0 END,
        CASE WHEN v_entrada THEN 0 ELSE p_cantidad END,
        v_nuevo_stock, v_costo, v_saldo_valorizado, NULL, NULL,
        p_obra_id, v_reversa_id, NULL, p_motivo, p_referencia_externa,
        p_documento_referencia, v_fecha
    );
    INSERT INTO cardex (
        articulo_id, usuario_id, obra_id, reversa_de_id, motivo,
        referencia_externa, fecha_registro, tipo_movimiento,
        cantidad_entrada, cantidad_salida, saldo_stock, costo_unitario,
        saldo_valorizado, documento_referencia, hash_integridad
    ) VALUES (
        p_articulo_id, v_actor_id, p_obra_id, v_reversa_id, p_motivo,
        p_referencia_externa, v_fecha, p_tipo,
        CASE WHEN v_entrada THEN p_cantidad ELSE 0 END,
        CASE WHEN v_entrada THEN 0 ELSE p_cantidad END,
        v_nuevo_stock, v_costo, v_saldo_valorizado, p_documento_referencia, v_hash
    ) RETURNING id INTO v_movimiento_id;
    RETURN v_movimiento_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

-- Genera un ajuste inverso ligado al movimiento original; no modifica el original.
CREATE OR REPLACE FUNCTION fn_reversar_movimiento(
    p_cardex_id INT,
    p_cantidad DECIMAL(12,3),
    p_motivo TEXT
) RETURNS INT AS $$
DECLARE
    v_origen cardex%ROWTYPE;
    v_tipo VARCHAR(24);
BEGIN
    PERFORM fn_exigir_permiso('inventario.ajustar');
    SELECT * INTO v_origen FROM cardex WHERE id = p_cardex_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-REVERSA]: Movimiento de origen inexistente (%).', p_cardex_id;
    END IF;
    v_tipo := CASE WHEN v_origen.cantidad_entrada > 0
        THEN 'AJUSTE_SALIDA'
        ELSE 'AJUSTE_ENTRADA'
    END;
    RETURN fn_registrar_movimiento_inventario(
        v_origen.articulo_id, v_tipo, p_cantidad, p_motivo,
        'REVERSA:CARDEX:' || p_cardex_id::TEXT,
        v_origen.obra_id, NULL, p_cardex_id, NULL
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;

-- Elimina tokens revocados ya vencidos; debe llamarse con permiso de administración.
CREATE OR REPLACE FUNCTION fn_limpiar_tokens_expirados()
RETURNS INT AS $$
DECLARE
    v_filas_eliminadas INT;
BEGIN
    PERFORM fn_exigir_permiso('usuarios.administrar');
    DELETE FROM tokens_revocados
    WHERE expira_en < CURRENT_TIMESTAMP;

    GET DIAGNOSTICS v_filas_eliminadas = ROW_COUNT;
    RETURN v_filas_eliminadas;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp;


-- ============================================================================
-- PASO 5: PRIVILEGIOS MÍNIMOS PARA EL BACKEND
-- ============================================================================

-- No se crea un usuario ni una contraseña de conexión. En Supabase, configura
-- la credencial del backend y otórgale membresía en alpha_backend. No la expongas
-- en el navegador ni la guardes en el repositorio.
-- Rol de grupo sin inicio de sesión propio; se asigna al usuario de conexión del backend.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'alpha_backend') THEN
        CREATE ROLE alpha_backend NOLOGIN;
    END IF;
END $$;

-- El acceso se controla con GRANT/REVOKE; este script no activa RLS.
-- Quita acceso directo a tablas, secuencias y funciones para los roles de cliente.
-- alpha_backend recibe solo los permisos concedidos explícitamente más abajo.
REVOKE ALL ON TABLE
    roles, permisos, roles_permisos, usuarios, tokens_revocados,
    auditoria_usuarios, auditoria_operaciones, categorias_articulo, proveedores,
    articulos, obras, facturas_proveedor, detalle_factura, egresos_obra,
    detalle_egreso, cardex, vw_stock_critico, vw_kardex_valorizado
FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE
    roles_id_seq, permisos_id_seq, usuarios_id_seq, auditoria_usuarios_id_seq,
    auditoria_operaciones_id_seq, categorias_articulo_id_seq, proveedores_id_seq,
    articulos_id_seq, obras_id_seq, facturas_proveedor_id_seq, detalle_factura_id_seq,
    egresos_obra_id_seq, detalle_egreso_id_seq, cardex_id_seq
FROM PUBLIC, anon, authenticated, service_role;
-- PostgreSQL concede EXECUTE a PUBLIC por defecto al crear funciones nuevas;
-- se revoca aquí y luego se habilitan solo las operaciones necesarias al backend.
REVOKE EXECUTE ON FUNCTION
    fn_validar_rut_chileno(TEXT),
    fn_auditar_cambios_usuarios(),
    fn_exigir_permiso(VARCHAR),
    fn_anonimizar_usuario(INT),
    fn_bloquear_cambios_auditoria(),
    fn_auditar_operacion(),
    fn_proteger_documentos_registrados(),
    fn_validar_stock_inicial_articulo(),
    fn_proteger_articulo_con_movimientos(),
    fn_proteger_obra_con_movimientos(),
    fn_bloquear_cardex(),
    fn_bloquear_truncate_cardex(),
    fn_calcular_hash_cardex(INT, INT, TEXT, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, INT, INT, INT, INT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ),
    fn_crear_factura_proveedor(INT, VARCHAR, VARCHAR, DATE, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, JSONB),
    fn_registrar_ingreso_compra(INT, JSONB),
    fn_crear_egreso_obra(INT, VARCHAR, VARCHAR, TEXT, JSONB),
    fn_proteger_egreso_registrado(),
    fn_registrar_egreso_obra(INT, JSONB),
    fn_registrar_movimiento_inventario(INT, VARCHAR, DECIMAL, TEXT, VARCHAR, INT, VARCHAR, INT, DECIMAL),
    fn_reversar_movimiento(INT, DECIMAL, TEXT),
    fn_limpiar_tokens_expirados()
FROM PUBLIC, anon, authenticated, service_role;

GRANT USAGE ON SCHEMA public TO alpha_backend;
-- Lectura para consultas del backend; las escrituras se limitan por tabla/columna
-- o se realizan mediante funciones transaccionales con SECURITY DEFINER.
GRANT SELECT ON TABLE
    roles, permisos, roles_permisos, usuarios, tokens_revocados,
    auditoria_usuarios, auditoria_operaciones, categorias_articulo, proveedores,
    articulos, obras, facturas_proveedor, detalle_factura, egresos_obra,
    detalle_egreso, cardex, vw_stock_critico, vw_kardex_valorizado
TO alpha_backend;
GRANT USAGE, SELECT ON SEQUENCE
    roles_id_seq, permisos_id_seq, usuarios_id_seq, categorias_articulo_id_seq, proveedores_id_seq,
    articulos_id_seq, obras_id_seq
TO alpha_backend;

-- Se permite crear el artículo con stock/costo en cero. El trigger impide saldos
-- iniciales manuales; estos deben registrarse por la función de movimientos.
GRANT INSERT (
    codigo_sku, codigo_barras, descripcion, categoria_id, unidad_medida,
    ubicacion, sector_bodega, stock_actual, stock_minimo,
    costo_promedio_ponderado, activo, especificaciones_tecnicas, creado_en
) ON articulos TO alpha_backend;
GRANT UPDATE (
    codigo_sku, codigo_barras, descripcion, categoria_id, unidad_medida,
    ubicacion, sector_bodega, stock_minimo, activo, especificaciones_tecnicas
) ON articulos TO alpha_backend;

GRANT INSERT (nombre, descripcion, creado_en) ON roles TO alpha_backend;
GRANT INSERT (codigo, descripcion, creado_en) ON permisos TO alpha_backend;
GRANT INSERT (rol_id, permiso_id) ON roles_permisos TO alpha_backend;
GRANT INSERT (
    rut, nombre, correo, password_hash, rol_id, activo, intentos_fallidos,
    bloqueado_hasta, ultimo_ingreso, password_modificado_en, creado_en
) ON usuarios TO alpha_backend;
GRANT UPDATE (
    nombre, correo, password_hash, rol_id, activo, intentos_fallidos,
    bloqueado_hasta, ultimo_ingreso, password_modificado_en
) ON usuarios TO alpha_backend;

-- Catálogos editables por el backend. La autorización por usuario también debe
-- comprobarse en la aplicación antes de ejecutar estas escrituras directas.
GRANT INSERT, UPDATE ON categorias_articulo, proveedores, obras TO alpha_backend;
GRANT INSERT ON tokens_revocados TO alpha_backend;

GRANT EXECUTE ON FUNCTION fn_validar_rut_chileno(TEXT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_anonimizar_usuario(INT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_crear_factura_proveedor(INT, VARCHAR, VARCHAR, DATE, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_ingreso_compra(INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_crear_egreso_obra(INT, VARCHAR, VARCHAR, TEXT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_egreso_obra(INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_movimiento_inventario(INT, VARCHAR, DECIMAL, TEXT, VARCHAR, INT, VARCHAR, INT, DECIMAL) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_reversar_movimiento(INT, DECIMAL, TEXT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_limpiar_tokens_expirados() TO alpha_backend;

-- Cardex y auditorías son de solo lectura para el backend: las escrituras ocurren
-- dentro de funciones/triggers controlados, no mediante ORM directo.
REVOKE ALL ON cardex, auditoria_usuarios, auditoria_operaciones FROM alpha_backend;
REVOKE ALL ON cardex, auditoria_usuarios, auditoria_operaciones FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON cardex, auditoria_usuarios, auditoria_operaciones TO alpha_backend;

COMMIT;
