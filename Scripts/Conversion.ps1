# This Powershell script is an example for the usage of the Azure Remote Rendering service
# Documentation: https://docs.microsoft.com/en-us/azure/remote-rendering/samples/powershell-example-scripts
#
# Usage:
# Fill out the assetConversionSettings in arrconfig.json next to this file or provide all necessary parameters on the commandline
# This script is using the ARR REST API to convert assets to the asset format used in rendering sessions

# Conversion.ps1 [-ConfigFile <pathtoconfig>]
#   Requires that the ARR account has access to the storage account. The documentation explains how to grant access.
#   Will:
#   - Load config from arrconfig.json or optional file provided by the -ConfigFile parameter
#   - Retrieve Azure Storage credentials for the configured storage account and logged in user
#   - Upload the directory pointed to in assetConversionSettings.localAssetDirectoryPath to the storage input container
#      using the provided storage account.
#   - Start a conversion using the ARR Conversion REST API and retrieves a conversion Id
#   - Poll the conversion status until the conversion succeeded or failed

# Conversion.ps1 -UseContainerSas [-ConfigFile <pathtoconfig>]
#   The -UseContainerSas will convert the input asset using the conversions/createWithSharedAccessSignature REST API.
#   Will also perform upload and polling of conversion status.
#   The script will access the provided storage account and generate SAS URIs which are used in the call to give access to the
#   blob containers of the storage account.

# The individual stages -Upload -ConvertAsset and -GetConversionStatus can be executed individually like:
# Conversion.ps1 -Upload
#   Only executes the Upload of the asset directory to the input storage container and terminates

# Conversion.ps1 -ConvertAsset
#  Only executes the convert asset step

# Conversion.ps1 -GetConversionStatus -Id <ConversionId> [-Poll]
#   Retrieves the status of the conversion with the provided conversion id.
#   -Poll will poll the conversion with given id until the conversion succeeds or fails

# Optional parameters:
# individual settings in the config file can be overridden on the command line:

Param(
    [switch] $Upload, # if set the local asset directory will be uploaded to the inputcontainer and the script exits
    [switch] $ConvertAsset,
    [switch] $GetConversionStatus,
    [switch] $Poll,
    [switch] $UseContainerSas, # If provided the script will generate container SAS tokens to be used with the conversions/createWithSharedAccessSignature REST API
    [string] $ConfigFile,
    [string] $Id, # optional ConversionId used with GetConversionStatus
    [string] $ArrAccountId, # optional override for arrAccountId of accountSettings in config file
    [string] $ArrAccountKey, # optional override for arrAccountKey of accountSettings in config file
    [string] $ArrAccountDomain, # optional override for region where the ARR account is located
    [string] $Region, # deprecated, please use explicit RemoteRenderingDomain and ArrAccountDomain
    [string] $ResourceGroup, # optional override for resourceGroup of assetConversionSettings in config file
    [string] $StorageAccountName, # optional override for storageAccountName of assetConversionSettings in config file
    [string] $BlobInputContainerName, # optional override for blobInputContainer of assetConversionSettings in config file
    [string] $BlobOutputContainerName, # optional override for blobOutputContainerName of assetConversionSettings in config file
    [string] $InputAssetPath, # path under inputcontainer/InputFolderPath pointing to the asset to be converted e.g model\box.fbx
    [string] $InputFolderPath, # optional path in input container, all data under this path will be retrieved by the conversion service , if empty all data from the input storage container will copied
    [string] $OutputFolderPath, # optional override for the path in output container, conversion result will be copied there
    [string] $OutputAssetFileName, # optional filename of the outputAssetFileName of assetConversionSettings in config file. needs to end in .arrAsset
    [string] $LocalAssetDirectoryPath, # Path to directory containing all input asset data (e.g. fbx and textures referenced by it)
    [string] $RemoteRenderingDomain, # optional override for region where conversion is or should be located
    [hashtable] $AdditionalParameters
)

. "$PSScriptRoot\ARRUtils.ps1"

