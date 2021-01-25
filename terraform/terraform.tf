terraform {
  required_providers {
    proxmox = {
      source = "Telmate/proxmox"
      version = "2.6.5"
    }
  }
}

variable "pm_pass" {
  type = string
}

provider "proxmox" {
  pm_tls_insecure = true
  pm_api_url = "https://pve:8006/api2/json"
  pm_user = "root@pam"
  pm_password = var.pm_pass
}

resource "proxmox_vm_qemu" "router" {
  name = "vyos"
  target_node = "pve"
  boot = "order=virtio0;ide2;net0"
  iso = "local:iso/vyos-rolling-latest.iso"

  memory = 1024

  disk {
    type = "virtio"
    storage = "local-lvm"
    size = "10G"
  }

  network {
    model = "virtio"
    bridge = "vmbr2"
  }

  serial {
    id = 0
    type = "socket"
  }

  connection {
    type     = "ssh"
    user     = "root"
    password = var.pm_pass
    host     = "pve"
  }

  provisioner "file" {
    source = "vyos-configure.exp"
    destination = "/var/lib/vz/snippets/vyos-configure.exp"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /var/lib/vz/snippets/vyos-configure.exp",
      "echo '${self.id}' | cut -d '/' -f3",
      "/var/lib/vz/snippets/vyos-configure.exp $(echo '${self.id}' | cut -d '/' -f3)"
    ]
  }
}

resource "proxmox_lxc" "mnjump" {
  hostname = "mnjump"
  onboot = true
  memory = 1024
  swap = 0
  rootfs {
    storage = "local-lvm"
    size = "8G"
  }
  network {
    name = "eth0"
    bridge = "vmbr2"
    ip = "dhcp"
  }
  ostemplate = "local:vztmpl/debian-10-standard_10.7-1_amd64.tar.gz"
  target_node = "pve"
  ssh_public_keys = file("../keys/id_rsa.pub")
  start = true
  unprivileged = true

  connection {
    host = "mnjump"
    user = "root"
    private_key = file("../keys/id_rsa")
  }

  provisioner "ansible" {
    plays {
      playbook {
        file_path = "../ansible/playbook.yml"
        roles_path = [
            "../ansible/roles"
        ]
      }
      extra_vars = {
        ansible_python_interpreter = "/usr/bin/python3"
      }
      hosts = [
	      "mnjump"
      ]
    }
    ansible_ssh_settings {
      insecure_no_strict_host_key_checking = false
    }
  }
}

locals {
  hosts = {
    mnshare = {
      name = "mnshare"
      cores = 1
      memory = 1024
      disksize = "4G"
      otherdisks = [{
        type = "virtio"
        storage = ""
        volume = "/dev/mn/nfs"
        size = "100G"
      },
      {
        type = "virtio"
        storage = ""
        volume = "/dev/mn/samba"
        size = "5120G"
      }]
    },
    mnapps = {
      name = "mnapps"
      cores = 4
      memory = 8192
      disksize = "20G"
      otherdisks = []
    }
  }
}

data "template_file" "user_data" {
  for_each = local.hosts
  template = file("cloudinit.yml")
  vars = {
    hostname = each.value.name
    pubkey = file("../keys/id_rsa.pub")
  }
}

resource "local_file" "cloud_init_user_data_file" {
  for_each = local.hosts
  content  = data.template_file.user_data[each.value.name].rendered
  filename = "files/${each.value.name}.yml"
}

resource "null_resource" "cloud_init_config_files" {
  for_each = local.hosts
  connection {
    type     = "ssh"
    user     = "root"
    password = var.pm_pass
    host     = "pve"
  }

  provisioner "file" {
    source      = local_file.cloud_init_user_data_file[each.value.name].filename
    destination = "/var/lib/vz/snippets/${each.value.name}.yml"
  }
}

resource "proxmox_vm_qemu" "metalnet" {
  for_each = local.hosts
  name = each.value.name
  target_node = "pve"
  clone = "debian-template"
  os_type = "cloud-init"
  agent = 1
  ipconfig0 = "ip=dhcp"
  sshkeys = file("../keys/id_rsa.pub")
  cicustom = "user=local:snippets/${each.value.name}.yml"
  force_recreate_on_change_of = local_file.cloud_init_user_data_file[each.value.name].content

  cores = each.value.cores
  memory = each.value.memory

  disk {
    type = "scsi"
    storage = "local-lvm"
    ssd = "1"
    discard = "on"
    size = each.value.disksize
  }

  dynamic "disk" {
    for_each = each.value.otherdisks
    content {
      type = disk.value["type"]
      storage = disk.value["storage"]
      volume = disk.value["volume"]
      size = disk.value["size"]
    }
  }

  network {
    model = "virtio"
    bridge = "vmbr2"
  }

  connection {
    host = self.ssh_host
    user = "debian"
    private_key = file("../keys/id_rsa")
  }

  provisioner "ansible" {
    plays {
      playbook {
        file_path = "../ansible/playbook.yml"
        roles_path = [
            "../ansible/roles"
        ]
      }
      extra_vars = {
        ansible_python_interpreter = "/usr/bin/python3"
      }
      hosts = [
	      each.value.name
      ]
    }
    ansible_ssh_settings {
      insecure_no_strict_host_key_checking = false
    }
  }

  provisioner "remote-exec" {
    inline = [
      "ip a"
    ]
  }
}
