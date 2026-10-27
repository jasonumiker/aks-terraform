mock_provider "azapi" {
  override_during = plan

  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000001"
      tenant_id       = "00000000-0000-0000-0000-000000000002"
      object_id       = "00000000-0000-0000-0000-000000000003"
    }
  }

  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/mock"
      output = {
        identity = {
          principalId = "00000000-0000-0000-0000-000000000004"
        }
        properties = {
          principalId = "00000000-0000-0000-0000-000000000004"
          endpoint    = "https://grafana.example.test"
          identityProfile = {
            kubeletidentity = {
              objectId = "00000000-0000-0000-0000-000000000005"
            }
          }
          addonProfiles = {
            azureKeyvaultSecretsProvider = {
              identity = {
                objectId = "00000000-0000-0000-0000-000000000006"
              }
            }
          }
        }
      }
    }
  }

  mock_resource "azapi_resource_action" {
    defaults = {
      output = {
        kubeconfigs = [{
          value = "Y2x1c3RlcnM6Ci0gY2x1c3RlcjoKICAgIGNlcnRpZmljYXRlLWF1dGhvcml0eS1kYXRhOiB0ZXN0Cg=="
        }]
      }
    }
  }
}

mock_provider "random" {}

override_resource {
  target          = azapi_resource.user_assigned_identity
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock"
    output = {
      properties = {
        principalId = "00000000-0000-0000-0000-000000000004"
      }
    }
  }
}

override_resource {
  target          = module.aks_standard.azapi_resource.this
  override_during = plan
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/mock/providers/Microsoft.ContainerService/managedClusters/mock"
    output = {
      properties = {
        identityProfile = {
          kubeletidentity = {
            objectId = "00000000-0000-0000-0000-000000000005"
          }
        }
        addonProfiles = {
          azureKeyvaultSecretsProvider = {
            identity = {
              objectId = "00000000-0000-0000-0000-000000000006"
            }
          }
        }
      }
    }
  }
}

