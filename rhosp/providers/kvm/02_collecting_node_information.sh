#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source rhosp-environment.sh
source $my_dir/../../../common/common.sh
source $my_dir/../../../contrib/infra/kvm/functions.sh

# collect MAC addresses of overcloud machines
function get_macs() {
  local name=$1
  truncate -s 0 /tmp/nodes-$name.txt
  sudo virsh domiflist $name | awk '$3 ~ "prov" {print $5};'
}

function get_vbmc_ip() {
  local name=$1
  call_vbmc list | grep $name | awk -F\| '{print $4}'
}

function get_vbmc_port() {
  local name=$1
  call_vbmc list | grep $name | awk -F\| '{print $5}'
}

function define_machine() {
  local caps=$1
  local mac=$2
  local pm_ip=$3
  local pm_port=$4
  cat << EOF >> instackenv.json
    {
      "pm_type": "pxe_ipmitool",
      "pm_addr": "$pm_ip",
      "pm_port": "$pm_port",
      "pm_user": "$IPMI_USER",
      "pm_password": "$IPMI_PASSWORD",
      "mac": [
        "$mac"
      ],
      "cpu": "2",
      "memory": "1000",
      "disk": "29",
      "arch": "x86_64",
      "capabilities": "$caps"
    },
EOF
}

# create overcloud machines definition
cat << EOF > instackenv.json
{
  "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
  "arch": "x86_64",
  "nodes": [
EOF

unset vbmc_ip
unset vbmc_port
unset mac

node_type=controller
node_number=0
for node in $(echo $overcloud_cont_instance | sed 's/,/ /g') ; do
  vbmc_ip=$(get_vbmc_ip $node)
  vbmc_port=$(get_vbmc_port $node)
  mac=$(get_macs $node)
  define_machine "node:overcloud-${node_type}-${node_number},boot_option:local" $mac $vbmc_ip $vbmc_port
  ((++node_number))
done

node_type=novacompute
node_number=0
for node in $(echo $overcloud_compute_instance | sed 's/,/ /g') ; do
  vbmc_ip=$(get_vbmc_ip $node)
  vbmc_port=$(get_vbmc_port $node)
  mac=$(get_macs $node)
  define_machine "node:overcloud-${node_type}-${node_number},boot_option:local" $mac $vbmc_ip $vbmc_port
  ((++node_number))
done

node=$overcloud_ctrlcont_instance
vbmc_ip=$(get_vbmc_ip $node)
vbmc_port=$(get_vbmc_port $node)
mac=$(get_macs $node)
define_machine "node:overcloud-contrailcontroller-0,boot_option:local" $mac $vbmc_ip $vbmc_port

# remove last comma
head -n -1 instackenv.json > instackenv.json.tmp
mv instackenv.json.tmp instackenv.json
cat << EOF >> instackenv.json
    }
  ]
}
EOF

# check this json (it's optional)
# curl --silent -O https://raw.githubusercontent.com/rthallisey/clapper/master/instackenv-validator.py
# python3 instackenv-validator.py -f ~/instackenv.json



