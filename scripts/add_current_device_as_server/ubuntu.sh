#!/usr/bin/env bash

echo "----------------------------------------------------------------------
This script will add current device as server to your Hookdoo account.
Credentials will be automatically set up for you.
User \"hookdoo\" will be created if it does not exist.
User's private key will be automatically generated.
You are free to change this user or his permissions later on.
----------------------------------------------------------------------"

if [ -z ${NO_CONFIRM} ]; then
    echo "Proceed? yes/no"
    read option
    if [ ${option} != "yes" ] ; then
        exit 0
    fi
else
    echo "NO_CONFIRM specified, proceeding automatically with script execution..."
    echo "..."
fi

echo "Checking if all necessary tools are available on this device..."
declare -a USED_COMMANDS=(curl adduser chpasswd ssh-keygen grep egrep touch cat ssh-add awk printf ssh-agent)

for command in "${USED_COMMANDS[@]}"; do
    if hash command 2>/dev/null; then
        echo "Checking if ${command} is available...[OK]"
    else
        echo "Checking if ${command} is available...[FAILED]"
        exit 1
    fi
done
echo "All necessary tools are available on this device...[OK]"
echo "..."

# require script to run as root
echo "Checking if script is run as root..."
if [ "$EUID" -ne 0 ] ; then
    echo "Script not run as root...[FAILED]"
    exit 1
else
    echo "Script run as root...[OK]"
    echo "..."
fi

# check if sshd_config file is available
SSHD_CONFIG_FILE=/etc/ssh/sshd_config
echo "Checking if SSHD config file is available at ${SSHD_CONFIG_FILE}..."
if [ ! -f ${SSHD_CONFIG_FILE} ]; then
    echo "SSHD config file not available...[FAILED]"
    exit 1
else
    echo "SSHD config file available...[OK]"
    echo "..."
fi

# require ssh server to be available
# check port ssh server is using
echo "Detecting SSH port used for remote sessions..."
SSH_PORT=$(grep -Po "^Port \K([0-9]*)" ${SSHD_CONFIG_FILE})
if [ $? -ne 0 ]; then
    echo "Failed to detect SSH port from SSHD config file...[FAILED]"
    exit 1
else
    echo "Dected SSH port = ${SSH_PORT}...[OK]"
    echo "..."
fi

# check if user hookdoo already exists
echo "Checking if user hookdoo already exists..."
if egrep "hookdoo" /etc/passwd >/dev/null; then
    echo "User hookdoo already exists...[OK]"
else
    echo "User hookdoo does not exist, creating..."
    adduser hookdoo --disabled-password --gecos "" --quiet
    echo "User hookdoo successfully created with no password attached...[OK]"
fi

echo "..."

# check if user hookdoo already has private key generated
echo "Setting up SSH private key for user hookdoo..."
HOOKDOO_KEY_FILE_PATH=/home/hookdoo/.ssh
HOOKDOO_PRIVATE_KEY_FILE=${HOOKDOO_KEY_FILE_PATH}/id_rsa
HOOKDOO_PUBLIC_KEY_FILE=${HOOKDOO_PRIVATE_KEY_FILE}.pub
AUTHORIZED_KEYS_FILE=${HOOKDOO_KEY_FILE_PATH}/authorized_keys
if [ ! -f ${HOOKDOO_PRIVATE_KEY_FILE} ]; then
    echo "No private key available for user hookdoo, okay, creating..."

    sudo -u hookdoo mkdir -p ${HOOKDOO_KEY_FILE_PATH}
    echo "Creating .ssh directory ${HOOKDOO_KEY_FILE_PATH}...[OK]"

    sudo -u hookdoo chmod 700 ${HOOKDOO_KEY_FILE_PATH}
    echo "Setting up privileges on .ssh directory...[OK]"

    sudo -u hookdoo ssh-keygen -t rsa -b 4096 -N "" -f ${HOOKDOO_PRIVATE_KEY_FILE} -q
    echo "Creating SSH private key file for user hookdoo...[OK]"

    sudo -u hookdoo touch ${AUTHORIZED_KEYS_FILE}
    sudo -u hookdoo cat ${HOOKDOO_PUBLIC_KEY_FILE}>${AUTHORIZED_KEYS_FILE}
    sudo -u hookdoo chmod 600 ${AUTHORIZED_KEYS_FILE}

    echo "Checking if ssh-agent is already running..."
    if [ ! -z ${SSH_AGENT_PID} ] && [ ps -p ${SSH_AGENT_PID} > /dev/null ] ; then
        echo "ssh-agent already running...[OK]"
    else
        echo "ssh-agent not running, okay, trying to start..."
        eval `ssh-agent -s` &>/dev/null
        echo "ssh-agent is now running...[OK]"
    fi

    sudo -E -s ssh-add ${HOOKDOO_PRIVATE_KEY_FILE} &>/dev/null
    echo "Authorizing created private key for access to this device...[OK]"