Set-StrictMode -Version Latest
$PrerequisitesInstalled = CheckPrerequisites
if (-Not $PrerequisitesInstalled) {
    WriteError("Prerequisites not installed - Exiting.")
    exit 1
}

$LoggedIn = CheckLogin
if (-Not $LoggedIn) {
    WriteError("User not logged in - Exiting.")
    exit 1
}

if (-Not ($Upload -or $ConvertAsset -or $GetConversionStatus )) {
    # if none of the three stages is explicitly asked for execute all stages and poll for conversion status until finished
    $Upload = $true
    $ConvertAsset = $true
    $GetConversionStatus = $true
    $Poll = $true
}

# Upload asset directory to the configured azure blob storage account and input container under given inputFolder
function UploadAssetDirectory($assetSettings) {
    $localAssetFile = Join-Path -Path $assetSettings.localAssetDirectoryPath -ChildPath $assetSettings.inputAssetPath
    $assetFileExistsLocally = Test-Path $localAssetFile
    if(!$assetFileExistsLocally)
    {
        WriteError("Unable to upload asset file from local asset directory '$($assetSettings.localAssetDirectoryPath)'. File '$localAssetFile' does not exist.")
        WriteError("'$($assetSettings.localAssetDirectoryPath)' must include the provided input asset path '$($assetSettings.inputAssetPath)' as a child.")
        return $false
    }

    WriteInformation ("Uploading asset directory from $($assetSettings.localAssetDirectoryPath) to blob storage input container ...")

    if ($assetSettings.localAssetDirectoryPath -notmatch '\\$') {
        $assetSettings.localAssetDirectoryPath += '\'
    }

    $inputDirExists = Test-Path  -Path $assetSettings.localAssetDirectoryPath
    if ($false -eq $inputDirExists) {
        WriteError("Unable to upload files from asset directory $($assetSettings.localAssetDirectoryPath). Directory does not exist.")
        return $false
    }

    $filesToUpload = @(Get-ChildItem -Path $assetSettings.localAssetDirectoryPath -File -Recurse)

    if (0 -eq $filesToUpload.Length) {
        WriteError("Unable to upload files from asset directory $($assetSettings.localAssetDirectoryPath). Directory is empty.")
    }

    WriteInformation ("Uploading $($filesToUpload.Length) files to input storage container")
    $filesUploaded = 0

    foreach ($fileToUpload in $filesToUpload) {
        $relativePathInFolder = $fileToUpload.FullName.Substring($assetSettings.localAssetDirectoryPath.Length).Replace("\", "/")
        $remoteBlobpath = $assetSettings.inputFolderPath + $relativePathInFolder

        WriteSuccess ("Uploading file $($fileToUpload.FullName) to input blob storage container")
        $blob = Set-AzStorageBlobContent -File $fileToUpload.FullName -Container $assetSettings.blobInputContainerName -Context $assetSettings.storageContext -Blob $remoteBlobpath -Force
        $filesUploaded++
        if ($null -ne $blob ) {
            WriteSuccess ("Uploaded file $filesUploaded/$($filesToUpload.Length) $($fileToUpload.FullName) to blob storage ...")
        }
        else {
            WriteError("Unable to upload file $fileToUpload from local asset directory location $($assetSettings.localAssetDirectoryPath) ...")
            return $false
        }
    }
    WriteSuccess ("Uploaded asset directory to input storage container")
    return $true
}

# Asset Conversion
# Starts a remote asset conversion by using the ARR conversion REST API <endPoint>/accounts/<accountId>/conversions/<conversionId>
# All files present in the input container under the (optional) folderPath will be copied to the ARR conversion service
# the output .arrAsset file will be written back to the provided outputcontainer under the given (optional) folderPath
# Immediately returns a conversion id which can be used to query the status of the conversion process (see below)
function ConvertAsset(
    $accountSettings,
    $arrAccountDomain,
    $remoteRenderingDomain,
    $accountId,
    $accountKey,
    $assetConversionSettings,
    $inputAssetPath,
    [switch] $useContainerSas,
    $conversionId,
    $additionalParameters) {
    try {
        WriteLine
        $inputContainerUri = "https://$($assetConversionSettings.storageAccountName).blob.core.windows.net/$($assetConversionSettings.blobInputContainerName)"
        $outputContainerUri = "https://$($assetConversionSettings.storageAccountName).blob.core.windows.net/$($assetConversionSettings.blobOutputContainerName)"
        $settings =
        @{
            inputLocation  =
            @{
                storageContainerUri    = $inputContainerUri;
                blobPrefix             = $assetConversionSettings.inputFolderPath;
                relativeInputAssetPath = $assetConversionSettings.inputAssetPath;
            };
            outputLocation =
            @{
                storageContainerUri    = $outputContainerUri;
                blobPrefix             = $assetConversionSettings.outputFolderPath;
                outputAssetFilename    = $assetConversionSettings.outputAssetFileName;
            }
        }

        if ($useContainerSas)
        {
            $settings.inputLocation  += @{ storageContainerReadListSas = $assetConversionSettings.inputContainerSAS }
            $settings.outputLocation += @{ storageContainerWriteSas    = $assetConversionSettings.outputContainerSAS }
        }

        if ($additionalParameters) {
            $additionalParameters.Keys | % { $settings += @{ $_ = $additionalParameters.Item($_) } }
        }

        $body =
        @{
            settings = $settings
        }

        if ([string]::IsNullOrEmpty($conversionId))
        {
            $conversionId = "Sample-Conversion-$([System.Guid]::NewGuid())"
        }

        $url = "$remoteRenderingDomain/accounts/$accountId/conversions/${conversionId}?api-version=2021-01-01-preview"

        $conversionType = if ($useContainerSas) {"container Shared Access Signatures"} else {"linked storage account"}

        WriteInformation("Converting Asset using $conversionType ...")
        WriteInformation("  arrAccountDomain: $arrAccountDomain")
        WriteInformation("  remoteRenderingDomain: $remoteRenderingDomain")
        WriteInformation("  accountId: $accountId")
        WriteInformation("Input:")
        WriteInformation("    storageContainerUri: $inputContainerUri")
        if ($useContainerSas) { WriteInformation("    inputContainerSAS: $($assetConversionSettings.inputContainerSAS)") }
        WriteInformation("    blobPrefix: $($assetConversionSettings.inputFolderPath)")
        WriteInformation("    relativeInputAssetPath: $($assetConversionSettings.inputAssetPath)")
        WriteInformation("Output:")
        WriteInformation("    storageContainerUri: $outputContainerUri")
        if ($useContainerSas) { WriteInformation("    outputContainerSAS: $($assetConversionSettings.outputContainerSAS)") }
        WriteInformation("    blobPrefix: $($assetConversionSettings.outputFolderPath)")
        WriteInformation("    outputAssetFilename: $($assetConversionSettings.outputAssetFileName)")

        $token = GetAuthenticationToken -arrAccountDomain $arrAccountDomain -accountId $accountId -accountKey $accountKey
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method PUT -ContentType "application/json" -Body ($body | ConvertTo-Json) -Headers @{ Authorization = "Bearer $token" }
        WriteSuccess("Successfully started the conversion with Id: $conversionId")
        WriteSuccessResponse($response.RawContent)

        return $conversionId
    }
    catch {
        WriteError("Unable to start conversion of the asset ...")
        HandleException($_.Exception)
        throw
    }
}

# calls the conversion status ARR REST API "<endPoint>/accounts/<accountId>/conversions/<conversionId>"
# returns the conversion process state
function GetConversionStatus($arrAccountDomain, $remoteRenderingDomain, $accountId, $accountKey, $conversionId) {
    try {
        $url = "$remoteRenderingDomain/accounts/$accountId/conversions/${conversionId}?api-version=2021-01-01-preview"

        $token = GetAuthenticationToken -arrAccountDomain $arrAccountDomain -accountId $accountId -accountKey $accountKey
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization = "Bearer $token" }

        WriteSuccessResponse($response.RawContent)
        return $response
    }
    catch {
        WriteError("Unable to get the status of the conversion with Id: $conversionId ...")
        HandleException($_.Exception)
        throw
    }
}

