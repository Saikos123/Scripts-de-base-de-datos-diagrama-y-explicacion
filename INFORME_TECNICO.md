# Informe técnico — base de datos de Proyecto Alpha

**Revisión:** 10 de noviembre de 2026
**Alcance:** scripts SQL, migraciones y estado de Supabase informado por el
usuario. No es una auditoría de seguridad ni certificación legal.

## Resumen ejecutivo

Se completó el **núcleo del esquema de base de datos** para inventario,
proveedores/clientes, compras, egresos, Kardex, permisos y las solicitudes de
materiales/acuses agregados en las migraciones. El usuario informó que ejecutó
el script y las migraciones relevantes en Supabase. Las capturas compartidas
confirman tablas de solicitudes/acuses, algunos permisos, RLS desactivado en
`public` y el bucket privado `acuse-recepcion`; no inspeccionamos directamente
el proyecto ni ejecutamos las pruebas de integración desde el backend.

Por lo tanto, el **diseño del núcleo está preparado para integración**, pero no
se debe declarar terminado todo el sistema. Faltan pruebas con la conexión real
del backend, verificación de permisos de extremo a extremo y el alcance de toma
de inventario físico solicitado en HU-06.

## Componentes del esquema

`script.sql` define 21 tablas, 34 funciones y 3 vistas. La migración
`migracion_proyecto1_solicitudes_y_acuses.sql` agrega tres tablas, funciones de
flujo y la vista de entregas sin acuse. La migración correctiva
`migracion_proyecto1_acuse_despues_despacho.sql` quita la regla que exigía el
acuse antes de registrar la salida. La migración de compras es para actualizar
una versión anterior del esquema; no debe aplicarse automáticamente junto con
el esquema base actual.

### Entidades del script base

- **Acceso y trazabilidad:** `roles`, `permisos`, `roles_permisos`, `usuarios`,
  `tokens_revocados`, `auditoria_usuarios`, `auditoria_operaciones` y
  `auditoria_cuentas_bancarias`.
- **Catálogos:** `categorias_articulo`, `proveedores`, `contactos_proveedor`,
  `cuentas_bancarias_proveedor`, `clientes`, `articulos` y `obras`.
- **Compras e inventario:** `facturas_proveedor`, `detalle_factura`,
  `devoluciones_proveedor`, `egresos_obra`, `detalle_egreso` y `cardex`.
- **Migración de solicitudes y acuses:** `solicitudes_materiales`,
  `detalle_solicitud_materiales` y `acuses_recepcion_egreso`.

### Reglas principales implementadas

- Costeo por **promedio ponderado móvil (PMP)**; no FIFO.
- Descuentos sucesivos en cascada, IVA y validación de totales.
- Recepción por guía, conciliación con factura y control del stock reservado.
- Egresos transaccionales con validación de stock y registro en Kardex.
- Mermas, devoluciones, uso interno y ajustes como tipos de movimiento.
- Kardex append-only con hash de integridad, verificación y movimientos de
  reversa.
- Roles y permisos comprobados por funciones de negocio, con grants/revokes
  destinados al rol `alpha_backend`.
- Solicitudes del Supervisor con aprobación/rechazo y relación con el egreso.
- Acuse inmutable asociado al egreso; el archivo se guarda en Storage y la base
  conserva la referencia y metadatos.
- `vw_stock_critico`, `vw_stock_despachable`, `vw_kardex_valorizado` y
  `vw_egresos_sin_acuse` apoyan consultas del backend.

## Decisiones de integración y seguridad

- El diseño está orientado a un **backend privado** con conexión PostgreSQL.
  `alpha_backend` es un rol `NOLOGIN`; la identidad de conexión del servidor
  debe tener la membresía necesaria y usar solo credenciales almacenadas en el
  servidor.
- Las funciones que requieren permisos dependen de que el backend establezca
  `app.current_user_id` dentro de cada transacción, después de autenticar al
  actor. No se debe aceptar ese identificador directamente desde el cliente.
