- curl query to get integer number of amf sessions
curl -s 10.0.0.3:9090/api/v1/query -G -d \
     'query=amf_session{service="open5gs-amf-metrics",namespace="give-your-namespace-here"}' | \
     jq '.[].data.result[0].value[1]' curl.json | tr -d '"'
