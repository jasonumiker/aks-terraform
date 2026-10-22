resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
  admin  = coalesce(var.admin_principal_id, data.azapi_client_config.current.object_id)
  # Built-in role: Network Contributor
  role_definitions                = "/subscriptions/${data.azapi_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions"
  network_contributor_role_id     = "${local.role_definitions}/4d97b98b-1d4f-4787-a291-c67834d212e7"
  monitoring_reader_role_id       = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
  monitoring_data_reader_role_id  = "b0d8363b-8ddd-447d-831f-62ca05bff136"
  acr_pull_role_id                = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
  key_vault_secrets_user_role_id  = "4633458b-17de-408a-b874-0445c86b69e6"
  key_vault_administrator_role_id = "00482a5a-887f-4fb3-b363-3b7fe8e74483"
  acr_name                        = "acr${replace(var.name_prefix, "-", "")}${local.suffix}"
  grafana_admin_role_id           = "22926164-76b3-42b3-bc55-97df8dab3e41"
}

resource "azapi_resource" "resource_group" {
  type                   = "Microsoft.Resources/resourceGroups@2024-03-01"
  name                   = "rg-${var.name_prefix}-${local.suffix}"
  location               = var.location
  parent_id              = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  response_export_values = []
}

# Monitoring
resource "azapi_resource" "log_analytics_workspace" {
  type      = "Microsoft.OperationalInsights/workspaces@2023-09-01"
  name      = "log-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    properties = {
      retentionInDays = 30
      sku             = { name = "PerGB2018" }
    }
  }
  response_export_values = []
}

resource "azapi_resource" "monitor_workspace" {
  type      = "Microsoft.Monitor/accounts@2023-04-03"
  name      = "prom-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    properties = {}
  }
  response_export_values = []
}

# Managed Grafana, wired to the Prometheus workspace
resource "azapi_resource" "grafana" {
  count = var.enable_grafana ? 1 : 0

  type      = "Microsoft.Dashboard/grafana@2023-09-01"
  name      = "graf-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  identity {
    type = "SystemAssigned"
  }
  body = {
    sku = { name = "Standard" }
    properties = {
      publicNetworkAccess = "Enabled"
      grafanaIntegrations = {
        azureMonitorWorkspaceIntegrations = [{
          azureMonitorWorkspaceResourceId = azapi_resource.monitor_workspace.id
        }]
      }
    }
  }
  response_export_values = ["identity.principalId", "properties.endpoint"]
}

resource "random_uuid" "grafana_monitoring_reader" {
  count = var.enable_grafana ? 1 : 0
}

# Lets Grafana read Azure Monitor data in the resource group
resource "azapi_resource" "grafana_monitoring_reader" {
  count = var.enable_grafana ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.grafana_monitoring_reader[0].result
  parent_id = azapi_resource.resource_group.id
  body = {
    properties = {
      principalId      = azapi_resource.grafana[0].output.identity.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = "${local.role_definitions}/${local.monitoring_reader_role_id}"
    }
  }
  response_export_values = []
  retry = {
    error_message_regex  = ["PrincipalNotFound", "does not exist in the directory"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }
}

resource "random_uuid" "grafana_prometheus_reader" {
  count = var.enable_grafana ? 1 : 0
}

# Lets Grafana query the Prometheus workspace
resource "azapi_resource" "grafana_prometheus_reader" {
  count = var.enable_grafana ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.grafana_prometheus_reader[0].result
  parent_id = azapi_resource.monitor_workspace.id
  body = {
    properties = {
      principalId      = azapi_resource.grafana[0].output.identity.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = "${local.role_definitions}/${local.monitoring_data_reader_role_id}"
    }
  }
  response_export_values = []
  retry = {
    error_message_regex  = ["PrincipalNotFound", "does not exist in the directory"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }
}

resource "random_uuid" "grafana_admin" {
  count = var.enable_grafana ? 1 : 0
}

resource "azapi_resource" "grafana_admin" {
  count = var.enable_grafana ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.grafana_admin[0].result
  parent_id = azapi_resource.grafana[0].id
  body = {
    properties = {
      principalId      = local.admin
      principalType    = var.admin_principal_type
      roleDefinitionId = "${local.role_definitions}/${local.grafana_admin_role_id}"
    }
  }
  response_export_values = []
}

# Networking
resource "azapi_resource" "virtual_network" {
  type      = "Microsoft.Network/virtualNetworks@2024-05-01"
  name      = "vnet-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    properties = {
      addressSpace = { addressPrefixes = [var.vnet_address_space] }
    }
  }
  response_export_values = []
}

