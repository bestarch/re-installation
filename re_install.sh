#!/usr/bin/env bash
# Interactive installer script to deploy a 3-node Redis Enterprise cluster on Ubuntu.

set -euo pipefail

TARBALL_URL="https://storage.googleapis.com/abhi-data-2024/redislabs-8.0.6-54-jammy-amd64-Ubuntu_22.04.tar"
TARBALL_NAME="${TARBALL_URL##*/}"
REMOTE_TMP="/tmp/${TARBALL_NAME}"
INSTALL_DIR="/tmp/redis_enterprise_install"
RLADMIN="/opt/redislabs/bin/rladmin"

echo "Enter IP address of node1:"
read -r NODE1
echo "Enter IP address of node2:"
read -r NODE2
echo "Enter IP address of node3:"
read -r NODE3
echo "Enter FQDN for the cluster (example: mycluster.example.com):"
read -r CLUSTER_FQDN
echo "Enter Cluster Admin username (example: admin@example.com):"
read -r ADMIN_USER
echo "Enter Cluster Admin password:"
read -r ADMIN_PASS

# SSH credentials (to login to nodes)
echo "Enter SSH username:"
read -r SSH_USER
echo "Enter SSH password for ${SSH_USER} (leave blank to use key-based auth):"
read -r -s SSH_PASS

echo "Enter persistence path (where external disk is mounted e.g /mnt/mydata):"
read -r PERSISTENT_PATH

# Are we running this script on node1 or on a separate server?
echo "Are you running this script on node1 (yes/no)?"
read -r ON_NODE1

# NODE1="localhost"
# NODE2="10.1.0.6"
# NODE3="10.1.0.8"
# CLUSTER_FQDN="mycluster.example.com"
# ADMIN_USER="admin@example.com"
# ADMIN_PASS="admin"
# PERSISTENT_PATH="/mnt/mydata"
# PERSIST_DIR="${PERSISTENT_PATH%/}/persist"


# Configure SSH options: disable BatchMode when password is provided
if [[ -n "${SSH_PASS}" ]]; then
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
fi


# # Ensure PERSISTENT_PATH is set and create/override the "persist" directory
# if [[ -z "${PERSISTENT_PATH:-}" ]]; then
#     echo "Error: PERSISTENT_PATH is not set." >&2
#     exit 1
# fi

# if [[ ! -d "${PERSISTENT_PATH}" ]]; then
#     echo "Error: PERSISTENT_PATH '${PERSISTENT_PATH}' does not exist or is not a directory." >&2
#     exit 1
# fi

# PERSIST_DIR="${PERSISTENT_PATH%/}/persist"
# echo "Preparing persistence directory: ${PERSIST_DIR}"

# # Remove existing persist dir if present, then recreate (use sudo in case of root-owned mount)
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

# Confirm before proceeding
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
            echo "Error: 'sshpass' is required when supplying SSH password. Install it and re-run (e.g. sudo apt install -y sshpass)." >&2
            exit 1
        fi
        echo "Using sshpass to connect to ${target}"
        sshpass -p "${SSH_PASS}" ssh $SSH_OPTS ${target} "$cmd"
        
    else
        # Key-based auth path
        ssh $SSH_OPTS "${target}" "$cmd"
    fi
}

preinstall_steps() {
    local host="$1"
    echo "Running pre-install steps on $host ..."
    # 1. update /etc/sysctl.conf (append)
    run_cmd "$host" "sudo bash -c 'echo \"net.ipv4.ip_local_port_range = 30000 65535\" >> /etc/sysctl.conf'"

    # apply sysctl immediately
    run_cmd "$host" "sudo sysctl -p || true"

    # 2. edit /etc/systemd/resolved.conf to set DNSStubListener=no
    run_cmd "$host" "sudo bash -c 'if grep -q \"^#*DNSStubListener\" /etc/systemd/resolved.conf; then sed -i \"s/^#*DNSStubListener=.*/DNSStubListener=no/\" /etc/systemd/resolved.conf; else echo \"DNSStubListener=no\" >> /etc/systemd/resolved.conf; fi'"

    # 3. rename /etc/resolv.conf to /etc/resolv.conf.orig (force move)
    run_cmd "$host" "sudo bash -c 'if [ -e /etc/resolv.conf ]; then mv -f /etc/resolv.conf /etc/resolv.conf.orig || true; fi'"

    # 4. create symlink /etc/resolv.conf -> /run/systemd/resolve/resolv.conf
    run_cmd "$host" "sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"

    # 5. restart systemd-resolved
    run_cmd "$host" "sudo service systemd-resolved restart || true"
}

install_node() {
    local host="$1"
    echo "Installing Redis Enterprise on $host ..."
    # create temp dir, download tarball, extract and run installer
    run_cmd "$host" "sudo mkdir -p ${INSTALL_DIR} && sudo chown \$(whoami) ${INSTALL_DIR}"
    run_cmd "$host" "rm -f ${REMOTE_TMP} || true && wget -q -O ${REMOTE_TMP} '${TARBALL_URL}'"
    run_cmd "$host" "mkdir -p ${INSTALL_DIR} && tar -xf ${REMOTE_TMP} -C ${INSTALL_DIR}"
    # find the extracted folder
    run_cmd "$host" "cd ${INSTALL_DIR} && sudo ./install.sh -y || (echo 'Installer failed on $host' >&2; exit 1)"
}

# Run preinstall and install on each node
for h in "$NODE1" "$NODE2" "$NODE3"; do
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

#CREATE_CLUSTER_CMD="sudo ${RLADMIN} cluster create ccs_persistent_path ${PERSIST_DIR} persistent_path ${PERSIST_DIR} name ${CLUSTER_FQDN} username ${ADMIN_USER} password ${ADMIN_PASS} "
CREATE_CLUSTER_CMD="sudo ${RLADMIN} cluster create name ${CLUSTER_FQDN} username ${ADMIN_USER} password ${ADMIN_PASS} "
run_cmd "$NODE1" "$CREATE_CLUSTER_CMD"

# Join node2 and node3 to the cluster on node1
join_node() {
    local host="$1"
    echo "Joining ${host} to cluster at ${NODE1} ..."

    #local join_cmd="sudo ${RLADMIN} cluster join nodes ${host} ccs_persistent_path ${PERSIST_DIR} persistent_path ${PERSIST_DIR} username ${ADMIN_USER} password ${ADMIN_PASS}"
    local join_cmd="sudo ${RLADMIN} cluster join nodes $NODE1 username ${ADMIN_USER} password ${ADMIN_PASS}"

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