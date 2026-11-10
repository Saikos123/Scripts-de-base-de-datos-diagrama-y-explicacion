-- Migracion aditiva para instalaciones que ya ejecutaron script.sql.
-- No volver a ejecutar script.sql sobre una base existente para aplicar estos cambios.
-- Las firmas se almacenan en Supabase Storage; PostgreSQL conserva solo sus metadatos.

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.usuarios') IS NULL
       OR to_regclass('public.obras') IS NULL
       OR to_regclass('public.articulos') IS NULL
       OR to_regclass('public.egresos_obra') IS NULL
       OR to_regclass('public.detalle_egreso') IS NULL
       OR to_regclass('public.auditoria_operaciones') IS NULL
       OR to_regclass('public.permisos') IS NULL
       OR to_regclass('public.roles') IS NULL
       OR to_regclass('public.roles_permisos') IS NULL THEN
        RAISE EXCEPTION 'La migracion requiere el esquema base de Proyecto Alpha.';
    END IF;
    IF to_regprocedure('public.fn_exigir_permiso(character varying)') IS NULL
       OR to_regprocedure('public.fn_auditar_operacion()') IS NULL THEN
        RAISE EXCEPTION 'La migracion requiere las funciones de permisos y auditoria del esquema base.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'alpha_backend') THEN
        RAISE EXCEPTION 'No existe alpha_backend. Ejecute y valide primero el esquema base.';
    END IF;
END;
$$;