else
    echo "SSH private key already set up...[OK]"
fi

echo "..."

# require email and password to be input interactively
# or set up as env
if [ -z ${HOOKDOO_EMAIL} ] ; then
    echo "Enter your Hookdoo email: "
    read HOOKDOO_EMAIL
else
    echo "Using hookdoo email specified from ENV...[OK]"
    EMAIL=${HOOKDOO_EMAIL}
fi

echo "..."

if [ -z ${HOOKDOO_PASSWORD} ] ; then
    echo "Enter your Hookdoo password: "
    read -s HOOKDOO_PASSWORD
else
    echo "Using hookdoo password specified from ENV...[OK]"
    PASSWORD=${HOOKDOO_PASSWORD}
fi

echo "..."

# when user is set up, create server
echo "Resolving your public IP address..."
HOOKDOO_API="https://api.hookdoo.com"

CURRENT_DEVICE_IP_ADDR=$(curl -s --fail ${HOOKDOO_API}/whatsmyip)
if [ $? -ne 0 ]; then
    echo "Got unexpected response...[FAILED]"
    echo "Hint: can you access the internet from this device?"
    exit 1
else
    echo "Your public IP address resolved...[OK]"
fi

echo "..."

# try to obtain token for current user
echo "Authenticating with Hookdoo API..."
AUTH_OUTPUT=$(curl -s --fail -d "{\"primaryEmail\":\"${HOOKDOO_EMAIL}\", \"plaintextPassword\":\"${HOOKDOO_PASSWORD}\"}" -H "Content-Type: application/json" -X POST ${HOOKDOO_API}/session)
if [ $? -ne 0 ]; then
    echo "Got unexpected response...[FAILED]"
    echo "Hint: are your credentials correct?"
    exit 1
else
    SESSION_ID=$(echo ${AUTH_OUTPUT} | grep -Po "\"id\":\"\K([A-Za-z0-9-]*)")
    echo "Sucessfully obtained session token...[OK]"
fi

echo "..."

echo "Creating server..."
PRIVATE_KEY=$(awk '{printf "%s\\n", $0}' ${HOOKDOO_PRIVATE_KEY_FILE})
curl -s --fail\
        --data "{\"name\":\"server\", \"hostname\":\"${CURRENT_DEVICE_IP_ADDR}\", \"enabled\":true, \"port\":\"${SSH_PORT}\", \"username\":\"hookdoo\", \"authMethod\":\"1\", \"plaintextPrivateKey\":\"${PRIVATE_KEY}\"}"\
        -H "Content-Type: application/json"\
        -H "Cookie: session-production=${SESSION_ID}"\
        -X POST ${HOOKDOO_API}/server > /dev/null

if [ $? -ne 0 ]; then
    echo "Got unexpected response...[FAILED]"
    echo "Hint: have you exceeded your server definition quota?"
    exit 1
else
    echo "Sucessfully created server...[OK]"
fi

echo "..."

echo "All done!"
