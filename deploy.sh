#!/bin/bash

# Exits on first failed command
set -e

# Errors on undefined variable
set -u

XVA_URL=https://xoa.io/xva

# Welcome message
printf "\n👋 \033[1mWelcome to the XOA auto-deploy script!\033[0m\n\n"

if ! which xe 2> /dev/null >&2
then
  echo
  echo '🔴 Sorry, the "xe" command is required for this auto-deploy.'
  echo
  echo '🚀 Please make sure you are running this script on an XCP-ng host.'
  echo
  exit 1
fi

# Basic check: are we on a XS/CH/XCP-ng host?
# Using a more flexible check for XCP-ng and other hypervisors
if ! (grep -i "XenServer\|Citrix Hypervisor\|XCP-ng\|xcp" /etc/issue > /dev/null || [ -f /etc/xensource-inventory ])
then
  printf "\n🔴 Sorry, it seems you are not on a XenServer or XCP-ng host.\n\n"
  printf "\n🚀 \033[1mThis script is meant to be deployed on XenServer or XCP-ng only.\033[0m\n\n"
  exit 1
fi

printf "✅ XCP-ng/XenServer host detected. Proceeding...\n\n"

# Proxy Configuration
printf "⚙️  PROXY CONFIGURATION\n\n"
read -p "Use proxy? (y/n) [n] " use_proxy
use_proxy=${use_proxy:-n}

if [ "$use_proxy" = "y" ] || [ "$use_proxy" = "Y" ]
then
  read -p "Proxy URL (e.g., http://proxy.example.com:3128): " proxy_url
  export http_proxy="$proxy_url"
  export https_proxy="$proxy_url"
  printf "\nProxy configured: %s\n\n" "$proxy_url"
else
  printf "\nNo proxy will be used.\n\n"
fi

# Network selection
printf "⚙️  NETWORK SELECTION\n\n"
printf "Available networks:\n"

# Get all networks and create an array 
mapfile -t networks < <(xe network-list params=uuid,name-label --minimal | tr "," ":" | sort)

# Display available networks
for i in "${!networks[@]}"; do
  network_info="${networks[$i]}"
  network_uuid=$(echo "$network_info" | cut -d':' -f1)
  network_name=$(echo "$network_info" | cut -d':' -f2-)
  printf "%3d) %s (UUID: %s)\n" $((i+1)) "$network_name" "$network_uuid"
done

# Default to management network
default_network=$(xe pif-list params=network-uuid,network-name-label management=true --minimal | tr "," ":" | head -1)
default_network_uuid=$(echo "$default_network" | cut -d':' -f1)
default_network_name=$(echo "$default_network" | cut -d':' -f2-)

printf "\nDefault selection: %s (Management Network)\n" "$default_network_name"
read -p "Choose the number of the network for XOA [Default = Management]: " network_choice

# Process network selection
selected_network_uuid="$default_network_uuid"
if [[ -n "$network_choice" && "$network_choice" =~ ^[0-9]+$ && "$network_choice" -le "${#networks[@]}" && "$network_choice" -gt 0 ]]; then
  selected_network_info="${networks[$((network_choice-1))]}"
  selected_network_uuid=$(echo "$selected_network_info" | cut -d':' -f1)
  selected_network_name=$(echo "$selected_network_info" | cut -d':' -f2-)
  printf "\nSelected network: %s (UUID: %s)\n\n" "$selected_network_name" "$selected_network_uuid"
else
  printf "\nUsing Management Network: %s (UUID: %s)\n\n" "$default_network_name" "$default_network_uuid"
fi

# Initial choice on network settings: fixed IP or DHCP? (default)
printf "⚙️  STEP 1: XOA Configuration \n\n"
printf "Network settings:\n"
read -p "IP address? [dhcp] " ip
ip=${ip:-dhcp}
if [ "$ip" != 'dhcp' ]
then
  read -p "Netmask? [255.255.255.0] " netmask
  netmask=${netmask:-255.255.255.0}
  read -p "Gateway? " gateway
  read -p "DNS? [8.8.8.8] " dns
  dns=${dns:-8.8.8.8}
else
  printf "\nYour XOA will be started using DHCP\n"
fi

printf '\n'

# Default or custom NTP servers
read -p 'Custom NTP servers (separated by spaces)? [] ' ntp
printf '\n'

# SSH account
printf "xoa SSH account:\n"
read -srp "Password? (disabled if empty) " xoaPassword
printf '\n\n'

if [ -n "$xoaPassword" ]
then
  printf "xoa account will be enabled\n\n"
else
  printf "xoa account is disabled. To enable it later, see https://xen-orchestra.com/docs/troubleshooting.html#set-or-recover-xoa-vm-password\n\n"
fi

