/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

provider "tls" {
  version = "~> 2.0"
}

resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "gce-keypair-pk" {
  content  = tls_private_key.main.private_key_pem
  filename = "${path.module}/sshkey"
}

data "google_compute_zones" "main" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

module "bastion" {
  source = "../bastion"

  network    = module.forseti-private-connection.network
  project_id = var.project_id
  subnetwork = module.forseti-private-connection.subnetwork
  zone       = data.google_compute_zones.main.names[0]
  key_suffix = "_private_conn"
}

module "forseti-private-connection" {
  source          = "../../../examples/private_connection"
  project_id      = var.project_id
  region          = var.region
  org_id          = var.org_id
  domain          = var.domain
  block_egress    = var.block_egress
  forseti_version = var.forseti_version

  instance_metadata = {
    sshKeys = "ubuntu:${tls_private_key.main.public_key_openssh}"
  }
}

# override fw rule that blocks *ALL* egress in the exampe to allow egress from bastion
resource "google_compute_firewall" "unblock-bastion-egress" {
  name               = "unblock-bastion-egress"
  project            = var.project_id
  network            = module.forseti-private-connection.network
  direction          = "EGRESS"
  destination_ranges = [module.forseti-private-connection.forseti-server-vm-ip]
  priority           = "1999"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "forseti_bastion_to_server" {

  name                    = "forseti-bastion-to-server-ssh-${module.forseti-private-connection.suffix}"
  project                 = var.project_id
  network                 = module.forseti-private-connection.network
  target_service_accounts = [module.forseti-private-connection.forseti-server-service-account]

  source_ranges = ["${module.bastion.host-private-ip}/32"]
  direction     = "INGRESS"
  priority      = "100"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

}

resource "null_resource" "wait_for_server" {
  triggers = {
    always_run = uuid()
  }

  provisioner "remote-exec" {
    script = "${path.module}/scripts/wait-for-forseti.sh"

    connection {
      type                = "ssh"
      user                = "ubuntu"
      host                = module.forseti-private-connection.forseti-server-vm-ip
      private_key         = tls_private_key.main.private_key_pem
      bastion_host        = module.bastion.host
      bastion_port        = module.bastion.port
      bastion_private_key = module.bastion.private_key
      bastion_user        = module.bastion.user
    }
  }

  depends_on = [
    google_compute_firewall.forseti_bastion_to_server,
    google_compute_firewall.unblock-bastion-egress
  ]
}