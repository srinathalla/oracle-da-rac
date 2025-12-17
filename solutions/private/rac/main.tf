#############################
# Create RHEL VM
# Create AIX VM
# Initialize RHEL VM
# Intitialize AIX VM
# Download Oracle binaries from cos
# Install GRID and RDBMS and Create Oracle Database
#############################

locals {
  nfs_mount = "/repos"

  pi_boot_volume = {
    "name" : "rootvg",
    "size" : "40",
    "count" : "1",
    "tier" : "tier1"
  }

  pi_crsdg_volume = {
    "name" : "CRSDG",
    "size" : "8",
    "count" : "4",
    "tier" : "tier1"
  }
}

###########################################################
# Create RHEL Management VM
###########################################################
module "pi_instance_rhel" {
  source  = "terraform-ibm-modules/powervs-instance/ibm"
  version = "2.7.0"

  pi_workspace_guid       = var.pi_existing_workspace_guid
  pi_ssh_public_key_name  = var.pi_ssh_public_key_name
  pi_image_id             = var.pi_rhel_image_name
  pi_networks             = var.pi_networks
  pi_instance_name        = "${var.prefix}-mgmt-rhel"
  pi_memory_size          = "4"
  pi_number_of_processors = ".25"
  pi_server_type          = var.pi_rhel_management_server_type
  pi_cpu_proc_type        = "shared"
  pi_storage_config = [{
    name  = "nfs"
    size  = "50"
    count = "1"
    tier  = "tier3"
    mount = local.nfs_mount
  }]
}

###########################################################
# Create AIX VM for Oracle RAC database
###########################################################

module "pi_instance_aix" {
  source  = "terraform-ibm-modules/powervs-instance/ibm"
  version = "2.7.0"

  # Number of RAC nodes
  count = var.rac_nodes

  pi_replicants = {
    count  = 1
    policy = "affinity"
  }

  pi_workspace_guid          = var.pi_existing_workspace_guid
  pi_ssh_public_key_name     = var.pi_ssh_public_key_name
  pi_image_id                = var.pi_aix_image_name
  pi_networks                = var.pi_networks
  pi_instance_name           = "${var.prefix}-aix-${count.index + 1}"
  pi_pin_policy              = var.pi_aix_instance.pin_policy
  pi_server_type             = var.pi_aix_instance.server_type
  pi_number_of_processors    = var.pi_aix_instance.number_processors
  pi_memory_size             = var.pi_aix_instance.memory_size
  pi_cpu_proc_type           = var.pi_aix_instance.cpu_proc_type
  pi_boot_image_storage_tier = "tier1"
  pi_user_tags               = var.pi_user_tags
}

data "ibm_pi_instance" "all_instances" {
  depends_on           = [module.pi_instance_aix]
  count                = var.rac_nodes
  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_instance_name     = "${var.prefix}-aix-${count.index + 1}"
}

locals {
  hosts_and_vars = {
    for idx in range(var.rac_nodes) :
    data.ibm_pi_instance.all_instances[idx].pi_instance_name => {
      ip = [
        for n in data.ibm_pi_instance.all_instances[idx].networks :
        n.ip if n.network_name == "ora_10_80_40"
      ][0]

      # Get WWN from the node_rootvg volume (the 40GB extension disk)
      EXTEND_ROOT_VOLUME_WWN = ibm_pi_volume.node_rootvg[idx].wwn
    }
  }
}



#####################################################
# Create Local and Shared Volumes
#####################################################

# --- Locals ---
locals {

  aix_instance_ids = [
    for i in range(var.rac_nodes) : data.ibm_pi_instance.all_instances[i].id
  ]

  expanded_shared_volumes = flatten([
    for vol in [local.pi_crsdg_volume, var.pi_data_volume, var.pi_redo_volume, var.pi_gimr_volume] : [
      for i in range(tonumber(vol.count)) : {
        name = "${lower(vol.name)}-${i + 1}"
        size = vol.size
        tier = vol.tier
      }
    ]
  ])

  shared_count = length(local.expanded_shared_volumes)
}

