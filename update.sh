#!/usr/bin/env sh

trojan_version=$(curl --silent "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" | jq ".tag_name" | tr -d '"')
installed_version=$(/usr/local/bin/trojan-go -version | grep "Trojan-Go v" | awk '{print $2}')

if [ "$trojan_version" != "$installed_version" ]; then
  echo "There is a new version for Trojan-GO: $installed_version (OLD) -> $trojan_version (NEW)."
  echo "Updating Trojan-GO ..."
  wget -c -O trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/$trojan_version/trojan-go-linux-amd64.zip"
  unzip -o trojan-go.zip trojan-go
  rm -f trojan-go.zip
  mv -f trojan-go /usr/local/bin/trojan-go
  systemctl restart trojan-go
  echo "Trojan-GO has been updated to $trojan_version."
else
  echo "Trojan-GO is already up to date."
fi
