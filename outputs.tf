output "resource_group_name" {
  value = azapi_resource.resource_group.name
}

output "cluster_name" {
  value = "aks-${var.name_prefix}-${local.suffix}"
}

output "virtual_network_id" {
  value = azapi_resource.virtual_network.id
}

output "grafana_endpoint" {
  value = one(azapi_resource.grafana[*].output.properties.endpoint)
}

output "container_registry_login_server" {
  value = var.enable_container_registry ? "${local.acr_name}.azurecr.io" : null
}

output "key_vault_id" {
  value = one(azapi_resource.key_vault[*].id)
}
