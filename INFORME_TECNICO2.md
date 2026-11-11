# Informe técnico: base de datos de Proyecto Alpha

**Fecha:** 10 de noviembre de 2026 · **Alcance:** esquema SQL, migraciones y
configuración de Supabase revisada.

Este informe resume lo implementado y los puntos que todavía deben probarse.
No constituye una auditoría de seguridad ni una certificación legal.

## Resumen ejecutivo

Se implementó el esquema de base de datos para usuarios y permisos,
proveedores y clientes, compras, inventario, egresos y Kardex. Después se
incorporaron las solicitudes de materiales, los acuses de recepción y la
corrección para registrar el despacho antes de cargar el acuse. Estos cambios
se aplicaron en Supabase. El bucket `acuse-recepcion` es privado y RLS está
desactivado en las tablas del esquema `public`.

La base está preparada para comenzar la integración con el backend, pero esa
integración aún debe realizarse y probarse. También falta definir si HU-06
requiere guardar los conteos de inventario físico y sus diferencias.

## Componentes del esquema

El script base define 21 tablas, 34 funciones y 3 vistas. La migración de
solicitudes agrega tres tablas, funciones para gestionar el flujo y una vista
de egresos sin acuse. La migración correctiva permite registrar primero la
salida y agregar el acuse después. En conjunto, el esquema actualizado contiene
24 tablas, 43 funciones y 4 vistas.

La migración de compras corresponde a una versión anterior del esquema y no
debe ejecutarse encima del script base actual sin revisar antes qué objetos
existen en la base.

### Entidades del script base

- **Acceso y trazabilidad:** `roles`, `permisos`, `roles_permisos`, `usuarios`,
  `tokens_revocados`, `auditoria_usuarios`, `auditoria_operaciones` y
  `auditoria_cuentas_bancarias`.
- **Catálogos:** `categorias_articulo`, `proveedores`, `contactos_proveedor`,
  `cuentas_bancarias_proveedor`, `clientes`, `articulos` y `obras`.
- **Compras e inventario:** `facturas_proveedor`, `detalle_factura`,
  `devoluciones_proveedor`, `egresos_obra`, `detalle_egreso` y `cardex`.
- **Solicitudes y acuses:** `solicitudes_materiales`,
  `detalle_solicitud_materiales` y `acuses_recepcion_egreso`.

### Reglas principales

- El inventario se valoriza mediante **promedio ponderado móvil (PMP)**, no
  FIFO.
- Los descuentos se aplican en cascada; se calculan y validan IVA y totales.
- La recepción por guía reserva las cantidades hasta conciliarlas con la
  factura.
- Los egresos validan existencias y registran los movimientos en el Kardex
  dentro de una transacción.
- Mermas, devoluciones, uso interno y ajustes se representan como movimientos
  de inventario.
- El Kardex conserva los movimientos originales, calcula hashes encadenados y
  permite verificar su integridad. Las correcciones se agregan como reversas.
- Las funciones de negocio comprueban roles y permisos y están destinadas a
  ejecutarse desde el rol `alpha_backend`.
- Las solicitudes del Supervisor pueden aprobarse o rechazarse y asociarse a
  un egreso.
- El acuse queda asociado al egreso. El archivo firmado se guarda en Storage;
  PostgreSQL conserva su referencia y metadatos.
- `vw_stock_critico`, `vw_stock_despachable`, `vw_kardex_valorizado` y
  `vw_egresos_sin_acuse` cubren consultas de inventario y seguimiento.

## Integración y seguridad

- La aplicación debe conectarse mediante un **backend privado**. `alpha_backend`
  es un rol `NOLOGIN`; la cuenta del servidor necesita la membresía
  correspondiente y debe mantener sus credenciales fuera del cliente y del
  repositorio.
- Las funciones que requieren autorización usan `app.current_user_id`. El
  backend debe validar la sesión y establecer esa variable dentro de cada
  transacción. No debe aceptar el identificador del actor directamente desde
  una petición del cliente.
