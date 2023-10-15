#!/usr/bin/env sh

USAGE="Usage: $(basename $0) -d <domain-name> -i <server-ip> -p <trojan-password>"

args=$(getopt -o "d:i:p:h" -- "$@")
eval set -- "$args"
while [ $# -ge 1 ]; do
  case "$1" in
    --)
      # No more options left.
      shift
      break
      ;;
    -d)
      domain_name="$2"
      shift
      ;;
    -i)
      server_ip="$2"
      shift
      ;;
    -p)
      trojan_password="$2"
      shift
      ;;
    -h)
      echo "$USAGE"
      exit 0
      ;;
  esac
  shift
done

if [ -z "$server_ip" ] || [ -z "$domain_name" ] || [ -z "$trojan_password" ]; then
  echo "Error: Missing arguments"
  echo "$USAGE"
  exit 0
fi

apt update -y
if ! apt install -y cron docker.io docker-compose nginx wget curl jq unzip qrencode sudo; then
  echo "Some of the required packages are failed to install, please install them manually."
  echo "If this is a docker-related issue, please consider using the following command to install:"
  echo "    curl -fsSL https://get.docker.com | sh"
  return 1
fi

if ! grep -q certusers /etc/group; then
  /usr/sbin/groupadd certusers
else
  echo "User group \"certusers\" already exists."
fi

if ! grep -q docker /etc/group; then
  /usr/sbin/groupadd docker
else
  echo "User group \"docker\" already exists."
fi

if ! grep -q trojan /etc/passwd; then
  /usr/sbin/useradd -r -M -G certusers trojan
  echo "User \"trojan\" created."
else
  echo "User \"trojan\" already exists."
fi

if ! grep -q acme /etc/passwd; then
  /usr/sbin/useradd -r -m -G certusers acme
  echo "User \"acme\" created."
else
  echo "User \"acme\" already exists."
fi

sed -i.bak -e "s/^.*Port .*$/Port 22/g" \
  -e "s/^.*PermitRootLogin.*yes.*$/PermitRootLogin no/g" \
  -e "s/^.*PubkeyAuthentication.*$/PubkeyAuthentication yes/g" \
  -e "s/^.*AuthorizedKeysFile.*$/AuthorizedKeysFile .ssh\/authorized_keys/g" \
  -e "s/^.*PasswordAuthentication.*yes.*$/PasswordAuthentication no/g" \
  /etc/ssh/sshd_config
ufw disable
systemctl restart sshd
echo "OpenSSH server configuration has been reloaded."

if [ "bbr" = "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" ]; then
  echo "BBR congestion control algorithm is already enabled."
else
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  echo "BBR congestion control algorithm is now enabled."
fi

if [ -f ./nginx.conf ]; then
  rm -f /etc/nginx/sites-available/default
  rm -f /etc/nginx/sites-enabled/default
  sed -e "s/<<server_name>>/$domain_name/g" \
    -e "s/<<ip>>/$server_ip/g" \
    ./nginx.conf >/etc/nginx/sites-available/default
  ln /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
  rm -f ./nginx.conf
fi
mkdir -p /var/www/html/
chown trojan:trojan 400.html
mv -f ./400.html /var/www/html/400.html
systemctl restart nginx
echo "Nginx server configuration is done."

mkdir -p /etc/letsencrypt/live
chown -R acme:acme /etc/letsencrypt/live
nginx_user="$(ps -eo user,command | grep nginx | grep "worker process" | awk '{print $1}')"
usermod -G certusers "$nginx_user"
mkdir -p /var/www/acme-challenge
chown -R acme:certusers /var/www/acme-challenge

sudo -i -u acme bash <<EOF
if [ -e "/home/acme/.acme.sh" ]; then
  echo "acme.sh is installed."
else
  echo "Installing acme.sh ..."
  curl https://get.acme.sh | sh
fi
LE_WORKING_DIR="/home/acme/.acme.sh"
'/home/acme/.acme.sh/acme.sh' --set-default-ca --server letsencrypt
'/home/acme/.acme.sh/acme.sh' --issue -d "$domain_name" -w /var/www/acme-challenge
'/home/acme/.acme.sh/acme.sh' --install-cert -d "$domain_name" --key-file /etc/letsencrypt/live/private.key --fullchain-file /etc/letsencrypt/live/certificate.crt
'/home/acme/.acme.sh/acme.sh' --upgrade  --auto-upgrade
chmod -R 750 /etc/letsencrypt/live
EOF
chown -R acme:certusers /etc/letsencrypt/live

trojan_version=$(curl --silent "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" | jq ".tag_name" | tr -d '"')
if [ "$trojan_version" = "null" ]; then
  exit 1
fi
wget -c -O trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/$trojan_version/trojan-go-linux-amd64.zip"
unzip -o trojan-go.zip trojan-go
rm -f trojan-go.zip
mkdir -p /usr/local/etc/trojan-go
mv -f trojan-go /usr/local/bin/trojan-go
mv -f config.yaml /usr/local/etc/trojan-go/config.yaml
mv -f trojan-go.service /etc/systemd/system/trojan-go.service
chown trojan:trojan /usr/local/bin/trojan-go
chmod 500 /usr/local/bin/trojan-go
chown root:root /etc/systemd/system/trojan-go.service
chown -R trojan:trojan /usr/local/etc/trojan-go

sed -i.bak -e "s/<<password>>/$trojan_password/g" \
  -e "s/<<server_name>>/$domain_name/g" \
  /usr/local/etc/trojan-go/config.yaml

systemctl daemon-reload
systemctl enable trojan-go
systemctl enable nginx
systemctl restart trojan-go
if systemctl status trojan-go | grep -q "active (running)"; then
  echo "Trojan is running."
else
  echo "Trojan failed to start."
fi

if ! crontab -u trojan -l 2>/dev/null | grep -q "trojan-go"; then
  echo "Adding Trojan cron job ..."
  entry="30 4 */3 * * /bin/systemctl restart trojan-go"
  if crontab -u trojan -l 2>&1 | grep -q "no crontab"; then
    echo "$entry" | crontab -u trojan -
  else
    crontab -u trojan -l 2>/dev/null | sed "\$a $entry" | crontab -u trojan -
  fi
  echo "Trojan cron job has been added."
fi

echo "Your Trojan URI: trojan://$trojan_password@$domain_name:443?sni=$domain_name&allowinsecure=0"
echo "Generating QR code of Trojan URI..."
qrencode -o - -t ANSI "trojan://$trojan_password@$domain_name:443?sni=$domain_name&allowinsecure=0"

echo "Running docker-compose to host a CyberChef web page ..."
docker-compose up -d
echo "Installation is done."
