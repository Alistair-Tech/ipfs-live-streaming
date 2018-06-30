#!/usr/bin/env bash

set -e

DOMAIN_NAME=$1
RTMP_SERVER_PRIVATE_IP=$2

IPFS_VERSION=0.4.15

# Wait for cloud-init to complete
until [[ -f /var/lib/cloud/instance/boot-finished ]]; do
  sleep 1
done

# Prevent apt-daily from holding up /var/lib/dpkg/lock on boot
systemctl disable apt-daily.service
systemctl disable apt-daily.timer

# Install Digital Ocean new metrics
curl -sSL https://agent.digitalocean.com/install.sh | sh

# Install programs
apt update
apt install -y \
  ffmpeg \
  inotify-tools \
  jq

# Create directory for generating client keys
mkdir /root/client-keys

########
# IPFS #
########

# Install IPFS
cd /tmp
wget "https://dist.ipfs.io/go-ipfs/v${IPFS_VERSION}/go-ipfs_v${IPFS_VERSION}_linux-amd64.tar.gz"
tar xvfz "go-ipfs_v${IPFS_VERSION}_linux-amd64.tar.gz"
cp go-ipfs/ipfs /usr/local/bin
cd ~

# Configure IPFS
ipfs init
sed -i 's#"Gateway": "/ip4/127.0.0.1/tcp/8080#"Gateway": "/ip4/0.0.0.0/tcp/8080#' ~/.ipfs/config
cp -f /tmp/ipfs-server/ipfs.service /etc/systemd/system/ipfs.service
systemctl daemon-reload
systemctl enable ipfs
systemctl start ipfs

# Write IPFS identity to client file
until [[ `ipfs id >/dev/null 2>&1; echo $?` -eq 0 ]]; do
  sleep 1
done
IPFS_ID=`ipfs id | jq .ID | sed 's/"//g'`
echo -n "$IPFS_ID" > ~/client-keys/ipfs_id

########################
# Process video stream #
########################

# Install video stream processing script
cp -f /tmp/ipfs-server/process-stream.sh ~/process-stream.sh

# Save settings to a file
echo "#!/bin/sh" > ~/settings
echo "export DOMAIN_NAME=\"${DOMAIN_NAME}\"" >> ~/settings
echo "export RTMP_SERVER_PRIVATE_IP=\"${RTMP_SERVER_PRIVATE_IP}\"" >> ~/settings
echo "export RTMP_STREAM=\"rtmp://${RTMP_SERVER_PRIVATE_IP}/live\"" >> ~/settings
echo "export IPFS_GATEWAY=\"http://ipfs-server.${DOMAIN_NAME}:8080\"" >> ~/settings
chmod +x ~/settings

# Install and start process-stream service
cp -f /tmp/ipfs-server/process-stream.service /etc/systemd/system/process-stream.service
systemctl daemon-reload
systemctl enable process-stream
systemctl start process-stream

# Install video streaming client (TODO: move code to this repo)
cd ~
apt install -y \
  nginx \
  zip
rm -rf /var/www/html/*
cd /var/www/html
unzip /tmp/ipfs-server/hlsclient.zip

echo "originalgw=gw='http://ipfs-server.$DOMAIN_NAME:8080/'" >> /var/www/html/common.js
echo "ipnsm3u8='http://ipfs-server.$DOMAIN_NAME:8080/ipns/$IPFS_ID'" >> /var/www/html/common.js
