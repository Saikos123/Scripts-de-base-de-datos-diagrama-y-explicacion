# Guía de prueba: Supabase, backend y Bruno

**Objetivo:** probar Alpha en un entorno separado del proyecto y la base de
datos de los compañeros. El entorno de prueba puede llamarse **Proyecto Alpha
- Beta**. No se debe usar para datos reales ni conectarse a la base del equipo
sin su autorización.

## Antes de empezar: qué prueba cada herramienta

- **Supabase SQL Editor** sirve para ejecutar SQL y comprobar tablas,
  restricciones, funciones y permisos.
- **El backend FastAPI** es el intermediario entre la aplicación y PostgreSQL.
- **Bruno** envía peticiones HTTP a la API para probar sus rutas, respuestas y
  autenticación. **No se conecta directamente a PostgreSQL** ni reemplaza el
  SQL Editor.

La configuración actual del backend del compañero todavía apunta a SQLite en
`backend/app/db/db.py` y `backend/app/main.py`. Además, inicializa el ORM en
más de un lugar y genera esquemas al arrancar. Por eso, **no basta con pegar
la URL de Supabase**: primero hay que adaptar y probar la configuración del
backend para que use una sola conexión y no intente crear tablas sobre el
esquema existente.

## 1. Crear un proyecto de beta independiente

