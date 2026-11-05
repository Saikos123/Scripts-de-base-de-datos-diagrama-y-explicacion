# Proyecto Alpha — base de datos

Este repositorio reúne el script inicial de PostgreSQL para el prototipo, una
exportación del diagrama DrawSQL y el informe que explica el diseño, sus
controles y los puntos que todavía deben validarse.

- [Script SQL](./script.sql)
- [Informe técnico y revisión del diagrama](./INFORME_TECNICO.md)
- [Diagrama DrawSQL (exportación del 5 de noviembre de 2026)](./docs/diagrama-drawsql.jpg)

## Antes de ejecutar

`script.sql` está pensado para una base Supabase de desarrollo vacía. No es una
migración para actualizar una instalación existente: `CREATE TABLE IF NOT EXISTS`
no modifica tablas que ya fueron creadas con otra estructura.

El esquema está diseñado para que un backend confiable se conecte a PostgreSQL.
No se deben incluir credenciales de base de datos en el frontend ni en este
repositorio. El diagrama se conserva como referencia visual, pero el informe
enumera diferencias con el SQL vigente que deben corregirse en DrawSQL.

La creación de las tablas no sustituye las pruebas de las funciones,
restricciones, triggers, transacciones y permisos desde una cuenta de conexión
con privilegios equivalentes a los previstos para el backend.
