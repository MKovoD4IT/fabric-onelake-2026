# Validación de Mirroring: AdventureWorksLT en Azure SQL Database

Resultado de `../sql/validate-mirroring-eligibility.sql` sobre el sample AdventureWorksLT
(General Purpose serverless, Gen5 2 vCores), 2026-11-11. Pendiente de contrastar con el mirror real en Fabric.

## Tablas

12 tablas, todas con PK. Ninguna queda afuera del mirror.

| Veredicto | Tablas |
| --- | --- |
| Completa | dbo.BuildVersion, dbo.ErrorLog, SalesLT.Address, Customer, CustomerAddress, Product, ProductCategory, ProductDescription, ProductModelProductDescription |
| Parcial | SalesLT.ProductModel, SalesOrderDetail, SalesOrderHeader |

## Qué no llega al lago (slide)

| Tabla | Columna | Motivo | Cómo se resuelve |
| --- | --- | --- | --- |
| SalesLT.ProductModel | CatalogDescription | xml | Extraer los atributos necesarios en Silver o ignorar |
| SalesLT.SalesOrderDetail | LineTotal | Columna calculada | Recalcular en Silver: `UnitPrice * (1 - UnitPriceDiscount) * OrderQty` |
| SalesLT.SalesOrderHeader | SalesOrderNumber | Columna calculada | Recalcular en Silver: `N'SO' + CONVERT(nvarchar(23), SalesOrderID)` |
| SalesLT.SalesOrderHeader | TotalDue | Columna calculada | Recalcular en Silver: `SubTotal + TaxAmt + Freight` |

## Advertencias

- **Truncamiento a 1 MB:** `SalesLT.Product.ThumbNailPhoto` (varbinary(max)) y `SalesLT.SalesOrderHeader.Comment` (nvarchar(max)). En el sample ningún valor llega a 1 MB.
- **Alias types a confirmar en el mirror:** 14 columnas usan tipos de usuario alias (`Name`, `Phone`, `Flag`, `NameStyle`, `OrderNumber`, `AccountNumber`) sobre nvarchar o bit. La documentación excluye los "User Defined Types"; hay que confirmar en Fabric si los alias se espejan como su tipo base.
