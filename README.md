# AKS lab

This Terraform configuration creates a Standard AKS cluster with a fixed-size,
shared system/workload node pool. It retains support for cluster stop/start.

## Outbound networking and idle costs

The cluster uses Standard Load Balancer outbound access with one AKS-managed
public IP. No NAT Gateway or dedicated NAT public IP is provisioned. Azure CNI
Overlay, Cilium, managed ingress, and cluster stop/start are unchanged.

This removes the NAT Gateway's hourly resource fee, not all idle costs. Retained
public IPs, applicable load-balancer charges, ACR, persistent storage, and any
enabled monitoring or optional services can still incur charges while AKS is
stopped. Load-balancer outbound access is suitable for this small lab; workloads
with many concurrent outbound connections may need additional SNAT capacity.

### Migrating an existing NAT Gateway deployment

Schedule downtime: changing outbound type interrupts existing connections and
changes the cluster's outbound public IP. Update external firewall/IP allowlists
for the new address. Start the cluster first if it is stopped.

For an existing deployment, migrate AKS egress **before** applying the Terraform
removal of the gateway. Run from this initialized Terraform working directory,
using the same backend, workspace, and Azure subscription as the deployment:

```sh
az aks update \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)" \
  --outbound-type loadBalancer \
  --load-balancer-managed-outbound-ip-count 1

terraform plan -out=tfplan
terraform apply tfplan
```

Proceed to Terraform only after the AKS update succeeds. Review the fresh plan
before applying: it should detach the NAT Gateway from `clusterSubnet` and
`systemSubnet`, delete the gateway and its dedicated public IP, and retain the
cluster. The explicit null subnet associations ensure existing gateways are
detached, rather than relying on Azure's handling of omitted properties.
Do not apply an older saved plan. After applying, verify node readiness,
application health, image pulls, and outbound connectivity from a workload.

For a new deployment, use the normal Terraform plan/apply workflow; the
pre-migration Azure CLI command is not needed.

See Microsoft's [AKS outbound types and migration guidance](https://learn.microsoft.com/azure/aks/egress-outboundtype).

## LocalDNS and workload autoscaling

These features use native AKS API settings through the existing Terraform module,
not Helm releases, Kubernetes manifests, or deployment scripts. All three are
enabled by default and can be disabled independently:

| Terraform variable | Default | AKS API setting |
| --- | --- | --- |
| `enable_local_dns` | `true` | Node pool `localDNSProfile.mode = "Required"` |
| `enable_keda` | `true` | Cluster `workloadAutoScalerProfile.keda.enabled` |
| `enable_vpa` | `true` | Cluster `workloadAutoScalerProfile.verticalPodAutoscaler.enabled` |

LocalDNS uses Microsoft's documented default forwarding and caching configuration.
Cluster DNS queries go to CoreDNS; root-zone queries from pods using
`dnsPolicy: Default` go to VNet DNS. Disabling it explicitly sets `Disabled`,
rather than omitting the profile and allowing version-dependent AKS defaults.
`Required` mode fails deployment if LocalDNS prerequisites are not met.

LocalDNS requires Kubernetes 1.31+, Azure Linux or Ubuntu 22.04+, and a node VM
with at least four vCPUs. The default Azure Linux / `Standard_D4ds_v5` pool meets
the OS and CPU requirements. **Changing LocalDNS on an existing node pool causes
a node reimage**: plan for disruption and use suitable workload replicas and pod
disruption budgets. Custom DNS servers and network rules must allow DNS over
both UDP and TCP port 53.

Enabling KEDA and VPA installs the AKS-managed components; it does not configure
application scaling. Applications must supply `ScaledObject`/`ScaledJob` and
`VerticalPodAutoscaler` resources respectively. Avoid combining VPA with
CPU/memory-based horizontal autoscaling on the same metrics. VPA update modes
can evict pods, and workload scaling remains constrained by the fixed node
capacity: neither node autoprovisioning nor cluster autoscaler is enabled.

