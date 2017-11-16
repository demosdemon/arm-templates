#!/bin/bash -e

# Automatically populates certain fields in the parameters.
# _artifactsLocation => The root uri of all the artifacts
# _artifactsLocationSasToken => The SAS token to append to the URI to authenticate all fetches
# _artifacts => A list of all the uploaded artifacts

function get_location() {
    azconfig="$HOME/.azure/config"
    if [ -f "$azconfig" ]; then
        location=$(awk -F= '/location/ {print $2}' "$azconfig" | tr -d ' ')

        if [ ! -z "$location" ]; then
            printf '%s' "$location"
        fi
    fi
}

function lower() {
    data=$1
    if [ -z "$data" ]; then
        read -d $'\0' -r data
    fi;
    awk '{print tolower($0)}' <<< "$data"
}

function strip_uuid() {
    uuid=$1
    if [ -z "$uuid" ]; then
        uuid=$(uuidgen)
    fi;
    uuid=${uuid//-/}
    uuid=$(lower "$uuid")
    uuid=${uuid:0:19}
    printf '%s' "$uuid"
}

function escape() {
    python3 -c 'import sys,json; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

function relpath() {
    python -c 'import os.path,sys;sys.stdout.write(os.path.relpath(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])))' "$1" "${2-${PWD}}"
}

function md5() {
    openssl md5 -binary < "$1" | base64 -w0
}

function append() {
    json=$1
    data=$2

    if [[ ${data:0:1} == '[' || ${data:0:1} == '{' ]]; then
        jq -c "$data + ." <<< "$json"
    else
        jq -c "[$data] + ." <<< "$json"
    fi
}

function addKey() {
    json=$1
    key=$2
    data=$3

    if [[ -z "$data" ]]; then
        data="null"
    fi

    append "$json" "{ $(escape "$key"): $data }"
}

while getopts "a:l:g:s:f:e:p:uvd" opt; do
    case $opt in
        a)
            artifactsStagingDirectory=$OPTARG #the folder or sample to deploy
            ;;
        l)
            location=$OPTARG #location for the deployed resource group
            ;;
        g)
            resourceGroupName=$OPTARG
            ;;
        u)
            uploadArtifacts='true' #set this switch to upload/stage artifacs
            ;;
        s)
            storageAccountName=$OPTARG #storage account to use for staging, if not supplied one will be created and reused
            ;;
        p)
            persistentStorageGroupName=$OPTARG #resource group for the staging storage account, ARM_Deploy_Staging by default
            ;;
        f)
            templateFile=$OPTARG
            ;;
        e)
            parametersFile=$OPTARG
            ;;
        v)
            validateOnly='true'
            ;;
        d)
            devMode='true'
            ;;
    esac
done

if [ -z "$location" ]; then
    location=$(get_location)
fi

