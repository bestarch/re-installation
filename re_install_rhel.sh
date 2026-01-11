#!/usr/bin/env bash
# Interactive installer script to deploy a 3-node Redis Enterprise cluster on RHEL 9.

set -euo pipefail


#TARBALL_URL="https://storage.googleapis.com/abhi-data-2024/redislabs-8.0.6-54-rhel9-x86_64.tar"
TARBALL_URL="https://storage.googleapis.com/abhi-data-2024/redislabs-7.8.4-18-rhel9-x86_64.tar"
TARBALL_NAME="${TARBALL_URL##*/}"
REMOTE_TMP="/tmp/${TARBALL_NAME}"
INSTALL_DIR="/tmp/redis_enterprise_install"
RLADMIN="/opt/redislabs/bin/rladmin"

# echo "Enter IP address of node1:"
# read -r NODE1
# echo "Enter IP address of node2:"
# read -r NODE2
# echo "Enter IP address of node3:"
# read -r NODE3
# echo "Enter FQDN for the cluster (example: mycluster.example.com):"
# read -r CLUSTER_FQDN
# echo "Enter Cluster Admin username (example: admin@example.com):"
# read -r ADMIN_USER
# echo "Enter Cluster Admin password:"
# read -r ADMIN_PASS
# echo "Do you want to set up NTP time synchronization (Y/N)?"
# read -r NTP_TIME_SYNC



# # SSH credentials (to login to nodes)
# echo "Enter SSH username:"
# read -r SSH_USER
# echo "Enter SSH password for ${SSH_USER} (leave blank to use key-based auth):"
# read -r -s SSH_PASS

# echo "Enter persistence path (where external disk is mounted e.g /mnt/mydata):"
# read -r PERSISTENT_PATH

# # Are we running this script on node1 or on a separate server?
# echo "Are you running this script on node1 (yes/no)?"
# read -r ON_NODE1

NODE1="10.1.0.15"
NODE2="10.1.0.16"
NODE3="10.1.0.17"
CLUSTER_FQDN="redis.dlqueue.com"
ADMIN_USER="admin@dlqueue.com"
ADMIN_PASS="admin"
ON_NODE1="yes"
SSH_USER="abhishek"
SSH_PASS="Password@123"
PERSISTENT_PATH="/mnt/mydata"
#PERSIST_DIR="${PERSISTENT_PATH%/}/persist"
NTP_TIME_SYNC="N"


# Configure SSH options: disable BatchMode when password is provided
if [[ -n "${SSH_PASS}" ]]; then
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
fi


# Ensure PERSISTENT_PATH is set and create/override the "persist" directory
if [[ -z "${PERSISTENT_PATH:-}" ]]; then
    echo "Error: PERSISTENT_PATH is not set." >&2
    exit 1
fi

if [[ ! -d "${PERSISTENT_PATH}" ]]; then
    echo "Error: PERSISTENT_PATH '${PERSISTENT_PATH}' does not exist or is not a directory." >&2
    exit 1
fi

PERSIST_DIR="${PERSISTENT_PATH%/}/persist"
echo "Preparing persistence directory: ${PERSIST_DIR}"

# Remove existing persist dir if present, then recreate (use sudo in case of root-owned mount)
# sudo rm -rf -- "${PERSIST_DIR}" || true
# sudo mkdir -p -- "${PERSIST_DIR}"
# sudo chown "$(whoami)" "${PERSIST_DIR}" || true


