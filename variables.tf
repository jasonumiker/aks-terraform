variable "location" {
  type        = string
  default     = "australiaeast"
  description = "Azure region. Must support API server VNet integration and availability zones 1, 2, and 3."
}

variable "name_prefix" {
  type        = string
  default     = "aks"
  description = "Prefix used for resource names."
}

variable "vnet_address_space" {
  type        = string
  default     = "172.19.0.0/16"
  description = "Address space of the virtual network."
}

variable "api_server_subnet_prefix" {
  type        = string
  default     = "172.19.0.0/28"
  description = "Subnet for the API server VNet integration (min /28)."
}

variable "cluster_subnet_prefix" {
  type        = string
  default     = "172.19.1.0/24"
  description = "Subnet for the conventional VMSS pool shared by system components and demo workloads."
}

variable "system_subnet_prefix" {
  type        = string
  default     = "172.19.2.0/24"
  description = "Reserved subnet retained from the Automatic configuration. The lab's shared system and workload pool uses cluster_subnet_prefix."
}

variable "system_node_count" {
  type        = number
  default     = 2
  description = "Fixed size of the conventional VMSS pool shared by system components and demo workloads (minimum 2). NAP and cluster autoscaler are disabled. Use AKS cluster stop/start when the lab is idle; retained resources still incur charges."

  validation {
    condition     = var.system_node_count >= 2 && var.system_node_count <= 1000 && floor(var.system_node_count) == var.system_node_count
    error_message = "system_node_count must be an integer between 2 and 1000."
  }
}

variable "system_node_vm_size" {
  type        = string
  default     = "Standard_D4ds_v5"
  description = "System pool VM size. Choose an AKS-supported non-B-series SKU with at least 4 vCPUs and 4 GiB memory, available in all three zones."
}

variable "private_endpoints_subnet_prefix" {
  type        = string
  default     = "172.19.3.0/24"
  description = "Non-overlapping subnet within the VNet for Key Vault private endpoints."
}

variable "alert_email" {
  type        = string
  default     = null
  description = "Email for recommended alerts. If null, alerts are not onboarded."
}

variable "admin_principal_id" {
  type        = string
  default     = null
  description = "Object ID granted Azure Kubernetes Service RBAC Admin. Defaults to the current caller."
}

variable "enable_telemetry" {
  type    = bool
  default = true
}

variable "admin_principal_type" {
  type        = string
  default     = "User"
  description = "Principal type of the admin (User, Group or ServicePrincipal); used for the Grafana Admin role assignment."
}

variable "acr_sku" {
  type        = string
  default     = "Basic"
  description = "Container registry SKU (Basic, Standard or Premium). Defaults to Basic to reduce lab costs."
}

variable "aks_log_categories" {
  type = list(string)
  default = [
    "kube-apiserver",
    "kube-audit-admin",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler",
    "cloud-controller-manager",
    "guard",
    "csi-azuredisk-controller",
    "csi-azurefile-controller",
    "csi-snapshot-controller",
  ]
  description = "AKS control-plane log categories sent to Log Analytics."
}

variable "enable_grafana" {
  type        = bool
  default     = false
  description = "Create an Azure Managed Grafana instance linked to the Prometheus workspace."
}

variable "enable_container_registry" {
  type        = bool
  default     = true
  description = "Create an Azure Container Registry and grant the kubelet identity AcrPull."
}

variable "enable_key_vault" {
  type        = bool
  default     = false
  description = "Create a Key Vault, its private endpoint subnet, private endpoint, private DNS resources and role assignments, and enable the secrets store CSI driver add-on. Disabled by default to reduce lab costs."
}

variable "enable_diagnostic_settings" {
  type        = bool
  default     = true
  description = "Send AKS control-plane logs and metrics to Log Analytics."
}
