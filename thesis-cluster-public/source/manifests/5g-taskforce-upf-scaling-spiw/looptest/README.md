This page describes a simple experiment with in place pod vertical scaling using Open5GS.

# Contents

1. [Enabling InPlacePodVerticalScaling](./README.md#enabling-inplacepodverticalscaling)
   
   1.1 [Enable during k3s installation](./README.md#11-enable-during-k3s-installation)
   
   1.2 [Enable on a running k3s cluster](./README.md#12-enable-on-a-running-k3s-cluster)
   
2. [Testing in place scaling of pods](./README.md#2-testing-in-place-scaling-of-pods)
   
   2.1 [Scale simple test pod](./README.md#21-scale-simple-test-pod)
   
   2.2 [Scale Open5GS UPF function](./README.md#22-scale-open5gs-upf-function)
   
   2.3 [Retrieve the number of UE sessions set up in the network](./README.md#23-retrieve-the-number-of-ue-sessions-set-up-in-the-network)

3. [Conclusion](./README.md#3-conclusion)
   

# 1. Enabling InPlacePodVerticalScaling

If InPlacePodVerticalScaling is enabled in your cluster you can skip this section and go to [testing](#testing-in-place-scaling-of-pods).

## 1.1. Enable during k3s installation

The easiest way is to install k3s with featureGate InPlacePodVerticalScaling enabled. For example for control nodes:

```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.32.3+k3s1   INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 \
  --disable servicelb --disable-cloud-controller \
  --kube-apiserver-arg=feature-gates=InPlacePodVerticalScaling=true \
  --kube-controller-manager-arg=feature-gates=InPlacePodVerticalScaling=true \
  --kube-scheduler-arg=feature-gates=InPlacePodVerticalScaling=true \
  --kubelet-arg=feature-gates=InPlacePodVerticalScaling=true \
  --kube-proxy-arg=feature-gates=InPlacePodVerticalScaling=true"   sh -
```

For agent nodes, only
```
  --kubelet-arg=feature-gates=InPlacePodVerticalScaling=true \
  --kube-proxy-arg=feature-gates=InPlacePodVerticalScaling=true
```
has to be added for each agent node.

If you did not enable it during installation, follow the steps below.

## 1.2 Enable on a running k3s cluster

(according to: https://github.com/k3s-io/k3s/issues/12025#issuecomment-2769290290)

1) On the server (master) node(s)

- modify file /etc/systemd/system/k3s.service to add feature-gates for apiserver, controller-manager and scheduler as follows

(Note: remaining settings visible are not relevant to in place scaling)
```
ubuntu@k3s01:~$ sudo nano /etc/systemd/system/k3s.service
...
ExecStart=/usr/local/bin/k3s \
    server \
        '--write-kubeconfig-mode' \
        '644' \
        '--disable' \
        'servicelb' \
        '--disable-cloud-controller' \
        '--kube-apiserver-arg=feature-gates=InPlacePodVerticalScaling=true' \
        '--kube-controller-manager-arg=feature-gates=InPlacePodVerticalScaling=true' \
        '--kube-scheduler-arg=feature-gates=InPlacePodVerticalScaling=true' \
        '--kubelet-arg=feature-gates=InPlacePodVerticalScaling=true' \
        '--kube-proxy-arg=feature-gates=InPlacePodVerticalScaling=true' \
```
- save the file and run
```
ubuntu@k3s01:~$ sudo systemctl daemon-reload
ubuntu@k3s01:~$ sudo systemctl stop k3s.service
ubuntu@k3s01:~$ sudo systemctl start k3s.service
```
2) On each agent node where the feature is to be enabled

(Note: one can enable the feature on a subset of workers, but needs to control pod placement then)

- modify file /etc/systemd/system/k3s-agent.service to add feature-gates as follows:
```
ubuntu@k3s02:~$ sudo nano /etc/systemd/system/k3s-agent.service
...
ExecStart=/usr/local/bin/k3s \
    agent \
        '--kubelet-arg=feature-gates=InPlacePodVerticalScaling=true' \
        '--kube-proxy-arg=feature-gates=InPlacePodVerticalScaling=true' \
```
- save the file and run:
```
ubuntu@k3s02:~$ sudo systemctl daemon-reload
ubuntu@k3s02:~$ sudo systemctl stop k3s-agent.service
ubuntu@k3s02:~$ sudo systemctl start k3s-agent.service
```
3) Check if in place scaling works - see the next section.

# 2. Testing in place scaling of pods

## 2.1 Scale simple test pod

### Define and create the pod
```
$ tee testinplace.yaml << EOT
apiVersion: v1
kind: Namespace
metadata:
  name: tests
---
apiVersion: v1
kind: Pod
metadata:
  name: inplacedemo
  namespace: tests
spec:
  containers:
  - name: inplacedemo
    image: alpine
    imagePullPolicy: IfNotPresent
    command: ["tail", "-f", "/dev/null"]
    resizePolicy:
    - resourceName: "memory"
      restartPolicy: "RestartContainer"
    resources:
      limits:
        cpu: "100m"
        memory: "1Gi"
      requests:
        cpu: "50m"
        memory: "500Mi"
EOT
```
### Run the pod and test in place scaling
  - using kubectl in terminal window
```
$ kubectl apply -f testinplace.yaml
$ kubectl patch -n tests pod inplacedemo --subresource resize --patch \
'{"spec":{"containers":[{"name":"inplacedemo", "resources":{"limits":{"cpu":"150m"}}}]}}'
```
  - using kubectl in bash script

    Note: this version works also when resource quotas are passed as variables as $cpu in this example.
```
cpu="150m"
kubectl patch -n $NAMESPACE pod $podname --subresource resize --patch \
 "{\"spec\":{\"containers\":[{\"name\":\"inplacedemo\", \"resources\":{\"limits\":{\"cpu\":\"$cpu\"}}}]}}"
```

## 2.2 Scale Open5GS UPF function

It is assumed that all components (Open5GS and the monitoring platform) have been installe according to our instructions. Otherwise some details may differ.

<pre><font color="#26A269"><b>ubuntu@labs</b></font>:<font color="#12488B"><b>~/labs/5gtask</b></font>$ kubectl get pods
NAME                                       READY   STATUS    RESTARTS        AGE
open5gs-amf-57c6c6c65b-vhh8c               1/1     Running   0               4h39m
open5gs-ausf-bcfd48966-bwr2q               1/1     Running   0               4h39m
open5gs-bsf-796ccbfc56-vvvmj               1/1     Running   0               4h39m
open5gs-mongodb-9df4bcfdb-pqr5b            1/1     Running   0               4h39m
open5gs-nrf-54dd7bcd5-f74d5                1/1     Running   0               4h39m
open5gs-nssf-6577c78cc9-q4vk4              1/1     Running   0               4h39m
open5gs-pcf-86678b795b-d9pz2               1/1     Running   5 (4h36m ago)   4h39m
open5gs-populate-84c9dd744c-mxcr8          1/1     Running   0               4h39m
open5gs-scp-789c9b466c-z7lqn               1/1     Running   0               4h39m
open5gs-smf-74845db7cb-bjjxd               1/1     Running   0               4h39m
open5gs-udm-8674db49b9-swxhl               1/1     Running   0               4h39m
open5gs-udr-77fd7748fb-nwwkk               1/1     Running   5 (4h37m ago)   4h39m
<font color="#DC143C"><b>open5gs-upf-8444fdb48d-sv26l               1/1     Running   0               4h39m</b></font>
open5gs-webui-55dbd67878-rpwk9             1/1     Running   0               4h39m
ueransim-gnb-d7d765f99-zfcdd               1/1     Running   0               4h7m
ueransim-gnb-ues-5b68cf9b78-gd4lr          1/1     Running   1 (4h7m ago)    4h7m
ueransim-ues-additional-6bcb88756c-ldjwq   1/1     Running   0               4h5m
<font color="#26A269"><b>ubuntu@labs</b></font>:<font color="#12488B"><b>~/labs/5gtask</b></font>$ kubectl patch -n default pod <font color="#26A269"><b>open5gs-upf-8444fdb48d-sv26l</b></font> --subresource resize --patch  \
&apos;{&quot;spec&quot;:{&quot;containers&quot;:[{&quot;name&quot;:&quot;<font color="#DC143C"><b>open5gs-upf</b></font>&quot;, &quot;resources&quot;:{&quot;limits&quot;:{&quot;cpu&quot;:&quot;150m&quot;}}}]}}&apos;
pod/<font color="#26A269"><b>open5gs-upf-8444fdb48d-sv26l</b></font> patched
# check if resized as requested
<font color="#26A269"><b>ubuntu@labs</b></font>:<font color="#12488B"><b>~/labs/5gtask</b></font>$ kubectl get pods/<font color="#26A269"><b>open5gs-upf-8444fdb48d-sv26l</b></font> \
-o=jsonpath=&apos;{.status.containerStatuses[0].resources}&apos; | jq
<b>{</b>
<b>  </b><font color="#12488B"><b>&quot;limits&quot;</b></font><b>: {</b>
<b>    </b><font color="#12488B"><b>&quot;cpu&quot;</b></font><b>: </b><font color="#26A269">&quot;150m&quot;</font>
<b>  },</b>
<b>  </b><font color="#12488B"><b>&quot;requests&quot;</b></font><b>: {</b>
<b>    </b><font color="#12488B"><b>&quot;cpu&quot;</b></font><b>: </b><font color="#26A269">&quot;50m&quot;</font>
<b>  }</b>
<b>}</b>
<font color="#26A269"><b>ubuntu@labs</b></font>:<font color="#12488B"><b>~/labs/5gtask</b></font>$</pre>

## 2.3 Retrieve the number of UE sessions set up in the network

The number of active sessions registered in the AMF function is read. Prometheus scrapes this metric from the AMF target every 15 seconds. We read it by querying Prometheus.

### Using a browser
```
http://10.254.186.64:9090/api/v1/query?query=amf_session{service="open5gs-amf-metrics",namespace="default"}`
```
### Curl on Linux
- command line (here, Open5GS runs in default namespace)
```
curl 10.254.186.64:9090/api/v1/query -G -d 'query=amf_session{service="open5gs-amf-metrics",namespace="default"}' | jq
```
- bash script (here, NAMESPACE is the namespace of Open5GS; PROMETHEUS_ADDR is a reacheble address of Prometheus)
```
# read the metric value: amf_sessions from Prometheus;
query="query=amf_session{service=\"open5gs-amf-metrics\",namespace=\"$NAMESPACE\"}"
echo -e "\nquery:" ${query}
amf_sessions=$(curl -s ${PROMETHEUS_ADDR}:9090/api/v1/query -G -d \
     ${query} | jq '.data.result[0].value[1]' | tr -d '"')
```
### Curl on Windows
(here, Open5GS runs in default namespace)
```
curl 10.254.186.64:9090/api/v1/query -G -d "query=amf_session{service=\"open5gs-amf-metrics\",namespace=\"default\"}"
```

# 3. Conclusion

You now know how to monitor the number of UE sessions and how Open5GS functions can be scaled vertically without restarting the pod. Vertical scaling can be important in case of stateful functions, i.e., functions whose state can not be recreated after restarting the pod. This is the case with UPF in Open5GS as UPF pod keeps the information about UE data plane sessions in RAM and not in persistent memory.

As a next step, you can do a small project to design a simple scaler of Open5GS functions based on the number of UE sessions in the network. In simplest form, it can monitor amf_session metric and scale UPF pod. This can correspond to a scenario in which a growth of the numbers of sessions indicates that the data plane load on the UPF is going to increase soon. In anticipation of this we add computing resources to UPF container to be able to handle this growth. A little bit more complex scenario could envolve joint scaling of UPF and AMF, possibly with some dependency of the operations, e.g., demanding that the UPF pod is scaled first and the AMF pod is scaled only once we can confirm the scaling of UPF has been successfull. Notice such a control of the sequence of operations can not be achieved with standard Kubernetes autoscalers - Horizontal and Vertical Pod Autoscalers (HPA, VPA).

Note: In case of scaling other functions than UPF, you will have to update manifest templates of respective deployments to declare `resources.requests` and/or `resources.limits` properties for the scaled containers. This is required as best effort containers (default setting in our Open5GS charts) can not be scaled vertically. Check UPF file `open5gs/open5gs-228/charts/open5gs-upf/values.yaml` in Helm charts (line ~ 220) to see how this can look like.


