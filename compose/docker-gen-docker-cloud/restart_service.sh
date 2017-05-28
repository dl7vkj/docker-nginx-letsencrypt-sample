#!/bin/bash

set -u


## Docker API
function docker_api {
    local scheme
    local curl_opts=(-s)
    local method=${2:-GET}
    # data to POST
    if [[ -n "${3:-}" ]]; then
        curl_opts+=(-d "$3")
    fi
    if [[ -z "$DOCKER_HOST" ]];then
        echo "Error DOCKER_HOST variable not set" >&2
        return 1
    fi
    if [[ $DOCKER_HOST == unix://* ]]; then
        curl_opts+=(--unix-socket ${DOCKER_HOST#unix://})
        scheme='http://localhost'
    else
        scheme="http://${DOCKER_HOST#*://}"
    fi
    [[ $method = "POST" ]] && curl_opts+=(-H 'Content-Type: application/json')
    curl "${curl_opts[@]}" -X${method} ${scheme}$1
}

function docker_exec {
    local id="${1?missing id}"
    local cmd="${2?missing command}"
    local data=$(printf '{ "AttachStdin": false, "AttachStdout": true, "AttachStderr": true, "Tty":false,"Cmd": %s }' "$cmd")
    exec_id=$(docker_api "/containers/$id/exec" "POST" "$data" | jq -r .Id)
    if [[ -n "$exec_id" ]]; then
        docker_api /exec/$exec_id/start "POST" '{"Detach": false, "Tty":false}'
    fi
}

function docker_kill {
    local id="${1?missing id}"
    local signal="${2?missing signal}"
    docker_api "/containers/$id/kill?signal=$signal" "POST"
}

## Nginx
reload_nginx() {
    if [[ -n "${NGINX_DOCKER_GEN_CONTAINER:-}" ]]; then
        # Using docker-gen separate container
        echo "Reloading nginx proxy (using separate container ${NGINX_DOCKER_GEN_CONTAINER})..."
        docker_kill "$NGINX_DOCKER_GEN_CONTAINER" SIGHUP
    else
        if [[ -n "${NGINX_PROXY_CONTAINER:-}" ]]; then
            echo "Reloading nginx proxy..."
            docker_exec "$NGINX_PROXY_CONTAINER" \
                        '[ "sh", "-c", "/usr/sbin/nginx -s reload" ]'
        fi
    fi
}

# Convert argument to lowercase (bash 4 only)
function lc() {
    echo "${@,,}"
}


export CONTAINER_ID=$(cat /proc/self/cgroup | sed -nE 's/^.+docker[\/-]([a-f0-9]{64}).*/\1/p' | head -n 1)

if [[ -z "$CONTAINER_ID" ]]; then
    echo "Error: can't get my container ID !" >&2
    exit 1
fi

function check_docker_socket {
    if [[ $DOCKER_HOST == unix://* ]]; then
        socket_file=${DOCKER_HOST#unix://}
        if [[ ! -S $socket_file ]]; then
            cat >&2 <<-EOT
ERROR: you need to share your Docker host socket with a volume at $socket_file
Typically you should run your container with: \`-v /var/run/docker.sock:$socket_file:ro\`
See the documentation at http://git.io/vZaGJ
EOT
            exit 1
        fi
    fi
}

function get_nginx_proxy_cid {
    # Look for a NGINX_VERSION environment variable in containers that we have mount volumes from.
    local volumes_from=$(docker_api "/containers/$CONTAINER_ID/json" | jq -r '.HostConfig.VolumesFrom[]' 2>/dev/null)
    for cid in $volumes_from; do
        cid=${cid%:*} # Remove leading :ro or :rw set by remote docker-compose (thx anoopr)
        if [[ $(docker_api "/containers/$cid/json" | jq -r '.Config.Env[]' | egrep -c '^NGINX_VERSION=') = "1" ]];then
            export NGINX_PROXY_CONTAINER=$cid
            break
        fi
    done
    # Check if any container has been labelled as the nginx proxy container.
    local labeled_cid=$(docker_api "/containers/json" | jq -r '.[] | select( .Labels["com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy"] == "true")|.Id')
    if [[ ! -z "${labeled_cid:-}" ]]; then
        export NGINX_PROXY_CONTAINER=$labeled_cid
    fi
    if [[ -z "${NGINX_PROXY_CONTAINER:-}" ]]; then
        echo "Error: can't get nginx-proxy container id !" >&2
        echo "Check that you use the --volumes-from option to mount volumes from the nginx-proxy or label the nginx proxy container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=true'." >&2
        exit 1
    fi
}

function get_docker_gen_cid {
    # Look for a NGINX_VERSION environment variable in containers that we have mount volumes from.
    # local volumes_from=$(docker_api "/containers/$CONTAINER_ID/json" | jq -r '.HostConfig.VolumesFrom[]' 2>/dev/null)
    # for cid in $volumes_from; do
    #     cid=${cid%:*} # Remove leading :ro or :rw set by remote docker-compose (thx anoopr)
    #     if [[ $(docker_api "/containers/$cid/json" | jq -r '.Config.Env[]' | egrep -c '^NGINX_VERSION=') = "1" ]];then
    #         export NGINX_PROXY_CONTAINER=$cid
    #         break
    #     fi
    # done
    # Check if any container has been labelled as the docker gen container.
    local labeled_cid=$(docker_api "/containers/json" | jq -r '.[] | select( .Labels["com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen"] == "true")|.Id')
    if [[ ! -z "${labeled_cid:-}" ]]; then
        export NGINX_DOCKER_GEN_CONTAINER=$labeled_cid
    fi
    if [[ -z "${NGINX_DOCKER_GEN_CONTAINER:-}" ]]; then
        echo "Error: can't get docker-gen container id !" >&2
        echo "Check that you label the docker-gen container to use with 'com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen=true'." >&2
        exit 1
    fi
}

function check_writable_directory {
    local dir="$1"
    docker_api "/containers/$CONTAINER_ID/json" | jq ".Mounts[].Destination" | grep -q "^\"$dir\"$"
    if [[ $? -ne 0 ]]; then
        echo "Warning: '$dir' does not appear to be a mounted volume."
    fi
    if [[ ! -d "$dir" ]]; then
        echo "Error: can't access to '$dir' directory !" >&2
        echo "Check that '$dir' directory is declared has a writable volume." >&2
        exit 1
    fi
    touch $dir/.check_writable 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "Error: can't write to the '$dir' directory !" >&2
        echo "Check that '$dir' directory is export as a writable volume." >&2
        exit 1
    fi
    rm -f $dir/.check_writable
}

function check_dh_group {
    if [[ ! -f /etc/nginx/certs/dhparam.pem ]]; then
        echo "Creating Diffie-Hellman group (can take several minutes...)"
        openssl dhparam -out /etc/nginx/certs/.dhparam.pem.tmp 2048
        mv /etc/nginx/certs/.dhparam.pem.tmp /etc/nginx/certs/dhparam.pem || exit 1
    fi
}



#PROXY_SERVICE=$PROXY_SERVICE_ENV_VAR

echo "Redeploying proxy service ..."
get_nginx_proxy_cid
reload_nginx
# proxy=`docker service ps --status Running | grep "^${PROXY_SERVICE}" | awk '{print $2}'`
# docker service redeploy $proxy
#docker service update ${PROXY_SERVICE} --force
echo "Redeployed proxy service ..."