# repeatedly poll the conversion status ARR REST API until success of failure
function PollConversionStatus($arrAccountDomain, $remoteRenderingDomain, $accountId, $accountKey, $conversionId) {
    $conversionStatus = "Running"
    $startTime = Get-Date

    $conversionResponse = $null
    $conversionSucceeded = $true;

    while ($true) {
        Start-Sleep -Seconds 10
        WriteProgress  -activity "Ongoing asset conversion with conversion id: '$conversionId'" -status "Since $([int]((Get-Date) - $startTime).TotalSeconds) seconds"

        $response = GetConversionStatus $arrAccountDomain $remoteRenderingDomain $accountId $accountKey $conversionId
        $responseJson = ($response.Content | ConvertFrom-Json)

        $conversionStatus = $responseJson.status

        if ("succeeded" -ieq $conversionStatus) {
            $conversionResponse = $responseJson
            break
        }

        if ($conversionStatus -iin "failed", "cancelled") {
            $conversionSucceeded = $false
            break
        }
    }

    $totalTimeElapsed = $(New-TimeSpan $startTime $(get-date)).TotalSeconds

    if ($conversionSucceeded) {
        WriteProgress -activity "Your asset conversion is complete" -status "Completed..."
        WriteSuccess("The conversion with Id: $conversionId was successful ...")
        WriteInformation ("Total time elapsed: $totalTimeElapsed  ...")
        WriteInformation($response)
    }
    else {
        WriteError("The asset conversion with Id: $conversionId resulted in an error")
        WriteInformation ("Total time elapsed: $totalTimeElapsed  ...")
        WriteInformation($response)
        exit 1
    }

    return $conversionResponse
}