- RLS está desactivado en las tablas de `public` y no hay políticas RLS allí.
  Esta configuración solo es adecuada si el acceso a esas tablas pasa por el
  backend y los permisos SQL están correctamente limitados. Si se habilita el
  acceso directo mediante Data API, habrá que diseñar y probar políticas RLS.
- El bucket `acuse-recepcion` es privado (`public = false`). Si las cargas y
  lecturas pasan por el servidor, no se necesitan políticas para clientes. Si
  se habilita el acceso directo, las políticas de Storage deben limitarlo al
  mínimo necesario.
- El script no configura respaldos ni demuestra que puedan restaurarse. El
  proceso de backup y recuperación debe probarse por separado.
- El archivo firmado y sus metadatos sirven como evidencia de recepción; no
  equivalen por sí solos a una firma electrónica certificada.

## Brechas respecto de la planificación HU-01 a HU-06

1. **HU-01 — Acceso:** están definidos usuarios, roles, permisos y tokens
   revocados. Falta integrar la autenticación real del backend, establecer el
   actor por transacción y probar la autorización en cada ruta.
2. **HU-02 — Egresos:** el esquema permite registrar egresos transaccionales,
   pero la ruta actual del backend no coincide con él: usa nombres de campos
   distintos y actualiza el stock directamente. Debe llamar las funciones SQL
   para aplicar las validaciones y actualizar el Kardex.
3. **HU-03 — Kardex e informes:** el Kardex y sus vistas están implementados.
   Faltan el endpoint de consulta con filtros y paginación, y las exportaciones
   si siguen siendo requisito.
4. **HU-04 — Compras:** la base cubre compras, descuentos, PMP, documentos y
   devoluciones. Faltan los endpoints y su integración con las funciones
   transaccionales.
5. **HU-05 — Mermas y uso interno:** `AJUSTE_MERMA` y `USO_INTERNO` se registran
   en el Kardex con un motivo obligatorio. No hace falta duplicar estos datos en
   una tabla `mermas` mientras se mantenga este diseño; falta integrar las
   operaciones en el backend.
6. **HU-06 — Inventario físico y alertas:** existen el stock mínimo y consultas
   de alertas, pero no hay tablas para registrar una toma física y sus
   diferencias. Si se requiere conservar esos conteos, habrá que acordar el
   flujo y preparar una migración. También faltan la consulta de costos
   históricos y el endpoint de alertas en el backend.

## Comprobaciones y pendientes

### Configuración aplicada en Supabase

- Se aplicó el script base, la migración de solicitudes y acuses, y la
  corrección del orden despacho-acuse.
- Las tablas nuevas y los permisos consultados están presentes.
- `alpha_backend` tiene los permisos SQL revisados para leer artículos y
  solicitudes, crear solicitudes y registrar acuses.
- RLS está desactivado en `public`; la Data API está deshabilitada para las
  tablas revisadas.
- El bucket `acuse-recepcion` existe y es privado.

### Pruebas que faltan

- Conectar el backend como miembro de `alpha_backend`, sin usar `postgres` ni
  exponer credenciales privilegiadas al navegador.
- Probar `SET LOCAL app.current_user_id` y la matriz completa de permisos.
- Recorrer el flujo solicitud → aprobación → egreso y actualización de
  inventario/Kardex → carga del archivo → registro posterior del acuse.
- Probar entradas inválidas, stock insuficiente, rollback y concurrencia.
- Confirmar que el ORM no escriba directamente datos que deban pasar por las
  funciones SQL.
- Ejecutar `SELECT * FROM fn_verificar_integridad_cardex();` en Supabase.
- Hacer un respaldo y comprobar su restauración en un entorno de prueba.
- Revisar `search_path`, privilegios heredados, políticas de Storage si se
  habilita acceso desde clientes y actualizar el diagrama.

## Estado actual

El esquema y las migraciones indicadas están aplicados en Supabase, y el bucket
de acuses es privado. El siguiente paso es integrar el backend de forma que use
las funciones y controles definidos en SQL, y probar los flujos con los
permisos de conexión previstos. También quedan pendientes las decisiones de
HU-06, la verificación de integridad del Kardex y una restauración de respaldo.
Por ahora, no corresponde considerar terminadas todas las historias ni declarar
el sistema listo para producción.
