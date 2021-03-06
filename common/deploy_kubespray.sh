#!/bin/bash

set -o errexit

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/common.sh"
source "$my_dir/functions.sh"
source "$my_dir/workaround.sh"

function is_kubeapi_accessible() {
  local x
  2>/dev/null exec {x}</dev/tcp/$1/6443 || return 1
  exec {x}<&-
  return 0
}

# parameters

KUBESPRAY_TAG=${KUBESPRAY_TAG:="release-2.14"}
K8S_MASTERS=${K8S_MASTERS:-$NODE_IP}
K8S_NODES=${K8S_NODES:-$NODE_IP}
K8S_POD_SUBNET=${K8S_POD_SUBNET:-"10.32.0.0/12"}
K8S_SERVICE_SUBNET=${K8S_SERVICE_SUBNET:-"10.96.0.0/12"}
K8S_VERSION=${K8S_VERSION:-"v1.18.10"}
CNI=${CNI:-cni}
IGNORE_APT_UPDATES_REPO={$IGNORE_APT_UPDATES_REPO:-false}
LOOKUP_NODE_HOSTNAMES={$LOOKUP_NODE_HOSTNAMES:-true}
CRYPTOGRAPHY_ALLOW_OPENSSL_102=true

# Apply docker cli workaround
workaround_kubespray_docker_cli

# kubespray parameters like CLOUD_PROVIDER can be set as well prior to calling this script

[ "$(whoami)" == "root" ] && echo Please run script as non-root user && exit 1

# install required packages

