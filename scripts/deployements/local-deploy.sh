#!/bin/bash
#
# Deploys in local host
#
#
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

function error_exit
{
    echo
    echo -e "\e[91m${1:-"Unknown Error"}" 1>&2
    exit 1
}

function substitute_environs
{
    # NOTE: be careful that no variable with $ are in .env or they will be replaced by envsubst unless a list of variables is given
    tmpfile=$(mktemp)
    envsubst < "${1:-"Missing File"}" > "${tmpfile}" && mv "${tmpfile}" "${1:-"Missing File"}"
}


# Using osx support functions
declare psed # fixes shellcheck issue with not finding psed
# shellcheck source=/dev/null
source "$( dirname "${BASH_SOURCE[0]}" )/../portable.sh"
# ${psed:?}


# Paths
this_script_dir=$(dirname "$0")
repo_basedir=$(realpath "${this_script_dir}"/../../)

# VCS info on current repo
current_git_url=$(git config --get remote.origin.url)
current_git_branch=$(git rev-parse --abbrev-ref HEAD)

machine_ip=$(get_this_ip)

devel_mode=0

usage="$(basename "$0") [-h] [--key=value]

Deploys all the osparc-ops stacks and the SIM-core stack on osparc.local.

where keys are:
    -h, --help  show this help text
    --devel_mode             (default: ${devel_mode})"

for i in "$@"
do
case $i in
    --devel_mode=*)
    devel_mode="${i#*=}"
    shift # past argument=value
    ;;
    ##
    :|--help|-h|*)
    error_exit "$usage"
    ;;
esac
done

# Loads configurations variables
# See https://askubuntu.com/questions/743493/best-way-to-read-a-config-file-in-bash
# shellcheck source=/dev/null
source "${repo_basedir}"/repo.config

