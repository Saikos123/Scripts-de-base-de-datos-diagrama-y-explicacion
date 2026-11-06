# Informe técnico: base de datos de Proyecto Alpha

**Fecha de revisión:** 5 de noviembre de 2026

**Alcance:** `script.sql` y exportación `supabase-schema.svg` incluida en `docs/`.

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

La exportación de Supabase refleja las tablas y relaciones que aparecen en el
proyecto al momento de exportarla, pero **no coincide por completo con la
versión vigente del SQL**. Se conserva como evidencia del estado observado y
se detallan abajo las diferencias pendientes.

## 2. Estructura y componentes del script

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

## 3. Uso de `JSONB`

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
base. La clasificación final debe contrastarse con el requisito académico
establecido. Si este exige dos almacenes independientes, será necesario
justificar e incorporar un segundo sistema de persistencia.

## 4. Revisión de la exportación de Supabase

La exportación `docs/supabase-schema.svg` incluye las entidades centrales y
permite seguir visualmente las principales relaciones. Los nombres de tabla y
las relaciones visibles coinciden en general con el modelo SQL. Se identifican
15 nodos de tablas, mientras el script define 16.

1. **Falta `tokens_revocados`.** El SQL sí crea esa tabla y una FK hacia
   `usuarios`. La exportación muestra un conector hacia `usuarios` desde un nodo
   que no aparece, por lo que la relación queda huérfana en el dibujo.
2. **Falta `proveedores.activo`.** El SQL vigente incluye esa columna para
   desactivar proveedores sin borrar su historial. Si la base desplegada debía
   incluirla, corresponde confirmar la migración aplicada y volver a exportar el
   esquema.
3. La exportación representa los campos de estado y movimiento como
   `varchar`, coherente con el SQL, que usa `VARCHAR` con `CHECK` en vez de
   tipos PostgreSQL `ENUM`. La vista del esquema no expone en la imagen las
   precisiones numéricas, nulabilidad, valores por defecto ni todas las
   restricciones; para esos detalles el script SQL sigue siendo la referencia.
4. `auditoria_usuarios.usuario_id` no tiene FK a `usuarios` en el SQL, lo que
   permite preservar el historial independientemente de la cuenta. La exportación
   no muestra una relación entre esas tablas, coherente con la definición SQL.

**Conclusión:** este diagrama representa el esquema observado en Supabase con
mayor fidelidad que la exportación anterior de DrawSQL. Aún no representa todo
el SQL vigente, debido a la tabla de tokens ausente y a la columna
`proveedores.activo`. La versión completa requiere resolver ambas diferencias y
generar una nueva exportación.

La siguiente verificación permite determinar si las diferencias están en la
base desplegada o únicamente en la exportación. Las consultas se ejecutan en el
SQL Editor del proyecto correspondiente:

```sql
SELECT to_regclass('public.tokens_revocados') AS tabla_tokens_revocados;

SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'proveedores'
      AND column_name = 'activo'
) AS proveedores_tiene_activo;
```

El resultado esperado es `tokens_revocados` para la primera consulta y `true`
para la segunda. Si alguno de esos resultados no se obtiene, la base requiere
la actualización SQL correspondiente antes de volver a exportar. Si ambos
resultados son correctos y el SVG no refleja esos objetos, la exportación debe
regenerarse desde el mismo proyecto y el esquema `public`.

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
  directamente con credenciales privilegiadas. El acceso desde clientes a
  través de Supabase REST/PostgREST requiere políticas RLS diseñadas y probadas.
- `fn_exigir_permiso` confía en `app.current_user_id`. Esa variable no valida un
  JWT por sí sola. El backend debe validar el token, resolver el usuario
  autenticado y establecer la variable con `SET LOCAL` en cada transacción. No
  debe aceptar un ID de actor enviado libremente por el cliente.
- Las funciones `SECURITY DEFINER` incluyen `public` en su `search_path`.
  La revisión de seguridad debe confirmar que ningún rol no confiable pueda
  crear objetos en ese esquema y debe comprobar los permisos efectivos del
  proyecto Supabase. Como refuerzo, se recomienda restringir el `search_path` o
  cualificar los objetos cuando sea posible.
- El backend recibe escritura directa en categorías, proveedores y obras. La
  autorización por usuario en esas operaciones depende del backend; el rol SQL
  compartido no conoce automáticamente el rol funcional de cada persona.