# --- Node-local volumes: rootvg and oravg  ---
resource "ibm_pi_volume" "node_rootvg" {
  depends_on = [data.ibm_pi_instance.all_instances]
  count      = var.rac_nodes

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_volume_name       = "${var.prefix}-aix-${count.index + 1}-${local.pi_boot_volume.name}"
  pi_volume_size       = local.pi_boot_volume.size
  pi_volume_type       = local.pi_boot_volume.tier
  pi_volume_shareable  = false
  pi_user_tags         = var.pi_user_tags
}

resource "ibm_pi_volume" "node_oravg" {
  depends_on = [ibm_pi_volume.node_rootvg]
  count      = var.rac_nodes

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_volume_name       = "${var.prefix}-aix-${count.index + 1}-${var.pi_oravg_volume.name}"
  pi_volume_size       = var.pi_oravg_volume.size
  pi_volume_type       = var.pi_oravg_volume.tier
  pi_volume_shareable  = false
  pi_user_tags         = var.pi_user_tags
}

# --- Shared volumes ---
resource "ibm_pi_volume" "shared" {
  depends_on = [ibm_pi_volume.node_oravg]
  count      = local.shared_count

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_volume_name       = "${var.prefix}-asm-${local.expanded_shared_volumes[count.index].name}"
  pi_volume_size       = local.expanded_shared_volumes[count.index].size
  pi_volume_type       = local.expanded_shared_volumes[count.index].tier
  pi_volume_shareable  = true
  pi_user_tags         = var.pi_user_tags

}

# --- Attach node-local volumes ---
resource "ibm_pi_volume_attach" "node_rootvg_attach" {
  count = var.rac_nodes

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_instance_id       = local.aix_instance_ids[count.index]
  pi_volume_id         = ibm_pi_volume.node_rootvg[count.index].volume_id

  depends_on = [
    ibm_pi_volume.node_rootvg
  ]

  lifecycle {
    ignore_changes = [pi_instance_id]
  }
}

resource "ibm_pi_volume_attach" "node_oravg_attach" {
  count = var.rac_nodes

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_instance_id       = local.aix_instance_ids[count.index]
  pi_volume_id         = ibm_pi_volume.node_oravg[count.index].volume_id

  depends_on = [
    ibm_pi_volume.node_oravg
  ]

  lifecycle {
    ignore_changes = [pi_instance_id]
  }
}

# --- Attach shared volumes to each node  ---
resource "ibm_pi_volume_attach" "shared_attach" {
  count = var.rac_nodes * local.shared_count

  pi_cloud_instance_id = var.pi_existing_workspace_guid
  pi_instance_id       = local.aix_instance_ids[floor(count.index / local.shared_count)]
  pi_volume_id         = element([for v in ibm_pi_volume.shared : v.volume_id], count.index % local.shared_count)

  depends_on = [
    ibm_pi_volume.shared
  ]

  lifecycle {
    ignore_changes = [pi_instance_id]
  }
}

###########################################################
# Ansible Host setup and configure as Proxy, NTP and DNS
###########################################################

locals {
  network_services_config = {
    squid = {
      enable     = true
      squid_port = "3128"
    }
    dns = {
      enable      = true
      dns_servers = "161.26.0.7; 161.26.0.8; 9.9.9.9;"
    }
    ntp = {
      enable = true
    }
  }
}

module "pi_instance_rhel_init" {
  source     = "../../../modules/ansible"
  depends_on = [module.pi_instance_rhel]

  bastion_host_ip        = var.bastion_host_ip
  ansible_host_or_ip     = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key        = var.ssh_private_key
  configure_ansible_host = true
  squid_server_ip        = var.squid_server_ip

  src_script_template_name = "configure-rhel-management/ansible_exec.sh.tftpl"
  dst_script_file_name     = "configure-rhel-management.sh"

  src_playbook_template_name = "configure-rhel-management/playbook-configure-network-services.yml.tftpl"
  dst_playbook_file_name     = "configure-rhel-management-playbook.yml"

  playbook_template_vars = {
    server_config     = jsonencode(local.network_services_config)
    pi_storage_config = jsonencode(module.pi_instance_rhel.pi_storage_configuration)
    nfs_config = jsonencode({
      nfs = {
        enable      = true
        directories = [local.nfs_mount]
      }
    })
  }

