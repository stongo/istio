#!/bin/bash

# Copyright 2017 Istio Authors

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. ${TESTS_DIR}/commonUtils.sh || { echo "Cannot load common utilities"; exit 1; }

K8CLI="kubectl"

# Generate a namespace to use for testing
function generate_namespace() {
    local uuid="$(uuidgen)"
    [[ -z "${uuid}" ]] && error_exit 'Please install uuidgen'
    echo "bookinfo-test-${uuid:0:8}"
}

# Create a kube namespace to isolate test
function create_namespace(){
    print_block_echo "Creating kube namespace"
    ${K8CLI} create namespace ${NAMESPACE} \
    || error_exit 'Failed to create namespace'
}

# Bring up control plane
function deploy_istio() {
    local istio_install="${1}"
    print_block_echo "Deploying ISTIO"
    ${K8CLI} -n ${NAMESPACE} create -f "${istio_install}" \
      || error_exit 'Failed to create control plane'
    retry -n 10 find_istio_endpoints \
      || error_exit 'Could not deploy istio'
}

function find_istio_endpoints() {
    local endpoints=($(${K8CLI} get endpoints -n ${NAMESPACE} \
      -o jsonpath='{.items[*].subsets[*].addresses[*].ip}'))
    echo ${endpoints[@]}
    [[ ${#endpoints[@]} -eq 4 ]] && return 0
    return 1
}

# Port forward manager, then point istioctl at it
function setup_istioctl(){
    print_block_echo "Setting up istioctl"
    ${K8CLI} -n ${NAMESPACE} port-forward $(${K8CLI} -n ${NAMESPACE} get pod -l istio=manager \
     -o jsonpath='{.items[0].metadata.name}') 8081:8081 &
    pfPID=$!
    export ISTIO_MANAGER_ADDRESS=http://localhost:8081
}

# Kill the port forwarding process
function cleanup_istioctl(){
    print_block_echo "Cleaning up istioctl"
    kill ${pfPID}
}

# Deploy the bookinfo microservices
function deploy_bookinfo() {
    local bookinfo_dir="${1}"
    print_block_echo "Deploying BookInfo to kube"
    ${K8CLI} -n ${NAMESPACE} create -f "${bookinfo_dir}" \
      || error_exit 'Failed to deploy bookinfo'
    retry -n 10 find_ingress_controller \
      || error_exit 'Could not deploy bookstore'
}

function find_ingress_controller() {
    #local gateway="$(${K8CLI} get svc istio-ingress-controller -n ${NAMESPACE} \
    #  -o jsonpath='{.status.loadBalancer.ingress[*].ip}')"
    #if [[ ${gateway} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    #    GATEWAY_URL="http://${gateway}"
    #    return 0
    #fi
    local gateway="$(${K8CLI} get po -l infra=istio-ingress-controller -n ${NAMESPACE} \
      -o jsonpath='{.items[0].status.hostIP}'):$(${K8CLI} get svc istio-ingress-controller -n ${NAMESPACE} \
      -o jsonpath={.spec.ports[0].nodePort})"
    if [[ ${gateway} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\:3[0-2][0-9][0-9][0-9]$ ]]; then
        GATEWAY_URL="http://${gateway}"
        return 0
    fi
    return 1
}

# Clean up all the things
function cleanup() {
    print_block_echo "Cleaning up ISTIO"
    ${K8CLI} -n ${NAMESPACE} delete -f "${ISTIO_INSTALL_DIR}"
    print_block_echo "Cleaning up BookInfo"
    ${K8CLI} -n ${NAMESPACE} delete -f "${BOOKINFO_DIR}"
    print_block_echo "Deleting namespace"
    ${K8CLI} delete namespace ${NAMESPACE}
}

# Debug dump for failures
function dump_debug() {
    echo ""
    $K8CLI -n $NAMESPACE get pods
    $K8CLI -n $NAMESPACE get thirdpartyresources
    $K8CLI -n $NAMESPACE get thirdpartyresources -o json
    GATEWAY_PODNAME=$($K8CLI -n $NAMESPACE get pods | grep istio-ingress | awk '{print $1}')
    $K8CLI -n $NAMESPACE logs $GATEWAY_PODNAME
    PRODUCTPAGE_PODNAME=$($K8CLI -n $NAMESPACE get pods | grep productpage | awk '{print $1}')
    $K8CLI -n $NAMESPACE logs $PRODUCTPAGE_PODNAME -c productpage
    $K8CLI -n $NAMESPACE logs $PRODUCTPAGE_PODNAME -c proxy
    $K8CLI -n $NAMESPACE get istioconfig -o yaml
    $K8CLI -n $NAMESPACE get cm/mixer-config -o yaml
    MIXER_PODNAME=$($K8CLI -n $NAMESPACE get pods | grep istio-mixer | awk '{print $1}')
    $K8CLI -n $NAMESPACE logs $MIXER_PODNAME
}
