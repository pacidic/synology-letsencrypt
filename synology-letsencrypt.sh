#!/bin/bash -e

[[ $EUID == 0 ]] || { echo >&2 "This script must be run as root"; exit 1; }

while getopts ":p:ch" opt; do
    case $opt in
        p) LEGO_PATH="$OPTARG" ;;
        c) CREATE_CERT_RELOAD_SCRIPT=false ;;
        h)
            echo "Usage: $0 [options]"
            echo "  -p <lego_path> The path where Lego will install your certs"
            echo "  -c Suppress [c]reation of the hook scripts, if you have your own"
            exit 0
            ;;
        :) echo "Error: -${OPTARG} requires an argument" >&2 ;;
        \?) echo "Invalid option -$OPTARG" >&2 ;;
    esac
done

LEGO_PATH=${LEGO_PATH:-/usr/local/etc/synology-letsencrypt}
CREATE_CERT_RELOAD_SCRIPT=${CREATE_CERT_RELOAD_SCRIPT:-true}

source "$LEGO_PATH/env"

export LEGO_PATH

archive_path="/usr/syno/etc/certificate/_archive"
cert_path="$LEGO_PATH/certificates"
cert_domain="${DOMAINS[1]#\*.}"
cert_reload_script_path="$LEGO_PATH/reload_cert.sh"
cert_status_hook_path="$LEGO_PATH/cert_status_hook.sh"
cert_status_path="$LEGO_PATH/cert_status"
mkdir -p "$cert_path"

## cert_id
cert_id_path="$cert_path/$cert_domain.cert_id"
/usr/local/bin/synology-letsencrypt-make-cert-id.sh "$cert_id_path" "$archive_path"
source "$cert_id_path"

if [[ -z $cert_id ]]; then
    echo >&2 "ID not found in $cert_id_path"
    exit 1
fi

## install hook
archive_cert_path="$archive_path/$cert_id"
if [[ ! -d $archive_cert_path ]]; then
    mkdir -p "$archive_cert_path"
fi

if [[ ${CREATE_CERT_RELOAD_SCRIPT} == true ]]; then
    # this runs on the host, so use /bin/bash
    cat >"$cert_reload_script_path" <<EOF
#!/bin/bash

cp "${cert_path}/${cert_domain}.crt" "${archive_cert_path}/cert.pem"
cp "${cert_path}/${cert_domain}.crt" "${archive_cert_path}/fullchain.pem"
cp "${cert_path}/${cert_domain}.issuer.crt" "${archive_cert_path}/chain.pem"
cp "${cert_path}/${cert_domain}.key" "${archive_cert_path}/privkey.pem"

/usr/local/bin/synology-letsencrypt-reload-services.sh "$cert_id"
EOF

    chmod 700 "$cert_reload_script_path"
fi

# clear $cert_status_path file before running
echo "false" > $cert_status_path

# prepare cert_status info script
# this runs in the lego docker container, so use /bin/sh
cat >"$cert_status_hook_path" <<EOF
#!/bin/sh

echo "true" > $cert_status_path
EOF

chmod 700 "$cert_status_hook_path"

## run or renew
if [[ -s $cert_path/$cert_domain.crt ]]; then
    CMD=(renew --renew-hook)
else
    CMD=(run --run-hook)
fi

# https://go-acme.github.io/lego/usage/cli/
docker run --network host -v $LEGO_PATH:$LEGO_PATH --env-file $LEGO_PATH/env lego/master \
    --path $LEGO_PATH \
    --accept-tos \
    --key-type "rsa4096" \
    --email "$EMAIL" \
    --dns "$DNS_PROVIDER" \
    "${DOMAINS[@]}" \
    "${LEGO_OPTIONS[@]}" \
    "${CMD[@]}" "$cert_status_hook_path"

reload_cert=$(<"$cert_status_path")
if [[ "$reload_cert" == "true" ]]; then
  /bin/bash $cert_reload_script_path
fi
