#!/usr/bin/env bash

set -euo pipefail

UNINSTALL="/opt/redislabs/bin/rl_uninstall.sh"


NODE1="10.1.0.15"
NODE2="10.1.0.16"
NODE3="10.1.0.17"
CLUSTER_FQDN="mycluster.example.com"
ON_NODE1="yes"
SSH_USER="abhishek"
SSH_PASS="Password@123"

# Configure SSH options: disable BatchMode when password is provided
if [[ -n "${SSH_PASS}" ]]; then
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
fi

if [[ "$ON_NODE1" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    EXEC_IS_LOCAL=true
else
    EXEC_IS_LOCAL=false
fi

# Confirm before proceeding
read -p "Proceed with uninstallation on nodes $NODE1, $NODE2, $NODE3 of cluster '$CLUSTER_FQDN'? Type 'Y' to continue: " CONFIRM
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
        sshpass -p "${SSH_PASS}" ssh $SSH_OPTS ${target} "$cmd"
        
    else
        # Key-based auth path
        ssh $SSH_OPTS "${target}" "$cmd"
    fi
}

uninstall() {
    local host="$1"
    echo "Uninstalling Redis Enterprise on $host ..."
    run_cmd "$host" "sudo ${UNINSTALL}"
}

# Run uninstall on each node
for h in "$NODE1" "$NODE2" "$NODE3"; do
    uninstall "$h"
done
echo "Uninstallation completed on all nodes."