- La auditoría de usuarios solo guarda `rol_id` y `activo` en los JSON de antes y
  después. Cambios de correo, RUT, nombre o contraseña disparan un evento
  `UPDATE`, pero sus valores no quedan registrados. Es una decisión de
  minimización de datos que debe documentarse. Si el requisito incluye identificar
  esos cambios, corresponde definir una lista permitida de campos o eventos que
  no exponga credenciales ni datos innecesarios.
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

Para una beta aislada, la configuración apropiada incluye un proyecto de
desarrollo, una conexión exclusiva del backend, credenciales fuera del
repositorio y datos ficticios. `alpha_backend` es un rol sin inicio de sesión;
la administración del proyecto debe concederlo al rol real de conexión del
servidor. El script no crea la contraseña ni el usuario de conexión.

La integración del backend requiere conectarse a PostgreSQL y alinearse con el
contrato de datos. La inicialización ORM debe ser única y registrar todos los
módulos necesarios. `generate_schemas()` no sustituye este script: el ORM no
genera automáticamente las funciones, triggers, permisos ni reglas de negocio
definidos aquí.

## 7. Instalación, actualización y pruebas pendientes

`CREATE TABLE IF NOT EXISTS` permite crear tablas faltantes, pero **no migra**
tablas que ya existan con otra estructura. En instalaciones creadas antes de
incorporar `proveedores.activo`, la actualización siguiente debe aplicarse si
la columna aún no existe:

```sql
ALTER TABLE public.proveedores
ADD COLUMN IF NOT EXISTS activo BOOLEAN NOT NULL DEFAULT TRUE;
```

La evidencia visual disponible confirmó tablas y relaciones visibles, los
roles y permisos, las dos vistas y las ocho categorías. La validación estática
aceptó 121 sentencias SQL. Estos resultados no prueban cada función ni trigger:
no se ejecutó una batería PostgreSQL con una cuenta `alpha_backend`.

La validación funcional previa al uso de datos reales debe realizarse en un
entorno beta. La secuencia recomendada es:

1. **Conectividad y privilegios:** comprobar TLS, el uso exclusivo de
   credenciales del servidor y los privilegios efectivos de `alpha_backend`.
2. **Validación de entradas:** confirmar el rechazo de RUT y correos inválidos,
   cantidades negativas, totales incorrectos y documentos duplicados.
3. **Compras e inventario:** verificar compras válidas y fallidas, incluyendo
   líneas, descuentos, IVA, saldo y costo promedio.
4. **Egresos y atomicidad:** probar egresos válidos y rechazos por stock
   insuficiente; confirmar que los fallos no dejan cambios parciales.
5. **Devoluciones:** comprobar su vínculo con el movimiento original y los
   límites de cantidad.
6. **Inmutabilidad:** validar el bloqueo de edición y borrado del Cardex,
   auditorías y documentos registrados.
7. **Autorización:** verificar permisos por rol para cada operación y ruta del
   backend.
8. **Auditoría:** comprobar los datos registrados, los omitidos y la
   identificación del actor.
9. **Aislamiento de acceso:** probar los permisos desde roles cliente de
   Supabase y desde la conexión del backend.
10. **Recuperación:** comprobar respaldo y restauración en un proyecto de
    prueba.

El editor SQL de Supabase suele operar con privilegios administrativos y no es
una prueba de permisos de la aplicación. La autorización se valida con el rol
de conexión previsto y mediante el backend.

## 8. Síntesis arquitectónica

El esquema mantiene en tablas relacionales la información que participa en
claves foráneas, cálculos, permisos e informes. `JSONB` se reserva para
metadatos de estructura variable, como especificaciones, DTE y referencias a
evidencia; los archivos binarios requieren almacenamiento de objetos separado.

El Cardex conserva la secuencia de movimientos de inventario. Las correcciones
se representan mediante movimientos de reversa, sin alterar los registros
originales. Supabase proporciona PostgreSQL administrado, mientras que la
autenticación de usuarios y la identificación del actor por transacción
corresponden a la integración del backend.

La consistencia del sistema depende de mantener el diagrama alineado con el
SQL vigente y de validar las funciones con los privilegios efectivos de la
conexión de backend.
