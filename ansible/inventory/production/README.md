# Ansible Inventory Configuration

This directory contains the Ansible inventory configuration for the k3s homelab cluster.

## Configuration Required Before Deployment

Before running any playbooks, you **MUST** configure the following values:

### 1. Network Configuration (`hosts.yml`)

Update the following variables with your actual network configuration:

```yaml
# In hosts.yml under all:vars:
control_plane_cidr: "192.168.1.10/24,192.168.1.11/24,192.168.1.12/24"  # TODO: Set actual CIDR
control_plane_vip: "192.168.1.10"  # TODO: Set actual VIP
worker_nodes_cidr: "192.168.1.20/24,192.168.1.21/24"  # TODO: Set actual CIDR
```

### 2. Host IP Addresses (`hosts.yml`)

Update the `ansible_host` values for each node:

```yaml
# Control plane nodes
cp-01:
  ansible_host: 192.168.1.10  # TODO: Set actual IP
cp-02:
  ansible_host: 192.168.1.11  # TODO: Set actual IP
cp-03:
  ansible_host: 192.168.1.12  # TODO: Set actual IP

# Worker nodes
worker-01:
  ansible_host: 192.168.1.20  # TODO: Set actual IP
worker-02:
  ansible_host: 192.168.1.21  # TODO: Set actual IP
```

### 3. SSH Configuration (`hosts.yml`)

Update SSH key path and user:

```yaml
ansible_user: homelab
ansible_ssh_private_key_file: ~/.ssh/homelab_key  # TODO: Set actual SSH key path
```

### 4. k3s Token (`hosts.yml`)

Generate a secure token for k3s cluster:

```yaml
k3s_token: "your-secure-k3s-token-here"  # TODO: Generate secure token
```

**Generate a secure token:**
```bash
openssl rand -hex 32
```

### 5. NFS Configuration (`hosts.yml`)

If using NFS storage, configure:

```yaml
nfs_server_ip: ""  # TODO: Set NFS server IP
nfs_export_path: "/nfs/k3s"  # TODO: Set NFS export path
```

### 6. k3s Network Configuration (`all.yml`)

Configure k3s networking:

```yaml
k3s_cluster_cidr: "10.42.0.0/16"  # TODO: Set actual cluster CIDR
k3s_service_cidr: "10.43.0.0/16"  # TODO: Set actual service CIDR
k3s_cluster_dns: "10.43.0.10"     # TODO: Set actual cluster DNS IP
```

## File Structure

```
inventory/production/
├── hosts.yml                    # Main inventory file
├── group_vars/
│   ├── all.yml                  # Variables for all hosts
│   ├── k3s_control_plane.yml    # Control plane specific variables
│   └── k3s_worker.yml           # Worker node specific variables
└── README.md                    # This file
```

## Testing Inventory

Test your inventory configuration:

```bash
# Test connectivity to all hosts
ansible all -m ping

# List all hosts and their variables
ansible-inventory --list

# Test specific group
ansible k3s_control_plane -m ping
ansible k3s_worker -m ping
```

## Deployment Order

1. **Prepare nodes:** `ansible-playbook playbooks/00_prepare_nodes.yml`
2. **Install control plane:** `ansible-playbook playbooks/01_install_k3s_cp.yml`
3. **Install workers:** `ansible-playbook playbooks/02_install_k3s_worker.yml`
4. **Complete deployment:** `ansible-playbook playbooks/site.yml`

## Security Notes

- Ensure SSH keys are properly configured and secured
- Use a strong, randomly generated k3s token
- Restrict firewall rules to necessary ports only
- Keep SSH private keys secure and never commit them to version control