#!/usr/bin/env bash

##############################################################################
# Prints log messages
# Arguments:
#   
##############################################################################
private_ip_address=10.0.6.243
echo $private_ip_address
oc get clusterversion
MASTER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/master= --no-headers | wc -l)
WORKER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)
echo $MASTER_NODES_COUNT master nodes and  $WORKER_NODES_COUNT worker nodes
worker_node1=`oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==1{print $1}'`
worker_node2=`oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==2{print $1}'`
#Reading the ipvalue from global var
#ls $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt
#private_ip_address=`cat $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt`
echo "private_ip_address";
echo $private_ip_address
#Assign the nodes to be eressable , ignore if labelled already
egress_assigned_n1=`oc get node $worker_node1 --show-labels|egrep -c egress-assignable`
if [ $egress_assigned_n1 == 1 ];then echo "Node $worker_node1 Already egressable";else oc label node  $worker_node1 "k8s.ovn.org/egress-assignable"="";fi
egress_assigned_n2=`oc get node $worker_node2 --show-labels|egrep -c egress-assignable`
if [ $egress_assigned_n2 == 1 ];then echo "Node $worker_node2 Already egressable";else oc label node  $worker_node2 "k8s.ovn.org/egress-assignable"="";fi
#oc label node  $worker_node2 "k8s.ovn.org/egress-assignable"=""

#TO Automatically get the value of ipv4 address and add the number of ip's in the same subnet of ipv4 in the egress object yaml files.
oc describe node $worker_node1|grep egress -C 3
#To create 2 egress objects and ignore if already created
eg_object1=`oc get egressip|awk 'NR==2{print $1}'`
if [ $eg_object1 ];then echo "$eg_object1 Already Exists";else oc create -f config_egressip_ovn_ns_qe_podSelector_red.yaml;fi
eg_object2=`oc get egressip|awk 'NR==3{print $1}'`
if [ $eg_object2 ];then echo "$eg_object2 Already Exists";else oc create -f config_egressip_ovn_ns_qe_podSelector_blue.yaml;fi

#copy egressip's to the txt file
oc get egressip>egressip.txt

#create test projects, and create some test pods in them, label the projects

for i in {1..4};
do 
    export test_num=$i
    test_name=test$test_num
    envsubst < namespace.yaml > namespace$test_num.yaml
    oc create -f namespace$test_num.yaml
    oc get ns test$i --show-labels
    oc get ns test_name$i --show-labels
    oc project test$i;oc create -f list_for_pods.json;oc get pods;
    #oc create -f list_for_pods.json -n $test_name
    rc_name=$(oc get rc -n $test_name --no-headers -o name)
    sleep 5
    oc wait $rc_name --for jsonpath='{.status.readyReplicas}'=2 --timeout=90s -n $test_name
    oc get pods -n $test_name
    #oc label ns test$i department=qe;
done


#Fetching the public ipaddress from the ipecho service that got enabled for the cluster and should be curled from outside
#label the pods of the projects to configure egress
for i in {1..2};do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;oc label pod $mypod team=blue ;done
for i in {3..4};do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;oc label pod $mypod team=red ;done

#curl to the ipecho service Ex-->'10.0.13.150' from outside and verify if it hits the egress ip "ipv4":"10.0.48.xxx"

echo "printing the env variable from pipeline"
echo $private_ip_address;
for i in {1..2}; do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;egress=$(oc exec $mypod -- curl $private_ip_address:9095);echo $egress;done

for i in {3..4}; do echo pod$i=mypod;mypod=$(oc get pods -n test$i|awk 'NR==2{print $1}');echo $mypod;echo $test$i;oc project test$i;egress=$(oc exec $mypod -- curl $private_ip_address:9095);echo $egress;done
#cluster is enabled with ipecho service and https://mastern-jenkins-csb-openshift-qe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-common/job/ginkgo-test/ is run successfully 

#Delete all the projects for next iteration and namespace.yaml files
for i in {1..4}; do oc delete ns test$i;rm namespace$i.yaml;done
echo "###################################ITERATION COMPLETE###########################################"
sleep 3;
