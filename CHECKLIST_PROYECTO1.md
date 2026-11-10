# Checklist de avance — Proyecto 1 [Alpha]

**Sistema:** Gestión Logística e Inventario
**Fecha de revisión:** 10 de noviembre de 2026
**Alcance:** requisitos del Proyecto 1 y preparación de su base de datos. No se
consideran requisitos adicionales de reservas generales o inventario físico
tomados de otros documentos.

> **Importante:** el usuario confirma que ejecutó `script.sql`, las migraciones
> de solicitudes/acuses y la corrección del orden despacho-acuse en Supabase.
> Las capturas compartidas confirman el bucket privado, RLS desactivado en
> `public` y permisos SQL seleccionados. No hemos conectado ni probado el
> backend contra esa instancia.

## Completadas

- [x] **Catálogo de artículos y categorías:** tablas, relaciones y
  validaciones implementadas; el script se instaló en una base local limpia.
- [x] **Proveedores y contactos:** se añadieron contactos normalizados de
  proveedores.
- [x] **Clientes asociados a obras:** se añadió el catálogo normalizado de
  clientes y su relación con obras; se conserva el texto histórico y se probó
  su asociación durante la migración.
- [x] **Compras y costos:** facturas, líneas, descuentos, IVA, cálculo de costo
  promedio ponderado y registro transaccional.
- [x] **Recepción por guía y conciliación con factura** *(antes parcial; ahora
  completada en la base de datos y probada localmente):* el stock se ingresa una
  sola vez y la factura se vincula a lo recibido sin duplicar cantidades.
- [x] **Ajuste de valorización** *(antes parcial; ahora completado y probado
  localmente):* la diferencia de costo se registra en el Kardex sin cambiar las
  unidades existentes.
- [x] **Bloqueo de despacho de guías pendientes** *(antes parcial; ahora
  completado y probado localmente):* las cantidades no conciliadas quedan
  reservadas al despacho; después de conciliar se habilita el stock disponible.
- [x] **Egresos a obras:** actualización transaccional de stock y validación de
  disponibilidad; se probó el despacho después de la conciliación.
- [x] **Devoluciones y notas de crédito** *(antes parcial; ahora completadas y
  probadas localmente):* la devolución queda vinculada a la compra, la nota de
  crédito y el movimiento de Kardex.
- [x] **Kardex inmutable:** se bloquean actualización, borrado y truncado; las
  correcciones se agregan como movimientos nuevos.
- [x] **Integridad de hashes del Kardex** *(antes parcial; ahora implementada y
  probada localmente):* un trigger genera los hashes al insertar y una función
  verifica la cadena; se comprobó que detecta una alteración intencional de
  prueba.
- [x] **Protección de cuentas bancarias:** acceso mediante funciones y sin
  lectura directa de la tabla para `alpha_backend`; se verificó en la base de
  pruebas.
- [x] **Backup y migración incremental:** se conserva el script original y la
  migración se aplicó a una copia local restaurada desde ese backup. Se
  comprobaron sus flujos principales y su ejecución repetida.

## Parcial / completadas

- [~] **Base de datos del equipo:** el usuario informa que ejecutó `script.sql`
  y las dos migraciones posteriores en Supabase. Capturas/consultas confirman
  tablas nuevas, permisos seleccionados, RLS desactivado en `public` y el
  bucket privado; falta completar la comparación del esquema y las pruebas con
  la conexión real del backend.
- [~] **Integridad del Kardex histórico:** la verificación está implementada,
  pero aún debe ejecutarse sobre la copia real. La migración no reescribe hashes
  históricos; cualquier discrepancia requiere investigación.
- [~] **Seguridad y permisos:** el esquema define roles, permisos y restricciones
  para el backend; se comprobaron algunos privilegios y que las tablas `public`
  no se exponen por Data API. Falta probar la conexión real, el conjunto
  completo de permisos y las funciones `SECURITY DEFINER` en Supabase.
- [~] **Diagrama de la base:** existe una exportación anterior, pero no refleja
  todas las tablas y relaciones añadidas. Debe actualizarse tras validar la
  migración en Supabase.
