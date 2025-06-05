# Ansible Configuration for k3s Homelab Cluster

This directory contains Ansible roles and playbooks for deploying and managing a k3s cluster on homelab infrastructure.

## Prerequisites

- Ansible >= 8.0.0
- Python >= 3.9
- SSH access to target nodes
- sudo privileges on target nodes

## Installation

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

2. Install Ansible collections (if needed):
```bash
ansible-galaxy collection install community.general
ansible-galaxy collection install kubernetes.core
```

## Configuration

Before running any playbooks, you must configure the inventory and variables:

1. **Update inventory**: Edit `inventory/production/hosts.yml`
   - Set actual IP addresses for your nodes
   - Configure SSH key paths
   - Set k3s token and network configuration

2. **Review group variables**: Check files in `inventory/production/group_vars/`
   - Adjust settings for your environment
   - Configure NFS, NVIDIA, and other optional components

See [inventory/production/README.md](inventory/production/README.md) for detailed configuration instructions.

## Quick Start

1. **Prepare all nodes:**
```bash
ansible-playbook playbooks/00_prepare_nodes.yml
```

2. **Install k3s control plane:**
```bash
ansible-playbook playbooks/01_install_k3s_cp.yml
```

3. **Install k3s workers:**
```bash
ansible-playbook playbooks/02_install_k3s_worker.yml
```

4. **Or run complete deployment:**
```bash
ansible-playbook playbooks/site.yml
```

## Playbook Structure

### Roles

- **`common`**: Basic OS configuration for all nodes
- **`k3s_common`**: k3s prerequisites and preparation
- **`k3s_control_plane`**: k3s server installation and HA setup
- **`k3s_worker`**: k3s agent installation
- **`nfs_client`**: NFS client configuration for storage
- **`nvidia_driver`**: NVIDIA GPU drivers and CUDA toolkit
- **`docker`**: Docker installation (optional, for builds)

### Playbooks

- **`00_prepare_nodes.yml`**: OS preparation and basic setup
- **`01_install_k3s_cp.yml`**: Control plane deployment
- **`02_install_k3s_worker.yml`**: Worker node deployment
- **`site.yml`**: Complete cluster deployment orchestration

## Testing and Validation

### Syntax Check
```bash
# Check all playbooks
for playbook in playbooks/*.yml; do
  ansible-playbook --syntax-check "$playbook" -i inventory/production/hosts.yml
done
```

### Dry Run
```bash
# Test without making changes
ansible-playbook playbooks/site.yml --check --diff
```

### Lint Code
```bash
# Lint roles and playbooks
ansible-lint .

# Lint YAML formatting
yamllint -c ../.yamllint .
```

### Inventory Validation
```bash
# Test connectivity
ansible all -m ping

# Show inventory structure
ansible-inventory --list
```

## Tags

Use tags to run specific parts of the deployment:

```bash
# Run only OS preparation
ansible-playbook playbooks/site.yml --tags "phase1"

# Run only control plane setup
ansible-playbook playbooks/site.yml --tags "phase2"

# Run only worker setup
ansible-playbook playbooks/site.yml --tags "phase3"

# Run specific role tasks
ansible-playbook playbooks/site.yml --tags "k3s_common,nfs_client"
```

## Limiting Execution

Run on specific hosts or groups:

```bash
# Run on specific host
ansible-playbook playbooks/site.yml --limit "cp-01"

# Run on specific group
ansible-playbook playbooks/site.yml --limit "k3s_control_plane"

# Run on multiple hosts
ansible-playbook playbooks/site.yml --limit "cp-01,worker-01"
```

## Troubleshooting

### Common Issues

1. **SSH Connection Failures**
   - Verify SSH key configuration
   - Check host IP addresses in inventory
   - Ensure SSH agent is running

2. **Privilege Escalation Issues**
   - Verify sudo access for the ansible user
   - Check `become` configuration in ansible.cfg

3. **k3s Installation Failures**
   - Verify network connectivity between nodes
   - Check firewall rules
   - Ensure required ports are open

### Debug Mode

Run with increased verbosity:

```bash
ansible-playbook playbooks/site.yml -vvv
```

### Check Logs

View Ansible logs:

```bash
tail -f ansible.log
```

## Security Considerations

- SSH keys should be properly secured
- k3s tokens should be randomly generated and kept secret
- Firewall rules are configured to restrict access
- Password authentication is disabled by default
- Regular security updates are recommended

## Directory Structure

```
ansible/
├── ansible.cfg              # Ansible configuration
├── requirements.txt         # Python dependencies
├── inventory/
│   └── production/          # Production environment
│       ├── hosts.yml        # Host definitions
│       ├── group_vars/      # Group-specific variables
│       └── README.md        # Configuration guide
├── roles/                   # Ansible roles
│   ├── common/              # OS basic configuration
│   ├── k3s_common/          # k3s prerequisites
│   ├── k3s_control_plane/   # k3s server setup
│   ├── k3s_worker/          # k3s agent setup
│   ├── nfs_client/          # NFS configuration
│   ├── nvidia_driver/       # GPU drivers
│   └── docker/              # Docker setup (optional)
└── playbooks/               # Ansible playbooks
    ├── 00_prepare_nodes.yml # Node preparation
    ├── 01_install_k3s_cp.yml # Control plane setup
    ├── 02_install_k3s_worker.yml # Worker setup
    └── site.yml             # Main orchestration
```

## Next Steps

After successful deployment:

1. Configure kubectl with the generated kubeconfig
2. Proceed to Phase 2: Kubernetes cluster basic setup
3. Deploy infrastructure components (monitoring, storage, etc.)
4. Deploy applications