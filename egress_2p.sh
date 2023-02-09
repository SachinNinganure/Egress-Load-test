#!/usr/bin/env bash

##############################################################################
# Prints log messages
# Arguments:
#   
##############################################################################
echo $private_ip_address
oc get clusterversion
MASTER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/master= --no-headers | wc -l)
WORKER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)
echo $MASTER_NODES_COUNT master nodes and  $WORKER_NODES_COUNT worker nodes
worker_node1=`oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==1{print $1}'`
worker_node2=`oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==2{print $1}'`
#Reading the ipvalue from global var
ls $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt
private_ip_address=`cat $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt`
echo "private_ip_address";echo" $private_ip_address"
#Assign the nodes to be eressable
oc label node  $worker_node1 "k8s.ovn.org/egress-assignable"=""
oc label node  $worker_node2 "k8s.ovn.org/egress-assignable"=""

#TO Automatically get the value of ipv4 address and add the number of ip's in the same subnet of ipv4 in the egress object yaml files.
oc describe node $worker_node1|grep egress -C 3
#To create 2 egress objects
oc create -f config_egressip_ovn_ns_qe_podSelector_red.yaml
oc create -f config_egressip_ovn_ns_qe_podSelector_blue.yaml

#to get egressip's
oc get egressip>egressip.txt

#create test projects, and create some test pods in them, label the projects

for i in {1..4};
do 
    export test_num=$i
    test_name=test$test_num
    envsubst < namespace.yaml > namespace$test_num.yaml
    oc create -f namespace$test_num.yaml
    oc create -f list_for_pods.json -n $test_name
    rc_name=$(oc get rc -n $test_name --no-headers -o name)
    sleep 5
    oc wait $rc_name --for jsonpath='{.status.readyReplicas}'=2 --timeout=90s -n $test_name
    oc get pods -n $test_name
    oc get pods;oc label ns test$i department=qe;
done


#TO Automate on fetching the public ipaddress from the ipecho service that got enabled for the cluster and should be curled from outside
#label the pods of the projects to configure egress
for i in {1..2};do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;oc label pod $mypod team=blue ;done
for i in {3..4};do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;oc label pod $mypod team=red ;done

#curl to the ipecho service '10.0.13.150' from outside and verify if it hits the egress ip "ipv4":"10.0.48.0/20"

echo "print ing the env variable from pipeline"
echo $private_ip_address;
for i in {1..2}; do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;egress=$(oc exec $mypod -- curl $private_ip_address:9095);echo $egress;done

for i in {3..4}; do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;egress=$(oc exec $mypod -- curl $private_ip_address:9095);echo $egress;done
#cluster is enabled with ipecho service and https://mastern-jenkins-csb-openshift-qe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-common/job/ginkgo-test/ is run successfully 

#Delete all the projects for next iteration
for i in {1..4}; do oc delete ns test$i;done
echo "###################################ITERATION COMPLETE###########################################"
sleep 3;
