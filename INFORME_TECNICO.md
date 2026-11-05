# Informe técnico: base de datos de Proyecto Alpha

**Fecha de revisión:** 5 de noviembre de 2026
**Alcance:** `script.sql` y exportación DrawSQL incluida en `docs/`.
**Destino previsto:** prototipo en Supabase.

## 1. Resumen ejecutivo

El diseño usa **una base PostgreSQL relacional** para datos de inventario,
usuarios, documentos y auditoría. Algunas columnas `JSONB` permiten guardar
metadatos con estructura variable. Es un modelo relacional con componentes
semiestructurados; **no son dos motores ni dos bases separadas**.

Para un prototipo, PostgreSQL en Supabase es una opción razonable: el proyecto
necesita claves foráneas, transacciones, restricciones, funciones y `JSONB`, y
PostgreSQL ofrece esas capacidades en un solo sistema. El script incorpora
varios controles útiles, pero todavía no corresponde presentarlo como listo
para producción ni como auditado de extremo a extremo. La autorización del
backend, RLS, los privilegios de los esquemas y las operaciones de negocio deben
probarse con la cuenta de conexión real.

La imagen DrawSQL sirve para explicar las entidades principales, pero **no
coincide por completo con la versión vigente del SQL**. Debe actualizarse antes
de tratarla como diagrama definitivo.

## 2. Qué contiene el script

El archivo define **16 tablas, 21 funciones, 2 vistas y triggers**. Las
sentencias crean el esquema, insertan roles, permisos y categorías iniciales,
establecen controles para documentos e inventario, y asignan privilegios al rol
de base de datos `alpha_backend`.

### Tablas

| Tabla | Propósito |
|---|---|
| `roles` | Perfiles funcionales: ADMIN, FINANZAS, BODEGA y SUPERVISOR. |
| `permisos` | Catálogo de acciones autorizables. |
| `roles_permisos` | Asignación muchos-a-muchos entre roles y permisos. |
| `usuarios` | Cuentas, credenciales en forma de hash, rol y estado de acceso. |
| `tokens_revocados` | Identificadores JTI de JWT invalidados antes de expirar. |
| `auditoria_usuarios` | Registro de eventos asociados a cuentas. No tiene FK a `usuarios`, para conservar el historial independiente de la vida de la cuenta. |
| `auditoria_operaciones` | Cambios registrados en las tablas operativas. |
| `categorias_articulo` | Catálogo editable de categorías; `activo` permite deshabilitarlas. |
| `proveedores` | Identificación actual del proveedor; las facturas también guardan datos históricos del documento. |
| `articulos` | Catálogo, unidad, ubicación, stock, costo promedio y especificaciones. |
| `obras` | Obras que reciben materiales. |
| `facturas_proveedor` | Encabezado de compra, importes, estado y metadatos DTE opcionales. |
| `detalle_factura` | Artículos, cantidades, precios y descuentos de una factura. |
| `egresos_obra` | Encabezado de entrega a una obra, receptor, motivo y metadatos de evidencia. |
| `detalle_egreso` | Artículos y cantidades de cada egreso. |
| `cardex` | Historial de entradas, salidas, ajustes y reversas de inventario. |

Las claves foráneas conectan usuarios con roles; roles y permisos por medio de
`roles_permisos`; categorías con artículos; proveedores con facturas; facturas
y egresos con sus detalles; y los detalles con artículos. `cardex` relaciona
los movimientos con el usuario, el artículo, el documento o la obra que los
originó y, si corresponde, otro movimiento que se revierte. Las reglas `RESTRICT`
conservan registros referenciados; los detalles usan `CASCADE` cuando se elimina
un encabezado todavía eliminable.

### Funciones