- [~] **Alertas e informes:** el SQL proporciona datos y vistas de apoyo, pero
  las alertas entregadas al usuario y los informes finales requieren integrar y
  probar el backend.

## Faltantes / por hacer

- [ ] Hacer backup de la instancia Supabase/base real y verificar que se pueda
  restaurar.
- [ ] Comparar el esquema real de Supabase con el script vigente. `IF NOT
  EXISTS` no actualiza tablas preexistentes; no volver a ejecutar el script
  inicial para intentar corregir diferencias.
- [x] Aplicar en Supabase, según confirmación del usuario, la migración de
  solicitudes/acuses y la correctiva que permite registrar el acuse después
  del despacho.
- [ ] Comparar el esquema desplegado con las migraciones aplicadas y probar una
  restauración en una copia antes de considerar producción.
- [ ] Verificar en Supabase el flujo despacho → acuse y el seguimiento mediante
  `vw_egresos_sin_acuse`, usando la conexión real del backend.
- [ ] En Supabase o una copia fiel, ejecutar
  `SELECT * FROM fn_verificar_integridad_cardex();`. Investigar cualquier
  resultado con `integro = false`; no regenerar en bloque los hashes históricos.
- [ ] Probar la migración y los flujos con el rol de conexión previsto para el
  backend, no solo con privilegios administrativos.
- [~] Se consultaron permisos SQL seleccionados de `alpha_backend` y se
  confirmó RLS desactivado en las tablas `public` mostradas. Falta verificar
  privilegios completos/heredados y probar la conexión real del backend.
- [ ] Mantener el acceso a `public` solo mediante el backend privado mientras
  no existan políticas RLS; diseñar y probar RLS antes de habilitar acceso
  directo desde clientes.
- [x] Crear el bucket privado `acuse-recepcion` en Supabase Storage (confirmado
  por consulta: `public = false`); configurar políticas solo si se habilita
  carga/lectura directa desde clientes. El archivo SQL conserva rutas y
  metadatos, no crea el bucket.
- [ ] Probar solicitudes, aprobación/rechazo, vínculo al egreso, coincidencia
  de líneas despachadas y registro del acuse posterior a la entrega, con
  permisos por rol.
- [ ] Resolver HU-06 si se requiere guardar tomas físicas: no existen todavía
  tablas de cabecera/detalle para conteos ni una operación de conciliación
  asociada.
- [ ] Revisar el `search_path` de las funciones `SECURITY DEFINER` y comprobar
  que ningún rol no confiable pueda crear objetos que alteren la resolución de
  nombres.
- [ ] Actualizar la exportación del diagrama después de aplicar y validar la
  migración.
- [ ] Alinear los modelos e integrar el backend con PostgreSQL. Adaptar los
  flujos para llamar a las funciones de recepción, conciliación, devolución,
  cuentas bancarias y verificación del Kardex, sin evadir las reglas mediante
  escrituras ORM directas.
- [ ] Validar autenticación e identificación del actor por transacción con
  `SET LOCAL app.current_user_id`; el backend debe validar el token y no confiar
  en un ID enviado libremente por el cliente.
- [ ] Ejecutar pruebas de permisos por rol, entradas inválidas, concurrencia,
  atomicidad, auditoría y restauración en un entorno beta.
- [ ] Implementar y probar desde el backend las alertas y los informes
  requeridos.
- [ ] Definir e implementar al menos una funcionalidad de valor agregado; se
  acordó dejarla para una etapa posterior del backend.

## Protección de datos personales y marco legal chileno

> **No se puede afirmar que el sistema “cumple completamente” estas leyes solo
> por revisar el SQL.** La evaluación depende también del propósito y base legal
> del tratamiento, quién accede a los datos, los contratos, la operación de
> Supabase, los plazos de conservación, la respuesta a solicitudes y las
> medidas organizacionales. Esta lista es una revisión técnica inicial, no una
> certificación ni asesoría jurídica.

