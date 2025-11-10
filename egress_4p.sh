#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

##############################################################################
# OpenShift Egress IP Testing Script
# Tests egress IP functionality with blue/red team pod labeling
##############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cleanup function
cleanup() {
    log_info "Cleaning up resources..."
    for i in {1..4}; do 
        oc delete ns test$i --ignore-not-found=true 2>/dev/null || true
        rm -f namespace$i.yaml
    done
}

# Set trap for cleanup on script exit
trap cleanup EXIT

log_info "Starting OpenShift Egress IP Test"
oc get clusterversion

# Get cluster information
MASTER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/master= --no-headers | wc -l)
WORKER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)
log_info "Cluster has $MASTER_NODES_COUNT master nodes and $WORKER_NODES_COUNT worker nodes"

if [[ $WORKER_NODES_COUNT -lt 2 ]]; then
    log_error "Need at least 2 worker nodes for egress testing"
    exit 1
fi

worker_node1=$(oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==1{print $1}')
worker_node2=$(oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==2{print $1}')
log_info "Using worker nodes: $worker_node1, $worker_node2"

# Reading the IP value from global var
IP_FILE="${WORKSPACE:-}/flexy-artifacts/workdir/install-dir/ipfile.txt"
if [[ ! -f "$IP_FILE" ]]; then
    log_error "IP file not found: $IP_FILE"
    exit 1
fi

private_ip_address=$(cat "$IP_FILE")
if [[ -z "$private_ip_address" ]]; then
    log_error "Private IP address is empty"
    exit 1
fi
log_info "Private IP address: $private_ip_address"

# Assign nodes to be egress-assignable, ignore if already labeled
log_info "Setting up egress-assignable nodes..."
for node in "$worker_node1" "$worker_node2"; do
    if oc get node "$node" --show-labels | grep -q "egress-assignable"; then
        log_info "Node $node already egress-assignable"
    else
        log_info "Labeling node $node as egress-assignable"
        oc label node "$node" "k8s.ovn.org/egress-assignable"=""
    fi
done

# Check egress configuration on nodes
log_info "Checking egress configuration:"
oc describe node "$worker_node1" | grep egress -C 3 || true

# Create egress objects if they don't exist
log_info "Setting up egress IP objects..."

# Check for red team egress object
if oc get egressip 2>/dev/null | grep -q "red" || oc get egressip 2>/dev/null | tail -n +2 | head -1 >/dev/null 2>&1; then
    log_info "Red team egress IP configuration exists"
else
    if [[ -f "config_egressip_ovn_ns_qe_podSelector_red.yaml" ]]; then
        log_info "Creating red team egress IP"
        oc create -f config_egressip_ovn_ns_qe_podSelector_red.yaml
    else
        log_warning "Red team egress config file not found"
    fi
fi

# Check for blue team egress object  
if oc get egressip 2>/dev/null | grep -q "blue" || [[ $(oc get egressip --no-headers 2>/dev/null | wc -l) -gt 1 ]]; then
    log_info "Blue team egress IP configuration exists"
else
    if [[ -f "config_egressip_ovn_ns_qe_podSelector_blue.yaml" ]]; then
        log_info "Creating blue team egress IP"
        oc create -f config_egressip_ovn_ns_qe_podSelector_blue.yaml
    else
        log_warning "Blue team egress config file not found"
    fi
fi

# Save current egress IP status
log_info "Saving egress IP status to egressip.txt"
oc get egressip > egressip.txt || log_warning "Could not save egress IP status"

# Create test projects and pods
log_info "Creating test namespaces and pods..."

for i in {1..4}; do
    log_info "Creating test namespace and pods for test$i"
    
    export test_num=$i
    test_name="test$test_num"
    
    # Check if namespace template exists
    if [[ ! -f "namespace.yaml" ]]; then
        log_error "namespace.yaml template not found"
        exit 1
    fi
    
    # Create namespace
    envsubst < namespace.yaml > "namespace$test_num.yaml"
    oc apply -f "namespace$test_num.yaml"
    
    # Switch to namespace and create pods
    oc project "$test_name"
    
    # Check if pod template exists
    if [[ ! -f "list_for_pods.json" ]]; then
        log_error "list_for_pods.json template not found"
        exit 1
    fi
    
    oc apply -f list_for_pods.json
    
    # Wait for replication controller to be ready
    sleep 5
    rc_name=$(oc get rc -n "$test_name" --no-headers -o name | head -1)
    if [[ -n "$rc_name" ]]; then
        log_info "Waiting for pods in $test_name to be ready..."
        if ! oc wait "$rc_name" --for jsonpath='{.status.readyReplicas}'=2 --timeout=90s -n "$test_name"; then
            log_warning "Pods in $test_name may not be fully ready"
        fi
    fi
    
    log_info "Pods in $test_name:"
    oc get pods -n "$test_name"
done

# Label pods for egress testing
log_info "Labeling pods for team assignment..."

# Label blue team pods (test1, test2)
for i in {1..2}; do
    namespace="test$i"
    mypod=$(oc get pods -n "$namespace" --no-headers | awk 'NR==1{print $1}' 2>/dev/null)
    
    if [[ -n "$mypod" ]]; then
        log_info "Labeling pod $mypod in $namespace as team=blue"
        oc project "$namespace"
        oc label pod "$mypod" team=blue --overwrite
    else
        log_warning "No pod found in namespace $namespace"
    fi
done

# Label red team pods (test3, test4)  
for i in {3..4}; do
    namespace="test$i"
    mypod=$(oc get pods -n "$namespace" --no-headers | awk 'NR==1{print $1}' 2>/dev/null)
    
    if [[ -n "$mypod" ]]; then
        log_info "Labeling pod $mypod in $namespace as team=red"
        oc project "$namespace"
        oc label pod "$mypod" team=red --overwrite
    else
        log_warning "No pod found in namespace $namespace"
    fi
done

# Test egress functionality
log_info "Starting egress IP tests..."
echo "Private IP address for testing: $private_ip_address"

# Test blue team (test1, test2)
for i in {1..2}; do 
    echo "=== Testing Blue Team Pod $i ==="
    namespace="test$i"
    mypod=$(oc get pods -n "$namespace" --no-headers | awk 'NR==1{print $1}' 2>/dev/null)
    
    if [[ -z "$mypod" ]]; then
        log_error "No pod found in namespace $namespace"
        continue
    fi
    
    echo "Pod: $mypod in namespace: $namespace"
    oc project "$namespace"
    echo "Executing curl to $private_ip_address:9095..."
    
    # Test curl with proper error handling
    curl_exit_code=0
    egress=$(timeout 30 oc exec "$mypod" -- curl -s --connect-timeout 10 --max-time 20 "$private_ip_address:9095" 2>/dev/null) || curl_exit_code=$?
    
    if [[ $curl_exit_code -eq 0 && -n "$egress" ]]; then
        echo "✓ Curl SUCCESS from $mypod"
        echo "Response: $egress"
        echo "Expected egress IP for blue team should be visible in response"
    else
        echo "✗ Curl FAILED from $mypod (exit code: $curl_exit_code)"
        if [[ $curl_exit_code -eq 124 ]]; then
            echo "Error: Connection timeout"
        elif [[ $curl_exit_code -eq 7 ]]; then
            echo "Error: Failed to connect to host"
        elif [[ $curl_exit_code -eq 28 ]]; then
            echo "Error: Operation timeout"
        else
            echo "Error: Curl failed with exit code $curl_exit_code"
        fi
        # Try to get more info about connectivity
        oc exec "$mypod" -- ping -c 1 "$private_ip_address" >/dev/null 2>&1 && echo "  - Ping to $private_ip_address: SUCCESS" || echo "  - Ping to $private_ip_address: FAILED"
    fi
    echo "---"
done

# Test red team (test3, test4)
for i in {3..4}; do 
    echo "=== Testing Red Team Pod $i ==="
    namespace="test$i"
    mypod=$(oc get pods -n "$namespace" --no-headers | awk 'NR==1{print $1}' 2>/dev/null)
    
    if [[ -z "$mypod" ]]; then
        log_error "No pod found in namespace $namespace"
        continue
    fi
    
    echo "Pod: $mypod in namespace: $namespace" 
    oc project "$namespace"
    echo "Executing curl to $private_ip_address:9095..."
    
    # Test curl with proper error handling
    curl_exit_code=0
    egress=$(timeout 30 oc exec "$mypod" -- curl -s --connect-timeout 10 --max-time 20 "$private_ip_address:9095" 2>/dev/null) || curl_exit_code=$?
    
    if [[ $curl_exit_code -eq 0 && -n "$egress" ]]; then
        echo "✓ Curl SUCCESS from $mypod"
        echo "Response: $egress"
        echo "Expected egress IP for red team should be visible in response"
    else
        echo "✗ Curl FAILED from $mypod (exit code: $curl_exit_code)"
        if [[ $curl_exit_code -eq 124 ]]; then
            echo "Error: Connection timeout"
        elif [[ $curl_exit_code -eq 7 ]]; then
            echo "Error: Failed to connect to host"
        elif [[ $curl_exit_code -eq 28 ]]; then
            echo "Error: Operation timeout"
        else
            echo "Error: Curl failed with exit code $curl_exit_code"
        fi
        # Try to get more info about connectivity
        oc exec "$mypod" -- ping -c 1 "$private_ip_address" >/dev/null 2>&1 && echo "  - Ping to $private_ip_address: SUCCESS" || echo "  - Ping to $private_ip_address: FAILED"
    fi
    echo "---"
done

# Test completion
log_success "Egress IP testing completed successfully!"
log_info "Check the curl results above to verify egress IP functionality"
log_info "Blue team pods should use blue team egress IP"
log_info "Red team pods should use red team egress IP"

# Note: Cleanup is handled by the trap function