resource "azapi_resource" "public_ip_nat_gateway" {
  type      = "Microsoft.Network/publicIPAddresses@2024-05-01"
  name      = "pip-nat-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    sku   = { name = "Standard", tier = "Regional" }
    zones = ["1", "2", "3"]
    properties = {
      publicIPAllocationMethod = "Static"
      publicIPAddressVersion   = "IPv4"
    }
  }
  response_export_values = []
}

resource "azapi_resource" "nat_gateway" {
  type      = "Microsoft.Network/natGateways@2024-05-01"
  name      = "nat-${var.name_prefix}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    sku = { name = "Standard" }
    properties = {
      idleTimeoutInMinutes = 4
      publicIpAddresses    = [{ id = azapi_resource.public_ip_nat_gateway.id }]
    }
  }
  response_export_values = []
}

# Subnets are created serially to avoid concurrent-write conflicts on the VNet.
resource "azapi_resource" "subnet_api_server" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "apiServerSubnet"
  parent_id = azapi_resource.virtual_network.id
  body = {
    properties = {
      addressPrefix = var.api_server_subnet_prefix
      delegations = [{
        name = "aks-apiserver"
        properties = {
          serviceName = "Microsoft.ContainerService/managedClusters"
        }
      }]
    }
  }
  response_export_values = []
}

resource "azapi_resource" "subnet_cluster" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "clusterSubnet"
  parent_id = azapi_resource.virtual_network.id
  body = {
    properties = {
      addressPrefix = var.cluster_subnet_prefix
      natGateway    = { id = azapi_resource.nat_gateway.id }
    }
  }
  response_export_values = []

  depends_on = [azapi_resource.subnet_api_server]
}

resource "azapi_resource" "subnet_system" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "systemSubnet"
  parent_id = azapi_resource.virtual_network.id
  body = {
    properties = {
      addressPrefix = var.system_subnet_prefix
      natGateway    = { id = azapi_resource.nat_gateway.id }
    }
  }
  response_export_values = []

  lifecycle {
    ignore_changes = [body.properties.delegations]
  }
  depends_on = [azapi_resource.subnet_cluster]
}

# Cluster identity (needed up front so it can be granted rights on the VNet)
resource "azapi_resource" "user_assigned_identity" {
  type                   = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name                   = "id-${var.name_prefix}-${local.suffix}"
  location               = azapi_resource.resource_group.location
  parent_id              = azapi_resource.resource_group.id
  response_export_values = ["properties.principalId"]
}

resource "random_uuid" "network_contributor" {}

resource "azapi_resource" "network_contributor" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.network_contributor.result
  parent_id = azapi_resource.virtual_network.id
  body = {
    properties = {
      principalId      = azapi_resource.user_assigned_identity.output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.network_contributor_role_id
    }
  }
  response_export_values = []
  # The identity may not have replicated to Entra ID yet.
  retry = {
    error_message_regex  = ["PrincipalNotFound", "does not exist in the directory"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }
}

# Container registry
resource "azapi_resource" "container_registry" {
  count = var.enable_container_registry ? 1 : 0

  type      = "Microsoft.ContainerRegistry/registries@2023-07-01"
  name      = local.acr_name
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    sku = { name = var.acr_sku }
    properties = {
      adminUserEnabled = false
    }
  }
  response_export_values = []
}