| Función | Qué hace |
|---|---|
| `fn_validar_rut_chileno` | Comprueba formato y dígito verificador con Módulo 11. |
| `fn_auditar_cambios_usuarios` | Añade un evento cuando se inserta, actualiza o elimina una cuenta. |
| `fn_exigir_permiso` | Requiere el usuario de la transacción y comprueba su permiso y estado activo. |
| `fn_anonimizar_usuario` | Sustituye datos identificatorios, invalida la cuenta y conserva su referencia histórica. |
| `fn_bloquear_cambios_auditoria` | Rechaza cambios y truncado en tablas de auditoría. |
| `fn_auditar_operacion` | Escribe cambios de tablas operativas y omite columnas elegidas para no copiar datos sensibles. |
| `fn_validar_stock_inicial_articulo` | Obliga a crear artículos sin saldo ni costo inicial. |
| `fn_proteger_documentos_registrados` | Bloquea cambios en facturas registradas y sus líneas; permite el cambio controlado de borrador a registrada. |
| `fn_proteger_articulo_con_movimientos` | Impide borrar o cambiar datos históricos clave de artículos con movimientos. |
| `fn_proteger_obra_con_movimientos` | Impide borrar o cambiar datos históricos de obras con movimientos. |
| `fn_proteger_egreso_registrado` | Protege egresos y sus líneas cuando ya generaron movimientos. |
| `fn_bloquear_cardex` | Rechaza `UPDATE` y `DELETE` del Cardex. |
| `fn_bloquear_truncate_cardex` | Rechaza `TRUNCATE` del Cardex. |
| `fn_calcular_hash_cardex` | Calcula SHA-256 encadenado al hash anterior, bajo un bloqueo transaccional. |
| `fn_crear_factura_proveedor` | Crea una factura en borrador y copia al documento los datos vigentes del proveedor. |
| `fn_registrar_ingreso_compra` | Valida líneas y totales, calcula descuentos/IVA/PMP, actualiza stock y agrega movimientos al Cardex. |
| `fn_crear_egreso_obra` | Crea un egreso en borrador después de validar obra, receptor y motivo. |
| `fn_registrar_egreso_obra` | Registra líneas, comprueba existencias, descuenta stock y agrega movimientos al Cardex. |
| `fn_registrar_movimiento_inventario` | Registra saldo inicial, merma, devolución, uso interno y ajustes permitidos. |
| `fn_reversar_movimiento` | Añade un movimiento correctivo ligado al original; no modifica el original. |
| `fn_limpiar_tokens_expirados` | Elimina tokens revocados vencidos, con permiso de administración. |

Las funciones de negocio se ejecutan dentro de la transacción que las llama.
Si una validación lanza una excepción, PostgreSQL revierte los cambios de esa
transacción. La aplicación debe tratar el error y no continuar una transacción
fallida.

### Vistas, restricciones y datos iniciales

- `vw_stock_critico` lista artículos cuyo saldo llegó o bajó del mínimo.
- `vw_kardex_valorizado` presenta movimientos con sus artículos, usuarios,
  documentos, proveedores y obras.
- Las restricciones `CHECK` limitan cantidades, estados, RUT, importes,
  descuentos y coherencia de los movimientos.
- El script carga cuatro roles, catorce permisos y ocho categorías. No crea
  proveedores, artículos, obras ni un administrador con contraseña conocida.

## 3. Por qué se usa `JSONB`

`JSONB` guarda datos que llegan con forma variable sin abandonar las tablas
relacionales ni sus claves foráneas:

- `articulos.especificaciones_tecnicas`: propiedades que cambian según la clase
  de artículo.
- `facturas_proveedor.datos_dte`: metadatos opcionales de documentos tributarios.
- `egresos_obra.evidencia_adjunta`: referencias y metadatos de evidencia.
- `datos_anteriores` y `datos_nuevos`: valores seleccionados por las funciones
  de auditoría.

Lo fijo y necesario para relaciones, cálculos, permisos e informes sigue en
columnas tipadas. Los datos JSONB de DTE y evidencia exigen un objeto JSON; el
script incluye índices GIN para algunas consultas. JSONB **no guarda imágenes ni
archivos binarios**. Los archivos deben ir a almacenamiento de objetos —por
ejemplo, Supabase Storage— y la base conservar identificadores o rutas. Este
script no crea buckets ni políticas de Storage.

Si el requisito académico es una solución híbrida, este diseño permite
describir un **modelo híbrido dentro de PostgreSQL**. Si se exigieran literalmente
dos bases distintas (una SQL y otra NoSQL), `JSONB` no equivale a una segunda
base: habría que confirmar el requisito con el profesor y justificar e
implementar otro almacén por separado.

