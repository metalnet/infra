terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.2.0"
    }
  }
}

variable "pm_pass" {
  type      = string
  sensitive = true
}

variable "nodes" {
  description = "List of nodes and their configurations."
  type = list(object({
    hostname = string
    nodename = string
    cores    = number
    memory   = number
    ip       = string
    mac      = string
  }))
}

variable "talos_version" {
  type = string
}

variable "talos_image_factory_id" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_ip" {
  type = string
}

provider "proxmox" {
  endpoint = "https://proxmox.apps.metalnet.org"
  username = "root@pam"
  password = var.pm_pass
}

resource "proxmox_download_file" "talos_image" {
  for_each                = { for node in var.nodes : node.nodename => node }
  node_name               = each.value.hostname
  content_type            = "iso"
  datastore_id            = "local"
  url                     = "https://factory.talos.dev/image/${var.talos_image_factory_id}/v${var.talos_version}/metal-amd64.iso"
  file_name               = "talos-v${var.talos_version}-metal-amd64.iso"
  overwrite               = false
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each        = { for node in var.nodes : node.nodename => node }
  depends_on      = [proxmox_download_file.talos_image]
  name            = each.key
  node_name       = each.value.hostname
  vm_id           = 300 + index(var.nodes, each.value)
  agent {
    enabled = true
    wait_for_ip {
      ipv4 = true
    }
  }
  stop_on_destroy = true
  machine         = "q35"
  bios            = "ovmf"
  cpu {
    cores = each.value.cores
    type  = "host"
  }
  memory {
    dedicated = each.value.memory
    floating  = 0
  }
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = "true"
  }
  cdrom {
    interface = "ide2"
    file_id   = "local:iso/talos-v${var.talos_version}-metal-amd64.iso"
  }
  efi_disk {
    datastore_id = "local-lvm"
    type         = "4m"
  }
  network_device {
    bridge       = "vmbr0"
    mac_address  = each.value.mac
    vlan_id      = "10"
  }
  operating_system {
    type = "l26"
  }
}

locals {
  #node_ips = [for vm in proxmox_virtual_environment_vm.talos : vm.ipv4_addresses[7][0]]
  node_ips = [for node in var.nodes : node.ip]
  cluster_endpoint = "https://${var.cluster_ip}:6443"
  install_image = "factory.talos.dev/installer/${var.talos_image_factory_id}:v${var.talos_version}"
}

resource "talos_machine_secrets" "machine_secrets" {
  talos_version = "v${var.talos_version}"
}

data "talos_client_configuration" "client_config" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  endpoints            = local.node_ips
  nodes                = local.node_ips
}

data "talos_machine_configuration" "control_machine_config" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.machine_secrets.machine_secrets
  kubernetes_version = "v${var.kubernetes_version}"
  talos_version      = "v${var.talos_version}"
  config_patches = [
    yamlencode({
      machine = {
        install = {
          image = local.install_image
        }
      }
    }),
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
    yamlencode({
      machine = {
        nodeLabels = {
          "node.kubernetes.io/exclude-from-external-load-balancers" = {
            "$patch" = "delete"
          }
        }
      }
    }),
    yamlencode({
      machine = {
        network = {
          interfaces = [{
            interface = "ens18"
            dhcp = true
            vip = {
              ip = var.cluster_ip
            }
          }]
        }
      }
    }),
    yamlencode({
      machine = {
        kernel = {
          modules = [
            {
              name = "drbd"
              parameters = [
                "usermode_helper=disabled"
              ]
            },
            {
              name = "drbd_transport_tcp"
            },
            {
              name = "dm-thin-pool"
            }
          ]
        }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "control_machine_config_apply" {
  for_each                    = { for ip in local.node_ips : ip => ip }
  depends_on                  = [proxmox_virtual_environment_vm.talos]
  client_configuration        = talos_machine_secrets.machine_secrets.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_machine_config.machine_configuration
  node                        = each.key
}

resource "talos_machine_bootstrap" "bootstrap" {
  depends_on           = [talos_machine_configuration_apply.control_machine_config_apply]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = local.node_ips[0]
  endpoint             = local.node_ips[0]
}

resource "talos_cluster_kubeconfig" "kubeconfig" {
  depends_on           = [talos_machine_bootstrap.bootstrap]
  client_configuration = talos_machine_secrets.machine_secrets.client_configuration
  node                 = var.cluster_ip
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.ca_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_key)
  client_certificate     = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.ca_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_key)
    client_certificate     = base64decode(talos_cluster_kubeconfig.kubeconfig.kubernetes_client_configuration.client_certificate)
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.1.2"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  set = [{
    name  = "configs.params.server\\.insecure"
    value = "true"
  }]
}

resource "kubernetes_manifest" "argocd-root" {
  depends_on = [helm_release.argocd]
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root-bootstrap"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/metalnet/infra.git"
        targetRevision = "HEAD"
        path           = "kube"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
          enabled  = true
        }
      }
    }
  }
}

data "kubernetes_secret_v1" "existing" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }
}

output "argocd_password" {
  value     = data.kubernetes_secret_v1.existing.data["password"]
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.client_config.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = resource.talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive = true
}