  src_inventory_template_name = "inventory.tftpl"
  dst_inventory_file_name     = "configure-rhel-management-inventory"
  inventory_template_vars = {
    host_or_ip = [module.pi_instance_rhel.pi_instance_primary_ip]
  }

}

###########################################################
# AIX Initialization
###########################################################

locals {
  squid_server_ip = var.squid_server_ip

  aix_primary_ips = [
    for inst in module.pi_instance_aix : inst.pi_instance_primary_ip
  ]

  aix_rootvg_wwns = [
    for inst in module.pi_instance_aix : inst.pi_storage_configuration[0].wwns
  ]

  playbook_aix_init_vars = {
    PROXY_IP_PORT  = "${local.squid_server_ip}:3128"
    NO_PROXY       = "TODO"
    ORA_NFS_HOST   = join(",", local.aix_primary_ips)
    ORA_NFS_DEVICE = local.nfs_mount
    AIX_INIT_MODE  = "rac"
    ROOT_PASSWORD  = var.root_password
  }
}

module "pi_instance_aix_init" {
  source     = "../../../modules/ansible"
  depends_on = [module.pi_instance_rhel_init]

  bastion_host_ip        = var.bastion_host_ip
  ansible_host_or_ip     = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key        = var.ssh_private_key
  configure_ansible_host = false
  squid_server_ip        = local.squid_server_ip

  src_script_template_name = "aix-init/ansible_exec.sh.tftpl"
  dst_script_file_name     = "aix_init.sh"

  src_playbook_template_name = "aix-init/playbook-aix-init.yml.tftpl"
  dst_playbook_file_name     = "aix-init-playbook.yml"
  playbook_template_vars     = local.playbook_aix_init_vars

  src_inventory_template_name = "inventory.tftpl"
  dst_inventory_file_name     = "aix-init-inventory"
  inventory_template_vars = {
    host_or_ip     = local.aix_primary_ips
    hosts_and_vars = local.hosts_and_vars
  }

}

######################################################
# COS Service credentials
# Download Oracle binaries
# from IBM Cloud Object Storage(COS) to Ansible host
# host NFS mount point
######################################################

locals {
  cos_service_credentials  = jsondecode(var.ibmcloud_cos_service_credentials)
  cos_apikey               = local.cos_service_credentials.apikey
  cos_resource_instance_id = local.cos_service_credentials.resource_instance_id
}

locals {

  ibmcloud_cos_oracle_configuration = {
    cos_apikey               = local.cos_apikey
    cos_region               = var.ibmcloud_cos_configuration.cos_region
    cos_resource_instance_id = local.cos_resource_instance_id
    cos_bucket_name          = var.ibmcloud_cos_configuration.cos_bucket_name
    cos_dir_name             = var.ibmcloud_cos_configuration.cos_oracle_database_sw_path
    download_dir_path        = "${local.nfs_mount}"
  }

  ibmcloud_cos_grid_configuration = {
    cos_apikey               = local.cos_apikey
    cos_region               = var.ibmcloud_cos_configuration.cos_region
    cos_resource_instance_id = local.cos_resource_instance_id
    cos_bucket_name          = var.ibmcloud_cos_configuration.cos_bucket_name
    cos_dir_name             = var.ibmcloud_cos_configuration.cos_oracle_grid_sw_path
    download_dir_path        = "${local.nfs_mount}"
  }

  ibmcloud_cos_patch_configuration = {
    cos_apikey               = local.cos_apikey
    cos_region               = var.ibmcloud_cos_configuration.cos_region
    cos_resource_instance_id = local.cos_resource_instance_id
    cos_bucket_name          = var.ibmcloud_cos_configuration.cos_bucket_name
    cos_dir_name             = var.ibmcloud_cos_configuration.cos_oracle_ru_file_path
    download_dir_path        = "${local.nfs_mount}"
  }

  ibmcloud_cos_opatch_configuration = {
    cos_apikey               = local.cos_apikey
    cos_region               = var.ibmcloud_cos_configuration.cos_region
    cos_resource_instance_id = local.cos_resource_instance_id
    cos_bucket_name          = var.ibmcloud_cos_configuration.cos_bucket_name
    cos_dir_name             = var.ibmcloud_cos_configuration.cos_oracle_opatch_file_path
    download_dir_path        = "${local.nfs_mount}"
  }

  ibmcloud_cos_cluvfy_configuration = {
    cos_apikey               = local.cos_apikey
    cos_region               = var.ibmcloud_cos_configuration.cos_region
    cos_resource_instance_id = local.cos_resource_instance_id
    cos_bucket_name          = var.ibmcloud_cos_configuration.cos_bucket_name
    cos_dir_name             = var.ibmcloud_cos_configuration.cos_oracle_cluvfy_file_path
    download_dir_path        = "${local.nfs_mount}"
  }
}