## 4. Revisión de la imagen DrawSQL

La imagen muestra las entidades centrales y, a nivel general, permite explicar
el flujo de inventario. Sin embargo, no debe rotularse como copia exacta del
script actual:

1. Falta la columna `proveedores.activo BOOLEAN NOT NULL DEFAULT TRUE`, presente
   en el SQL vigente para permitir una baja lógica.
2. La imagen representa varios campos como tipos `ENUM`, incluidos estados de
   documentos y movimientos. En el SQL actual esos campos son `VARCHAR` con
   restricciones `CHECK`, no tipos `ENUM` de PostgreSQL.
3. La acción de `auditoria_operaciones` también se representa como enum en el
   dibujo; el SQL la declara `VARCHAR(10)` limitada por `CHECK`.
4. `auditoria_usuarios.usuario_id` no tiene clave foránea en el SQL. Esto permite
   conservar el historial aunque la cuenta deje de existir. Si el diagrama
   dibuja una FK en esa relación, hay que quitarla o modificar el SQL de forma
   deliberada; no conviene que ambos documentos se contradigan.

**Conclusión del diagrama:** es una buena vista general, pero está
desactualizado en tipos y en la columna de proveedor. Actualizarlo desde DrawSQL
usando el SQL vigente y volver a exportarlo antes de presentarlo como definitivo.
La imagen incluida aquí queda identificada como referencia pendiente de esa
sincronización.

## 5. Seguridad: qué hay y qué falta

### Controles incluidos

- Hash de contraseñas almacenado en `password_hash`; el SQL no crea una
  contraseña inicial conocida.
- Restricciones de RUT, correo, estados, cantidades, importes y relaciones.
- Roles funcionales y permisos, verificados por las funciones que registran
  operaciones.
- `GRANT`/`REVOKE` para limitar acceso directo de `PUBLIC`, `anon`,
  `authenticated` y `service_role`; el backend recibe permisos específicos.
- Cardex y auditorías se protegen frente a `UPDATE`, `DELETE` y `TRUNCATE`;
  correcciones de inventario se agregan como movimientos nuevos.
- Auditoría de operaciones con exclusión de varias columnas personales o de
  evidencia.
- Anonimización de cuenta que mantiene la referencia histórica sin conservar
  RUT, correo original ni contraseña.

### Límites que impiden llamarlo “seguro para producción”

- **El script no habilita RLS.** El acceso se basa en privilegios SQL y en que la
  aplicación use una conexión confiable. No se debe conectar el navegador
  directamente con credenciales privilegiadas. Si se pretende usar Supabase
  REST/PostgREST desde clientes, hay que diseñar y probar políticas RLS.
- `fn_exigir_permiso` confía en `app.current_user_id`. Esa variable no valida un
  JWT por sí sola. El backend debe validar el token, resolver el usuario
  autenticado y establecer la variable con `SET LOCAL` en cada transacción. No
  debe aceptar un ID de actor enviado libremente por el cliente.
- Las funciones `SECURITY DEFINER` incluyen `public` en su `search_path`.
  Verificar que ningún rol no confiable pueda crear objetos en ese esquema y
  probar los permisos efectivos del proyecto Supabase. Endurecer más el
  `search_path` o cualificar objetos cuando sea posible.
- El backend recibe escritura directa en categorías, proveedores y obras. La
  autorización por usuario en esas operaciones depende del backend; el rol SQL
  compartido no conoce automáticamente el rol funcional de cada persona.
- La auditoría de usuarios solo guarda `rol_id` y `activo` en los JSON de antes y
  después. Cambios de correo, RUT, nombre o contraseña disparan un evento
  `UPDATE`, pero sus valores no quedan registrados. Es una decisión de
  minimización de datos que debe documentarse; si se necesita auditar qué cambió,
  definir una lista segura de campos o eventos.
- La auditoría operativa excluye la clave `nombre` de todas las tablas, además de
  otros campos. Esto reduce exposición de datos, pero también puede ocultar
  cambios de nombres de obras, categorías u otros datos no personales.