if [[ "$ON_NODE1" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    EXEC_HOST="$NODE1"
    EXEC_IS_LOCAL=true
else
    EXEC_HOST="$NODE1"
    EXEC_IS_LOCAL=false
fi

# Confirm before proceeding and normalize NTP choice
if [[ "$NTP_TIME_SYNC" == "Y" || "$NTP_TIME_SYNC" == "y" ]]; then
    echo "NTP time will be synced"
    NTP_TIME_SYNC="Y"
else
    echo "NTP time will NOT be synced. If you haven't synced it manually, abort the installation and set it first."
    NTP_TIME_SYNC="N"
fi
read -p "Proceed with installation on nodes $NODE1, $NODE2, $NODE3 and create cluster '$CLUSTER_FQDN' with admin user '$ADMIN_USER' and password '$ADMIN_PASS'? Type 'Y' to continue: " CONFIRM
CONFIRM="$(echo "$CONFIRM" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
if [ "$CONFIRM" != "Y" ]; then
    echo "Aborting."
    exit 1
fi


# Helper to run a command on a remote host (or local when host matches local IP)
run_cmd() {
    local host="$1"; shift
    local cmd="$*"

    # Local execution when target is local or executing locally on NODE1
    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || ( "${EXEC_IS_LOCAL}" == "true" && "$host" == "$NODE1" ) ]]; then
        if [[ -n "${SSH_PASS:-}" && "$cmd" == *"sudo "* ]]; then
            # provide sudo password on local execution
            echo "${SSH_PASS}" | sudo -S bash -lc "$cmd"
        else
            sudo bash -c "$cmd"
        fi
        return
    fi

    # Remote execution
    local target="${SSH_USER}@${host}"

    # If a password is provided, ensure sshpass exists
    if [[ -n "${SSH_PASS:-}" ]]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "Error: 'sshpass' is required when supplying SSH password. Install it and re-run (e.g. sudo dnf install -y sshpass)." >&2
            exit 1
        fi
        echo "Using sshpass to connect to ${target}"
        sshpass -p "${SSH_PASS}" ssh -tt $SSH_OPTS ${target} "$cmd"
        
    else
        # Key-based auth path
        ssh $SSH_OPTS "${target}" "$cmd"
    fi
}

# Ensure RHEL9 prerequisites on remote host (dnf-based)
ensure_prereqs() {
    local host="$1"
    echo "Ensuring prerequisites on ${host} (RHEL 9)..."
    run_cmd "$host" "bash -lc 'if ! command -v dnf >/dev/null 2>&1; then echo \"Error: dnf not found on target host\" >&2; exit 1; fi; sudo dnf update -y || true; sudo dnf -y install wget tar expect || true'"
    if [[ -n "${SSH_PASS:-}" ]]; then
        run_cmd "$host" "sudo dnf -y install epel-release || true; sudo dnf -y install sshpass || true"
    fi
}

