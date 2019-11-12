Import-Module Az.Accounts

$CustomerId = "7412232b-b63b-4bc5-aa06-9a73b13a5e0d"  

$SharedKey = "f5bvEYa5ETHgCRRld0y+yc2Zv1pNZ5XSNAFrhyI+XcfA7x27keu0ZuYA5Am2Ge6q4+w/kgdigWzo59Fp3Jbmyg=="

$LogType = "SQLRecordA"

$TimeStampField = ""

$conn = Get-AutomationConnection -name "AzureAutoConnection"

Add-AzAccount -ServicePrincipal -ApplicationId $conn.ApplicationId -TenantId $conn.Tenantid -CertificateThumbprint $conn.CertificateThumbprint

$resultsArr = @()

$arr = @()

function Query-SQLMI ($connectionString, $sqlCommand) {
    $connection = New-Object System.Data.SqlClient.SqlConnection
	$connection.ConnectionString =  $connectionString
	$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
	$SqlCmd.CommandText = $sqlCommand
	$SqlCmd.Connection = $connection
	$SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
	$SqlAdapter.SelectCommand = $SqlCmd

	$DataSet = New-Object System.Data.DataSet
	$SqlAdapter.Fill($DataSet) | Out-Null
	$Connection.Close()

    ## Return all of the rows from their query
    $rows = $dataSet.Tables | Select-Object -Expand Rows
    return $rows
}

function Get-ConnectionString ($automationCredentialName) {
    $credObject = get-automationPSCredential -Name $automationCredentialName
    $connString = $credObject.GetNetworkCredential().password
    $connString = $connString.split("|")
    return $connString
}


Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}


Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}

function Parse-Results ($rows) {
    write-output $arr.gettype()
    foreach ($row in $rows) {
        $ProcID = $row.productid
        $name = $row.Name
        $SellEndDate = Get-Date($row.SellEndDate) -f "MM/dd/yyyy HH:mm:ss"

        $obj = [pscustomobject] @{
                    ProductId = $ProcID
                    ProductName = $name
                    SellEndDate = $SellEndDate
                }
        $arr = [Array]$arr + ($obj)
}
return $arr    
}

$sqlCommand = "SELECT * FROM [SalesLT].[Product] where SellEndDate is not null"

function Main() {
    $connectionStrings = Get-ConnectionString -automationCredentialName "MyConnectionString"
    foreach ($connectionstring in $connectionStrings) {
        if ($connectionString) {
            Write-Output $connectionString
            Write-Output "hold"
            $rows = Query-SQLMI -connectionString $connectionstring -sqlCommand $sqlCommand
            if ($rows.count -gt 0) {
                 $resultsArr = Parse-Results -rows $rows  
                }
            }
    }
	if ($resultsArr.Count -gt 0) {
		$resultsArrObj = $resultsArr | ConvertTo-Json
		Write-Output $resultsArrObj
		Post-LogAnalyticsData -customerId $CustomerId -sharedKey $SharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($resultsArrObj)) -logType $logType
	}
}

Main