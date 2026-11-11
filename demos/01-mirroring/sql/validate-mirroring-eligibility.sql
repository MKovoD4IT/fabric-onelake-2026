/*
    Validación previa al Mirroring en Fabric
    ----------------------------------------
    Revisa, tabla por tabla y columna por columna, qué va a llegar a OneLake
    según las limitaciones documentadas de Fabric Mirroring:
    https://learn.microsoft.com/fabric/mirroring/azure-sql-database-limitations
    https://learn.microsoft.com/fabric/mirroring/sql-server-limitations

    Sirve para Azure SQL Database (AdventureWorksLT) y SQL Server 2022 (AdventureWorks).
    Ejecutar en la base de datos a espejar. Devuelve tres result sets:
      1. Tablas: si se espejan, con qué advertencias
      2. Columnas que no llegan al lago (o llegan con pérdida/truncamiento)
      3. Resumen
    Solo lee metadatos: no modifica nada.
*/
SET NOCOUNT ON;

DECLARE @cols TABLE (
    object_id   int,
    column_id   int,
    schema_name sysname,
    table_name  sysname,
    column_name sysname,
    type_name   sysname,
    base_type   sysname,
    max_length  smallint,
    scale       tinyint,
    is_computed bit,
    is_encrypted bit,
    is_key      bit,
    status      varchar(20),     -- NO_SOPORTADA | PERDIDA | TRUNCAMIENTO | VERIFICAR
    motivo      nvarchar(200)
);

INSERT INTO @cols (object_id, column_id, schema_name, table_name, column_name, type_name, base_type,
                   max_length, scale, is_computed, is_encrypted, is_key, status, motivo)
SELECT
    c.object_id, c.column_id, s.name, t.name, c.name,
    ut.name,
    COALESCE(bt.name, ut.name),
    c.max_length, c.scale, c.is_computed,
    CASE WHEN c.encryption_type IS NOT NULL THEN 1 ELSE 0 END,
    k.is_key,
    x.status, x.motivo
FROM sys.columns c
JOIN sys.tables  t  ON t.object_id = c.object_id
JOIN sys.schemas s  ON s.schema_id = t.schema_id
JOIN sys.types   ut ON ut.user_type_id = c.user_type_id
-- LEFT: los tipos CLR (hierarchyid, geometry, geography) tienen system_type_id 240, que no es un user_type_id
LEFT JOIN sys.types bt ON bt.user_type_id = c.system_type_id
-- ¿La columna es parte de la PK (o del índice clustered si no hay PK)?
OUTER APPLY (
    SELECT CAST(CASE WHEN EXISTS (
        SELECT 1
        FROM sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.object_id = c.object_id
          AND ic.column_id = c.column_id
          AND ic.key_ordinal > 0
          AND (i.is_primary_key = 1
               OR (i.type = 1 AND NOT EXISTS (SELECT 1 FROM sys.indexes p
                                              WHERE p.object_id = c.object_id AND p.is_primary_key = 1)))
    ) THEN 1 ELSE 0 END AS bit) AS is_key
) k
CROSS APPLY (
    SELECT
        CASE
            WHEN c.is_computed = 1                                   THEN 'NO_SOPORTADA'
            WHEN ut.is_assembly_type = 1 AND ut.is_user_defined = 1  THEN 'NO_SOPORTADA'
            WHEN ut.name IN ('geometry','geography')                  THEN 'NO_SOPORTADA'
            WHEN bt.name IN ('image','text','ntext','xml','timestamp','sql_variant')
                                                                     THEN 'NO_SOPORTADA'
            WHEN ut.name IN ('json','vector')                         THEN 'NO_SOPORTADA'
            WHEN c.encryption_type IS NOT NULL                       THEN 'NO_SOPORTADA'
            WHEN ut.name = 'hierarchyid'                             THEN 'VERIFICAR'
            WHEN bt.name IN ('datetime2','datetimeoffset','time') AND c.scale = 7
                                                                     THEN 'PERDIDA'
            WHEN bt.name IN ('varchar','nvarchar','varbinary') AND c.max_length = -1
                                                                     THEN 'TRUNCAMIENTO'
            WHEN ut.is_user_defined = 1                              THEN 'VERIFICAR'
        END AS status,
        CASE
            WHEN c.is_computed = 1                                   THEN N'Columna calculada: no se espeja; recalcular en Silver'
            WHEN ut.is_assembly_type = 1 AND ut.is_user_defined = 1  THEN N'UDT CLR: no se espeja'
            WHEN ut.name IN ('geometry','geography')                  THEN N'Tipo espacial: no se espeja'
            WHEN bt.name IN ('image','text','ntext')                  THEN N'Tipo LOB legado: no se espeja'
            WHEN bt.name = 'xml'                                      THEN N'xml: no se espeja'
            WHEN bt.name = 'timestamp'                                THEN N'rowversion/timestamp: no se espeja'
            WHEN bt.name = 'sql_variant'                              THEN N'sql_variant: no se espeja'
            WHEN ut.name IN ('json','vector')                         THEN N'json/vector: la tabla entera no se espeja'
            WHEN c.encryption_type IS NOT NULL                       THEN N'Always Encrypted: la tabla no se espeja'
            WHEN ut.name = 'hierarchyid'                             THEN N'hierarchyid: no listado como columna no soportada; confirmar en el mirror'
            WHEN bt.name IN ('datetime2','datetimeoffset','time') AND c.scale = 7
                                                                     THEN N'Precisión 7: Delta guarda 6 dígitos (datetimeoffset además pierde la zona horaria)'
            WHEN bt.name IN ('varchar','nvarchar','varbinary') AND c.max_length = -1
                                                                     THEN N'(max): valores mayores a 1 MB se truncan en OneLake'
            WHEN ut.is_user_defined = 1                              THEN N'Alias type (' + ut.name + N' sobre ' + bt.name + N'): confirmar en el mirror'
        END AS motivo
) x
WHERE t.is_ms_shipped = 0
  AND x.status IS NOT NULL;

