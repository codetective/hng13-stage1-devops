
#!/usr/bin/env bash


set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/deploy_${TIMESTAMP}.log"

log()   { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S%z)" "$*" | tee -a "$LOG_FILE"; }
info()  { log "INFO: $*"; }
error() { log "ERROR: $*"; }
succ()  { log "DONE: $*"; }
die()   { error "$*"; exit "${2:-1}"; }

trap 'error "Unexpected error at line $LINENO. See $LOG_FILE"; exit 2' ERR
trap 'log "Interrupted"; exit 130' INT

CLEANUP_MODE=0
for a in "$@"; do
case "$a" in
--cleanup) CLEANUP_MODE=1 ;;
-h|--help) echo "Usage: $0 [--cleanup]"; exit 0 ;;
esac
done


read_input() {
: "${GIT_URL:=$(printf '' ; read -p 'Git repository to deploy (https://...): ' REPLY && printf '%s' "$REPLY")}"
: "${PAT:=$(printf '' ; read -s -p 'Personal Access Token (press Enter if public): ' REPLY && printf '%s' "$REPLY" && echo)}"
: "${BRANCH:=$(printf '' ; read -p "Branch [main]: " REPLY && printf '%s' "${REPLY:-main}")}"
: "${REMOTE_USER:=$(printf '' ; read -p 'Remote SSH username: ' REPLY && printf '%s' "$REPLY")}"
: "${REMOTE_HOST:=$(printf '' ; read -p 'Remote server IP/hostname: ' REPLY && printf '%s' "$REPLY")}"
: "${SSH_KEY:=$(printf '' ; read -p 'SSH key path (e.g. ~/.ssh/id_rsa): ' REPLY && printf '%s' "$REPLY")}"
: "${CONTAINER_PORT:=$(printf '' ; read -p 'App port inside container (e.g. 3000): ' REPLY && printf '%s' "$REPLY")}"
: "${REMOTE_PROJECT_DIR:=$(printf '' ; read -p 'Remote project directory (optional): ' REPLY && printf '%s' "$REPLY")}"

if [ -z "$GIT_URL" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$SSH_KEY" ] || [ -z "$CONTAINER_PORT" ]; then
die "You didn’t enter all required details (repo URL, SSH user, host, key, or port)."
fi

REPO_NAME="$(basename -s .git "$GIT_URL")"
if [ -z "$REMOTE_PROJECT_DIR" ]; then
REMOTE_PROJECT_DIR="/home/${REMOTE_USER}/${REPO_NAME}"
fi
}


check_local_prereqs() {
for c in git ssh rsync curl; do
command -v "$c" >/dev/null 2>&1 || die "$c not found — please install it."
done
info "Local tools ready."
}


prepare_local_repo() {
info "Getting repo ready for $GIT_URL (branch: $BRANCH)"
if [ -n "$PAT" ] && printf '%s' "$GIT_URL" | grep -qE '^https?://'; then
AUTH_GIT_URL="$(printf '%s' "$GIT_URL" | sed -E "s#https?://#https://${PAT}@#")"
else
AUTH_GIT_URL="$GIT_URL"
fi

if [ -d "$SCRIPT_DIR/$REPO_NAME/.git" ]; then
info "Repo exists. Pulling latest changes..."
(cd "$SCRIPT_DIR/$REPO_NAME" && git fetch --all --prune >>"$LOG_FILE" 2>&1 && git checkout "$BRANCH" >>"$LOG_FILE" 2>&1 && git pull origin "$BRANCH" >>"$LOG_FILE" 2>&1) || die "Git pull failed."
else
info "Cloning from remote..."
(cd "$SCRIPT_DIR" && git clone --branch "$BRANCH" "$AUTH_GIT_URL" >>"$LOG_FILE" 2>&1) || die "Git clone failed."
fi

cd "$SCRIPT_DIR/$REPO_NAME"
if [ -f "docker-compose.yml" ] || [ -f "Dockerfile" ]; then
succ "Docker setup found."
else
info "No Dockerfile found. Creating a simple one for Node.js..."
cat > Dockerfile <<'DOCKER'
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production || npm install --production || true
COPY . .
EXPOSE 3000
CMD ["npm","start"]
DOCKER
succ "Default Dockerfile created."
fi
}

check_ssh_connectivity() {
info "Testing SSH access to ${REMOTE_USER}@${REMOTE_HOST}..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" >/dev/null 2>&1 || die "SSH connection failed. Check key or server access."
succ "SSH connection works."
}


install_docker_if_needed() {
info "Checking if Docker exists..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'DOCKER_CHECK'
set -euo pipefail
if command -v docker >/dev/null 2>&1; then
echo "Docker already installed: $(docker --version)"
exit 0
fi
echo "Docker not found. Installing..."
curl -fsSL [https://get.docker.com](https://get.docker.com) -o get-docker.sh && sudo sh get-docker.sh >/tmp/docker_install.log 2>&1
sudo systemctl enable --now docker >/dev/null 2>&1
sudo usermod -aG docker "$USER" >/dev/null 2>&1 || true
echo "Docker installed: $(docker --version)"
DOCKER_CHECK
succ "Docker ready."
}


install_docker_compose_if_needed() {
info "Checking if Docker Compose exists..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'COMPOSE_CHECK'
set -euo pipefail
if command -v docker-compose >/dev/null 2>&1; then
echo "Docker Compose found: $(docker-compose --version)"
exit 0
fi
echo "Installing Docker Compose..."
sudo curl -L "[https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname](https://github.com/docker/compose/releases/latest/download/docker-compose-$%28uname) -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose || true
echo "Docker Compose installed: $(docker-compose --version)"
COMPOSE_CHECK
succ "Docker Compose ready."
}


install_nginx_if_needed() {
info "Checking if Nginx exists..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'NGINX_CHECK'
set -euo pipefail
if command -v nginx >/dev/null 2>&1; then
echo "Nginx found: $(nginx -v 2>&1)"
exit 0
fi
echo "Installing Nginx..."
if command -v apt-get >/dev/null 2>&1; then
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y nginx >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
sudo yum install -y epel-release nginx >/dev/null 2>&1
else
echo "Unsupported OS for Nginx install"
exit 1
fi
sudo systemctl enable --now nginx >/dev/null 2>&1
echo "Nginx installed."
NGINX_CHECK
succ "Nginx ready."
}


remote_prepare() {
info "Preparing remote server..."
install_docker_if_needed
install_docker_compose_if_needed
install_nginx_if_needed
succ "Remote environment ready."
}


transfer_project() {
info "Sending project files to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_PROJECT_DIR}' && chown ${REMOTE_USER}:${REMOTE_USER} '${REMOTE_PROJECT_DIR}'"
if command -v rsync >/dev/null 2>&1; then
rsync -avz --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" "$SCRIPT_DIR/$REPO_NAME/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"$LOG_FILE" 2>&1
else
scp -i "$SSH_KEY" -r "$SCRIPT_DIR/$REPO_NAME/" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/" >>"$LOG_FILE" 2>&1
fi
succ "Project transferred."
}


remote_deploy() {
info "Starting deployment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_DEPLOY
set -euo pipefail
cd "${REMOTE_PROJECT_DIR}"
echo "Cleaning old containers and images..."
sudo docker ps -a --filter "name=${REPO_NAME}" --format '{{.ID}}' | xargs -r sudo docker rm -f || true
sudo docker images --filter "reference=*${REPO_NAME}*" --format '{{.ID}}' | xargs -r sudo docker rmi -f || true

if [ -f docker-compose.yml ]; then
echo "Using docker-compose..."
sudo docker-compose down 2>/dev/null || true
sudo docker-compose up -d --build
else
echo "Using Dockerfile..."
IMG_TAG="${REPO_NAME}:latest"
sudo docker build -t "$IMG_TAG" .
sudo docker run -d --name "${REPO_NAME}_$(date +%s)" --restart unless-stopped -p ${CONTAINER_PORT}:${CONTAINER_PORT} "$IMG_TAG"
fi
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
REMOTE_DEPLOY
succ "Deployment done."
}


configure_nginx() {
info "Setting up Nginx reverse proxy..."
NGINX_CONFIG_FILE="/tmp/nginx_${REPO_NAME}.conf"
cat > "$NGINX_CONFIG_FILE" <<EOF
server {
listen 80;
server_name _;
location / {
proxy_pass [http://127.0.0.1:${CONTAINER_PORT}](http://127.0.0.1:${CONTAINER_PORT});
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
}
}
EOF
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NGINX_CONFIG_FILE" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/nginx_config.conf" >>"$LOG_FILE" 2>&1
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<'NGINX_SETUP'
set -euo pipefail
sudo mv /tmp/nginx_config.conf /etc/nginx/sites-available/app.conf
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default || true
sudo nginx -t
sudo systemctl reload nginx
NGINX_SETUP
rm -f "$NGINX_CONFIG_FILE"
succ "Nginx configured (HTTP only)."
}


validate_deployment() {
info "Validating deployment..."
sleep 5
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active docker" >/dev/null 2>&1 || die "Docker not active."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active nginx" >/dev/null 2>&1 || die "Nginx not active."
info "Testing app at http://${REMOTE_HOST}"
if curl -sfS --connect-timeout 10 "http://${REMOTE_HOST}" >/dev/null 2>&1; then
succ "App reachable at http://${REMOTE_HOST}"
else
info "App not reachable — check firewall or port mapping."
fi
}


cleanup_remote() {
info "Cleaning remote host..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" /bin/bash <<REMOTE_CLEAN
set -euo pipefail
sudo docker ps -a --format '{{.Names}}' | grep -E '${REPO_NAME}' | xargs -r sudo docker rm -f || true
sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '${REPO_NAME}' | xargs -r sudo docker rmi -f || true
sudo rm -f /etc/nginx/sites-enabled/app.conf /etc/nginx/sites-available/app.conf || true
sudo nginx -t && sudo systemctl reload nginx || true
sudo rm -rf "${REMOTE_PROJECT_DIR}" || true
echo "Cleanup done."
REMOTE_CLEAN
succ "Remote cleanup done."
}


main() {
if [ "$CLEANUP_MODE" -eq 1 ]; then
read_input
check_local_prereqs
check_ssh_connectivity
cleanup_remote
succ "finished cleanup."
exit 0
fi

read_input
check_local_prereqs
prepare_local_repo
check_ssh_connectivity
remote_prepare
transfer_project
remote_deploy
configure_nginx
validate_deployment

succ "Deployment complete."
info "You can access the app at: http://${REMOTE_HOST}"
info "Logs are saved at: $LOG_FILE"
}

main "$@"
