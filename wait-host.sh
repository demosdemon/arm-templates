#!/bin/bash

set -e

TOKEN=$1
BASE_DIR=$(cd "$(dirname "$0")" && pwd)

if [[ -z "$TOKEN" ]]; then
    echo "Usage: $0 TOKEN"
    echo ""
    echo "  TOKEN is the unique token that identifies the virtual machine, vs-dev-TOKEN"
    exit 2
fi

PWSH="$BASE_DIR/pwsh.py --host lbc-vs-dev-$TOKEN.southcentralus.cloudapp.azure.com --user Brandon --password file:$BASE_DIR/.pass"

ID=$(az vm list -g '' --query "[?name=='vs-dev-$TOKEN'].id" --output tsv)

while $PWSH Test-Path C:\\SetupComplete.txt | grep -qi false; do
    $PWSH "Get-ChildItem -Path C:\ -Filter 'SetupLog*.txt' | Sort-Object -Descending -Property Name | Select-Object -First 1 | Get-Content"
    date
    sleep 60
done

# az vm deallocate --ids $ID