run "standard_defaults" {
  command = plan

  variables {
    enable_telemetry = false
  }

  assert {
    condition     = var.system_node_count == 2
    error_message = "The default lab must use two nodes shared by system components and demo workloads."
  }

  assert {
    condition     = length(azapi_resource.argocd) == 0
    error_message = "The Argo CD extension must be disabled by default."
  }

  assert {
    condition = (
      local.network_profile.outbound_type == "loadBalancer" &&
      local.network_profile.load_balancer_sku == "standard" &&
      local.network_profile.load_balancer_profile.managed_outbound_ips.count == 1
    )
    error_message = "The lab must use a Standard Load Balancer with one managed outbound IP instead of a NAT Gateway."
  }

  assert {
    condition = (
      local.network_profile.network_plugin == "azure" &&
      local.network_profile.network_plugin_mode == "overlay" &&
      local.network_profile.network_dataplane == "cilium"
    )
    error_message = "Changing outbound access must preserve Azure CNI Overlay and Cilium."
  }

  assert {
    condition = (
      azapi_resource.subnet_cluster.body.properties.natGateway == null &&
      azapi_resource.subnet_system.body.properties.natGateway == null
    )
    error_message = "Both node subnets must explicitly detach any existing NAT Gateway."
  }

  assert {
    condition     = local.local_dns_profile.mode == "Required"
    error_message = "The default lab must require LocalDNS rather than only validating its configuration."
  }

  assert {
    condition = (
      local.local_dns_profile.vnet_dns_overrides["."].forward_destination == "VnetDNS" &&
      local.local_dns_profile.kube_dns_overrides["."].forward_destination == "ClusterCoreDNS" &&
      alltrue([
        for overrides in [local.local_dns_profile.vnet_dns_overrides, local.local_dns_profile.kube_dns_overrides] :
        overrides["cluster.local"].forward_destination == "ClusterCoreDNS" &&
        overrides["cluster.local"].protocol == "ForceTCP" &&
        overrides["."].protocol == "PreferUDP"
      ])
    )
    error_message = "LocalDNS must preserve AKS default cluster and VNet DNS forwarding paths and protocols."
  }

  assert {
    condition = (
      local.workload_auto_scaler_profile.keda.enabled &&
      local.workload_auto_scaler_profile.vertical_pod_autoscaler.enabled
    )
    error_message = "The default lab must enable the managed KEDA and VPA add-ons."
  }

  assert {
    condition     = local.ingress_profile.gateway_api.installation == "Standard"
    error_message = "The cluster must install the Azure-managed Gateway API CRDs."
  }

  assert {
    condition = (
      local.ingress_profile.web_app_routing.enabled &&
      local.ingress_profile.web_app_routing.gateway_api_implementations.app_routing_istio.mode == "Enabled"
    )
    error_message = "The cluster must enable the Istio-backed application routing Gateway API implementation."
  }

  assert {
    condition     = local.ingress_profile.web_app_routing.nginx.default_ingress_controller_type == "None"
    error_message = "The cluster must not provision a default NGINX ingress controller."
  }

  assert {
    condition     = azapi_resource.acr_pull[0].body.properties.principalId == "00000000-0000-0000-0000-000000000005"
    error_message = "ACR must grant pull access to the Standard cluster's kubelet identity."
  }

  assert {
    condition     = azapi_resource.container_registry[0].body.sku.name == "Basic"
    error_message = "The default lab must use the Basic container registry SKU."
  }

  assert {
    condition = (
      length(azapi_resource.key_vault) == 0 &&
      length(azapi_resource.subnet_private_endpoints) == 0 &&
      length(azapi_resource.key_vault_private_dns) == 0 &&
      length(azapi_resource.key_vault_private_dns_link) == 0 &&
      length(azapi_resource.key_vault_private_endpoint) == 0 &&
      length(azapi_resource.key_vault_private_dns_group) == 0 &&
      length(azapi_resource.kv_secrets_user) == 0 &&
      length(azapi_resource.kv_admin) == 0 &&
      length(random_uuid.kv_secrets_user) == 0 &&
      length(random_uuid.kv_admin) == 0
    )
    error_message = "The default lab must not create Key Vault or any of its dedicated networking and role assignment resources."
  }

  assert {
    condition     = output.key_vault_id == null
    error_message = "The default lab must have a null Key Vault output."
  }

  assert {
    condition     = azapi_resource.aks_diagnostic_settings[0].parent_id == module.aks_standard.resource_id
    error_message = "Diagnostics must target the Standard cluster."
  }

  assert {
    condition     = azapi_resource.subnet_api_server.body.properties.delegations[0].properties.serviceName == "Microsoft.ContainerService/managedClusters"
    error_message = "API server VNet integration requires an explicitly delegated subnet."
  }
}

run "argocd_enabled" {
  command = plan

  variables {
    enable_telemetry = false
    enable_argocd    = true
  }

  assert {
    condition     = length(azapi_resource.argocd) == 1
    error_message = "Enabling Argo CD must create exactly one extension."
  }

  assert {
    condition = (
      azapi_resource.argocd[0].type == "Microsoft.KubernetesConfiguration/extensions@2023-05-01" &&
      azapi_resource.argocd[0].name == "argocd" &&
      azapi_resource.argocd[0].parent_id == module.aks_standard.resource_id &&
      azapi_resource.argocd[0].body.properties.extensionType == "Microsoft.ArgoCD"
    )
    error_message = "Argo CD must be installed as an Azure cluster extension on the Standard cluster."
  }

  assert {
    condition = (
      azapi_resource.argocd[0].body.properties.autoUpgradeMinorVersion &&
      azapi_resource.argocd[0].body.properties.releaseTrain == "Stable" &&
      azapi_resource.argocd[0].body.properties.scope.cluster.releaseNamespace == "argocd" &&
      azapi_resource.argocd[0].body.properties.configurationSettings["redis-ha.enabled"] == "false" &&
      azapi_resource.argocd[0].body.properties.configurationSettings["configs.params.application\\.namespaces"] == "argocd"
    )
    error_message = "The lab extension must use stable automatic upgrades, the argocd namespace, and non-HA Redis for the two-node pool."
  }
}