module "ibmcloud_cos_oracle" {
  source     = "../../../modules/ibmcloud-cos"
  depends_on = [module.pi_instance_rhel_init]

  access_host_or_ip          = var.bastion_host_ip
  target_server_ip           = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key            = var.ssh_private_key
  ibmcloud_cos_configuration = local.ibmcloud_cos_oracle_configuration
}

module "ibmcloud_cos_patch" {
  source     = "../../../modules/ibmcloud-cos"
  depends_on = [module.ibmcloud_cos_oracle]

  access_host_or_ip          = var.bastion_host_ip
  target_server_ip           = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key            = var.ssh_private_key
  ibmcloud_cos_configuration = local.ibmcloud_cos_patch_configuration
}

module "ibmcloud_cos_opatch" {
  source     = "../../../modules/ibmcloud-cos"
  depends_on = [module.ibmcloud_cos_patch]

  access_host_or_ip          = var.bastion_host_ip
  target_server_ip           = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key            = var.ssh_private_key
  ibmcloud_cos_configuration = local.ibmcloud_cos_opatch_configuration
}

module "ibmcloud_cos_grid" {
  source     = "../../../modules/ibmcloud-cos"
  depends_on = [module.ibmcloud_cos_opatch]
  count      = var.oracle_install_type == "ASM" ? 1 : 0

  access_host_or_ip          = var.bastion_host_ip
  target_server_ip           = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key            = var.ssh_private_key
  ibmcloud_cos_configuration = local.ibmcloud_cos_grid_configuration
}

module "ibmcloud_cos_cluvfy" {
  source     = "../../../modules/ibmcloud-cos"
  depends_on = [module.ibmcloud_cos_opatch]
  count      = var.oracle_install_type == "ASM" ? 1 : 0

  access_host_or_ip          = var.bastion_host_ip
  target_server_ip           = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key            = var.ssh_private_key
  ibmcloud_cos_configuration = local.ibmcloud_cos_cluvfy_configuration
}