# Key Vault (Azure RBAC authorization)
resource "azapi_resource" "key_vault" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = "kv-${substr(replace(var.name_prefix, "-", ""), 0, 12)}-${local.suffix}"
  location  = azapi_resource.resource_group.location
  parent_id = azapi_resource.resource_group.id
  body = {
    properties = {
      tenantId                  = data.azapi_client_config.current.tenant_id
      sku                       = { family = "A", name = "standard" }
      enableRbacAuthorization   = true
      enableSoftDelete          = true
      softDeleteRetentionInDays = 7
      enablePurgeProtection     = true
      publicNetworkAccess       = "Disabled"
    }
  }
  response_export_values = []
}

resource "azapi_resource" "subnet_private_endpoints" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "privateEndpointsSubnet"
  parent_id = azapi_resource.virtual_network.id
  body = {
    properties = {
      addressPrefix                  = var.private_endpoints_subnet_prefix
      privateEndpointNetworkPolicies = "Disabled"
    }
  }
  response_export_values = []

  depends_on = [azapi_resource.subnet_system]
}

resource "azapi_resource" "key_vault_private_dns" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Network/privateDnsZones@2024-06-01"
  name      = "privatelink.vaultcore.azure.net"
  parent_id = azapi_resource.resource_group.id
  location  = "global"
  body = {
    properties = {}
  }
  response_export_values = []
}

resource "azapi_resource" "key_vault_private_dns_link" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01"
  name      = "aks-vnet"
  parent_id = azapi_resource.key_vault_private_dns[0].id
  location  = "global"
  body = {
    properties = {
      registrationEnabled = false
      virtualNetwork      = { id = azapi_resource.virtual_network.id }
    }
  }
  response_export_values = []
}

resource "azapi_resource" "key_vault_private_endpoint" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Network/privateEndpoints@2024-05-01"
  name      = "pe-${azapi_resource.key_vault[0].name}"
  parent_id = azapi_resource.resource_group.id
  location  = azapi_resource.resource_group.location
  body = {
    properties = {
      subnet = { id = azapi_resource.subnet_private_endpoints[0].id }
      privateLinkServiceConnections = [{
        name = "key-vault"
        properties = {
          privateLinkServiceId = azapi_resource.key_vault[0].id
          groupIds             = ["vault"]
        }
      }]
    }
  }
  response_export_values = []
}

resource "azapi_resource" "key_vault_private_dns_group" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01"
  name      = "default"
  parent_id = azapi_resource.key_vault_private_endpoint[0].id
  body = {
    properties = {
      privateDnsZoneConfigs = [{
        name       = "key-vault"
        properties = { privateDnsZoneId = azapi_resource.key_vault_private_dns[0].id }
      }]
    }
  }
  response_export_values = []
}

resource "random_uuid" "acr_pull" {
  count = var.enable_container_registry ? 1 : 0
}

# Kubelet identity pulls images from the registry
resource "azapi_resource" "acr_pull" {
  count = var.enable_container_registry ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.acr_pull[0].result
  parent_id = azapi_resource.container_registry[0].id
  body = {
    properties = {
      principalId      = module.aks_standard.kubelet_identity.objectId
      principalType    = "ServicePrincipal"
      roleDefinitionId = "${local.role_definitions}/${local.acr_pull_role_id}"
    }
  }
  response_export_values = []
}

resource "random_uuid" "kv_secrets_user" {
  count = var.enable_key_vault ? 1 : 0
}

# Secrets Store CSI driver identity reads secrets
resource "azapi_resource" "kv_secrets_user" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.kv_secrets_user[0].result
  parent_id = azapi_resource.key_vault[0].id
  body = {
    properties = {
      principalId      = module.aks_standard.key_vault_secrets_provider_identity.objectId
      principalType    = "ServicePrincipal"
      roleDefinitionId = "${local.role_definitions}/${local.key_vault_secrets_user_role_id}"
    }
  }
  response_export_values = []
}

resource "random_uuid" "kv_admin" {
  count = var.enable_key_vault ? 1 : 0
}

resource "azapi_resource" "kv_admin" {
  count = var.enable_key_vault ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = random_uuid.kv_admin[0].result
  parent_id = azapi_resource.key_vault[0].id
  body = {
    properties = {
      principalId      = local.admin
      principalType    = var.admin_principal_type
      roleDefinitionId = "${local.role_definitions}/${local.key_vault_administrator_role_id}"
    }
  }
  response_export_values = []
}

