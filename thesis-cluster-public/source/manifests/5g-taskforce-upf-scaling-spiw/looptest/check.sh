#!/bin/bash

##name: site-status.sh

#FAIL_CODE=6

#check_status(){
#response=$(curl -o /dev/null --silent --head --write-out '%{http_code}' "192.168.10.57:9090/api/v1/query -G -d query='amf_session{service="aaa",namespace="ddd"}'")
#echo $response
#}


#check_status

#nc -z -v -w5 192.168.10.56 9090
#response=$?
#echo $response
#if [[ $response -ne 0 ]] ; then
#  echo "not reachable"
#else
#  echo "reachable"
#fi

kubectl patch -n default pod open5gs-upf-8444fdb48d-sv26l --subresource resize --patch \
 '{"spec":{"containers":[{"name":"open5gs-upf", "resources":{"limits":{"cpu":"110m"}}}]}}'