INSERT INTO permisos (codigo, descripcion) VALUES
    ('solicitudes.crear', 'Permite crear y cancelar solicitudes de materiales propias'),
    ('solicitudes.consultar', 'Permite consultar solicitudes de materiales'),
    ('solicitudes.gestionar', 'Permite aprobar o rechazar solicitudes y asociarlas a egresos'),
    ('egresos.acuse', 'Permite registrar el acuse de recepcion de un egreso')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO roles_permisos (rol_id, permiso_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permisos p
WHERE (r.nombre = 'ADMIN'
       AND p.codigo IN (
           'solicitudes.crear', 'solicitudes.consultar',
           'solicitudes.gestionar', 'egresos.acuse'
       ))
   OR (r.nombre = 'BODEGA'
       AND p.codigo IN ('solicitudes.consultar', 'solicitudes.gestionar', 'egresos.acuse'))
   OR (r.nombre = 'SUPERVISOR'
       AND p.codigo IN ('solicitudes.crear', 'solicitudes.consultar'))
ON CONFLICT (rol_id, permiso_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS solicitudes_materiales (
    id SERIAL PRIMARY KEY,
    obra_id INT NOT NULL REFERENCES obras(id) ON DELETE RESTRICT,
    solicitante_id INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    motivo TEXT NOT NULL CHECK (length(trim(motivo)) > 0),
    estado VARCHAR(12) NOT NULL DEFAULT 'PENDIENTE'
        CHECK (estado IN ('PENDIENTE', 'APROBADA', 'RECHAZADA', 'CANCELADA', 'DESPACHADA')),
    creada_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revisada_por INT REFERENCES usuarios(id) ON DELETE RESTRICT,
    revisada_en TIMESTAMPTZ,
    comentario_revision TEXT,
    egreso_id INT UNIQUE REFERENCES egresos_obra(id) ON DELETE RESTRICT,
    despachada_en TIMESTAMPTZ,
    CHECK (
        (estado IN ('PENDIENTE', 'CANCELADA') AND revisada_por IS NULL AND revisada_en IS NULL)
        OR (estado IN ('APROBADA', 'RECHAZADA', 'DESPACHADA')
            AND revisada_por IS NOT NULL AND revisada_en IS NOT NULL)
    ),
    CHECK (
        (estado IN ('APROBADA', 'RECHAZADA', 'CANCELADA', 'PENDIENTE') AND despachada_en IS NULL)
        OR (estado = 'DESPACHADA' AND despachada_en IS NOT NULL AND egreso_id IS NOT NULL)
    ),
    CHECK (estado <> 'RECHAZADA' OR length(trim(COALESCE(comentario_revision, ''))) > 0)
);

CREATE TABLE IF NOT EXISTS detalle_solicitud_materiales (
    id SERIAL PRIMARY KEY,
    solicitud_id INT NOT NULL REFERENCES solicitudes_materiales(id) ON DELETE CASCADE,
    articulo_id INT NOT NULL REFERENCES articulos(id) ON DELETE RESTRICT,
    cantidad_solicitada DECIMAL(12,3) NOT NULL CHECK (cantidad_solicitada > 0),
    detalle_tecnico TEXT,
    UNIQUE (solicitud_id, articulo_id)
);

CREATE INDEX IF NOT EXISTS idx_solicitudes_estado_fecha
    ON solicitudes_materiales (estado, creada_en DESC);
CREATE INDEX IF NOT EXISTS idx_solicitudes_solicitante_fecha
    ON solicitudes_materiales (solicitante_id, creada_en DESC);
CREATE INDEX IF NOT EXISTS idx_solicitudes_obra_fecha
    ON solicitudes_materiales (obra_id, creada_en DESC);

CREATE TABLE IF NOT EXISTS acuses_recepcion_egreso (
    id SERIAL PRIMARY KEY,
    egreso_id INT NOT NULL UNIQUE REFERENCES egresos_obra(id) ON DELETE RESTRICT,
    receptor_nombre VARCHAR(150) NOT NULL CHECK (length(trim(receptor_nombre)) > 0),
    receptor_identificador VARCHAR(50),
    recibido_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    storage_bucket VARCHAR(100) NOT NULL CHECK (length(trim(storage_bucket)) > 0),
    storage_path TEXT NOT NULL CHECK (
        length(trim(storage_path)) > 0
        AND storage_path !~ '(^/|(^|/)\.\.(/|$)|^https?://)'
    ),
    sha256_archivo VARCHAR(64) CHECK (sha256_archivo IS NULL OR sha256_archivo ~ '^[0-9a-fA-F]{64}$'),
    registrado_por INT NOT NULL REFERENCES usuarios(id) ON DELETE RESTRICT,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION fn_crear_solicitud_materiales(
    p_obra_id INT,
    p_motivo TEXT,
    p_lineas JSONB
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_solicitud_id INT;
    v_linea JSONB;
    v_articulo_id INT;
    v_cantidad DECIMAL(12,3);
BEGIN
    v_actor_id := fn_exigir_permiso('solicitudes.crear');

    IF p_motivo IS NULL OR length(trim(p_motivo)) = 0
       OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Se requiere motivo y una lista de articulos.';
    END IF;
    IF jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Se requiere motivo y al menos un articulo.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM obras WHERE id = p_obra_id AND estado = 'EN_PROCESO') THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: La obra no existe o no esta en proceso.';
    END IF;

    INSERT INTO solicitudes_materiales (obra_id, solicitante_id, motivo)
    VALUES (p_obra_id, v_actor_id, p_motivo)
    RETURNING id INTO v_solicitud_id;

    FOR v_linea IN SELECT value FROM jsonb_array_elements(p_lineas)
    LOOP
        IF jsonb_typeof(v_linea) IS DISTINCT FROM 'object'
           OR COALESCE(v_linea->>'articulo_id', '') !~ '^[1-9][0-9]*$'
           OR COALESCE(v_linea->>'cantidad', '') !~ '^[0-9]+([.][0-9]{1,3})?$' THEN
            RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Cada linea requiere articulo_id y cantidad valida.';
        END IF;

        v_articulo_id := (v_linea->>'articulo_id')::INT;
        v_cantidad := (v_linea->>'cantidad')::DECIMAL(12,3);
        IF v_cantidad <= 0 THEN
            RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: La cantidad debe ser mayor que cero.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM detalle_solicitud_materiales
            WHERE solicitud_id = v_solicitud_id AND articulo_id = v_articulo_id
        ) THEN
            RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: No repita articulos; consolide las cantidades.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM articulos WHERE id = v_articulo_id AND activo) THEN
            RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: El articulo no existe o esta inactivo.';
        END IF;

        INSERT INTO detalle_solicitud_materiales (
            solicitud_id, articulo_id, cantidad_solicitada, detalle_tecnico
        ) VALUES (
            v_solicitud_id,
            v_articulo_id,
            v_cantidad,
            NULLIF(trim(v_linea->>'detalle_tecnico'), '')
        );
    END LOOP;

    RETURN v_solicitud_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_cancelar_solicitud_materiales(p_solicitud_id INT)
RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_solicitante_id INT;
    v_estado VARCHAR(12);
BEGIN
    v_actor_id := fn_exigir_permiso('solicitudes.crear');
    SELECT solicitante_id, estado
    INTO v_solicitante_id, v_estado
    FROM solicitudes_materiales
    WHERE id = p_solicitud_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: La solicitud no existe.';
    END IF;
    IF v_solicitante_id <> v_actor_id THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Solo quien la solicito puede cancelarla.';
    END IF;
    IF v_estado <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Solo se pueden cancelar solicitudes pendientes.';
    END IF;

    UPDATE solicitudes_materiales SET estado = 'CANCELADA' WHERE id = p_solicitud_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_resolver_solicitud_materiales(
    p_solicitud_id INT,
    p_aprobar BOOLEAN,
    p_comentario TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_actor_id INT;
    v_estado VARCHAR(12);
BEGIN
    v_actor_id := fn_exigir_permiso('solicitudes.gestionar');
    IF p_aprobar IS NULL OR (NOT p_aprobar AND length(trim(COALESCE(p_comentario, ''))) = 0) THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Rechazar requiere un comentario.';
    END IF;

    SELECT estado INTO v_estado
    FROM solicitudes_materiales
    WHERE id = p_solicitud_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: La solicitud no existe.';
    END IF;
    IF v_estado <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Solo se pueden resolver solicitudes pendientes.';
    END IF;

    UPDATE solicitudes_materiales
    SET estado = CASE WHEN p_aprobar THEN 'APROBADA' ELSE 'RECHAZADA' END,
        revisada_por = v_actor_id,
        revisada_en = CURRENT_TIMESTAMP,
        comentario_revision = NULLIF(trim(p_comentario), '')
    WHERE id = p_solicitud_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_vincular_solicitud_egreso(
    p_solicitud_id INT,
    p_egreso_id INT
) RETURNS VOID AS $$
DECLARE
    v_estado VARCHAR(12);
    v_obra_solicitud INT;
    v_obra_egreso INT;
BEGIN
    PERFORM fn_exigir_permiso('solicitudes.gestionar');
    PERFORM fn_exigir_permiso('egresos.registrar');

    SELECT estado, obra_id INTO v_estado, v_obra_solicitud
    FROM solicitudes_materiales
    WHERE id = p_solicitud_id
    FOR UPDATE;
    IF NOT FOUND OR v_estado <> 'APROBADA' THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Solo se vincula una solicitud aprobada.';
    END IF;

    SELECT obra_id INTO v_obra_egreso
    FROM egresos_obra
    WHERE id = p_egreso_id AND estado = 'BORRADOR'
    FOR UPDATE;
    IF NOT FOUND OR v_obra_egreso <> v_obra_solicitud THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: El egreso debe ser borrador de la misma obra.';
    END IF;
    IF EXISTS (SELECT 1 FROM solicitudes_materiales WHERE egreso_id = p_egreso_id) THEN
        RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: El egreso ya esta vinculado a otra solicitud.';
    END IF;

    UPDATE solicitudes_materiales
    SET egreso_id = p_egreso_id
    WHERE id = p_solicitud_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_actualizar_solicitud_al_registrar_egreso()
RETURNS TRIGGER AS $$
DECLARE
    v_solicitud_id INT;
BEGIN
    IF OLD.estado = 'BORRADOR' AND NEW.estado = 'REGISTRADO' THEN
        SELECT id INTO v_solicitud_id
        FROM solicitudes_materiales
        WHERE egreso_id = NEW.id
        FOR UPDATE;

        IF FOUND THEN
            IF NOT EXISTS (
                SELECT articulo_id, cantidad_solicitada
                FROM detalle_solicitud_materiales
                WHERE solicitud_id = v_solicitud_id
                EXCEPT
                SELECT articulo_id, SUM(cantidad_solicitada)
                FROM detalle_egreso
                WHERE egreso_id = NEW.id
                GROUP BY articulo_id
            ) AND NOT EXISTS (
                SELECT articulo_id, SUM(cantidad_solicitada)
                FROM detalle_egreso
                WHERE egreso_id = NEW.id
                GROUP BY articulo_id
                EXCEPT
                SELECT articulo_id, cantidad_solicitada
                FROM detalle_solicitud_materiales
                WHERE solicitud_id = v_solicitud_id
            ) THEN
                UPDATE solicitudes_materiales
                SET estado = 'DESPACHADA', despachada_en = CURRENT_TIMESTAMP
                WHERE id = v_solicitud_id AND estado = 'APROBADA';
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: La solicitud vinculada no esta aprobada.';
                END IF;
            ELSE
                RAISE EXCEPTION 'ERROR [FYAG-SOLICITUD]: Las lineas despachadas no coinciden con la solicitud aprobada.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_actualizar_solicitud_al_registrar_egreso ON egresos_obra;
CREATE TRIGGER trg_actualizar_solicitud_al_registrar_egreso
AFTER UPDATE OF estado ON egresos_obra
FOR EACH ROW EXECUTE FUNCTION fn_actualizar_solicitud_al_registrar_egreso();

CREATE OR REPLACE FUNCTION fn_exigir_acuse_egreso()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.estado = 'BORRADOR'
       AND NEW.estado = 'REGISTRADO'
       AND NOT EXISTS (
           SELECT 1 FROM acuses_recepcion_egreso WHERE egreso_id = NEW.id
       ) THEN
        RAISE EXCEPTION 'ERROR [FYAG-ACUSE]: Registre el acuse de recepcion antes de confirmar el egreso.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_exigir_acuse_egreso ON egresos_obra;
CREATE TRIGGER trg_exigir_acuse_egreso
BEFORE UPDATE OF estado ON egresos_obra
FOR EACH ROW EXECUTE FUNCTION fn_exigir_acuse_egreso();

CREATE OR REPLACE FUNCTION fn_registrar_acuse_recepcion_egreso(
    p_egreso_id INT,
    p_receptor_nombre VARCHAR(150),
    p_receptor_identificador VARCHAR(50),
    p_storage_bucket VARCHAR(100),
    p_storage_path TEXT,
    p_sha256_archivo VARCHAR(64) DEFAULT NULL
) RETURNS INT AS $$
DECLARE
    v_actor_id INT;
    v_acuse_id INT;
BEGIN
    v_actor_id := fn_exigir_permiso('egresos.acuse');
    IF p_receptor_nombre IS NULL OR length(trim(p_receptor_nombre)) = 0
       OR p_storage_bucket IS NULL OR length(trim(p_storage_bucket)) = 0
       OR p_storage_path IS NULL OR length(trim(p_storage_path)) = 0
       OR p_storage_path ~ '(^/|(^|/)\.\.(/|$)|^https?://)'
       OR (p_sha256_archivo IS NOT NULL AND p_sha256_archivo !~ '^[0-9a-fA-F]{64}$') THEN
        RAISE EXCEPTION 'ERROR [FYAG-ACUSE]: Datos del receptor o archivo invalidos.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM egresos_obra
        WHERE id = p_egreso_id AND estado IN ('BORRADOR', 'REGISTRADO')
    ) THEN
        RAISE EXCEPTION 'ERROR [FYAG-ACUSE]: El egreso no existe o no admite un acuse.';
    END IF;

    INSERT INTO acuses_recepcion_egreso (
        egreso_id, receptor_nombre, receptor_identificador,
        storage_bucket, storage_path, sha256_archivo, registrado_por
    ) VALUES (
        p_egreso_id, trim(p_receptor_nombre), NULLIF(trim(p_receptor_identificador), ''),
        trim(p_storage_bucket), p_storage_path, p_sha256_archivo, v_actor_id
    )
    RETURNING id INTO v_acuse_id;
    RETURN v_acuse_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

CREATE OR REPLACE FUNCTION fn_bloquear_cambios_acuse()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'ERROR [FYAG-ACUSE]: El acuse es inmutable; registre una correccion como nuevo evento.';
END;
$$ LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_inmutable_acuse ON acuses_recepcion_egreso;
CREATE TRIGGER trg_inmutable_acuse
BEFORE UPDATE OR DELETE ON acuses_recepcion_egreso
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios_acuse();

DROP TRIGGER IF EXISTS trg_no_truncate_acuses ON acuses_recepcion_egreso;
CREATE TRIGGER trg_no_truncate_acuses
BEFORE TRUNCATE ON acuses_recepcion_egreso
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios_acuse();

DROP TRIGGER IF EXISTS trg_auditoria_solicitudes ON solicitudes_materiales;
CREATE TRIGGER trg_auditoria_solicitudes
AFTER INSERT OR UPDATE OR DELETE ON solicitudes_materiales
FOR EACH ROW EXECUTE FUNCTION fn_auditar_operacion();

DROP TRIGGER IF EXISTS trg_auditoria_detalle_solicitud ON detalle_solicitud_materiales;
CREATE TRIGGER trg_auditoria_detalle_solicitud
AFTER INSERT OR UPDATE OR DELETE ON detalle_solicitud_materiales
FOR EACH ROW EXECUTE FUNCTION fn_auditar_operacion();

CREATE OR REPLACE FUNCTION fn_auditar_acuse_recepcion()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO auditoria_operaciones (
        tabla, registro_id, accion, datos_anteriores, datos_nuevos, ejecutado_por
    ) VALUES (
        TG_TABLE_NAME,
        NEW.id::TEXT,
        TG_OP,
        NULL,
        jsonb_build_object(
            'id', NEW.id,
            'egreso_id', NEW.egreso_id,
            'sha256_archivo', NEW.sha256_archivo,
            'registrado_por', NEW.registrado_por,
            'creado_en', NEW.creado_en
        ),
        COALESCE(NULLIF(current_setting('app.current_user_id', true), ''), SESSION_USER::TEXT)
    );
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp;

DROP TRIGGER IF EXISTS trg_auditoria_acuses ON acuses_recepcion_egreso;
CREATE TRIGGER trg_auditoria_acuses
AFTER INSERT ON acuses_recepcion_egreso
FOR EACH ROW EXECUTE FUNCTION fn_auditar_acuse_recepcion();

CREATE OR REPLACE VIEW vw_egresos_sin_acuse AS
SELECT eo.id AS egreso_id, eo.obra_id, eo.fecha_salida, eo.responsable_obra,
       eo.tecnico_receptor_id, eo.usuario_id
FROM egresos_obra eo
LEFT JOIN acuses_recepcion_egreso ar ON ar.egreso_id = eo.id
WHERE eo.estado = 'REGISTRADO' AND ar.id IS NULL;

REVOKE ALL ON solicitudes_materiales, detalle_solicitud_materiales, acuses_recepcion_egreso
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE solicitudes_materiales_id_seq, detalle_solicitud_materiales_id_seq,
    acuses_recepcion_egreso_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON solicitudes_materiales, detalle_solicitud_materiales,
    acuses_recepcion_egreso, vw_egresos_sin_acuse TO alpha_backend;

REVOKE EXECUTE ON FUNCTION fn_crear_solicitud_materiales(INT, TEXT, JSONB),
    fn_cancelar_solicitud_materiales(INT),
    fn_resolver_solicitud_materiales(INT, BOOLEAN, TEXT),
    fn_vincular_solicitud_egreso(INT, INT),
    fn_registrar_acuse_recepcion_egreso(INT, VARCHAR, VARCHAR, VARCHAR, TEXT, VARCHAR),
    fn_actualizar_solicitud_al_registrar_egreso(),
    fn_exigir_acuse_egreso(),
    fn_bloquear_cambios_acuse(),
    fn_auditar_acuse_recepcion()
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION fn_crear_solicitud_materiales(INT, TEXT, JSONB),
    fn_cancelar_solicitud_materiales(INT),
    fn_resolver_solicitud_materiales(INT, BOOLEAN, TEXT),
    fn_vincular_solicitud_egreso(INT, INT),
    fn_registrar_acuse_recepcion_egreso(INT, VARCHAR, VARCHAR, VARCHAR, TEXT, VARCHAR)
    TO alpha_backend;

COMMIT;