# Execution of script starts here

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = "$PSScriptRoot\arrconfig.json"
}

$config = LoadConfig `
    -fileLocation $ConfigFile `
    -ArrAccountId $ArrAccountId `
    -ArrAccountKey $ArrAccountKey `
    -ArrAccountDomain $ArrAccountDomain `
    -Region $Region `
    -RemoteRenderingDomain $RemoteRenderingDomain `
    -StorageAccountName $StorageAccountName `
    -ResourceGroup $ResourceGroup `
    -BlobInputContainerName $BlobInputContainerName `
    -BlobOutputContainerName $BlobOutputContainerName `
    -LocalAssetDirectoryPath $LocalAssetDirectoryPath `
    -InputAssetPath $InputAssetPath `
    -InputFolderPath $InputFolderPath `
    -OutputAssetFileName $OutputAssetFileName

if ($null -eq $config) {
    WriteError("Error reading config file - Exiting.")
    exit 1
}

$defaultConfig = GetDefaultConfig

if ($ConvertAsset -or $Upload -or $UseContainerSas) {
    $storageSettingsOkay = VerifyStorageSettings $config $defaultConfig
    if ($false -eq $storageSettingsOkay) {
        WriteError("Error reading assetConversionSettings in $ConfigFile - Exiting.")
        exit 1
    }

    # if we do any conversion related things we need to validate storage settings
    # we do not need the storage settings if we only want to spin up a session
    $isValid = ValidateConversionSettings $config $defaultConfig $ConvertAsset
    if ($false -eq $isValid) {
        WriteError("The config file is not valid. Please ensure the required values are filled in - Exiting.")
        exit 1
    }
    WriteSuccess("Successfully Loaded Configurations from file : $ConfigFile ...")

    $config = AddStorageAccountInformationToConfig $config

    if ($null -eq $config) {
        WriteError("Azure settings not valid. Please ensure the required values are filled in correctly in the config file $ConfigFile")
        exit 1
    }
}

if ($Upload) {
    $uploadSuccessful = UploadAssetDirectory $config.assetConversionSettings
    if ($false -eq $uploadSuccessful) {
        WriteError("Upload failed - Exiting.")
        exit 1
    }
}

