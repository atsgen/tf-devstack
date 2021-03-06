
#Undercloud
export prov_cidr="${prov_cidr}"
export prov_subnet_len="${prov_subnet_len}"

export prov_inspection_iprange="${prov_inspection_iprange}"
export prov_dhcp_start="${prov_dhcp_start}"
export prov_dhcp_end="${prov_dhcp_end}"

export prov_ip="${prov_ip}"
export prov_ip_cidr="${prov_ip_cidr}"

export fixed_vip="${fixed_vip}"

export domain="${domain}"

export undercloud_instance="${undercloud_instance}"

export ipa_instance="${ipa_instance}"
export ipa_mgmt_ip="${ipa_mgmt_ip}"
export ipa_prov_ip="${ipa_prov_ip}"

#RHOSP16 additional parameters for undercloud.conf
export undercloud_admin_host="${undercloud_admin_host}"
export undercloud_public_host="${undercloud_public_host}"

#Prov IPs for overcloud nodes
export overcloud_cont_prov_ip="${overcloud_cont_prov_ip}"
export overcloud_compute_prov_ip="${overcloud_compute_prov_ip}"
export overcloud_ctrlcont_prov_ip="${overcloud_ctrlcont_prov_ip}"

export overcloud_cont_instance="${overcloud_cont_instance}"
export overcloud_compute_instance="${overcloud_compute_instance}"
export overcloud_ctrlcont_instance="${overcloud_ctrlcont_instance}"