# Stoppable lab cluster: system components and demo workloads share one VMSS pool.
module "aks_standard" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.5"

  name             = "aks-${var.name_prefix}-${local.suffix}"
  location         = azapi_resource.resource_group.location
  parent_id        = azapi_resource.resource_group.id
  enable_telemetry = var.enable_telemetry

  sku = {
    name = "Base"
    tier = "Standard"
  }

  managed_identities = {
    user_assigned_resource_ids = [azapi_resource.user_assigned_identity.id]
  }

  api_server_access_profile = {
    enable_vnet_integration = true
    subnet_id               = azapi_resource.subnet_api_server.id
  }

  default_agent_pool = {
    name                = "systempool"
    count_of            = var.system_node_count
    vm_size             = var.system_node_vm_size
    availability_zones  = ["1", "2", "3"]
    os_sku              = "AzureLinux"
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = false
    node_taints         = []
    vnet_subnet_id      = azapi_resource.subnet_cluster.id
    upgrade_settings = {
      max_surge = "33%"
    }
  }

  node_provisioning_profile = {
    mode               = "Manual"
    default_node_pools = "None"
  }

  enable_rbac            = true
  disable_local_accounts = true
  aad_profile = {
    managed           = true
    enable_azure_rbac = true
    tenant_id         = data.azapi_client_config.current.tenant_id
  }

  oidc_issuer_profile = {
    enabled = true
  }

  security_profile = {
    workload_identity = {
      enabled = true
    }
    image_cleaner = {
      enabled        = true
      interval_hours = 168
    }
  }

  addon_profile_azure_policy = {
    enabled = true
  }

  ingress_profile = {
    web_app_routing = {
      enabled = true
    }
  }

  auto_upgrade_profile = {
    upgrade_channel         = "stable"
    node_os_upgrade_channel = "NodeImage"
  }

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
  }

  addon_profile_key_vault_secrets_provider = var.enable_key_vault ? {
    enabled = true
    config = {
      enable_secret_rotation = true
    }
  } : null

  addon_profile_oms_agent = {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = azapi_resource.log_analytics_workspace.id
      use_aad_auth                        = true
    }
  }

  onboard_monitoring      = true
  prometheus_workspace_id = azapi_resource.monitor_workspace.id
  onboard_alerts          = var.alert_email != null
  alert_email             = var.alert_email

  azure_monitor_profile = {
    metrics = {
      enabled = true
    }
  }

  maintenanceconfiguration = {
    aksManagedAutoUpgradeSchedule = {
      name = "aksManagedAutoUpgradeSchedule"
      maintenance_window = {
        duration_hours = 4
        start_time     = "00:00"
        utc_offset     = "+00:00"
        start_date     = "2025-09-27"
        schedule = {
          weekly = {
            day_of_week    = "Sunday"
            interval_weeks = 1
          }
        }
      }
    }
  }

  role_assignments = {
    admin = {
      principal_id               = local.admin
      role_definition_id_or_name = "Azure Kubernetes Service RBAC Admin"
    }
  }

  depends_on = [
    azapi_resource.network_contributor,
    azapi_resource.subnet_system,
  ]
}

# Control-plane logs to Log Analytics (kube-audit-admin avoids the cost of full kube-audit)
resource "azapi_resource" "aks_diagnostic_settings" {
  count = var.enable_diagnostic_settings ? 1 : 0

  # Azure returns additional disabled categories and may reorder the log list.
  list_unique_id_property    = { "properties.logs" = "category" }
  ignore_other_items_in_list = ["properties.logs"]

  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "diag-${var.name_prefix}-${local.suffix}"
  parent_id = module.aks_standard.resource_id
  body = {
    properties = {
      workspaceId                 = azapi_resource.log_analytics_workspace.id
      logAnalyticsDestinationType = "Dedicated"
      logs = [
        for category in var.aks_log_categories : {
          category = category
          enabled  = true
        }
      ]
      metrics = [{
        category = "AllMetrics"
        enabled  = true
      }]
    }
  }
  response_export_values = []
}