- El hash encadenado ayuda a detectar alteraciones si se conserva y verifica la
  cadena, pero no es una firma externa ni una prueba absoluta contra el dueño o
  administrador de la base, quien podría alterar objetos o desactivar triggers.
- No están configurados los buckets, políticas de archivos, monitorización,
  retención de respaldos ni proceso de rotación de credenciales.

**Valoración:** hay una base razonable de integridad y permisos para pruebas
controladas del prototipo. La protección real depende del despliegue y de la
integración del backend; no está demostrada únicamente porque el SQL cree las
tablas o porque Supabase genere el diagrama.

## 6. Supabase y alcance del prototipo

Supabase ofrece PostgreSQL administrado en la nube. El esquema utiliza
características propias de PostgreSQL (`JSONB`, PL/pgSQL, triggers, vistas,
secuencias, funciones y `pgcrypto`) y hace referencia a roles de Supabase
(`anon`, `authenticated`, `service_role`). Por eso no es un script genérico para
cualquier motor SQL ni una aplicación NoSQL.

Para una beta aislada es apropiado si se usa un proyecto de desarrollo, una
conexión exclusiva del backend, credenciales fuera del repositorio y datos
ficticios. `alpha_backend` es un rol sin inicio de sesión; el administrador debe
concederlo al rol real de conexión usado por el servidor. El script no crea la
contraseña ni el usuario de conexión.

El backend actual todavía debe conectarse a PostgreSQL y alinearse con el
contrato. Debe usarse un único proceso de inicialización ORM, cargar todos los
módulos necesarios y no ejecutar `generate_schemas()` como sustituto de este
script: el ORM no genera automáticamente las funciones, triggers, permisos ni
reglas de negocio aquí definidos.

## 7. Instalación, actualización y pruebas pendientes

`CREATE TABLE IF NOT EXISTS` permite crear tablas faltantes, pero **no migra**
tablas que ya existan con otra estructura. La beta creada antes de agregar
`proveedores.activo` necesita esta actualización, si aún no se aplicó:

```sql
ALTER TABLE public.proveedores
ADD COLUMN IF NOT EXISTS activo BOOLEAN NOT NULL DEFAULT TRUE;
```

Las capturas compartidas durante la prueba confirmaron tablas y relaciones
visibles, roles/permisos, las dos vistas y las ocho categorías. La validación
estática de este archivo aceptó 121 sentencias SQL. Eso no equivale a probar cada
función y trigger: no se ejecutó aquí una batería PostgreSQL desde una cuenta
`alpha_backend`.

Antes de usar datos reales, probar en la beta:

1. conexión del backend con TLS, credenciales solo del servidor y privilegios
   efectivos de `alpha_backend`;
2. rechazo de RUT/correo inválidos, cantidades negativas, totales incorrectos y
   documentos duplicados;
3. compra válida y fallida: líneas, descuentos, IVA, saldo y costo promedio;
4. egreso válido y fallido por stock insuficiente, y reversión de la operación
   sin cambios parciales;
5. devoluciones vinculadas al movimiento original y con límite de cantidad;
6. bloqueo de edición/borrado del Cardex, auditorías y documentos registrados;
7. autorización por rol en cada operación y por cada ruta del backend;
8. auditorías: valores que se registran, valores omitidos y actor identificado;
9. restricciones de acceso desde roles Supabase cliente y desde la conexión de
   backend;
10. respaldo y restauración en un proyecto de prueba.

El editor SQL de Supabase suele operar con privilegios administrativos y no es
una prueba de permisos de la aplicación. Las pruebas de autorización deben
ejecutarse con el rol de conexión previsto y mediante el backend.

## 8. Explicación breve para el equipo

> “El inventario y los documentos son relacionales para asegurar referencias,
> cálculos y transacciones. Usamos JSONB solo para metadatos cuyo formato cambia,
> como especificaciones, DTE y referencias de evidencia; los archivos se guardan
> en Storage. El Cardex conserva cada movimiento y las correcciones se agregan
> como reversas. Supabase aporta PostgreSQL administrado, pero la seguridad de
> usuarios depende de que el backend valide el JWT y establezca el actor por
> transacción. El diagrama se mantiene alineado con el SQL y las funciones se
> prueban con un rol real de backend.”
