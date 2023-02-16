# Egress-Load-test
#Author : Sachin Ninganure
This repo deals with Automating running of egress perf test accmplishing the following tasks

1] Sets up a cluster with an external ipecho service used to validate if egress IPs are functioning.

2]Repeatedly (for  times)creates and delete 200 projects configured for egress IP with a pod sending requests to the ipecho service and verifying egress IP is used.

3]Verifying egress IP works well throughout the test

4] curl is used to interact with egress url from within the pod

5]Run a set of chaos[kraken] tests in parallel with egress test and verify if Egress Functions correctly continously.

Reference jira's https://issues.redhat.com/browse/OCPQE-12310
		 https://issues.redhat.com/browse/OCPQE-13579
About "Pipeline egress-perf-chaos-multibranch" 
       Build number expects cluster id against which test is to be executed
********* "Check-box IPECHO" is to be enabled when ipecho service is to be set on the cluster for the first time ********
ONE AMONG THE BELOW MUST BE SELECTED
******** "Check-box 4Projects" must be selected for repeatedly creating only 4 projects SEE STEP 2 **********
******** "Check-box 200Projects" must be selected for repeatedly creating 200 projects SEE STEP 2 **********
Chaos test with the Egress-Network-Scenario will be run in parallel to Egress-Perf Test.
