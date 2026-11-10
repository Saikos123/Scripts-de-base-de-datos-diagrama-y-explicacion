# Guía de prueba: Supabase, backend y Bruno

**Objetivo:** establecer un procedimiento reproducible para validar Alpha en
un entorno beta aislado del entorno compartido del equipo. El entorno beta no
se destina a datos reales ni debe conectarse a bases compartidas sin la
autorización correspondiente.

## Antes de empezar: qué prueba cada herramienta

- **Supabase SQL Editor** sirve para ejecutar SQL y comprobar tablas,
  restricciones, funciones y permisos.
- **El backend FastAPI** es el intermediario entre la aplicación y PostgreSQL.
- **Bruno** envía peticiones HTTP a la API para probar sus rutas, respuestas y
  autenticación. **No se conecta directamente a PostgreSQL** ni reemplaza el
  SQL Editor.

En la versión de referencia revisada, el backend utiliza SQLite en
`backend/app/db/db.py` y `backend/app/main.py`, inicializa el ORM en más de un
lugar y genera esquemas durante el arranque. Por ello, **la configuración no
se limita a sustituir la URL de conexión**: primero debe unificarse y probarse
la inicialización para evitar la creación automática de tablas sobre un esquema
existente.

## 1. Crear un proyecto de beta independiente