-- Tipos que bloquean la tabla entera si están en la PK / índice clustered
DECLARE @keyBlockers TABLE (object_id int PRIMARY KEY, detalle nvarchar(400));
INSERT INTO @keyBlockers
SELECT object_id, STRING_AGG(column_name + N' (' + type_name + N')', N', ')
FROM @cols
WHERE is_key = 1
  AND (is_computed = 1
       OR status = 'NO_SOPORTADA'
       OR type_name = 'hierarchyid'
       OR (base_type IN ('datetime2','datetimeoffset','time') AND scale = 7))
GROUP BY object_id;

/* 1. Tablas */
WITH tablas AS (
    SELECT
        t.object_id,
        s.name AS schema_name,
        t.name AS table_name,
        rc.row_count,
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
             THEN 1 ELSE 0 END AS has_pk,
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 5)
             THEN 1 ELSE 0 END AS has_cci,
        t.temporal_type,
        t.is_memory_optimized,
        t.is_external,
        CAST(CASE WHEN t.is_node = 1 OR t.is_edge = 1 THEN 1 ELSE 0 END AS bit) AS is_graph
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    OUTER APPLY (SELECT SUM(ps.row_count) AS row_count
                 FROM sys.dm_db_partition_stats ps
                 WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) rc
    WHERE t.is_ms_shipped = 0
)
SELECT
    tb.schema_name,
    tb.table_name,
    tb.row_count,
    CASE
        WHEN tb.temporal_type = 1                                  THEN 'NO SE ESPEJA'
        WHEN tb.is_memory_optimized = 1                            THEN 'NO SE ESPEJA'
        WHEN tb.is_external = 1                                    THEN 'NO SE ESPEJA'
        WHEN tb.is_graph = 1                                       THEN 'NO SE ESPEJA'
        WHEN tb.has_cci = 1                                        THEN 'NO SE ESPEJA'
        WHEN kb.object_id IS NOT NULL                              THEN 'NO SE ESPEJA'
        WHEN EXISTS (SELECT 1 FROM @cols c WHERE c.object_id = tb.object_id
                       AND (c.type_name IN ('json','vector') OR c.is_encrypted = 1))
                                                                   THEN 'NO SE ESPEJA'
        WHEN EXISTS (SELECT 1 FROM @cols c WHERE c.object_id = tb.object_id AND c.status = 'NO_SOPORTADA')
                                                                   THEN 'PARCIAL'
        ELSE 'COMPLETA'
    END AS veredicto,
    CASE WHEN tb.has_pk = 0 THEN 'Sí' ELSE '' END AS sin_pk_agregar_a_mano,
    CONCAT_WS(N' | ',
        CASE WHEN tb.temporal_type = 1     THEN N'Tabla de historial temporal' END,
        CASE WHEN tb.is_memory_optimized=1 THEN N'In-memory' END,
        CASE WHEN tb.is_external = 1       THEN N'Tabla externa' END,
        CASE WHEN tb.is_graph = 1          THEN N'Tabla de grafo' END,
        CASE WHEN tb.has_cci = 1           THEN N'Clustered columnstore' END,
        CASE WHEN kb.object_id IS NOT NULL THEN N'Clave con tipo no soportado: ' + kb.detalle END,
        CASE WHEN tb.has_pk = 0            THEN N'Sin PK: no se agrega sola si ya existía; seleccionarla manualmente' END,
        (SELECT STRING_AGG(c.column_name, N', ') FROM @cols c
          WHERE c.object_id = tb.object_id AND c.status = 'NO_SOPORTADA')
    ) AS detalle
FROM tablas tb
LEFT JOIN @keyBlockers kb ON kb.object_id = tb.object_id
ORDER BY veredicto DESC, tb.schema_name, tb.table_name;

/* 2. Columnas que no llegan (o llegan distinto) al lago */
SELECT schema_name, table_name, column_name, type_name,
       CASE WHEN type_name <> base_type THEN base_type ELSE '' END AS tipo_base,
       status, motivo
FROM @cols
ORDER BY CASE status WHEN 'NO_SOPORTADA' THEN 1 WHEN 'VERIFICAR' THEN 2 WHEN 'PERDIDA' THEN 3 ELSE 4 END,
         schema_name, table_name, column_id;

/* 3. Resumen */
SELECT status, COUNT(*) AS columnas, COUNT(DISTINCT object_id) AS tablas
FROM @cols
GROUP BY status
ORDER BY status;