- Según capturas compartidas, RLS está desactivado en tablas de `public` y no
  hay políticas allí. Esto es coherente únicamente mientras el acceso a esas
  tablas se mantenga detrás del backend y los permisos SQL sean correctos. Si
  algún cliente accede directamente por Data API, hay que definir y probar
  políticas RLS antes de habilitarlo.
- El bucket `acuse-recepcion` fue confirmado como privado (`public = false`).
  No se necesitan políticas para clientes si toda carga/lectura la hace el
  servidor; cualquier acceso directo requiere políticas Storage de mínimo
  privilegio.
- El script no crea copias de seguridad ni garantiza su restauración. Se
  requieren procedimientos de backup/restore independientes.
- Una firma almacenada como imagen/archivo y metadatos es evidencia de recepción;
  no debe describirse como firma electrónica certificada sin cumplir los
  requisitos aplicables.

## Brechas respecto de la planificación HU-01 a HU-06

1. **HU-01:** el esquema aporta usuarios, roles, permisos y tokens revocados;
   falta validar la autenticación real del backend, establecer el actor por
   transacción y probar autorización en cada ruta.
2. **HU-02:** existen egresos y transacción SQL. La ruta actual del backend no
   es compatible con el esquema: usa nombres de campos distintos y actualiza
   stock directamente. Debe llamar las funciones SQL para no saltarse el Kardex
   ni las validaciones.
3. **HU-03:** el Cardex y sus vistas están implementados. Faltan endpoint de
   consulta con filtros/paginación y generación de exportaciones si se mantienen
   como requisito.
4. **HU-04:** la base implementa compras, descuentos, PMP, documentos y
   devoluciones; faltan endpoints e integración con las funciones transaccionales.
5. **HU-05:** la base registra `AJUSTE_MERMA` y `USO_INTERNO` con motivo
   obligatorio en el Kardex; no hace falta una tabla duplicada `mermas` si se
   mantiene esta decisión. Falta integrar sus operaciones en el backend.
6. **HU-06:** stock mínimo y alertas consultables existen, pero no hay tablas
   para cabecera/detalle de toma física. Si se requiere persistir conteos y sus
   diferencias, se debe acordar el flujo y diseñar una migración independiente.
   La consulta de costos históricos y el endpoint de alertas también deben
   integrarse y probarse.

## Estado de validación

### Confirmado por el usuario/capturas

- Se ejecutó el script base y se aplicaron las migraciones de solicitudes/acuses
  y del orden despacho-acuse; el usuario confirmó que la correctiva funcionó.
- Las tablas nuevas y permisos seleccionados aparecen en Supabase.
- `alpha_backend` tiene los permisos SQL consultados para leer artículos y
  solicitudes, crear solicitudes y registrar acuses.
- RLS aparece desactivado en `public`; la API Data está deshabilitada para las
  tablas mostradas.
- El bucket `acuse-recepcion` existe con `public = false`.

### Aún por probar antes de producción

- Conexión del backend como rol miembro de `alpha_backend`, sin usar `postgres`
  ni exponer credenciales privilegiadas al navegador.
- Ejecución de `SET LOCAL app.current_user_id` y matriz completa de permisos.
- Flujo solicitud → aprobación → egreso/actualización de stock/Kardex →
  carga del archivo → registro del acuse posterior.
- Rechazo de operaciones inválidas, stock insuficiente, rollback, concurrencia
  y ausencia de escrituras ORM directas que eludan funciones.
- Resultado de `SELECT * FROM fn_verificar_integridad_cardex();` en Supabase.
- Backup real y restauración probada.
- Revisión de configuración `search_path`, privilegios heredados, políticas
  Storage si hay acceso desde cliente y actualización del diagrama.

## Conclusión

**El núcleo de la base de datos está diseñado y, según lo informado, desplegado
en Supabase con sus migraciones recientes y bucket privado.** Esto permite que
el equipo empiece la integración en una rama de trabajo, pero no demuestra que
el backend sea todavía compatible ni que todas las historias HU-01 a HU-06 estén
terminadas. La toma de inventario físico, la integración del backend y las
pruebas de entorno siguen pendientes. No se afirma cumplimiento legal ni
preparación de producción.