###########################################################
# Oracle GRID Installation on AIX
###########################################################

 locals {
  node1 = {
    name = data.ibm_pi_instance.all_instances[0].pi_instance_name
    fqdn = "${data.ibm_pi_instance.all_instances[0].pi_instance_name}.${var.cluster_domain}"

    pub_ip = one([
      for net in data.ibm_pi_instance.all_instances[0].networks :
      net.ip if can(regex("pub|public", lower(net.network_name)))
    ])

    priv1_ip = one([
      for net in data.ibm_pi_instance.all_instances[0].networks :
      net.ip if can(regex("priv1|private1", lower(net.network_name)))
    ])

    priv2_ip = one([
      for net in data.ibm_pi_instance.all_instances[0].networks :
      net.ip if can(regex("priv2|private2", lower(net.network_name)))
    ])
  }

  node2 = {
    name = data.ibm_pi_instance.all_instances[1].pi_instance_name
    fqdn = "${data.ibm_pi_instance.all_instances[1].pi_instance_name}.${var.cluster_domain}"

    pub_ip = one([
      for net in data.ibm_pi_instance.all_instances[1].networks :
      net.ip if can(regex("pub|public", lower(net.network_name)))
    ])

    priv1_ip = one([
      for net in data.ibm_pi_instance.all_instances[1].networks :
      net.ip if can(regex("priv1|private1", lower(net.network_name)))
    ])

    priv2_ip = one([
      for net in data.ibm_pi_instance.all_instances[1].networks :
      net.ip if can(regex("priv2|private2", lower(net.network_name)))
    ])
  }

  # Build cluster_nodes
  cluster_nodes = join(",", [
    for idx in range(var.rac_nodes) :
    "${data.ibm_pi_instance.all_instances[idx].pi_instance_name}:${data.ibm_pi_instance.all_instances[idx].pi_instance_name}-vip"
  ])


  playbook_oracle_install_vars = {
    ORA_NFS_HOST    = module.pi_instance_rhel.pi_instance_primary_ip
    ORA_NFS_DEVICE  = local.nfs_mount
    DNS_SERVER_IP   = var.dns_server_ip
    DATABASE_SW     = "${local.nfs_mount}/${var.ibmcloud_cos_configuration.cos_oracle_database_sw_path}"
    GRID_SW         = "${local.nfs_mount}/${var.ibmcloud_cos_configuration.cos_oracle_grid_sw_path}"
    RU_FILE         = "${local.nfs_mount}/${var.ibmcloud_cos_configuration.cos_oracle_ru_file_path}"
    OPATCH_FILE     = "${local.nfs_mount}/${var.ibmcloud_cos_configuration.cos_oracle_opatch_file_path}"
    CLUVFY_FILE     = "${local.nfs_mount}/${var.ibmcloud_cos_configuration.cos_oracle_cluvfy_file_path}"
    RU_VERSION      = var.ru_version
    ORA_SID         = var.ora_sid
    ROOT_PASSWORD   = var.root_password
    ORA_DB_PASSWORD = var.ora_db_password
    TIME_ZONE       = var.time_zone
    CLUSTER_DOMAIN  = var.cluster_domain
    CLUSTER_NAME    = var.cluster_name
    CLUSTER_NODES   = local.cluster_nodes
    node1_name     = local.node1.name
    node1_fqdn     = local.node1.fqdn
    node1_pub_ip   = local.node1.pub_ip
    node1_priv1_ip = local.node1.priv1_ip
    node1_priv2_ip = local.node1.priv2_ip

    node2_name     = local.node2.name
    node2_fqdn     = local.node2.fqdn
    node2_pub_ip   = local.node2.pub_ip
    node2_priv1_ip = local.node2.priv1_ip
    node2_priv2_ip = local.node2.priv2_ip

    netmask_pub = "255.255.252.0"
    netmask_pvt = "255.255.255.0"

      node1_pub_if   = "en1"
      node1_priv1_if = "en2"
      node1_priv2_if = "en3"

      node2_pub_if   = "en1"
      node2_priv1_if = "en2"
      node2_priv2_if = "en3"

  }
}

module "oracle_install" {
  source     = "../../../modules/ansible"
  depends_on = [module.ibmcloud_cos_grid, module.pi_instance_aix_init]

  bastion_host_ip        = var.bastion_host_ip
  ansible_host_or_ip     = module.pi_instance_rhel.pi_instance_primary_ip
  ssh_private_key        = var.ssh_private_key
  configure_ansible_host = false
  squid_server_ip        = local.squid_server_ip

  src_script_template_name = "oracle-grid-install-rac/ansible_exec.sh.tftpl"
  dst_script_file_name     = "oracle_install.sh"

  src_playbook_template_name = "oracle-grid-install-rac/playbook-install-oracle-grid.yml.tftpl"
  dst_playbook_file_name     = "playbook-install-oracle-grid.yml"
  playbook_template_vars     = local.playbook_oracle_install_vars

  src_vars_template_name = "oracle-grid-install-rac/rac_vars.yml.tftpl"
  dst_vars_file_name     = "rac_vars.yml"
  vars_template_vars     = local.playbook_oracle_install_vars

  src_inventory_template_name = "inventory.tftpl"
  dst_inventory_file_name     = "oracle-grid-install-inventory"
  inventory_template_vars = {
    host_or_ip     = local.aix_primary_ips
    hosts_and_vars = local.hosts_and_vars
  }
}