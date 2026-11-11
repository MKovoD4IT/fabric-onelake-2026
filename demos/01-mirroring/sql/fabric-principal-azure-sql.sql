/*
    Principal con permisos mínimos para que Fabric espeje la base Azure SQL.
    https://learn.microsoft.com/fabric/mirroring/azure-sql-database-tutorial#database-principal-for-fabric

    El servidor se crea con autenticación solo Entra, así que se usa la
    identidad del workspace de Fabric (Workspace identity) en lugar de un login SQL.
    Requiere que el workspace de demo exista y tenga la identidad habilitada
    (Workspace settings > Workspace identity).

    Conectarse como admin de Entra del servidor.
    Reemplazar <WorkspaceIdentityName> por el nombre del workspace.
*/

-- 1) En la base master
CREATE LOGIN [<WorkspaceIdentityName>] FROM EXTERNAL PROVIDER;
GO

-- 2) En la base a espejar (AdventureWorksLT)
CREATE USER [<WorkspaceIdentityName>] FOR LOGIN [<WorkspaceIdentityName>];
GRANT SELECT,
      ALTER ANY EXTERNAL MIRROR,
      VIEW DATABASE PERFORMANCE STATE,
      VIEW DATABASE SECURITY STATE
   TO [<WorkspaceIdentityName>];
GO