preinstall_steps() {
    local host="$1"
    echo "Running pre-install steps on $host ..."

    # Prepare persistence directory
    run_cmd "$host" "sudo rm -rf ${PERSIST_DIR} || true; sudo mkdir -p ${PERSIST_DIR} || true; sudo chown -R redislabs:redislabs ${PERSIST_DIR} || true"
    
    # 1. update /etc/sysctl.conf (append)
    run_cmd "$host" "sudo bash -c 'echo \"net.ipv4.ip_local_port_range = 30000 65535\" >> /etc/sysctl.conf'"

    # apply sysctl immediately
    run_cmd "$host" "sudo sysctl -p || true"

    # Ensure RHEL prerequisites (dnf installs)
    ensure_prereqs "$host"

    # 2. If systemd-resolved exists on the host, set DNSStubListener=no and manage resolv.conf
    run_cmd "$host" "bash -lc 'if [ -f /etc/systemd/resolved.conf ] || systemctl list-unit-files | grep -q systemd-resolved; then if grep -q \"^#*DNSStubListener\" /etc/systemd/resolved.conf; then sudo sed -i \"s/^#*DNSStubListener=.*/DNSStubListener=no/\" /etc/systemd/resolved.conf; else echo \"DNSStubListener=no\" | sudo tee -a /etc/systemd/resolved.conf >/dev/null; fi; if [ -f /run/systemd/resolve/resolv.conf ]; then sudo mv -f /etc/resolv.conf /etc/resolv.conf.orig || true; sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; fi; sudo systemctl restart systemd-resolved || sudo service systemd-resolved restart || true; else echo \"systemd-resolved not present; skipping resolv changes\"; fi'"

    # 3. SELinux: detect enforcement and offer to set permissive temporarily
    local sel
    sel=$(run_cmd "$host" "bash -lc 'if command -v getenforce >/dev/null 2>&1; then getenforce || true; fi'" || true)
    if [[ "${sel}" == *"Enforcing"* ]]; then
        echo "SELinux is Enforcing on ${host}. It's recommended to set to Permissive during install to avoid denials."
        read -p "Set SELinux to Permissive on ${host} for installation? (y/N): " set_sel
        if [[ "${set_sel}" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            run_cmd "$host" "sudo setenforce 0 || true"
            run_cmd "$host" "sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true"
            echo "Set SELinux to permissive on ${host} (until reboot)."
        else
            echo "Leaving SELinux unchanged on ${host}."
        fi
    fi

    # 4. Firewalld: detect and warn
    local fw
    fw=$(run_cmd "$host" "bash -lc 'if systemctl is-active --quiet firewalld; then echo active; fi'" || true)
    if [[ "${fw}" == *"active"* ]]; then
        echo "Warning: firewalld is active on ${host}. Ensure necessary Redis Enterprise ports are allowed or disable firewalld as appropriate."
    fi
}

install_node() {
    local host="$1"
    echo "Installing Redis Enterprise on $host ..."
    # create temp dir, download tarball, extract and run installer
    run_cmd "$host" "sudo mkdir -p ${INSTALL_DIR} && sudo chown \$(whoami) ${INSTALL_DIR}"
    run_cmd "$host" "rm -f ${REMOTE_TMP} || true && wget -q -O ${REMOTE_TMP} '${TARBALL_URL}'"
    run_cmd "$host" "mkdir -p ${INSTALL_DIR} && tar -xf ${REMOTE_TMP} -C ${INSTALL_DIR}"

    #run_cmd "$host" "cd ${INSTALL_DIR} && spawn sudo ./install.sh || (echo 'Installer failed on $host' >&2; exit 1)"
    run_cmd "$host" "
export INSTALL_DIR='${INSTALL_DIR}'
export NTP_TIME_SYNC='${NTP_TIME_SYNC}'

expect <<'EOF'
set timeout -1

cd \$env(INSTALL_DIR)
spawn sudo ./install.sh

expect {
  -re {Do you want to set up NTP time synchronization now.*} {
    send \"\\\$env(NTP_TIME_SYNC)\\r\"
    exp_continue
  }
  -re {Press ENTER to continue.*} {
    send \"\\r\"
    exp_continue
  }
  -re {.*} {
    send \"Y\\r\"
    exp_continue
  }
  eof
}

set status [wait]
exit [lindex \$status 3]
EOF
" || { echo "Installer failed on $host" >&2; exit 1; }
    
    }

# Run preinstall and install on each node
for h in "$NODE1" ; do
    preinstall_steps "$h"
    install_node "$h"
    sleep 5
done

# Create cluster from node1 (either local or remote via ssh)
echo "Creating cluster on node1 ($NODE1) ..."
sleep 10

# Wait a short while for services to be up
echo "Waiting for services to initialize on node1..."
sleep 60

CREATE_CLUSTER_CMD="sudo ${RLADMIN} cluster create ccs_persistent_path ${PERSIST_DIR} persistent_path ${PERSIST_DIR} name ${CLUSTER_FQDN} username ${ADMIN_USER} password ${ADMIN_PASS} "
#CREATE_CLUSTER_CMD="sudo ${RLADMIN} cluster create name ${CLUSTER_FQDN} username ${ADMIN_USER} password ${ADMIN_PASS} "
run_cmd "$NODE1" "$CREATE_CLUSTER_CMD"

# Join node2 and node3 to the cluster on node1
join_node() {
    local host="$1"
    echo "Joining ${host} to cluster at ${NODE1} ..."

    local join_cmd="sudo ${RLADMIN} cluster join nodes $NODE1 ccs_persistent_path ${PERSIST_DIR} persistent_path ${PERSIST_DIR} username ${ADMIN_USER} password ${ADMIN_PASS}"
    #local join_cmd="sudo ${RLADMIN} cluster join nodes $NODE1 username ${ADMIN_USER} password ${ADMIN_PASS}"

    local attempt=1
    local max_attempts=5

    until run_cmd "$host" "${join_cmd}"; do
        if (( attempt >= max_attempts )); then
            echo "ERROR: failed to join ${host} after ${attempt} attempts" >&2
            return 1
        fi
        echo "Join attempt ${attempt} for ${host} failed, retrying in 10s..."
        attempt=$((attempt + 1))
        sleep 10
    done

    echo "${host} joined successfully."
}

# Join both nodes
join_node "$NODE2"
sleep 5
join_node "$NODE3"