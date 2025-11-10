#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

##############################################################################
# OpenShift Egress IP Load Testing Script (200 pods)
# Tests egress IP functionality with blue/red team pod labeling at scale
##############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TOTAL_NAMESPACES=200
BLUE_TEAM_END=100
RED_TEAM_START=101
BATCH_SIZE=10
PARALLEL_JOBS=5

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Progress tracking
progress_counter=0
total_operations=0

show_progress() {
    progress_counter=$((progress_counter + 1))
    local percent=$((progress_counter * 100 / total_operations))
    echo -e "\r${BLUE}[PROGRESS]${NC} $percent% ($progress_counter/$total_operations) $1" >&2
}

# Cleanup function
cleanup() {
    log_info "Cleaning up resources..."
    log_info "This may take several minutes for 200 namespaces..."
    
    # Delete namespaces in parallel batches to speed up cleanup
    for ((batch_start=1; batch_start<=TOTAL_NAMESPACES; batch_start+=BATCH_SIZE)); do
        batch_end=$((batch_start + BATCH_SIZE - 1))
        if [[ $batch_end -gt $TOTAL_NAMESPACES ]]; then
            batch_end=$TOTAL_NAMESPACES
        fi
        
        log_info "Deleting namespaces test$batch_start to test$batch_end..."
        for ((i=batch_start; i<=batch_end; i++)); do
            oc delete ns "test$i" --ignore-not-found=true 2>/dev/null &
            rm -f "namespace$i.yaml" 2>/dev/null &
        done
        
        # Wait for this batch to complete before starting next
        wait
    done
    
    log_info "Cleanup completed"
}

# Set trap for cleanup on script exit
trap cleanup EXIT

# Utility function to wait for namespace creation
wait_for_namespace() {
    local namespace="$1"
    local timeout=60
    local counter=0
    
    while ! oc get namespace "$namespace" >/dev/null 2>&1; do
        sleep 1
        counter=$((counter + 1))
        if [[ $counter -gt $timeout ]]; then
            log_warning "Timeout waiting for namespace $namespace"
            return 1
        fi
    done
    return 0
}

# Function to create namespaces in parallel
create_namespaces_batch() {
    local start=$1
    local end=$2
    
    for ((i=start; i<=end; i++)); do
        {
            export test_num=$i
            test_name="test$test_num"
            
            # Generate namespace file
            envsubst < namespace.yaml > "namespace$test_num.yaml"
            
            # Create namespace
            if oc apply -f "namespace$test_num.yaml" >/dev/null 2>&1; then
                wait_for_namespace "$test_name"
            else
                log_warning "Failed to create namespace $test_name"
            fi
        } &
    done
    wait
}

# Function to create pods in parallel
create_pods_batch() {
    local start=$1
    local end=$2
    
    for ((i=start; i<=end; i++)); do
        {
            test_name="test$i"
            
            # Switch to namespace and create pods
            if oc project "$test_name" >/dev/null 2>&1; then
                if oc apply -f list_for_pods.json >/dev/null 2>&1; then
                    # Wait for replication controller to be ready
                    sleep 2
                    rc_name=$(oc get rc -n "$test_name" --no-headers -o name 2>/dev/null | head -1)
                    if [[ -n "$rc_name" ]]; then
                        oc wait "$rc_name" --for jsonpath='{.status.readyReplicas}'=2 --timeout=90s -n "$test_name" >/dev/null 2>&1 || true
                    fi
                    show_progress "Created pods in $test_name"
                else
                    log_warning "Failed to create pods in $test_name"
                fi
            else
                log_warning "Could not switch to namespace $test_name"
            fi
        } &
        
        # Limit concurrent jobs
        if (( $(jobs -r | wc -l) >= PARALLEL_JOBS )); then
            wait -n  # Wait for any job to complete
        fi
    done
    wait
}

# Function to label pods in parallel
label_pods_batch() {
    local start=$1
    local end=$2
    local team=$3
    
    for ((i=start; i<=end; i++)); do
        {
            namespace="test$i"
            mypod=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | awk 'NR==1{print $1}')
            
            if [[ -n "$mypod" ]]; then
                oc project "$namespace" >/dev/null 2>&1
                oc label pod "$mypod" "team=$team" --overwrite >/dev/null 2>&1
                show_progress "Labeled $mypod as team=$team"
            fi
        } &
        
        # Limit concurrent jobs
        if (( $(jobs -r | wc -l) >= PARALLEL_JOBS )); then
            wait -n
        fi
    done
    wait
}

