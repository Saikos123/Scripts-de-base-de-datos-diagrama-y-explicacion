-- ============================================================================
-- PROYECTO ALPHA (FYAG SpA) - ESQUEMA POSTGRESQL 
-- ============================================================================

-- Alcance y condiciones de instalación:
-- Este archivo crea el esquema inicial para una base de desarrollo de Alpha.
-- IF NOT EXISTS no actualiza tablas que ya existan con otra estructura; las
-- actualizaciones posteriores requieren migraciones controladas.
-- Las fechas se almacenan como TIMESTAMPTZ. La capa de presentación convierte
-- los valores a America/Santiago; no se modifica la configuración global de
-- Supabase.
-- El backend valida JWT y permisos, y establece app.current_user_id con
-- SET LOCAL en cada transacción. Este identificador de sesión no autentica por
-- sí solo al usuario. alpha_backend se utiliza desde el backend confiable, no
-- desde el navegador.
-- Las funciones SECURITY DEFINER incluyen public en su search_path. El esquema
-- no debe conceder CREATE a roles no confiables.
-- Los JSONB de evidencia y DTE almacenan metadatos y rutas de Supabase Storage,
-- no archivos binarios ni URLs firmadas de corta duración. La política de
-- retención debe definirse antes de anonimizar datos; la operación no modifica
-- respaldos.

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
    cliente_id INT REFERENCES clientes(id) ON DELETE RESTRICT,
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
    documento_origen_id INT REFERENCES facturas_proveedor(id) ON DELETE RESTRICT,
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
    CONSTRAINT uq_documento_proveedor UNIQUE (proveedor_id, tipo_documento, numero_factura),
    CONSTRAINT chk_documento_origen_tipo CHECK (
        (tipo_documento = 'NOTA_CREDITO' AND documento_origen_id IS NOT NULL)
        OR (tipo_documento = 'FACTURA')
        OR (tipo_documento IN ('BOLETA', 'GUIA_DESPACHO') AND documento_origen_id IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_facturas_dte_gin ON facturas_proveedor USING GIN (datos_dte jsonb_path_ops);
CREATE UNIQUE INDEX IF NOT EXISTS uq_factura_por_guia
    ON facturas_proveedor(documento_origen_id)
    WHERE tipo_documento = 'FACTURA' AND documento_origen_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_documentos_origen
    ON facturas_proveedor(documento_origen_id) WHERE documento_origen_id IS NOT NULL;

-- Líneas de compra; las restricciones comprueban subtotales y descuentos.
CREATE TABLE IF NOT EXISTS detalle_factura (
    id SERIAL PRIMARY KEY,
    factura_id INT NOT NULL REFERENCES facturas_proveedor(id) ON DELETE CASCADE,
    detalle_guia_id INT REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    detalle_documento_origen_id INT REFERENCES detalle_factura(id) ON DELETE RESTRICT,
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
    ),
    CONSTRAINT chk_detalle_origenes_mutuamente_excluyentes CHECK (
        detalle_guia_id IS NULL OR detalle_documento_origen_id IS NULL
    )
);

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

DROP TRIGGER IF EXISTS trg_validar_detalle_documento_origen ON detalle_factura;
CREATE TRIGGER trg_validar_detalle_documento_origen
BEFORE INSERT OR UPDATE OF factura_id, articulo_id, cantidad,
    detalle_guia_id, detalle_documento_origen_id
ON detalle_factura
FOR EACH ROW EXECUTE FUNCTION fn_validar_detalle_documento_origen();

CREATE UNIQUE INDEX IF NOT EXISTS uq_detalle_factura_guia
    ON detalle_factura(detalle_guia_id) WHERE detalle_guia_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_detalle_factura_factura
    ON detalle_factura(factura_id);
CREATE INDEX IF NOT EXISTS idx_detalle_factura_documento_origen
    ON detalle_factura(detalle_documento_origen_id)
    WHERE detalle_documento_origen_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cliente_sin_rut
    ON clientes (lower(trim(razon_social))) WHERE rut IS NULL;

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
            'AJUSTE_ENTRADA', 'AJUSTE_SALIDA', 'AJUSTE_VALORIZACION'
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
        ) OR (
            tipo_movimiento = 'AJUSTE_VALORIZACION'
            AND cantidad_entrada = 0 AND cantidad_salida = 0
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

CREATE TABLE IF NOT EXISTS devoluciones_proveedor (
    id SERIAL PRIMARY KEY,
    nota_credito_id INT NOT NULL REFERENCES facturas_proveedor(id) ON DELETE RESTRICT,
    detalle_nota_id INT NOT NULL UNIQUE REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    detalle_compra_origen_id INT NOT NULL REFERENCES detalle_factura(id) ON DELETE RESTRICT,
    movimiento_cardex_id INT NOT NULL UNIQUE REFERENCES cardex(id) ON DELETE RESTRICT,
    cantidad DECIMAL(12,3) NOT NULL CHECK (cantidad > 0),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

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
        'categorias_articulo', 'proveedores', 'contactos_proveedor', 'clientes',
        'articulos', 'obras',
        'facturas_proveedor', 'detalle_factura', 'egresos_obra', 'detalle_egreso',
        'devoluciones_proveedor'
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

CREATE OR REPLACE VIEW vw_stock_despachable AS
SELECT
    a.id AS articulo_id,
    a.codigo_sku,
    a.descripcion,
    a.stock_actual,
    fn_stock_pendiente_guia(a.id) AS reservado_guia_pendiente,
    a.stock_actual - fn_stock_pendiente_guia(a.id) AS disponible_despacho
FROM articulos a;

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

DROP TRIGGER IF EXISTS trg_proteger_stock_guia_pendiente ON articulos;
CREATE TRIGGER trg_proteger_stock_guia_pendiente
BEFORE UPDATE OF stock_actual ON articulos
FOR EACH ROW EXECUTE FUNCTION fn_proteger_stock_guia_pendiente();

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

CREATE TABLE IF NOT EXISTS auditoria_cuentas_bancarias (
    id BIGSERIAL PRIMARY KEY,
    cuenta_id INT NOT NULL,
    proveedor_id INT NOT NULL,
    usuario_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    accion VARCHAR(10) NOT NULL CHECK (accion IN ('CREAR', 'ACTUALIZAR')),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

DROP TRIGGER IF EXISTS trg_no_update_delete_auditoria_cuentas ON auditoria_cuentas_bancarias;
CREATE TRIGGER trg_no_update_delete_auditoria_cuentas
BEFORE UPDATE OR DELETE ON auditoria_cuentas_bancarias
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

DROP TRIGGER IF EXISTS trg_no_truncate_auditoria_cuentas ON auditoria_cuentas_bancarias;
CREATE TRIGGER trg_no_truncate_auditoria_cuentas
BEFORE TRUNCATE ON auditoria_cuentas_bancarias
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios_auditoria();

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
    v_pendiente_guia DECIMAL(12,3);
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
        v_pendiente_guia := fn_stock_pendiente_guia(v_articulo_id);
        IF v_stock - v_pendiente_guia < v_cantidad THEN
            RAISE EXCEPTION 'ERROR [FYAG-STOCK]: Artículo %, stock %, reservado por guías pendientes %, disponible para despacho %, solicitado %.',
                v_articulo_id, v_stock, v_pendiente_guia,
                v_stock - v_pendiente_guia, v_cantidad;
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
    v_pendiente_guia DECIMAL(12,3);
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
    v_pendiente_guia := fn_stock_pendiente_guia(p_articulo_id);
    IF NOT v_entrada AND p_cantidad > 0
       AND v_stock - v_pendiente_guia < p_cantidad THEN
        RAISE EXCEPTION 'ERROR [FYAG-STOCK]: Stock %, reservado por guías pendientes %, disponible %, solicitado %.',
            v_stock, v_pendiente_guia, v_stock - v_pendiente_guia, p_cantidad;
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

-- Eliminación de tokens revocados vencidos; requiere permiso de administración.
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
    auditoria_usuarios, auditoria_operaciones, auditoria_cuentas_bancarias,
    categorias_articulo, proveedores, contactos_proveedor, cuentas_bancarias_proveedor,
    clientes,
    articulos, obras, facturas_proveedor, detalle_factura, devoluciones_proveedor, egresos_obra,
    detalle_egreso, cardex, vw_stock_critico, vw_kardex_valorizado,
    vw_stock_despachable
FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE
    roles_id_seq, permisos_id_seq, usuarios_id_seq, auditoria_usuarios_id_seq,
    auditoria_operaciones_id_seq, categorias_articulo_id_seq, proveedores_id_seq,
    auditoria_cuentas_bancarias_id_seq, contactos_proveedor_id_seq,
    cuentas_bancarias_proveedor_id_seq, clientes_id_seq,
    articulos_id_seq, obras_id_seq, facturas_proveedor_id_seq, detalle_factura_id_seq,
    egresos_obra_id_seq, detalle_egreso_id_seq, cardex_id_seq,
    devoluciones_proveedor_id_seq
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
    fn_generar_hash_cardex(),
    fn_verificar_integridad_cardex(),
    fn_stock_pendiente_guia(INT),
    fn_proteger_stock_guia_pendiente(),
    fn_registrar_recepcion_guia(INT, JSONB),
    fn_registrar_devolucion_proveedor(INT, JSONB),
    fn_ajustar_valorizacion_factura(INT, INT),
    fn_guardar_cuenta_bancaria_proveedor(INT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, INT),
    fn_listar_cuentas_bancarias_proveedor(INT),
    fn_crear_factura_proveedor(INT, VARCHAR, VARCHAR, DATE, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, JSONB),
    fn_registrar_ingreso_compra(INT, JSONB),
    fn_vincular_factura_guia(INT, INT, JSONB),
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
    contactos_proveedor, clientes,
    articulos, obras, facturas_proveedor, detalle_factura, devoluciones_proveedor, egresos_obra,
    detalle_egreso, cardex, vw_stock_critico, vw_kardex_valorizado,
    vw_stock_despachable
TO alpha_backend;
GRANT USAGE, SELECT ON SEQUENCE
    roles_id_seq, permisos_id_seq, usuarios_id_seq, categorias_articulo_id_seq, proveedores_id_seq,
    contactos_proveedor_id_seq, clientes_id_seq,
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
GRANT INSERT, UPDATE ON contactos_proveedor, clientes TO alpha_backend;
GRANT INSERT ON tokens_revocados TO alpha_backend;

GRANT EXECUTE ON FUNCTION fn_validar_rut_chileno(TEXT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_verificar_integridad_cardex() TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_anonimizar_usuario(INT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_crear_factura_proveedor(INT, VARCHAR, VARCHAR, DATE, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, DECIMAL, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_ingreso_compra(INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_recepcion_guia(INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_registrar_devolucion_proveedor(INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_vincular_factura_guia(INT, INT, JSONB) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_guardar_cuenta_bancaria_proveedor(INT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, INT) TO alpha_backend;
GRANT EXECUTE ON FUNCTION fn_listar_cuentas_bancarias_proveedor(INT) TO alpha_backend;
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
REVOKE ALL ON cuentas_bancarias_proveedor, auditoria_cuentas_bancarias
    FROM alpha_backend, PUBLIC, anon, authenticated, service_role;

COMMIT;
