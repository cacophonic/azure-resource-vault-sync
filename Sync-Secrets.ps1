param (
    [string]$JsonString
)

function Get-ApiVersion {
    param ([string]$resourceId)

    switch -regex ($resourceId) {
        "Microsoft.Storage/storageAccounts"      { return "2022-09-01" }
        "Microsoft.DocumentDB/databaseAccounts"  { return "2022-09-01" }
        "Microsoft.KeyVault/vaults"              { return "2022-09-01" }
        "Microsoft.ServiceBus/namespaces"        { return "2024-01-01" }
        "Microsoft.Insights/components"          { return "2020-02-02-preview" }
        "Microsoft.Cache/Redis"                  { return "2023-04-01" }
        default {
            throw "Unsupported resource type in resourceId: $resourceId"
        }
    }
}

function Get-ResourceValue {
    param (
        [string]$resourceId,
        [string]$apiVersion,
        [string]$type
    )

    $baseUrl = "https://management.azure.com"

    if ($resourceId -match "Microsoft.Insights/components") {
        $uri = "$baseUrl${resourceId}?api-version=${apiVersion}"
        $response = Invoke-AzRestMethod -Method GET -Uri $uri
        $props = ($response.Content | ConvertFrom-Json).properties

        if ($type -eq "connectionstring") { 
            return $props.connectionString 
        } 
        else { 
            return $props.instrumentationKey 
        }
    }

    elseif ($resourceId -match "Microsoft.Cache/Redis") {
        $uri = "$baseUrl${resourceId}/listKeys?api-version=${apiVersion}"
        $response = Invoke-AzRestMethod -Method POST -Uri $uri
        $json = $response.Content | ConvertFrom-Json

        if ($type -eq "connectionstring") {
            $host = ($resourceId -split "/")[-1]
            return "${host}.redis.cache.windows.net:6380,password=${json.primaryKey},ssl=True,abortConnect=False"
        } else {
            return $json.primaryKey
        }
    }

    elseif ($resourceId -match "Microsoft.Storage/storageAccounts") {
        $uri = "$baseUrl${resourceId}/listKeys?api-version=${apiVersion}"
        $response = Invoke-AzRestMethod -Method POST -Uri $uri
        $json = $response.Content | ConvertFrom-Json
        $key = $json.keys[0].value
        $accountName = ($resourceId -split "/")[-1]

        if ($type -eq "connectionstring") {
            return "DefaultEndpointsProtocol=https;AccountName=$accountName;AccountKey=$key;EndpointSuffix=core.windows.net"
        } else {
            return $key
        }
    }

    elseif ($resourceId -match "Microsoft.ServiceBus/namespaces") {
        $baseResourceId = $resourceId
        $authRule = "RootManageSharedAccessKey"

        if ($resourceId -match "/authorizationRules/") {
            $uri = "$baseUrl${resourceId}/listKeys?api-version=${apiVersion}"
        } else {
            $baseResourceId = "$resourceId/authorizationRules/$authRule"
            $uri = "$baseUrl${baseResourceId}/listKeys?api-version=${apiVersion}"
        }

        $response = Invoke-AzRestMethod -Method POST -Uri $uri
        $json = $response.Content | ConvertFrom-Json

        if ($type -eq "connectionstring") {
            return $json.primaryConnectionString
        } else {
            return $json.primaryKey
        }
    }

    else {
        $uri = "$baseUrl${resourceId}/listKeys?api-version=${apiVersion}"
        $response = Invoke-AzRestMethod -Method POST -Uri $uri
        $json = $response.Content | ConvertFrom-Json

        if ($type -eq "key") {
            return $json.Keys[0].value
        } elseif ($type -eq "connectionstring") {
            foreach ($candidate in @("connectionString", "primaryConnectionString", "primary")) {
                if ($json.PSObject.Properties.Name -contains $candidate) {
                    return $json.$candidate
                }
            }
            throw "No connection string found in $resourceId response"
        } else {
            throw "Unsupported type '$type'"
        }
    }
}

function Get-PlainTextSecret {
    param (
        [SecureString]$secure
    )
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    )
}

# Set Azure context
$subscription = Get-AzContext | Select-Object -ExpandProperty Subscription
Set-AzContext -SubscriptionId $subscription.Id | Out-Null

$object = $JsonString | ConvertFrom-Json
$resources = $object.resourceConfig.value

foreach ($resource in $resources) {
    $resId        = $resource.resourceId
    $keyVaultName = $resource.keyVaultName
    $secretName   = $resource.secretName
    $type         = $resource.type.ToLower()

    Write-Host "`nProcessing: $resId [$type]"

    $apiVersion   = Get-ApiVersion -resourceId $resId
    $secretValue  = Get-ResourceValue -resourceId $resId -apiVersion $apiVersion -type $type

    try {
        $existingSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -ErrorAction Stop
        $existingValue  = Get-PlainTextSecret -secure $existingSecret.SecretValue
    } catch {
        $existingValue = $null
    }

    if ($existingValue -ne $secretValue) {
        Write-Host "Updating secret '$secretName' in Key Vault '$keyVaultName'"
        Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName `
            -SecretValue (ConvertTo-SecureString $secretValue -AsPlainText -Force) | Out-Null
    } else {
        Write-Host "No changes detected for '$secretName'. Skipping."
    }
}