# Downloading and importing the VM
printf "📥  STEP 2: XOA Download\n\n"
printf "Importing XOA VM: this might take a while..."
if ! {
  if [ $# -ge 1 ]
  then
    # import from file
    uuid=$(xe vm-import filename="$1" 2>&1)
   else
    # import from URL
    if ! uuid=$(xe vm-import url="$XVA_URL" 2>&1)
    then
      # if it fails (likely due to XS < 7.0 but maybe HTTP proxy)
      # use wget with environment variables for proxy
      if [ "$use_proxy" = "y" ] || [ "$use_proxy" = "Y" ]
      then
        # Relying on the already set environment variables http_proxy and https_proxy
        # Debugging output
        printf "\nUsing wget with proxy %s for download...\n" "$http_proxy"
        uuid=$(wget --no-check-certificate --no-verbose -O- "$XVA_URL" | xe vm-import filename=/dev/stdin 2>&1)
      else
        uuid=$(wget --no-check-certificate --no-verbose -O- "$XVA_URL" | xe vm-import filename=/dev/stdin 2>&1)
      fi
    fi
  fi
}
then
  printf "\n\nAuto-deploy failed. Please contact us at https://vates.tech/contact for assistance.\nError:\n\n %s\n\n" "$uuid"
  exit 0
fi

# If static IP selected, fill the xenstore
if [ "$ip" != 'dhcp' ]
then
  xe vm-param-set uuid="$uuid" xenstore-data:vm-data/ip="$ip" xenstore-data:vm-data/netmask="$netmask" xenstore-data:vm-data/gateway="$gateway" xenstore-data:vm-data/dns="$dns"
fi

# If custom NTP servers are provided, fill the xenstore
if [ -n "$ntp" ]
then
  xe vm-param-set uuid="$uuid" xenstore-data:vm-data/ntp="$ntp"
fi

if [ -n "$xoaPassword" ]
then
  xe vm-param-set uuid="$uuid" xenstore-data:vm-data/system-account-xoa-password="$xoaPassword"
fi

# By default, the deploy script will make sure we boot XOA with a VIF on the selected network
vifUuid=$(xe vm-vif-list uuid="$uuid" params=uuid minimal=true)

# Move the VIF to the selected network
printf "\nConnecting VM to the selected network...\n"
xe vif-move uuid="$vifUuid" network-uuid="$selected_network_uuid"

# Starting the VM
printf "\n\n🏁  STEP 3: Starting XOA\n\n"

printf "Booting XOA VM...\n"
xe vm-start uuid="$uuid"
sleep 2

# Waiting for the VM IP from Xen tools for 60 secs
printf "Waiting for your XOA to be ready...\n"

# list VM IP addresses and returns the first non link local addresses
#
# IPv6 addresses are enclosed in brackets for use in URL
get_hostname() {
  local address addresses i n

  IFS=';' read -r -a addresses <<<"$(xe vm-param-get uuid="$uuid" param-name=networks)"

  # Bash < 4.4 reports unbound variable if array is empty
  set +u
  n=${#addresses[@]}
  set -u
  if [ $n -eq 0 ]
  then
    return 1
  fi

  # Remove prefixes and dedup
  readarray -t addresses <<<"$(printf '%s\n' "${addresses[@]#*': '}" | sort -u)"

  for i in "${!addresses[@]}"
  do
    address=${addresses[$i]}
    case "$address" in
      fe80:*) # ignore link local address
        unset "addresses[$i]"
        continue
        ;;
      *:*)
        address="[$address]"
        ;;
    esac
    addresses[$i]=$address
  done

  set +u
  n=${#addresses[@]}
  set -u
  if [ $n -eq 0 ]
  then
    return 1
  fi

  printf '\n\033[1m'
  if [ "$ip" = dhcp ]
  then
    printf "🟢 Your XOA is ready at:\n"
    for address in "${addresses[@]}"
    do
      printf "  https://%s/\n" "$address"
    done
  else
    # If we use a fixed IP but on a DHCP enabled network
    # We don't want to get the first IP displayed by the tools
    # But the fixed one
    printf "🟢 Your XOA is ready at https://%s/\n" "$ip"

    # clean the xenstore data
    xe vm-param-remove uuid="$uuid" param-name=xenstore-data param-key=vm-data/dns param-key=vm-data/ip param-key=vm-data/netmask param-key=vm-data/gateway &> /dev/null
  fi
  printf '\033[0m'
}

wait=0
limit=60
while {
  ! get_hostname && \
  [ "$wait" -lt "$limit" ]
}
do
  let wait=wait+1
  sleep 1
done

if [ $wait -eq $limit ]
then
  printf "\n🟠  \033[1mYour XOA booted but we couldn't fetch its IP address\033[0m\n"
fi

printf "\nDefault UI credentials: admin@admin.net/admin\n"
printf "\nVM UUID: %s\n\n" "$uuid"

# Unset proxy if set
if [ "$use_proxy" = "y" ] || [ "$use_proxy" = "Y" ]
then
  unset http_proxy
  unset https_proxy
fi