if [[ $# -eq 0 || -z $artifactsStagingDirectory || -z $location ]]; then
    echo "Usage: $0 <-a foldername> <-l location> [-e parameters-file] [-g resource-group-name] [-u] [-s storageAccountName] [-v]"
    exit 1
fi

if [[ -z $templateFile ]]; then
    templateFile="$artifactsStagingDirectory/azuredeploy.json"
fi

if [[ $devMode ]]; then
    parametersFile="$artifactsStagingDirectory/azuredeploy.parameters.dev.json"
else
    if [[ -z $parametersFile ]]; then
        parametersFile="$artifactsStagingDirectory/azuredeploy.parameters.json"
    fi
fi

if [[ -z $persistentStorageGroupName ]]; then
    persistentStorageGroupName="ARM_Deploy_Staging"
fi

templateName=$( basename "${templateFile%.*}" )
templateDirectory=$( basename "$( dirname "$templateFile")" )
deploymentName="${templateDirectory}-${templateName}-$(strip_uuid)"

if [[ -z $resourceGroupName ]]; then
    resourceGroupName=$(basename "${artifactsStagingDirectory}")
fi

parameterJson=$( jq -c '.parameters' "$parametersFile" )

if [[ -z $uploadArtifacts ]]; then
    uploadArtifacts=$(jq 'has("_artifactsLocation") and has("_artifactsLocationSasToken")' <<< "$parameterJson")
fi


if $uploadArtifacts; then
    if [[ -z $storageAccountName ]];then
        subscriptionId=$(strip_uuid "$(az account show -o json | jq -r .id)")
        artifactsStorageAccountName="stage$subscriptionId"
        artifactsResourceGroupName="$persistentStorageGroupName"

        # pass empty resourceGroupName in case user has set a default resource group in settings
        if [[ -z $( az storage account list -g '' -o json | jq -r ".[].name | select(. == $(escape "$artifactsStorageAccountName"))" ) ]]; then
            az group create -n "$artifactsResourceGroupName" -l "$location"
            az storage account create -l "$location" --sku "Standard_LRS" -g "$artifactsResourceGroupName" -n "$artifactsStorageAccountName" 2>/dev/null
        fi
    else
        artifactsResourceGroupName=$( az storage account list -o json | jq -r ".[] | select(.name == $(escape "$storageAccountName")) | .resourceGroup" )

        if [[ -z $artifactsResourceGroupName ]]; then
            echo "Cannot find storageAccount: $storageAccountName"
            exit 2
        fi
    fi

    artifactsStorageContainerName=$(lower "${resourceGroupName}-stageartifacts")

    artifactsStorageAccountKey=$( az storage account keys list -g "$artifactsResourceGroupName" -n "$artifactsStorageAccountName" -o json | jq -r '.[0].value' )
    az storage container create -n "$artifactsStorageContainerName" --account-name "$artifactsStorageAccountName" --account-key "$artifactsStorageAccountKey" >/dev/null 2>&1

    # Get a 4-hour SAS Token for the artifacts container. Fall back to OSX date syntax if Linux syntax fails.
    plusFourHoursUtc=$(date -u -v+4H +%Y-%m-%dT%H:%MZ 2>/dev/null) || plusFourHoursUtc=$(date -u --date "4 hour" +%Y-%m-%dT%H:%MZ)

    sasToken=$( az storage container generate-sas -n "$artifactsStorageContainerName" --permissions r --expiry "$plusFourHoursUtc" --account-name "$artifactsStorageAccountName" --account-key "$artifactsStorageAccountKey" -o json | jq -r .)

    blobEndpoint=$( az storage account show -n "$artifactsStorageAccountName" -g "$artifactsResourceGroupName" -o json | jq -r '.primaryEndpoints.blob' )

    parameterJson=$( addKey "$parameterJson" _artifactsLocation "{value: $(escape "$blobEndpoint$artifactsStorageContainerName")}" )
    parameterJson=$( addKey "$parameterJson" _artifactsLocationSasToken "{value: $(escape "?$sasToken")}" )

    artifactsStagingDirectory=$( sed 's/\/*$//' <<< "$artifactsStagingDirectory" )

    artifacts="[]"

    while read -d $'\0' -r filepath; do
        relFilePath=$(relpath "$filepath" "$artifactsStagingDirectory")
        artifacts=$(append "$artifacts" "$(escape "$relFilePath")")
        md5=$(md5 "$filepath")
        az_md5=$(az storage blob show --container "$artifactsStorageContainerName" -n "$relFilePath" --account-name "$artifactsStorageAccountName" --account-key "$artifactsStorageAccountKey" -o json | jq -r '.properties.contentSettings.contentMd5')
        if [[ "$md5" != "$az_md5" ]]; then
            contentType=$(file "$filepath" -I | cut -d: -f2 | tr -d ' ')
            echo "Uploading file $relFilePath..."
            az storage blob upload -f "$filepath" --container "$artifactsStorageContainerName" -n "$relFilePath" --content-md5 "$md5" --content-type "$contentType" --account-name "$artifactsStorageAccountName" --account-key "$artifactsStorageAccountKey" --verbose
        fi
    done < <(find "$artifactsStagingDirectory" -type f -print0)

    # shellcheck disable=SC2091
    if "$(jq 'has("_artifacts")' <<< "$parameterJson")"; then
        parameterJson=$(addKey "$parameterJson" _artifacts "{value: $artifacts}")
    fi

    templateRelPath=$(relpath "$templateFile" "$artifactsStagingDirectory")
    templateUri="$blobEndpoint$artifactsStorageContainerName/$templateRelPath?$sasToken"

fi

az group create -n "$resourceGroupName" -l "$location"

if [[ $validateOnly ]]; then
    command=("validate")
else
    command=("create" "-n" "$deploymentName")
fi

if $uploadArtifacts; then
    templateArg=("--template-uri" "$templateUri")
else
    templateArg=("--template-file" "$templateFile")
fi

az group deployment "${command[@]}" "${templateArg[@]}" -g "$resourceGroupName" --parameters "$parameterJson" --verbose
