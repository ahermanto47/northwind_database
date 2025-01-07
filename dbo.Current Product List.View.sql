SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE VIEW [dbo].[Current Product List] AS
SELECT Product_List.ProductID, Product_List.ProductName
FROM Products AS Product_List
WHERE (((Product_List.Discontinued)=0))
--ORDER BY Product_List.ProductName

GO
