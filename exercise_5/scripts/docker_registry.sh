#!/usr/bin/env bash

set -eu
source /etc/environment
export VAULT_ADDR="http://192.168.0.254:8200"

POLICYDIR=/tmp/vault_policies
mkdir -p $POLICYDIR

# Create PKI backends
docker exec vault \
  vault mount -path /inovex/k8s_ca pki || exit 0

# Allow issuing an unlimited ca
docker exec vault \
  vault mount-tune -max-lease-ttl=87600h /inovex/k8s_ca

docker exec vault \
  vault write /inovex/k8s_ca/root/generate/internal \
                common_name=K8S_CA_$(date +%F-%H:%M) ttl=10h

docker exec vault \
  vault write /inovex/k8s_ca/roles/master \
                allow_any_name='true' \
                enforce_hostnames='false' \
                organization='' \
                max_ttl="4m" \
                allow_ip_sans='true' \
                generate_lease='true'

docker exec vault \
  /bin/sh -c 'echo path \"/inovex/k8s_ca/issue/master\" {policy=\"write\"} | vault policy-write k8s_ca_master_issue -'

docker exec vault \
  vault write /auth/inovex/approle/role/k8s_ca_master \
                bind_secret_id=false \
                policies=k8s_ca_master_issue \
                bound_cidr_list=192.168.0.0/16

DOCKER_REGISTRY_ROLE_ID=$(docker exec vault \
  vault read -format=json /auth/inovex/approle/role/k8s_ca_master/role-id | jq -r .data.role_id
)
export DOCKER_REGISTRY_ROLE_ID

docker exec vault \
  vault write /inovex/k8s_ca/issue/master \
                common_name="docker-registry"

### Create certificate

CURL_STATUS_CODE=$(curl \
                    -Ss \
                    -XPOST \
                    --data "{\"role_id\": \"${DOCKER_REGISTRY_ROLE_ID}\"}" \
                    ${VAULT_ADDR}/v1/auth/inovex/approle/login \
                    -w "%{response_code}" \
                    -o VAULT_TOKEN_RAW)

if [[ "$CURL_STATUS_CODE" != 200 ]]; then
    echo "Failed to retrieve token! Error was: \"$(cat VAULT_TOKEN_RAW)\""
    exit 1
fi

VAULT_TOKEN=$(jq -r .auth.client_token VAULT_TOKEN_RAW)
echo $VAULT_TOKEN > vault_token
echo 'Successfully fetched token via approle id'

# Get ca, cert and key and write them into distinct files
mkdir certs
echo 'Fetching x509 certificate for cluster...'
RAW_VAULT_ANSWER_FILE=vault_answer
curl  --fail \
      -s \
      -H "X-VAULT-TOKEN: ${VAULT_TOKEN}" \
      -XPOST \
      --data '{"common_name": "docker-registry.foo", "ttl": "1h"}' \
      ${VAULT_ADDR}/v1/inovex/k8s_ca/issue/master \
      -o ${RAW_VAULT_ANSWER_FILE}
jq -r .data.issuing_ca ${RAW_VAULT_ANSWER_FILE} > certs/ca.pem
jq -r .data.certificate ${RAW_VAULT_ANSWER_FILE} > certs/docker.crt
jq -r .data.private_key ${RAW_VAULT_ANSWER_FILE} > certs/docker.pem
echo 'Successfully fetched x509 certificate for cluster'

### Start docker container with certificates

docker run -d \
  --restart=always \
  --name registry \
  -v $PWD/certs:/certs \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/docker.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/docker.pem \
  -p 192.168.0.253:443:443 \
  registry:2