if [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
    sudo yum install -y python3 python3-pip libyaml-devel python3-devel git
elif [ "$DISTRO" == "ubuntu" ]; then
    # Ensure updates repo is available
    if [[ "$IGNORE_APT_UPDATES_REPO" != "false" ]] && ! apt-cache policy | grep http | awk '{print $2 $3}' | sort -u | grep -q updates; then
        echo "Ubuntu updates repo could not be found! Please check your apt sources" 1>&2
        echo "If you believe this to be a mistake and want to proceed, set IGNORE_APT_UPDATES_REPO=true and run again." 1>&2
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -y
    sudo -E apt-get -y purge unattended-upgrades || /bin/true
    sudo -E apt-get install -y python3 python3-pip libyaml-dev python3-dev git

    ubuntu_release=`lsb_release -r | awk '{split($2,a,"."); print a[1]}'`
    if [ 16 -eq $ubuntu_release ]; then
        sudo apt-add-repository --yes --update ppa:ansible/ansible-2.7
        sudo apt update
        sudo apt install -y ansible python3-cffi python3-crypto libssl-dev
        pip3 install pyOpenSSL
    fi
else
    echo "Unsupported OS version" && exit 1
fi

# prepare ssh key authorization for all-in-one single node deployment

set_ssh_keys

# setup timeserver

setup_timeserver

# deploy kubespray

[ ! -d kubespray ] && git clone --depth 1 --single-branch --branch=${KUBESPRAY_TAG} https://github.com/kubernetes-sigs/kubespray.git
cd kubespray/

# If we now install the cryptography and cffi of the required version, then the newest versions will not be installed together with the ansible
sudo pip3 install -c${UPPER_CONSTRAINTS_FILE:=https://releases.openstack.org/constraints/upper/${OPENSTACK_VERSION:-master}} cryptography cffi

sudo pip3 install -r requirements.txt

cp -rfp inventory/sample/ inventory/mycluster
declare -a IPS=( $K8S_MASTERS $K8S_NODES )
masters=( $K8S_MASTERS )

# Copy devstack-directory to another nodes
ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
devstack_dir="$(basename $(dirname $my_dir))"
for machine in $(echo "$CONTROLLER_NODES $AGENT_NODES" | tr " " "\n" | sort -u); do
  if ! ip a | grep -q "$machine"; then
    echo "Copy devstack from master to $machine"
    scp -r $ssh_opts $(dirname $my_dir) $machine:/tmp/
  fi
done

echo Deploying to IPs ${IPS[@]} with masters ${masters[@]}
export KUBE_MASTERS_MASTERS=${#masters[@]}
if ! [ -e inventory/mycluster/hosts.yml ] && [[ "$LOOKUP_NODE_HOSTNAMES" == "true" ]]; then
    node_count=0
    for ip in $(echo ${IPS[@]} | tr ' ' '\n' | awk '!x[$0]++'); do
        declare -A IPS_WITH_HOSTNAMES
        hostname=$(ssh $ssh_opts $ip hostname -s)
        IPS_WITH_HOSTNAMES[$hostname]=$ip
       ((node_count+=1))
    done
    # Test if all hostnames were unique
    if [[ "${#IPS_WITH_HOSTNAMES[@]}" != "$node_count" ]]; then
        echo "ERROR: Not all hosts have unique hostnames." 1>&2
        echo "To use automatic host naming, set LOOKUP_NODE_HOSTNAMES=false" 1>&2
        exit 1
    fi
    CONFIG_FILE=inventory/mycluster/hosts.yml python3 contrib/inventory_builder/inventory.py $(for host in "${!IPS_WITH_HOSTNAMES[@]}"; do echo -n "$host,${IPS_WITH_HOSTNAMES[$host]} ";done)
else
    CONFIG_FILE=inventory/mycluster/hosts.yml python3 contrib/inventory_builder/inventory.py ${IPS[@]}
fi

sed -i "s/kube_network_plugin: .*/kube_network_plugin: $CNI/g" inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo "helm_enabled: true" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo 'helm_version: "v2.16.11"' >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo 'helm_stable_repo_url: "https://charts.helm.sh/stable"' >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml

# DNS
# Allow host and hostnet pods to resolve cluster domains
echo "resolvconf_mode: host_resolvconf" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo "enable_nodelocaldns: false" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml

# Grab first nameserver from /etc/resolv.conf that is not coredns
if sudo systemctl is-enabled systemd-resolved.service; then
  nameserver=$(grep -i nameserver /run/systemd/resolve/resolv.conf | grep -v $(echo $K8S_SERVICE_SUBNET | cut -d. -f1-2) | head -1 | awk '{print $2}')
  resolvfile=/run/systemd/resolve/resolv.conf
else
  nameserver=$(grep -i nameserver /etc/resolv.conf | grep -v $(echo $K8S_SERVICE_SUBNET | cut -d. -f1-2) | head -1 | awk '{print $2}')
  resolvfile=/etc/resolv.conf
fi
if [ -z "$nameserver" ]; then
  echo "FATAL: No existing nameservers detected. Please set one in $resolvfile before deploying again."
  exit 1
fi
# Set upstream DNS server used by host and coredns for recursive lookups
echo "upstream_dns_servers: ['$nameserver']" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo "nameservers: ['$nameserver']" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
# Fix coredns deployment on single node
echo "dns_min_replicas: 1" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml

# enable docker live restore option
#
# set live-restore via config file to avoid conflicts between command line and 
# config file parametrs (docker fails to start if a parameter is in both places).
# tf-dev-env and deployment methods (not using kubespray) use config file approach.
#    the way via kubespray:
#    echo "docker_options: '--live-restore'" >> inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
echo "Create /etc/docker/daemon.json on all nodes"
# Master-node
sudo -E $my_dir/create_docker_config.sh
# All another nodes
for machine in $(echo "$CONTROLLER_NODES $AGENT_NODES" | tr " " "\n" | sort -u); do
  if ! ip a | grep -q "$machine"; then
    ssh $ssh_opts $machine "sudo yum install -y python3 python3-pip"
    ssh $ssh_opts $machine "export CONTAINER_REGISTRY=$CONTAINER_REGISTRY ; sudo -E /tmp/${devstack_dir}/common/create_docker_config.sh"
  fi
done

extra_vars=""
[[ -n $K8S_POD_SUBNET ]] && extra_vars="-e kube_pods_subnet=$K8S_POD_SUBNET"
[[ -n $K8S_SERVICE_SUBNET ]] && extra_vars="$extra_vars -e kube_service_addresses=$K8S_SERVICE_SUBNET"
[[ -n $K8S_VERSION ]] && extra_vars="$extra_vars -e kube_version=$K8S_VERSION"
ansible-playbook -i inventory/mycluster/hosts.yml --become --become-user=root cluster.yml $extra_vars "$@"

mkdir -p ~/.kube
sudo cp /root/.kube/config ~/.kube/config
sudo chown -R $(id -u):$(id -g) ~/.kube

# NB. kubespray deletes k8s_POD_kube-apiserver ct in the end to
# trigger a kube-apiserver reset thus kube API can be available
# for a moment and then disappears. the port test is not enough
# let's wait for k8s_POD_kube-apiserver cts first to catch the
# kube-apiserver POD restart.
if ! wait_cmd_success 'if [ -z "$(sudo docker ps -q --filter '\''name=k8s_POD_kube-apiserver*'\'')" ]; then false; fi' 5 12
then
  echo "Kubernetes API POD is not available"
  exit 1
fi
if ! wait_cmd_success "is_kubeapi_accessible ${masters[0]}" 5 12
then
  echo "Kubernetes API is not accessible"
  exit 1
fi
if [[ "openstack" == "${ORCHESTRATOR}" && "${CNI}" == "calico" ]]
then
  # NB. calico requires custom mtu settings when network is over vxlan
  # because of an extra packet header otherwise packet loss is observed.
  # this is what we have in vexx.
  k=/usr/local/bin/kubectl
  echo "Wait for calico-node daemonset"
  wait_cmd_success "$k -n kube-system get daemonset/calico-node" 5 36

  echo "Patch calico-node daemonset"
  $k -n kube-system patch daemonset/calico-node --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "FELIX_IPINIPMTU", "value": "1400"}}]'
  $k -n kube-system patch daemonset/calico-node --type='json' -p='[{"op": "add", "path": "/spec/template/spec/initContainers/0/env/-", "value": {"name": "CNI_MTU", "value": "1400"}}]'
  $k rollout restart daemonset calico-node -n kube-system

  echo "Patch calico CNI template on all nodes"
  for machine in $(echo "$CONTROLLER_NODES $AGENT_NODES" | tr " " "\n" | sort -u); do
    echo "Patch calico CNI template at $machine"
    ssh $ssh_opts $machine <<'PATCH'
sudo sed --in-place=.backup -re 's!^(\s*)("log_level":.*)$!\1\2\n\1"mtu": __CNI_MTU__,!'  /etc/cni/net.d/calico.conflist.template
PATCH
  done

  echo "Patch calico-node pods"
  $k -n kube-system delete pods --selector k8s-app=calico-node
fi

cd ../
