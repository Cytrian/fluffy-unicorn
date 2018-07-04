#!/bin/bash

docker exec vault \
  vault delete /inovex/k8s_ca/root

docker exec vault \
  vault write /inovex/k8s_ca/root/generate/internal common_name=K8S_CA_$(date +%F-%H:%M) ttl=10h


