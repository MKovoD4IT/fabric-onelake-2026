# Validación de Mirroring: AdventureWorks2022 en SQL Server 2022 (VM)

Resultado de `../sql/validate-mirroring-eligibility.sql` sobre AdventureWorks2022 (OLTP completo),
restaurada en la VM con SQL Server 2022 Developer, 2026-11-11. Pendiente de contrastar con el mirror real en Fabric.

CDC quedó habilitado en la base y en las 71 tablas, con los jobs `cdc.AdventureWorks2022_capture` y
`cdc.AdventureWorks2022_cleanup`. Como CDC ya está configurado, `fabric_login` solo tiene CONNECT SQL y
CONNECT/SELECT en la base: **no necesita sysadmin**.

## Tablas

71 tablas, todas con PK.

| Veredicto | Tablas |
| --- | --- |
| Completa | 55 |
| Parcial (faltan columnas) | 14 |
| No se espeja | 2: `Production.Document` y `Production.ProductDocument` |

Las dos tablas excluidas tienen la PK sobre `DocumentNode`, de tipo **hierarchyid**: una tabla cuya clave
usa un tipo no soportado no se puede espejar.

## Qué no llega al lago (slide)

| Motivo | Columnas |
| --- | --- |
| **xml** (8) | dbo.DatabaseLog.XmlEvent · HumanResources.JobCandidate.Resume · Person.Person.AdditionalContactInfo, Demographics · Production.Illustration.Diagram · Production.ProductModel.CatalogDescription, Instructions · Sales.Store.Demographics |
| **Calculadas** (10) | HumanResources.Employee.OrganizationLevel · Production.Document.DocumentLevel · Production.WorkOrder.StockedQty · Purchasing.PurchaseOrderDetail.LineTotal, StockedQty · Purchasing.PurchaseOrderHeader.TotalDue · Sales.Customer.AccountNumber · Sales.SalesOrderDetail.LineTotal · Sales.SalesOrderHeader.SalesOrderNumber, TotalDue |
| **geography** (1) | Person.Address.SpatialLocation |
| **hierarchyid en la PK** | Production.Document y Production.ProductDocument completas |

## Advertencias

- **hierarchyid fuera de la PK:** `HumanResources.Employee.OrganizationNode`. La documentación no lo lista como columna no soportada; confirmar en el mirror.
- **Pérdida de precisión:** `HumanResources.Shift.StartTime` y `EndTime` son `time(7)`; Delta guarda 6 dígitos.
- **Truncamiento a 1 MB:** dbo.DatabaseLog.TSQL, Production.Document.DocumentSummary y Document, Production.ProductPhoto.ThumbNailPhoto y LargePhoto.
- **Alias types:** 45 columnas usan `Name`, `Flag`, `Phone`, `AccountNumber`, `OrderNumber`, etc. Confirmar en el mirror que llegan como su tipo base.

## Comparación con AdventureWorksLT (Azure SQL)

| | AdventureWorksLT | AdventureWorks2022 |
| --- | --- | --- |
| Tablas | 12 | 71 |
| No se espejan | 0 | 2 (hierarchyid en la PK) |
| Parciales | 3 | 14 |
| Columnas no soportadas | 4 | 19 |
| Mecanismo | Change feed nativo de Azure SQL | CDC + on-premises data gateway |
