# Proyecto Alpha — base de datos

Esquema PostgreSQL/Supabase y migraciones para la gestión de inventario,
compras, obras, solicitudes de materiales, egresos, Kardex y acuses.

## Archivos

- [`script.sql`](./script.sql): esquema base para una instalación nueva.
- [`migracion_proyecto1_compras.sql`](./migracion_proyecto1_compras.sql):
  migración para la versión anterior del esquema; comparar antes de aplicarla,
  porque el esquema base vigente ya contiene esos componentes.
- [`migracion_proyecto1_solicitudes_y_acuses.sql`](./migracion_proyecto1_solicitudes_y_acuses.sql):
  agrega solicitudes del Supervisor, permisos y registro de acuses.
- [`migracion_proyecto1_acuse_despues_despacho.sql`](./migracion_proyecto1_acuse_despues_despacho.sql):
  permite registrar el despacho y luego el acuse de recepción.
- [`INFORME_TECNICO.md`](./INFORME_TECNICO.md): alcance, decisiones y estado
  conocido de la base.
- [`CHECKLIST_PROYECTO1.md`](./CHECKLIST_PROYECTO1.md): avance, validaciones y
  pendientes.
- [`GUIA_PRUEBA_SUPABASE_BRUNO.md`](./GUIA_PRUEBA_SUPABASE_BRUNO.md): guía de
  pruebas de integración.
- [`docs/supabase-schema.svg`](./docs/supabase-schema.svg): diagrama exportado;
  revisar su fecha y sincronización antes de usarlo como referencia actual.

## Instalación y actualización

`script.sql` está pensado para una base vacía. Sus `CREATE TABLE IF NOT EXISTS`
no actualizan tablas que ya existan; no volver a ejecutarlo en una base activa
para corregir diferencias.

Para una instalación existente:

1. Hacer y verificar un respaldo restaurable.
2. Comparar el esquema desplegado con los archivos SQL.
3. Probar únicamente las migraciones necesarias en una copia restaurada.
4. Aplicar los cambios aprobados y verificar permisos y flujos.

No ejecutar `migracion_proyecto1_compras.sql` a ciegas: es una migración de
compatibilidad para una versión anterior, mientras que el `script.sql` vigente
ya define clientes, contactos, cuentas bancarias, devoluciones y la vista de
stock despachable.

El usuario informó que ejecutó `script.sql`, la migración de solicitudes/acuses
y la corrección del orden despacho-acuse en Supabase. También se confirmó en
capturas que el bucket `acuse-recepcion` es privado y que RLS está desactivado
en las tablas de `public`. Esto documenta el estado informado; no equivale a
una auditoría independiente ni a pruebas funcionales desde el backend.

## Flujo de despacho y acuse

El backend debe registrar la salida mediante `fn_registrar_egreso_obra`, que
valida stock y registra el movimiento de Kardex en una transacción. Después de
la recepción física, debe subir la evidencia al bucket privado
`acuse-recepcion` y guardar sus metadatos mediante
`fn_registrar_acuse_recepcion_egreso`. `vw_egresos_sin_acuse` permite consultar
entregas sin acuse.

El archivo se almacena en Supabase Storage; PostgreSQL conserva su bucket, ruta
y metadatos. La credencial de Storage debe permanecer en el servidor. Si un
cliente va a acceder directamente a Storage o a las tablas, hay que diseñar y
probar políticas RLS apropiadas; no habilitar acceso público como atajo.

## Alcance completado y límites

El esquema cubre el núcleo de inventario, compras con descuentos sucesivos e IVA,
PMP, recepciones/conciliación, devoluciones, egresos, Kardex inmutable, permisos,
solicitudes y acuses. Las pruebas locales previas validan partes de la lógica,
pero no certifican el comportamiento de la instancia Supabase ni la integración
del backend.

La planificación HU-01 a HU-06 también pide persistir conteos físicos de
inventario. El esquema actual incluye stock mínimo y una vista de stock crítico,
pero no tiene tablas de toma de inventario y detalle; ese alcance requiere una
decisión y una migración aparte. La integración de endpoints, autenticación,
permisos por operación, alertas, reportes y pruebas de restauración sigue siendo
trabajo del backend/equipo.

No incluir en Git credenciales, claves Supabase, archivos `.env` ni volcados con
datos personales.