| Norma relevante | Cómo se relaciona con el sistema | Estado en este proyecto |
|---|---|---|
| [Ley 19.628 sobre protección de la vida privada](https://www.bcn.cl/leychile/navegar?idNorma=141599) | Relevante para RUT, nombre, correo, cuentas de usuario, identificadores y demás datos personales. Requiere definir y documentar finalidad, acceso, conservación y respuesta a solicitudes de titulares. | [~] El esquema reduce algunos datos en auditoría y tiene anonimización, pero el SQL por sí solo no demuestra cumplimiento legal ni operativo. Revisar aviso/política, finalidad, base jurídica, accesos, conservación y procedimiento de derechos. |
| [Ley 21.719, que regula la protección y el tratamiento de datos personales](https://www.bcn.cl/leychile/navegar?idNorma=1209272) | Reforma el régimen de la Ley 19.628. Por la fecha de esta revisión (8 de noviembre de 2026), su entrada en vigor está prevista para el 1 de diciembre de 2026; el equipo debe preparar la operación y confirmar el texto y las obligaciones aplicables con asesoría jurídica. | [ ] No se ha hecho una evaluación de brechas ni de preparación para su entrada en vigor. |
| [Código del Trabajo, artículo 154 bis](https://www.bcn.cl/leychile/navegar?idNorma=207436) | Puede ser pertinente cuando el sistema trata información privada de trabajadores a la que el empleador accede por la relación laboral. | [~] Hay controles técnicos de acceso, pero falta definir perfiles autorizados, confidencialidad, finalidad y procedimiento de baja con el responsable de personas/asesoría laboral. |

### Cuentas desactivadas, solicitudes de eliminación e historial

- [x] **El esquema tiene baja lógica:** `usuarios.activo` permite marcar una
  cuenta inactiva sin borrar su fila. Las relaciones de facturas, egresos y
  movimientos del Kardex usan `ON DELETE RESTRICT`, lo que protege el historial
  operativo referido a ese usuario.
- [x] **La auditoría de usuario no copia RUT, correo ni contraseña:** registra
  cambios de rol/estado y el identificador de actor.
- [ ] **Desactivar no es lo mismo que ocultar datos:** cambiar `activo` a
  `false` bloquea la autorización en `fn_exigir_permiso`, pero no borra ni
  enmascara el nombre, RUT o correo. La aplicación debe impedir el inicio de
  sesión y excluir o restringir la exposición de cuentas inactivas en sus
  consultas y pantallas.
- [ ] **Revisar el flujo de anonimización:** `fn_anonimizar_usuario` no solo
  desactiva; también elimina el RUT de la fila y reemplaza nombre, correo y
  contraseña. Las referencias de facturas, egresos, Kardex y auditorías se
  conservan, pero al reemplazar el nombre se pierde la identificación directa
  de esa persona en consultas históricas. No debe usarse como sinónimo de baja
  ordinaria sin acordar la política de conservación y trazabilidad.
- [ ] **No definir una regla absoluta de “nunca se elimina ningún dato”:** una
  solicitud del titular debe evaluarse conforme a la norma aplicable y a las
  obligaciones de conservación que correspondan. La baja de la cuenta puede
  mantenerse separada de la eliminación o anonimización de datos; conservar
  datos personales indefinidamente tampoco debe asumirse como permitido.
- [ ] Documentar plazos y motivos de conservación para usuarios, facturas,
  movimientos, auditorías, respaldos y datos de autenticación; definir quién
  puede autorizar una eliminación o anonimización y cómo se propaga a copias y
  respaldos.
- [ ] Revocar sesiones/tokens de una cuenta desactivada y verificar que las
  rutas del backend comprueben `activo` en cada autenticación/autorización.
- [ ] Validar este flujo con el encargado de datos/personas y asesoría jurídica
  en Chile antes de tratarlo como cumplimiento de ley.

## Conclusión

El núcleo de base de datos —compras, PMP, recepciones/conciliación,
devoluciones, egresos, Kardex, permisos, solicitudes y acuses— está
implementado. El usuario confirma que el esquema y las migraciones recientes se
ejecutaron en Supabase; las capturas revisadas confirman parte de su
configuración. La base está **preparada para integración**, pero la conexión
real del backend, sus permisos y los flujos completos aún deben probarse.
También falta decidir si HU-06 incluirá persistencia de conteos físicos, pues
esas tablas no forman parte del esquema actual. No se afirma que todas las HU
del sistema estén terminadas ni que exista certificación de cumplimiento legal.