1. Entra al [Dashboard de Supabase](https://supabase.com/dashboard) e inicia
   sesión.
2. Crea un proyecto nuevo con un nombre reconocible, por ejemplo
   **Proyecto Alpha - Beta**. No reutilices el proyecto de otro integrante.
3. Escoge una región cercana al equipo y genera una contraseña de base de
   datos larga y aleatoria. Guárdala en un gestor de contraseñas; no la pongas
   en el chat, el código, Bruno ni un repositorio.
4. Espera a que el proyecto termine de aprovisionarse y verifica que el nombre
   del proyecto seleccionado sea el de beta antes de ejecutar SQL.

## 2. Cargar el esquema inicial

El archivo [`script.sql`](./script.sql) crea el esquema inicial; no es una
migración para actualizar una base existente. `CREATE TABLE IF NOT EXISTS` no
cambia una tabla creada previamente con otra estructura.

1. Abre **SQL Editor** en el proyecto beta.
2. Crea una consulta nueva y pega el contenido completo de `script.sql`.
3. Revisa una vez más que estás en el proyecto beta y ejecuta el script.
4. Si aparece un error, detente y lee el primer error. No vuelvas a ejecutar
   todo el archivo a ciegas: primero hay que determinar qué alcanzó a ejecutar
   y corregir el problema.
5. Si termina sin errores, conserva la consulta y anota la fecha de ejecución.

El script crea el grupo PostgreSQL `alpha_backend` con `NOLOGIN` y le concede
permisos específicos. **No crea un usuario de conexión ni una contraseña para
el backend.** Esa cuenta debe prepararse por separado cuando se adapte el
backend, siguiendo la guía oficial de [roles PostgreSQL en Supabase](https://supabase.com/docs/guides/database/postgres/roles).
No conectes la aplicación con el usuario administrador `postgres`.

## 3. Verificar que la beta tiene el esquema esperado

Ejecuta estas consultas en el SQL Editor:

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

Resultados esperados: **16** tablas, `tokens_revocados`, `true` para
`proveedores_tiene_activo`, y `alpha_backend` con `rolcanlogin = false`.
Si algo no coincide, no conectes aún el backend: compara el resultado con el
script y, si corresponde, genera una nueva exportación del esquema.

También puedes comprobar los permisos del grupo:

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

## 4. Preparar la conexión del backend (siguiente etapa)

Cuando el esquema beta esté verificado, la conexión del backend se configura
así:

1. Aísla el trabajo en una rama o copia de prueba autorizada por el grupo. No
   cambies la rama compartida del compañero para conectar la beta.
2. En Supabase, abre **Connect** y elige el tipo de conexión. Para una máquina
   local que solo tenga IPv4, usa **Session pooler**. La conexión directa puede
   requerir IPv6 o el complemento IPv4; los detalles están en la
   [documentación de conexiones](https://supabase.com/docs/guides/database/connecting-to-postgres).
3. Copia la cadena que ofrece el Dashboard y reemplaza la contraseña de ejemplo
   por la de la cuenta de conexión dedicada. Si contiene caracteres especiales,
   codifícalos para URL como indica Supabase. No construyas a mano el host ni el
   usuario del pooler.
4. Guarda la URL como variable de entorno local, por ejemplo `DATABASE_URL`;
   asegúrate de que el archivo local de variables esté ignorado por Git. No
   publiques la URL ni la insertes en el frontend.
5. Antes de apuntar el backend a Supabase, modifica su configuración para que
   ambas inicializaciones de Tortoise usen esa variable, evita la inicialización
   duplicada y desactiva la creación automática de esquemas. El SQL debe ser la
   fuente del esquema; cualquier cambio posterior debe gestionarse como una
   migración controlada.
6. Conecta el backend con una cuenta PostgreSQL de inicio de sesión dedicada,
   miembro de `alpha_backend`, no con `postgres`, `service_role` ni una clave
   `service_role` de Supabase. Mantén la contraseña solo en el entorno local.
7. Arranca el backend y comprueba en sus logs que conecta a la base beta. Haz
   una prueba de lectura y una operación de prueba; luego confirma desde el SQL
   Editor que los datos aparecieron en esa beta y no en otra base.

La cadena de conexión no se debe poner en Bruno: Bruno habla con la API HTTP,
no con PostgreSQL. Como la configuración actual del backend sigue en SQLite,
los pasos 4–6 requieren adaptar y revisar ese código antes de afirmar que la
API está probando Supabase.

## 5. Instalar y usar Bruno para probar la API

**Sí, Bruno es recomendable** para probar las rutas del backend y guardar una
colección de pruebas que el grupo pueda compartir. Descárgalo desde la
[página oficial de Bruno](https://www.usebruno.com/downloads) o instala la
versión de Windows con:

```powershell
winget install bruno.bruno
```

Cuando el backend esté funcionando:

1. Abre Bruno y crea una colección, por ejemplo **Proyecto Alpha - Beta**.
2. Configura una variable de entorno `baseUrl` con la dirección local de la
   API, normalmente `http://127.0.0.1:8000`. No agregues credenciales de base
   de datos.
3. Abre `http://127.0.0.1:8000/docs` en el navegador para revisar las rutas
   que FastAPI realmente publica. Usa en Bruno esas rutas y métodos; no inventes
   endpoints.
4. Prueba primero una petición de lectura y después los flujos de inicio de
   sesión, permisos, categorías y operaciones que ya existan. Para operaciones
   que cambien datos, confirma que la API está apuntando a beta.
5. Si la API usa token, guárdalo como variable secreta local en Bruno. No lo
   subas a Git ni lo incluyas en capturas o documentación compartida.
6. Registra el método, la ruta, el resultado esperado y el resultado obtenido
   para cada prueba. Las colecciones de Bruno se pueden compartir, pero deben
   excluir contraseñas, tokens y variables secretas.

Antes de probar el arranque actual del backend, revisa y reemplaza cualquier
cuenta de administrador de demostración o credencial fija que tenga el código.
Usa una cuenta de prueba con una contraseña nueva; no publiques valores
predeterminados.

## 6. Límites de seguridad para esta beta

- El SQL actual no habilita RLS. Mantén el acceso a la base detrás del backend
  confiable y no publiques tablas directamente mediante la API de Supabase
  hasta diseñar y probar RLS y sus políticas.
- El script revoca permisos de tablas a `anon`, `authenticated` y
  `service_role`; no uses esas identidades para saltarte los permisos
  intencionados del backend.
- No subas contraseñas, URLs PostgreSQL, tokens ni claves `service_role` al
  repositorio, a Bruno o al frontend.
- Usa datos ficticios y mantén el proyecto separado del trabajo y las
  credenciales de los demás integrantes.

## Referencias oficiales

- [Conectar a PostgreSQL en Supabase](https://supabase.com/docs/guides/database/connecting-to-postgres)
- [Roles PostgreSQL en Supabase](https://supabase.com/docs/guides/database/postgres/roles)
- [RLS en Supabase](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Descargar Bruno](https://www.usebruno.com/downloads)
- [Documentación de Bruno](https://docs.usebruno.com/)