# Function to test egress in parallel
test_egress_batch() {
    local start=$1
    local end=$2
    local team=$3
    local private_ip_address=$4
    local success_count=0
    local fail_count=0
    
    log_info "Testing $team team pods (test$start to test$end)..."
    
    for ((i=start; i<=end; i++)); do
        {
            namespace="test$i"
            mypod=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | awk 'NR==1{print $1}')
            
            if [[ -n "$mypod" ]]; then
                if egress=$(timeout 30 oc exec -n "$namespace" "$mypod" -- curl -s --connect-timeout 5 --max-time 10 "$private_ip_address:9095" 2>&1); then
                    echo "✓ SUCCESS: $mypod ($namespace) - Response: $egress"
                    echo 1 > "/tmp/success_$i"
                else
                    echo "✗ FAILED: $mypod ($namespace) - Error: $egress"
                    echo 1 > "/tmp/fail_$i"
                fi
            else
                echo "✗ NO POD: $namespace"
                echo 1 > "/tmp/fail_$i"
            fi
        } &
        
        # Limit concurrent jobs
        if (( $(jobs -r | wc -l) >= PARALLEL_JOBS )); then
            wait -n
        fi
    done
    wait
    
    # Count results
    success_count=$(find /tmp -name "success_*" 2>/dev/null | wc -l)
    fail_count=$(find /tmp -name "fail_*" 2>/dev/null | wc -l)
    
    # Cleanup temp files
    rm -f /tmp/success_* /tmp/fail_* 2>/dev/null || true
    
    log_info "$team team results: $success_count successes, $fail_count failures"
}

##############################################################################
# Main script execution
##############################################################################

log_info "Starting OpenShift Egress IP Load Test (200 pods)"
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

# Assign nodes to be egress-assignable
log_info "Setting up egress-assignable nodes..."
for node in "$worker_node1" "$worker_node2"; do
    if oc get node "$node" --show-labels | grep -q "egress-assignable"; then
        log_info "Node $node already egress-assignable"
    else
        log_info "Labeling node $node as egress-assignable"
        oc label node "$node" "k8s.ovn.org/egress-assignable"=""
    fi
done

# Check egress configuration
log_info "Checking egress configuration:"
oc describe node "$worker_node1" | grep egress -C 3 || true

# Create egress objects
log_info "Setting up egress IP objects..."

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

# Save egress IP status
log_info "Saving egress IP status to egressip.txt"
oc get egressip > egressip.txt || log_warning "Could not save egress IP status"

# Check required files
if [[ ! -f "namespace.yaml" ]]; then
    log_error "namespace.yaml template not found"
    exit 1
fi

if [[ ! -f "list_for_pods.json" ]]; then
    log_error "list_for_pods.json template not found"
    exit 1
fi

# Calculate total operations for progress tracking
total_operations=$((TOTAL_NAMESPACES * 3))  # namespace creation, pod creation, labeling

# Create namespaces in batches
log_info "Creating $TOTAL_NAMESPACES test namespaces in batches..."
for ((batch_start=1; batch_start<=TOTAL_NAMESPACES; batch_start+=BATCH_SIZE)); do
    batch_end=$((batch_start + BATCH_SIZE - 1))
    if [[ $batch_end -gt $TOTAL_NAMESPACES ]]; then
        batch_end=$TOTAL_NAMESPACES
    fi
    
    log_info "Creating namespaces test$batch_start to test$batch_end..."
    create_namespaces_batch $batch_start $batch_end
    
    for ((i=batch_start; i<=batch_end; i++)); do
        show_progress "Created namespace test$i"
    done
done

# Create pods in batches
log_info "Creating pods in $TOTAL_NAMESPACES namespaces..."
for ((batch_start=1; batch_start<=TOTAL_NAMESPACES; batch_start+=BATCH_SIZE)); do
    batch_end=$((batch_start + BATCH_SIZE - 1))
    if [[ $batch_end -gt $TOTAL_NAMESPACES ]]; then
        batch_end=$TOTAL_NAMESPACES
    fi
    
    create_pods_batch $batch_start $batch_end
done

# Label pods for teams
log_info "Labeling blue team pods (1-$BLUE_TEAM_END)..."
for ((batch_start=1; batch_start<=BLUE_TEAM_END; batch_start+=BATCH_SIZE)); do
    batch_end=$((batch_start + BATCH_SIZE - 1))
    if [[ $batch_end -gt $BLUE_TEAM_END ]]; then
        batch_end=$BLUE_TEAM_END
    fi
    
    label_pods_batch $batch_start $batch_end "blue"
done

log_info "Labeling red team pods ($RED_TEAM_START-$TOTAL_NAMESPACES)..."
for ((batch_start=RED_TEAM_START; batch_start<=TOTAL_NAMESPACES; batch_start+=BATCH_SIZE)); do
    batch_end=$((batch_start + BATCH_SIZE - 1))
    if [[ $batch_end -gt $TOTAL_NAMESPACES ]]; then
        batch_end=$TOTAL_NAMESPACES
    fi
    
    label_pods_batch $batch_start $batch_end "red"
done

echo  # New line after progress updates

# Test egress functionality
log_info "Starting egress IP tests for $TOTAL_NAMESPACES pods..."
log_info "This will test pods in batches to verify egress IP functionality"

# Test blue team
test_egress_batch 1 $BLUE_TEAM_END "Blue" "$private_ip_address"

# Test red team  
test_egress_batch $RED_TEAM_START $TOTAL_NAMESPACES "Red" "$private_ip_address"

# Test completion
log_success "Egress IP load testing completed successfully!"
log_info "Tested $TOTAL_NAMESPACES pods across blue and red teams"
log_info "Check the test results above to verify egress IP functionality"
log_info "Blue team pods should use blue team egress IP"
log_info "Red team pods should use red team egress IP"

# Note: Cleanup is handled by the trap function