See Microsoft's [LocalDNS configuration](https://learn.microsoft.com/azure/aks/localdns-custom),
[KEDA API configuration](https://learn.microsoft.com/azure/aks/keda-deploy-add-on-arm),
and [VPA documentation](https://learn.microsoft.com/azure/aks/vertical-pod-autoscaler).

## Optional Argo CD extension

Set `enable_argocd = true` in your Terraform variables to install the Azure-managed
`Microsoft.ArgoCD` cluster extension. It defaults to `false`; setting it back to
`false` removes the extension on the next apply.

```hcl
enable_argocd = true
```

The extension installs in the `argocd` namespace, allows Application definitions
in that namespace, and automatically receives minor updates from the Stable
release train. Redis HA is disabled to suit this lab's two-node pool; the
extension's default HA configuration requires at least four nodes. This is a lab
configuration, not a production HA deployment.

Before enabling it, register the required subscription resource providers:

```sh
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
```

The Terraform caller needs permission to manage
`Microsoft.KubernetesConfiguration/extensions` on the cluster (for example,
Kubernetes Extension Contributor). The cluster must be running and have outbound
access to the required Azure endpoints and your Git repositories.

After applying, verify the extension and pods:

```sh
az k8s-extension show \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --cluster-name "$(terraform output -raw cluster_name)" \
  --cluster-type managedClusters \
  --name argocd \
  --query provisioningState --output tsv

kubectl get pods --namespace argocd
```

The status command requires the Azure CLI `k8s-extension` extension; `kubectl`
requires credentials for this cluster. Terraform installs Argo CD only: it does
not create Applications, repository credentials, workload-identity bindings for
private registries, or a public UI/ingress route. Manage those separately. Before
disabling Argo CD, review application cleanup and finalizers; do not assume that
removing the extension removes deployed workloads.

See Microsoft's [Argo CD quickstart](https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-deploy-gitops-argo-cd)
and [deployment tutorial and network requirements](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd).

## Managed ingress

The cluster uses the application routing add-on's **Istio-backed Kubernetes
Gateway API implementation**, matching the default for **new AKS Automatic
clusters on Kubernetes 1.36 and later**. Earlier Automatic clusters used managed
NGINX by default.

[The ingress configuration](main.tf) enables Azure-managed Gateway API CRDs
(`installation = "Standard"`) and the application routing Istio implementation.
It disables provisioning of the default NGINX ingress controller.

This is **not** the full Istio service mesh add-on: it does not inject workload
sidecars or support Istio-specific traffic resources. Azure manages the ingress
control plane and its upgrades.

### Using ingress

After applying the Terraform configuration, verify the managed GatewayClass:

```sh
kubectl get gatewayclass approuting-istio
```

Applications must define `gateway.networking.k8s.io/v1` `Gateway` resources with
`spec.gatewayClassName: approuting-istio`, listeners, and corresponding
`HTTPRoute` resources pointing at their Kubernetes Services. Enabling the add-on
does not itself create an application Gateway, public ingress IP, route, DNS
record, or TLS certificate. This repository does not deploy application routes.

### Existing NGINX workloads

Terraform does **not** convert existing `Ingress` resources or NGINX annotations.
If the cluster already serves workloads through NGINX, follow Microsoft's
[migration guide](https://learn.microsoft.com/azure/aks/app-routing-nginx-to-gateway-api-migration)
before retiring the old ingress path: run both implementations during migration,
validate replacement Gateways and routes, and cut over DNS first.

For that staged migration, temporarily retain the cluster's existing
`default_ingress_controller_type` instead of `"None"`. Setting it to `"None"`
stops default NGINX controller reconciliation; existing `NginxIngressController`
resources and their data planes must also be removed explicitly after cutover.

See Microsoft's [Gateway API application routing documentation](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)
for supported features, limitations, and examples.