min_pw_length=8
if [ ${#SERVICES_PASSWORD} -lt $min_pw_length ]; then
    error_exit "Password length should be at least $min_pw_length characters"
fi

echo
echo -e "\e[1;33mDeploying osparc on ${MACHINE_FQDN}, using credentials $SERVICES_USER:$SERVICES_PASSWORD...\e[0m"

# -------------------------------- Simcore -------------------------------
pushd "${repo_basedir}"/services/simcore;
simcore_env=".env"
simcore_compose="docker-compose.deploy.yml"

substitute_environs ${simcore_env}

# docker-compose-simcore
# for local use we need tls self-signed certificate for the traefik entrypoint in simcore
$psed --in-place --expression='s/traefik.http.routers.${PREFIX_STACK_NAME}_webserver.entrypoints=.*/traefik.http.routers.${PREFIX_STACK_NAME}_webserver.entrypoints=https/' ${simcore_compose}
$psed --in-place --expression='s/traefik.http.routers.${PREFIX_STACK_NAME}_webserver.tls=.*/traefik.http.routers.${PREFIX_STACK_NAME}_webserver.tls=true/' ${simcore_compose}

# for local use we need to provide the generated certificate authority so that storage can access S3, or the director the registry
$psed --in-place --expression='s/\s\s\s\s#secrets:/    secrets:/' ${simcore_compose}
$psed --in-place --expression='s/\s\s\s\s\s\s#- source: rootca.crt/      - source: rootca.crt/' ${simcore_compose}
$psed --in-place --expression="s~\s\s\s\s\s\s\s\s#target: /usr/local/share/ca-certificates/osparc.crt~        target: /usr/local/share/ca-certificates/osparc.crt~" ${simcore_compose}
$psed --in-place --expression='s~\s\s\s\s\s\s#- SSL_CERT_FILE=/usr/local/share/ca-certificates/osparc.crt~      - SSL_CERT_FILE=/usr/local/share/ca-certificates/osparc.crt~' ${simcore_compose}

# check if changes were done, basically if there are changes in the repo
if [ "$devel_mode" -eq 0 ]; then
    for path in ${simcore_env} ${simcore_compose}
    do
        if ! git diff origin/"${current_git_branch}" --quiet --exit-code $path; then 
            error_exit "${simcore_env} is modified, please commit and push your changes and restart the script";
        fi
    done
fi
popd


# -------------------------------- PORTAINER ------------------------------
echo
echo -e "\e[1;33mstarting portainer...\e[0m"
pushd "${repo_basedir}"/services/portainer
sed -i "s/PORTAINER_ADMIN_PWD=.*/PORTAINER_ADMIN_PWD=$SERVICES_PASSWORD/" .env
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
make up
popd

# -------------------------------- TRAEFIK -------------------------------
echo
echo -e "\e[1;33mstarting traefik...\e[0m"
pushd "${repo_basedir}"/services/traefik
# copy certificates to traefik
cp "${repo_basedir}"/certificates/*.crt secrets/
cp "${repo_basedir}"/certificates/*.key secrets/
# setup configuration
$psed --in-place --expression="s/MACHINE_FQDN=.*/MACHINE_FQDN=$MACHINE_FQDN/" .env
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
$psed --in-place --expression="s/TRAEFIK_USER=.*/TRAEFIK_USER=$SERVICES_USER/" .env
traefik_password=$(docker run --rm --entrypoint htpasswd registry:2 -nb "$SERVICES_USER" "$SERVICES_PASSWORD" | cut -d ':' -f2)
$psed --in-place --expression="s|TRAEFIK_PASSWORD=.*|TRAEFIK_PASSWORD=${traefik_password}|" .env
make up-local
popd

# -------------------------------- MINIO -------------------------------
# In the .env, MINIO_NUM_MINIOS and MINIO_NUM_PARTITIONS need to be set at 1 to work without labelling the nodes with minioX=true

echo
echo -e "\e[1;33mstarting minio...\e[0m"
pushd "${repo_basedir}"/services/minio;
$psed --in-place --expression="s/MINIO_NUM_MINIOS=.*/MINIO_NUM_MINIOS=1/" .env
$psed --in-place --expression="s/MINIO_NUM_PARTITIONS=.*/MINIO_NUM_PARTITIONS=1/" .env

$psed --in-place --expression="s/MINIO_ACCESS_KEY=.*/MINIO_ACCESS_KEY=$SERVICES_PASSWORD/" .env
$psed --in-place --expression="s/MINIO_SECRET_KEY=.*/MINIO_SECRET_KEY=$SERVICES_PASSWORD/" .env
$psed --in-place --expression="s/STORAGE_DOMAIN=.*/STORAGE_DOMAIN=${STORAGE_DOMAIN}/" .env
make up; popd
echo "waiting for minio to run...don't worry..."
while [ ! "$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 10 https://"${STORAGE_DOMAIN}"/minio/health/ready)" = 200 ]; do
    echo "waiting for minio to run..."
    sleep 5s
done

# -------------------------------- REGISTRY -------------------------------
echo
echo -e "\e[1;33mstarting registry...\e[0m"
pushd "${repo_basedir}"/services/registry

# set configuration
$psed --in-place --expression="s/REGISTRY_DOMAIN=.*/REGISTRY_DOMAIN=$REGISTRY_DOMAIN/" .env
$psed --in-place --expression="s/S3_ACCESS_KEY_ID=.*/S3_ACCESS_KEY_ID=$SERVICES_PASSWORD/" .env
$psed --in-place --expression="s/S3_SECRET_ACCESS_KEY=.*/S3_SECRET_ACCESS_KEY=$SERVICES_PASSWORD/" .env
$psed --in-place --expression="s/S3_BUCKET=.*/S3_BUCKET=${S3_BUCKET}/" .env
$psed --in-place --expression="s/S3_ENDPOINT=.*/S3_ENDPOINT=${S3_ENDPOINT}/" .env
make up
popd


# -------------------------------- Redis commander-------------------------------
echo
echo -e "\e[1;33mstarting redis commander...\e[0m"
pushd "${repo_basedir}"/services/redis-commander

# set configuration
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env

make up
popd

# -------------------------------- MONITORING -------------------------------
echo
echo -e "\e[1;33mstarting monitoring...\e[0m"
# set MACHINE_FQDN
pushd "${repo_basedir}"/services/monitoring
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
$psed --in-place --expression="s|GF_SERVER_ROOT_URL=.*|GF_SERVER_ROOT_URL=https://$MACHINE_FQDN/grafana|" grafana/config.monitoring
$psed --in-place --expression="s|GF_SECURITY_ADMIN_PASSWORD=.*|GF_SECURITY_ADMIN_PASSWORD=$SERVICES_PASSWORD|" grafana/config.monitoring
$psed --in-place --expression="s|basicAuthPassword:.*|basicAuthPassword: $SERVICES_PASSWORD|" grafana/provisioning/datasources/datasource.yml

# if  the script is running under Windows, this line need to be commented : - /etc/hostname:/etc/host_hostname
if grep -qEi "(Microsoft|WSL)" /proc/version;
then 
    if [ ! "$(grep -qEi  "#- /etc/hostname:/etc/nodename # don't work with windows" &> /dev/null docker-compose.yml)" ]
    then
        $psed --in-place --expression="s~- /etc/hostname:/etc/nodename # don't work with windows~#- /etc/hostname:/etc/nodename # don't work with windows~" docker-compose.yml
    fi
else
    if [ "$(grep  "#- /etc/hostname:/etc/nodename # don't work with windows" &> /dev/null docker-compose.yml)" ]  
    then
        $psed --in-place --expression="s~#- /etc/hostname:/etc/nodename # don't work with windows~- /etc/hostname:/etc/nodename # don't work with windows~" docker-compose.yml
    fi
fi

make up
popd

# -------------------------------- JAEGER -------------------------------
echo
echo -e "\e[1;33mstarting jaeger...\e[0m"
# set MACHINE_FQDN
pushd "${repo_basedir}"/services/jaeger
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
make up
popd


# -------------------------------- Adminer -------------------------------
echo
echo -e "\e[1;33mstarting adminer...\e[0m"
pushd "${repo_basedir}"/services/adminer
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
$psed --in-place --expression="s/POSTGRES_DEFAULT_SERVER=.*/POSTGRES_DEFAULT_SERVER=$POSTGRES_HOST/" .env
make up
popd

# -------------------------------- GRAYLOG -------------------------------
echo
echo -e "\e[1;33mstarting graylog...\e[0m"
# set MACHINE_FQDN
pushd "${repo_basedir}"/services/graylog;
graylog_password=$(echo -n "$SERVICES_PASSWORD" | sha256sum | cut -d ' ' -f1)
$psed --in-place --expression="s/MONITORING_DOMAIN=.*/MONITORING_DOMAIN=$MONITORING_DOMAIN/" .env
$psed --in-place --expression="s|GRAYLOG_HTTP_EXTERNAL_URI=.*|GRAYLOG_HTTP_EXTERNAL_URI=https://$MONITORING_DOMAIN/graylog/|" .env
$psed --in-place --expression="s|GRAYLOG_ROOT_PASSWORD_SHA2=.*|GRAYLOG_ROOT_PASSWORD_SHA2=$graylog_password|" .env

# if  the script is running under Windows, this line need to be commented : - /etc/hostname:/etc/host_hostname
if grep -qEi "(Microsoft|WSL)" /proc/version;
then 
    if [ ! "$(grep -qEi  "#- /etc/hostname:/etc/host_hostname # does not work in windows" &> /dev/null docker-compose.yml)" ]
    then
        $psed --in-place --expression="s~- /etc/hostname:/etc/host_hostname # does not work in windows~#- /etc/hostname:/etc/host_hostname # does not work in windows~" docker-compose.yml
    fi
else
    if [ "$(grep  "#- /etc/hostname:/etc/host_hostname # does not work in windows" &> /dev/null docker-compose.yml)" ]
    then
        $psed --in-place --expression="s~#- /etc/hostname:/etc/host_hostname # does not work in windows~- /etc/hostname:/etc/host_hostname # does not work in windows~" docker-compose.yml
    fi
fi

make up

echo
echo "waiting for graylog to run..."
while [ ! "$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 10  -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://"$MONITORING_DOMAIN"/graylog/api/users)" = 401 ]; do
    echo "waiting for graylog to run..."
    sleep 5s
done
json_data=$(cat <<EOF
{
"title": "standard GELF UDP input",
    "type": "org.graylog2.inputs.gelf.udp.GELFUDPInput",
    "global": "true",
    "configuration": {
        "bind_address": "0.0.0.0",
        "port":12201
    }
}
EOF
)
curl -u "$SERVICES_USER":"$SERVICES_PASSWORD" --header "Content-Type: application/json" \
    --header "X-Requested-By: cli" -X POST \
    --data "$json_data" https://"$MONITORING_DOMAIN"/graylog/api/system/inputs
popd

# -------------------------------- ADMINER -------------------------------
echo
echo -e "\e[1;33mstarting adminer...\e[0m"
pushd "${repo_basedir}"/services/adminer;
make up
popd

if [ "$devel_mode" -eq 0 ]; then

    # -------------------------------- DEPlOYMENT-AGENT -------------------------------
    echo
    echo -e "\e[1;33mstarting deployment-agent for simcore...\e[0m"
    pushd "${repo_basedir}"/services/deployment-agent;

    if [[ $current_git_url == git* ]]; then
        # it is a ssh style link let's get the organisation name and just replace this cause that conf only accepts https git repos
        current_organisation=$(echo "$current_git_url" | cut -d":" -f2 | cut -d"/" -f1)
        sed -i "s|https://github.com/ITISFoundation/osparc-ops.git|https://github.com/$current_organisation/osparc-ops.git|" deployment_config.default.yaml
    else
        sed -i "/- id: simcore-ops-repo/{n;s|url:.*|url: $current_git_url|}" deployment_config.default.yaml
    fi
    sed -i "/- id: simcore-ops-repo/{n;n;s|branch:.*|branch: $current_git_branch|}" deployment_config.default.yaml

    secret_id=$(docker secret inspect --format="{{ .ID  }}" rootca.crt)
    # full original -> replacement
    YAML_STRING="environment:\n        S3_ENDPOINT: ${STORAGE_DOMAIN}:10000\n        S3_ACCESS_KEY: ${SERVICES_PASSWORD}\n        S3_SECRET_KEY: ${SERVICES_PASSWORD}"
    sed -i "s/environment: {}/$YAML_STRING/" deployment_config.default.yaml
    # update
    sed -i "s/S3_ENDPOINT:.*/S3_ENDPOINT: ${STORAGE_DOMAIN}/" deployment_config.default.yaml
    sed -i "s/S3_ACCESS_KEY:.*/S3_ACCESS_KEY: ${SERVICES_PASSWORD}/" deployment_config.default.yaml
    sed -i "s/S3_SECRET_KEY:.*/S3_SECRET_KEY: ${SERVICES_PASSWORD}/" deployment_config.default.yaml
    sed -i "s/DIRECTOR_SELF_SIGNED_SSL_SECRET_ID:.*/DIRECTOR_SELF_SIGNED_SSL_SECRET_ID: ${secret_id}/" deployment_config.default.yaml
    # portainer
    sed -i "/- url: .*portainer:9000/{n;s/username:.*/username: ${SERVICES_USER}/}" deployment_config.default.yaml
    sed -i "/- url: .*portainer:9000/{n;n;s/password:.*/password: ${SERVICES_PASSWORD}/}" deployment_config.default.yaml
    # extra_hosts
    sed -i "s|extra_hosts: \[\]|extra_hosts:\n        - \"${MACHINE_FQDN}:${machine_ip}\"|" deployment_config.default.yaml
    # AWS don't use Minio and Postgresql. We need to use them again in local.
    sed -i "s~excluded_services:.*~excluded_services: [webclient]~" deployment_config.default.yaml
    # Prefix stack name
    $psed --in-place --expression="s/PREFIX_STACK_NAME=.*/PREFIX_STACK_NAME=$PREFIX_STACK_NAME/" .env
    # defines the simcore stack name
    $psed --in-place --expression="s/SIMCORE_STACK_NAME=.*/SIMCORE_STACK_NAME=$SIMCORE_STACK_NAME/" .env
    # set the image tag to be used from dockerhub
    $psed --in-place --expression="s/SIMCORE_IMAGE_TAG=.*/SIMCORE_IMAGE_TAG=$SIMCORE_IMAGE_TAG/" .env
    # update
    sed -i "/extra_hosts:/{n;s/- .*/- \"${MACHINE_FQDN}:${machine_ip}\"/}" deployment_config.default.yaml
    make down up;
    popd
fi