if ($ConvertAsset) {
    if ($UseContainerSas) {
        # Generate SAS and provide it in rest call - this is used if your storage account is not connected with your ARR account
        $inputContainerSAS = GenerateInputContainerSAS $config.assetConversionSettings.storageContext.BlobEndPoint $config.assetConversionSettings.blobInputContainerName $config.assetConversionSettings.storageContext
        $config.assetConversionSettings.inputContainerSAS = $inputContainerSAS

        $outputContainerSAS = GenerateOutputContainerSAS -blobEndPoint $config.assetConversionSettings.storageContext.blobEndPoint  -blobContainerName $config.assetConversionSettings.blobOutputContainerName -storageContext $config.assetConversionSettings.storageContext
        $config.assetConversionSettings.outputContainerSAS = $outputContainerSAS

        $Id = ConvertAsset -arrAccountDomain $config.accountSettings.arrAccountDomain -remoteRenderingDomain $config.renderingSessionSettings.remoteRenderingDomain -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -assetConversionSettings $config.assetConversionSettings -useContainerSas -conversionId $Id -AdditionalParameters $AdditionalParameters 
    }
    else {
        # The ARR account has read/write access to the blob containers of the storage account - so we do not need to generate SAS tokens for access
        $Id = ConvertAsset -arrAccountDomain $config.accountSettings.arrAccountDomain -remoteRenderingDomain $config.renderingSessionSettings.remoteRenderingDomain -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -assetConversionSettings $config.assetConversionSettings  -conversionId $Id -AdditionalParameters $AdditionalParameters
    }
}

$conversionResponse = $null
if ($GetConversionStatus) {
    if ([string]::IsNullOrEmpty($Id)) {
        $Id = Read-Host "Please enter the conversion Id"
    }

    if ($Poll) {
        $conversionResponse = PollConversionStatus -arrAccountDomain $config.accountSettings.arrAccountDomain -remoteRenderingDomain $config.renderingSessionSettings.remoteRenderingDomain -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -conversionId $Id
    }
    else {
        $response = GetConversionStatus -remoteRenderingDomain $config.renderingSessionSettings.remoteRenderingDomain -arrAccountDomain $config.accountSettings.arrAccountDomain -accountId  $config.accountSettings.arrAccountId  -accountKey $config.accountSettings.arrAccountKey -conversionId $Id
        $responseJson = ($response.Content | ConvertFrom-Json)
        $conversionStatus = $responseJson.status

        if ("succeeded" -ieq $conversionStatus) {
            $conversionResponse = $responseJson
        }
    }
}

if ($null -ne $conversionResponse) {
    WriteSuccess("Successfully converted asset.")
    WriteSuccess("Converted asset uri: $($conversionResponse.output.outputAssetUri)")

    if ($UseContainerSas) {
        $blobPath = "$($conversionResponse.settings.outputLocation.blobPrefix)$($conversionResponse.settings.outputLocation.outputAssetFilename)"
        # now retrieve the converted model SAS URI - you will need to call the ARR SDK API with a URL to your model to load a model in your application
        $sasUrl = GenerateOutputmodelSASUrl $config.assetConversionSettings.blobOutputContainerName $blobPath $config.assetConversionSettings.storageContext
        WriteInformation("model SAS URI: $sasUrl")
    }
}

