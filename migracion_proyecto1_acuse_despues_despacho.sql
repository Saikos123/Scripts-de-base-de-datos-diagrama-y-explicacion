-- Correccion para instalaciones que ya aplicaron
-- migracion_proyecto1_solicitudes_y_acuses.sql.
-- El despacho se registra primero; el acuse se agrega despues de la recepcion.
-- No elimina ni modifica egresos, acuses, solicitudes ni movimientos existentes.

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.egresos_obra') IS NULL
       OR to_regclass('public.acuses_recepcion_egreso') IS NULL THEN
        RAISE EXCEPTION
            'Se requiere aplicar primero migracion_proyecto1_solicitudes_y_acuses.sql.';
    END IF;
END;
$$;

-- La ausencia de acuse se controla y monitorea con vw_egresos_sin_acuse.
-- fn_registrar_acuse_recepcion_egreso permite anexarlo al egreso registrado.
DROP TRIGGER IF EXISTS trg_exigir_acuse_egreso ON public.egresos_obra;

COMMIT;