run "key_vault_enabled" {
  command = plan

  variables {
    enable_telemetry = false
    enable_key_vault = true
    acr_sku          = "Standard"
  }

  assert {
    condition = (
      length(azapi_resource.key_vault) == 1 &&
      length(azapi_resource.subnet_private_endpoints) == 1 &&
      length(azapi_resource.key_vault_private_dns) == 1 &&
      length(azapi_resource.key_vault_private_dns_link) == 1 &&
      length(azapi_resource.key_vault_private_endpoint) == 1 &&
      length(azapi_resource.key_vault_private_dns_group) == 1 &&
      length(azapi_resource.kv_secrets_user) == 1 &&
      length(azapi_resource.kv_admin) == 1 &&
      length(random_uuid.kv_secrets_user) == 1 &&
      length(random_uuid.kv_admin) == 1
    )
    error_message = "Opting into Key Vault must create its dedicated networking and role assignment resources."
  }

  assert {
    condition     = azapi_resource.kv_secrets_user[0].body.properties.principalId == "00000000-0000-0000-0000-000000000006"
    error_message = "Key Vault must grant secrets access to the Standard cluster's CSI identity."
  }

  assert {
    condition     = output.key_vault_id == azapi_resource.key_vault[0].id
    error_message = "Enabling Key Vault must expose its resource ID."
  }

  assert {
    condition     = azapi_resource.container_registry[0].body.sku.name == "Standard"
    error_message = "The container registry SKU must remain configurable."
  }
}

run "optional_integrations_disabled" {
  command = plan

  variables {
    enable_telemetry           = false
    enable_grafana             = false
    enable_argocd              = false
    enable_container_registry  = false
    enable_key_vault           = false
    enable_local_dns           = false
    enable_keda                = false
    enable_vpa                 = false
    enable_diagnostic_settings = false
    system_node_count          = 2
  }

  assert {
    condition = (
      length(azapi_resource.grafana) == 0 &&
      length(azapi_resource.argocd) == 0 &&
      length(azapi_resource.container_registry) == 0 &&
      length(azapi_resource.key_vault) == 0 &&
      length(azapi_resource.acr_pull) == 0 &&
      length(azapi_resource.kv_secrets_user) == 0 &&
      length(azapi_resource.aks_diagnostic_settings) == 0
    )
    error_message = "Disabling optional integrations must remove their resources and identity grants."
  }

  assert {
    condition     = output.grafana_endpoint == null && output.container_registry_login_server == null && output.key_vault_id == null
    error_message = "Disabled optional integrations must have null outputs."
  }

  assert {
    condition = (
      local.local_dns_profile.mode == "Disabled" &&
      !local.workload_auto_scaler_profile.keda.enabled &&
      !local.workload_auto_scaler_profile.vertical_pod_autoscaler.enabled
    )
    error_message = "Disabling LocalDNS, KEDA, and VPA must explicitly disable their AKS API settings."
  }
}

run "independent_autoscaler_options" {
  command = plan

  variables {
    enable_telemetry = false
    enable_keda      = false
  }

  assert {
    condition = (
      !local.workload_auto_scaler_profile.keda.enabled &&
      local.workload_auto_scaler_profile.vertical_pod_autoscaler.enabled &&
      local.local_dns_profile.mode == "Required"
    )
    error_message = "KEDA must be independently configurable without disabling VPA or LocalDNS."
  }
}

run "invalid_system_node_count" {
  command = plan

  variables {
    enable_telemetry  = false
    system_node_count = 1
  }

  expect_failures = [var.system_node_count]
}

run "fractional_system_node_count" {
  command = plan

  variables {
    enable_telemetry  = false
    system_node_count = 2.5
  }

  expect_failures = [var.system_node_count]
}
