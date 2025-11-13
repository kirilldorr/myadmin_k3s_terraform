#!/bin/bash -e

echo "LOG update apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo "LOG Installing Docker&AWS CLI..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release awscli

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io

echo "LOG Starting Docker..."
systemctl start docker
systemctl enable docker
usermod -a -G docker ubuntu

ECR_REGISTRY="${ecr_registry_id}.dkr.ecr.${aws_region}.amazonaws.com"

echo "LOG Gettong ETC password..."
ECR_PASSWORD=""
RETRY_COUNT=0
MAX_RETRIES=12 

until [ $RETRY_COUNT -ge $MAX_RETRIES ]; do
  
  ECR_PASSWORD=$(aws ecr get-login-password --region ${aws_region} 2>/dev/null)
  if [ -n "$ECR_PASSWORD" ]; then
    echo "LOG Successfull."
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT+1))
  echo "LOG Retry (for 5s)..."
  sleep 5
done

if [ -z "$ECR_PASSWORD" ]; then
  echo "LOG ERROR: Unable to retrieve ECR password after $MAX_RETRIES attempts."
  exit 1
fi

echo $ECR_PASSWORD | docker login --username AWS --password-stdin $ECR_REGISTRY

if [ $? -ne 0 ]; then
  echo "LOG ERROR: Docker login to ECR failed."
  exit 1
fi
echo "LOG Docker login successful."

echo "LOG Waiting for Docker socket..."
timeout 60 sh -c 'until docker info > /dev/null 2>&1; do echo "LOG Waiting for Docker socket..."; sleep 3; done'

if ! docker info > /dev/null 2>&1; then
  echo "LOG ERROR: Docker socket not available after timeout."
  exit 1
fi

echo "LOG Turning off ufw..."
ufw disable || echo "LOG ufw not installed, skipping disable."

echo "LOG Retrieving public IP..."
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# ВАЖЛИВО: Змінні Bash, як і раніше, потребують подвійного долара ($$)
echo "LOG Installing K3s з --tls-san=$${PUBLIC_IP}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--docker --tls-san $${PUBLIC_IP}" sh -

echo "LOG Waiting for k3s.yaml to be created..."
START_TIME=$(date +%s)
until [ -f /etc/rancher/k3s/k3s.yaml ]; do
  CURRENT_TIME=$(date +%s)
  if (( CURRENT_TIME - START_TIME > 300 )); then
    echo "LOG ERROR: Timeout waiting for k3s.yaml."
    echo "LOG k3s.yaml status check:"
    systemctl status k3s.service || systemctl status k3s-server.service || echo "LOG Failed to get k3s service status"
    echo "LOG Last 50 lines of k3s logs:"
    journalctl -u k3s.service -n 50 --no-pager || journalctl -u k3s-server.service -n 50 --no-pager || echo "LOG Failed to get k3s logs"
    exit 1
  fi
  echo "LOG Waiting for k3s.yaml... (passed $(( CURRENT_TIME - START_TIME )) seconds)"
  sleep 5
done

echo "LOG k3s.yaml found."

echo "LOG Updating k3s.yaml with public IP..."
sed -i "s/127.0.0.1/$${PUBLIC_IP}/g" /etc/rancher/k3s/k3s.yaml

echo "LOG Copying k3s.yaml to /home/ubuntu/k3s.yaml..."
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/k3s.yaml
chown ubuntu:ubuntu /home/ubuntu/k3s.yaml