1. Abrir el [Dashboard de Supabase](https://supabase.com/dashboard) e iniciar
   sesión.
2. Crear un proyecto independiente con un nombre identificable, por ejemplo
   **Proyecto Alpha - Beta**. No reutilizar proyectos de otros integrantes.
3. Seleccionar una región cercana al equipo y generar una contraseña de base
   de datos larga y aleatoria. Guardarla en un gestor de contraseñas; no
   incluirla en conversaciones, código, Bruno ni repositorios.
4. Esperar a que finalice el aprovisionamiento y verificar que el proyecto
   seleccionado sea el entorno beta antes de ejecutar SQL.

## 2. Cargar el esquema inicial

El archivo [`script.sql`](./script.sql) crea el esquema inicial; no es una
migración para actualizar una base existente. `CREATE TABLE IF NOT EXISTS` no
cambia una tabla creada previamente con otra estructura.

Si el proyecto ya tiene la base creada con el script original, no vuelvas a
ejecutar `script.sql`. Primero realiza y comprueba un backup restaurable; compara
el esquema y prueba únicamente las migraciones necesarias en una copia. La
migración [`migracion_proyecto1_compras.sql`](./migracion_proyecto1_compras.sql)
corresponde a una versión anterior: el `script.sql` actual ya contiene esos
componentes, por lo que no se debe aplicar a ciegas.

Para una instalación nueva, el script base crea 21 tablas. La migración
[`migracion_proyecto1_solicitudes_y_acuses.sql`](./migracion_proyecto1_solicitudes_y_acuses.sql)
agrega tres tablas de solicitudes y acuses. Si ya fue aplicada, la migración
[`migracion_proyecto1_acuse_despues_despacho.sql`](./migracion_proyecto1_acuse_despues_despacho.sql)
permite registrar primero el despacho y después el acuse. No reejecutar
migraciones ya aplicadas solo para “asegurarse”.

Después de aplicar el esquema y las migraciones aprobadas, ejecuta:

```sql
SELECT * FROM fn_verificar_integridad_cardex();
```

Solo continúa si `integro` es `true`. Si devuelve `false`, no se reescriben los
movimientos históricos: detén la puesta en producción y revisa el primer ID
informado antes de cualquier reparación.

1. Abrir **SQL Editor** en el proyecto beta.
2. Crear una consulta nueva e incorporar el contenido completo de `script.sql`.
3. Confirmar que el proyecto seleccionado es el entorno beta y ejecutar el
   script.
4. Ante un error, detener la ejecución y analizar el primer mensaje. Antes de
   reejecutar el archivo, determinar qué sentencias llegaron a completarse y
   corregir la causa.
5. Si la ejecución termina sin errores, conservar la consulta y registrar la
   fecha de aplicación.

El script crea el grupo PostgreSQL `alpha_backend` con `NOLOGIN` y le concede
permisos específicos. **No crea un usuario de conexión ni una contraseña para
el backend.** Esa cuenta requiere configuración separada durante la adaptación del backend,
según la guía oficial de [roles PostgreSQL en Supabase](https://supabase.com/docs/guides/database/postgres/roles).
La aplicación no debe conectarse con el usuario administrador `postgres`.

## 3. Verificar que la beta tiene el esquema esperado

Ejecutar las siguientes consultas en SQL Editor:

```sql
SELECT COUNT(*) AS tablas_public
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE';

SELECT
    to_regclass('public.tokens_revocados') AS tabla_tokens_revocados,
    EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'proveedores'
          AND column_name = 'activo'
    ) AS proveedores_tiene_activo;

SELECT rolname, rolcanlogin
FROM pg_catalog.pg_roles
WHERE rolname = 'alpha_backend';
```

Resultados esperados para el esquema base actual: **21** tablas,
`tokens_revocados`, `true` para `proveedores_tiene_activo`, y `alpha_backend`
con `rolcanlogin = false`. Después de la migración de solicitudes/acuses deben
existir además `solicitudes_materiales`, `detalle_solicitud_materiales` y
`acuses_recepcion_egreso` (24 tablas públicas en total, sin contar vistas).
Ante cualquier discrepancia, posponer la conexión del backend y comparar los
resultados con el script. Si corresponde, generar una nueva exportación del
esquema.

Los permisos del grupo pueden comprobarse con la siguiente consulta:

```sql
SELECT
    has_table_privilege('alpha_backend', 'public.cardex', 'SELECT')
        AS puede_leer_cardex,
    has_table_privilege('alpha_backend', 'public.cardex', 'INSERT')
        AS puede_insertar_cardex;
```

El resultado esperado es `true` y `false`, respectivamente. `cardex` se lee
directamente, pero sus movimientos se escriben por las funciones previstas en
el script.

## 4. Configurar y comprobar el Storage privado

El acuse firmado se guarda como archivo en Supabase Storage; PostgreSQL conserva
el bucket y la ruta. El usuario confirmó la existencia de `acuse-recepcion` con
`public = false`. Para comprobarlo:

```sql
SELECT id, name, public
FROM storage.buckets
WHERE id = 'acuse-recepcion';
```

La aplicación debe subir el archivo desde el backend y solo después registrar
sus metadatos con `fn_registrar_acuse_recepcion_egreso`. No poner credenciales
de Storage en el navegador. Si se habilita subida/lectura directa por clientes,
crear y probar políticas Storage limitadas; no hacer público el bucket.

## 5. Preparar la conexión del backend (siguiente etapa)

Una vez verificado el esquema beta, configurar la conexión del backend según
la siguiente secuencia:

1. Aislar el trabajo en una rama o copia de prueba autorizada por el equipo.
   No modificar ramas compartidas para conectar el entorno beta.
2. En Supabase, abrir **Connect** y seleccionar el tipo de conexión. Para una
   máquina local que solo tenga IPv4, seleccionar **Session pooler**. La
   conexión directa puede requerir IPv6 o el complemento IPv4; los detalles
   están en la
   [documentación de conexiones](https://supabase.com/docs/guides/database/connecting-to-postgres).
3. Copiar la cadena ofrecida por el Dashboard y sustituir la contraseña de
   ejemplo por la de la cuenta de conexión dedicada. Codificar los caracteres
   especiales como URL según las instrucciones de Supabase. No construir
   manualmente el host ni el usuario del pooler.
4. Guardar la URL como variable de entorno local, por ejemplo `DATABASE_URL`,
   y comprobar que el archivo local de variables esté ignorado por Git. No
   publicar la URL ni incorporarla al frontend.
5. Antes de conectar el backend a Supabase, unificar las inicializaciones de
   Tortoise para utilizar esa variable, eliminar inicializaciones duplicadas y
   desactivar la creación automática de esquemas. El SQL constituye la fuente
   del esquema; los cambios posteriores requieren migraciones controladas.
6. Utilizar una cuenta PostgreSQL de inicio de sesión dedicada, miembro de
   `alpha_backend`. No utilizar `postgres`, `service_role` ni una clave
   `service_role` de Supabase. Mantener la contraseña únicamente en el entorno
   local.
7. Iniciar el backend y confirmar en sus registros la conexión al entorno beta.
   Ejecutar una lectura y una operación de prueba; verificar luego en SQL
   Editor que los datos se almacenaron en esa misma base.

La cadena de conexión no corresponde a Bruno: Bruno se comunica con la API
HTTP, no directamente con PostgreSQL. En la versión de referencia que utiliza
SQLite, los pasos 4–6 requieren adaptar y revisar el código antes de considerar
que la API está probando Supabase.

## 6. Instalar y usar Bruno para probar la API

Bruno permite probar las rutas del backend y conservar colecciones de pruebas
compartibles. La aplicación puede descargarse desde la
[página oficial de Bruno](https://www.usebruno.com/downloads). En Windows,
también puede instalarse mediante:

```powershell
winget install bruno.bruno
```

Con el backend en funcionamiento:

1. Crear una colección, por ejemplo **Proyecto Alpha - Beta**.
2. Configurar `baseUrl` con la dirección local de la API, normalmente
   `http://127.0.0.1:8000`. No incorporar credenciales de base de datos.
3. Consultar `http://127.0.0.1:8000/docs` para identificar las rutas y métodos
   publicados por FastAPI. Utilizar únicamente endpoints existentes.
4. Ejecutar primero una petición de lectura y continuar con los flujos de
   inicio de sesión, permisos, categorías y operaciones implementadas. Antes
   de una operación que modifique datos, confirmar que la API apunta al entorno
   beta.
5. Si la API utiliza tokens, guardarlos como variables secretas locales de
   Bruno. No incluirlos en Git, capturas ni documentación compartida.
6. Registrar para cada prueba el método, la ruta, el resultado esperado y el
   obtenido. Las colecciones compartidas deben excluir contraseñas, tokens y
   variables secretas.

Antes de iniciar la versión de referencia del backend, revisar y retirar
cualquier cuenta de administrador de demostración o credencial fija presente
en el código. Utilizar una cuenta de prueba con una contraseña nueva y no
publicar valores predeterminados.

## 7. Límites de seguridad para esta beta

- En las tablas `public`, el diseño aplicado mantiene RLS desactivado y depende
  de grants/revokes de mínimo privilegio y del backend confiable. No exponer
  tablas mediante la API de Supabase a clientes; si se requiere acceso directo,
  habilitar RLS y probar políticas antes de publicarlo.
- Mantener RLS activado en las tablas internas de `storage` y usar el bucket
  privado. Crear políticas Storage solo si los clientes acceden directamente.
- El script revoca permisos de tablas a `anon`, `authenticated` y
  `service_role`; esas identidades no deben utilizarse para eludir los permisos
  previstos para el backend.
- No incluir contraseñas, URLs PostgreSQL, tokens ni claves `service_role` en
  el repositorio, Bruno ni el frontend.
- Utilizar datos ficticios y mantener el entorno beta separado de las bases y
  credenciales compartidas.

## Referencias oficiales

- [Conectar a PostgreSQL en Supabase](https://supabase.com/docs/guides/database/connecting-to-postgres)
- [Roles PostgreSQL en Supabase](https://supabase.com/docs/guides/database/postgres/roles)
- [RLS en Supabase](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Descargar Bruno](https://www.usebruno.com/downloads)
- [Documentación de Bruno](https://docs.usebruno.com/)
