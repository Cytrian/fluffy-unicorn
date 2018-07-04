#!/bin/bash

export VAULT_ADDR="http://192.168.0.254:8200"
export VAULT_TOKEN=$(cat vault_token)
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

docker restart registry