# SIG # Begin signature block
# MIInkwYJKoZIhvcNAQcCoIInhDCCJ4ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAmObskj2ZIhCYo
# tIb5qUfeR7q1J+QWMc6o+KDyyc+uT6CCDXYwggX0MIID3KADAgECAhMzAAADTrU8
# esGEb+srAAAAAANOMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjMwMzE2MTg0MzI5WhcNMjQwMzE0MTg0MzI5WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDdCKiNI6IBFWuvJUmf6WdOJqZmIwYs5G7AJD5UbcL6tsC+EBPDbr36pFGo1bsU
# p53nRyFYnncoMg8FK0d8jLlw0lgexDDr7gicf2zOBFWqfv/nSLwzJFNP5W03DF/1
# 1oZ12rSFqGlm+O46cRjTDFBpMRCZZGddZlRBjivby0eI1VgTD1TvAdfBYQe82fhm
# WQkYR/lWmAK+vW/1+bO7jHaxXTNCxLIBW07F8PBjUcwFxxyfbe2mHB4h1L4U0Ofa
# +HX/aREQ7SqYZz59sXM2ySOfvYyIjnqSO80NGBaz5DvzIG88J0+BNhOu2jl6Dfcq
# jYQs1H/PMSQIK6E7lXDXSpXzAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUnMc7Zn/ukKBsBiWkwdNfsN5pdwAw
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwMDUxNjAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAD21v9pHoLdBSNlFAjmk
# mx4XxOZAPsVxxXbDyQv1+kGDe9XpgBnT1lXnx7JDpFMKBwAyIwdInmvhK9pGBa31
# TyeL3p7R2s0L8SABPPRJHAEk4NHpBXxHjm4TKjezAbSqqbgsy10Y7KApy+9UrKa2
# kGmsuASsk95PVm5vem7OmTs42vm0BJUU+JPQLg8Y/sdj3TtSfLYYZAaJwTAIgi7d
# hzn5hatLo7Dhz+4T+MrFd+6LUa2U3zr97QwzDthx+RP9/RZnur4inzSQsG5DCVIM
# pA1l2NWEA3KAca0tI2l6hQNYsaKL1kefdfHCrPxEry8onJjyGGv9YKoLv6AOO7Oh
# JEmbQlz/xksYG2N/JSOJ+QqYpGTEuYFYVWain7He6jgb41JbpOGKDdE/b+V2q/gX
# UgFe2gdwTpCDsvh8SMRoq1/BNXcr7iTAU38Vgr83iVtPYmFhZOVM0ULp/kKTVoir
# IpP2KCxT4OekOctt8grYnhJ16QMjmMv5o53hjNFXOxigkQWYzUO+6w50g0FAeFa8
# 5ugCCB6lXEk21FFB1FdIHpjSQf+LP/W2OV/HfhC3uTPgKbRtXo83TZYEudooyZ/A
# Vu08sibZ3MkGOJORLERNwKm2G7oqdOv4Qj8Z0JrGgMzj46NFKAxkLSpE5oHQYP1H
# tPx1lPfD7iNSbJsP6LiUHXH1MIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGXMwghlvAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAANOtTx6wYRv6ysAAAAAA04wDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIK8pJUiEKyD6uuL1ngEUzFXo
# eCJ0aUafgm27JrB/B3TtMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAhkv/l7qBRnlUDmrcChM2OtNsJqlAnn5egZS40nWlxWA2S9TKLoECe1R+
# 7xC7A3EPofTYPyBT5ZxSGlBQ76TygR7jgZx4j1gHRohTmnNgqS3td2Xq5HFrAaR3
# e72tGFdWU1vRjIRS4eyHKanG/79Rspp4YUXxRfzh/LNXSDPEcdqB17JdxoyXHwmo
# KUFqGu3URJk7eYRwe7CqBTE+dqyDpL14pingxp1oHfa0NdjX/ba/vggeNsi3UVbY
# +gUknzOuyBRhIiulGGeoEwbeJtJ1M0LlfSDba+LUV0q6/CEkH3+D1QSQFCUc1uMV
# q7TxJTd9lG7gr0nMtq7dePIIWWM6paGCFv0wghb5BgorBgEEAYI3AwMBMYIW6TCC
# FuUGCSqGSIb3DQEHAqCCFtYwghbSAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsq
# hkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCAxLvlLXlIQnpSWuuIkSlILwY820/E8VpaUMEr7CnJn5QIGZGzUUjTd
# GBMyMDIzMDUyNDE2NDkwOC45NDlaMASAAgH0oIHQpIHNMIHKMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjo3QkYxLUUz
# RUEtQjgwODElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCC
# EVQwggcMMIIE9KADAgECAhMzAAAByPmw7mft6mtGAAEAAAHIMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTIyMTEwNDE5MDEz
# N1oXDTI0MDIwMjE5MDEzN1owgcoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjdCRjEtRTNFQS1CODA4MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAucudfihPgyRWwnnIuJCqc3TCtFk0XOimFcKjU9bS6WFn
# g2l+FrIid0mPZ7KWs6Ewj21X+ZkGkM6x+ozHlmNtnHSQ48pjIFdlKXIoh7fSo41A
# 4n0tQIlwhs8uIYIocp72xwDBHKSZxGaEa/0707iyOw+aXZXNcTxgNiREASb9thlL
# ZM75mfJIgBVvUmdLZc+XOUYwz/8ul7IEztPNH4cn8Cn0tJhIFfp2netr8GYNoiyI
# qxueG7+sSt2xXl7/igc5cHPZnWhfl9PaB4+SutrA8zAhzVHTnj4RffxA4R3k4BRb
# PdGowQfOf95ZeYxLTHf5awB0nqZxOY+yuGWhf6hp5RGRouc9beVZv98M1erYa55S
# 1ahZgGDQJycVtEy82RlmKfTYY2uNmlPLWtnD7sDlpVkhYQGKuTWnuwQKq9ZTSE+0
# V2cH8JaWBYJQMIuWWM83vLPo3IT/S/5jT2oZOS9nsJgwwCwRUtYtwtq8/PJtvt1V
# 6VoG4Wd2/MAifgEJOkHF7ARPqI9Xv28+riqJZ5mjLGz84dP2ryoe0lxYSz3PT5Er
# KoS0+zJpYNAcxbv2UXiTk3Wj/mZ3tulz6z4XnSl5gy0PLer+EVjz4G96GcZgK2d9
# G+uYylHWwBneIv9YFQj6yMdW/4sEpkEbrpiJNemcxUCmBipZ7Sc35rv4utkJ4/UC
# AwEAAaOCATYwggEyMB0GA1UdDgQWBBS1XC9JgbrSwLDTiJJT4iK7NUvk9TAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEBCwUAA4IC
# AQDD1nJSyEPDqSgnfkFifIbteJb7NkZCbRj5yBGiT1f9fTGvUb5CW7k3eSp3uxUq
# om9LWykcNfQa/Yfw0libEim9YRjUNcL42oIFqtp/7rl9gg61oiB8PB+6vLEmjXkY
# xUUR8WjKKC5Q5dx96B21faSco2MOmvjYxGUR7An+4529lQPPLqbEKRjcNQb+p+mk
# QH2XeMbsh5EQCkTuYAimFTgnui2ZPFLEuBpxBK5z2HnKneHUJ9i4pcKWdCqF1AOV
# N8gXIH0R0FflMcCg5TW8v90Vwx/mP3aE2Ige1uE8M9YNBn5776PxmA16Z+c2s+hY
# I+9sJZhhRA8aSYacrlLz7aU/56OvEYRERQZttuAFkrV+M/J+tCeGNv0Gd75Y4lKL
# Mp5/0xoOviPBdB2rD5C/U+B8qt1bBqQLVZ1wHRy0/6HhJxbOi2IgGJaOCYLGX2zz
# 0VAT6mZ2BTWrJmcK6SDv7rX7psgC+Cf1t0R1aWCkCHJtpYuyKjf7UodRazevOf6V
# 01XkrARHKrI7bQoHFL+sun2liJCBjN51mDWoEgUCEvwB3l+RFYAL0aIisc5cTaGX
# /T8F+iAbz+j2GGVum85gEQS9uLzSedoYPyEXxTblwewGdAxqIZaKozRBow49OnL+
# 5CgooVMf3ZSqpxc2QC0E03l6c/vChkYyqMXq7Lwd4PnHqjCCB3EwggVZoAMCAQIC
# EzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIyNVoX
# DTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9DtWC
# 0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2Z4VG
# Iwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N7dcP
# 2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXcag/P
# XfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJj361
# VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjklqwB
# Sru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37ZyL9t9
# X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M269e
# wvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLXpyDw
# wvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLUHMVr
# 9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode2o+e
# FnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEAATAj
# BgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYEFJ+n
# FV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEBMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAf
# BgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEugSaBH
# hkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNS
# b29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUF
# BzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0Nl
# ckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt4Swf
# ZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsPMeTC
# j/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++Kctu
# 2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9QKC/
# GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2wh3D
# YXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aRAfbO
# xnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5zbcqO
# Cb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nxt67I
# 6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3Fb+0
# zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+ANuOaM
# mdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNT
# TY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggLLMIICNAIBATCB+KGB0KSBzTCByjEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWlj
# cm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEmMCQGA1UECxMdVGhhbGVzIFRTUyBF
# U046N0JGMS1FM0VBLUI4MDgxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAN/OE1C7xjU0ClIDXQBiucAY7suyoIGD
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZIhvcNAQEF
# BQACBQDoGKQ7MCIYDzIwMjMwNTI0MjI1NjU5WhgPMjAyMzA1MjUyMjU2NTlaMHQw
# OgYKKwYBBAGEWQoEATEsMCowCgIFAOgYpDsCAQAwBwIBAAICH1YwBwIBAAICEmYw
# CgIFAOgZ9bsCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgC
# AQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQUFAAOBgQDJbY6JfwOPEYaB
# q0B5VAKxBnA3O7oA4lxOy1WCpfCFSHXoUYaDmGImXZh25uTXsNG6vh8aQnQne8Vq
# Ot0Zi+WjlWZdR6wfaeWanZNBXkLtDJELki5OWh38G/PcMsmVw6Sw2QbihF/IRRvJ
# RcD/YG+M8FOzalDNp9oyxuBN1x3SfzGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAByPmw7mft6mtGAAEAAAHIMA0GCWCGSAFl
# AwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcN
# AQkEMSIEILwApqMl50ID8vnX8P6kiSj6xW/hQlw91g2syCzjjMojMIH6BgsqhkiG
# 9w0BCRACLzGB6jCB5zCB5DCBvQQgYgCYz80/baMvxw6jcqSvL0FW4TdvA09nxHfs
# PhuEA2YwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAA
# Acj5sO5n7eprRgABAAAByDAiBCABqOZMQOrLCvbbvKY/2amQZA3fY2wwIKsRjAL5
# aikGeTANBgkqhkiG9w0BAQsFAASCAgB1yoyk6fYRGR2KBvubvF2XMk6j1kYm96Bo
# +Tp+oe8Zu2x0gY0awgT2fHtlyp9Xmw47IuIGiXmxcuzagTbSNkVaqnT//52LTfCc
# 3DAFHDuvI3LGtAGI3QIm5NdKQdk5g3EVtOnBxCF7fMt/ZYKzZ5r8aTrMp4AK8ydd
# nZekW1K6MPU+zEbnkq6t+TFmRLuWz3hMG36AHHTSmwg1jrT8PhCOgzRLLZyHh0yJ
# emqyT2h3ZDmWslIJMB9okLVRFQUhyAq04WqIGUBjt4wvrtW750JskGZxPAN98Avo
# z0yv1P7Rg6/j374/qPWg9TuCB08MGjit6gGmqLNcpVD2a1ac5Mup8vrt6+l6Vlfi
# zs4ID1Dn/Tsz2APmSNsb0I+Nwx9pCx2btPOQCzF74iHJePBwcVb+wec3Z7R6ym2f
# yb+zw8sQdXLjdOleH4a1TmzgfwVO5rj/KzmrIWQNn4hokyGPO0tnWCFztBw848ds
# tRKIQSzuyH+tm8iMP52B77u3u8OWp5nsXaDW57Mgavil833sufspLOPfALOA3ZyS
# w69yb8qvO4w6C8dAbjUSL/xzP2Y9j7RhEONKA9wKiNXaZQ54ffFcGgKGlb/Nh6yS
# fRtkZmviVcMpfQWh0SP9KSQxJhjdDx0CwQxm32uOnMGWy3dCF9u4fynVOBJ9rSSD
# tszjDjuBCQ==
# SIG # End signature block
