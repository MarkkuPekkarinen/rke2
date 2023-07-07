#!/usr/bin/env bash

# https://github.com/clemenko/rke2
# this script assumes digitalocean is setup with DNS.
# you need doctl, kubectl, uuid, jq, k3sup, pdsh and curl installed.
# clemenko@gmail.com 

###################################
# edit varsw
###################################
set -e
num=3
password=Pa22word
zone=nyc1
size=s-4vcpu-8gb-amd 
#s-8vcpu-16gb-amd
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
domain=rfed.io

#image=ubuntu-22-04-x64
#image=almalinux-8-x64
image=rockylinux-9-x64

# rancher / k8s
prefix=rke # no rke k3s
rke2_channel=v1.25 #latest

# ingress nginx or traefik
ingress=nginx

# stackrox automation
export REGISTRY_USERNAME=AndyClemenko
# export REGISTRY_PASSWORD= # set on the command line 

# Carbide creds
export CARBIDEUSER=andy-clemenko-read-token
#export CARBIDEPASS=  # set on the command line

######  NO MOAR EDITS #######
export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NO_COLOR='\x1b[0m'
export PDSH_RCMD_TYPE=ssh

#better error checking
command -v doctl >/dev/null 2>&1 || { echo -e "$RED" " ** Doctl was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo -e "$RED" " ** Curl was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "$RED" " ** Jq was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }
command -v pdsh >/dev/null 2>&1 || { echo -e "$RED" " ** Pdsh was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }
command -v k3sup >/dev/null 2>&1 || { echo -e "$RED" " ** K3sup was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "$RED" " ** Kubectl was not found. Please install. ** " "$NO_COLOR" >&2; exit 1; }

#### doctl_list ####
function dolist () { doctl compute droplet list --no-header|grep $prefix |sort -k 2; }

source functions.sh

################################# up ################################
function up () {
build_list=""
# helm repo update > /dev/null 2>&1

if [ ! -z $(dolist) ]; then
  echo -e "$RED" "Warning - cluster already detected..." "$NO_COLOR"
  exit
fi

#rando list generation
for i in $(seq 1 $num); do build_list="$build_list $prefix$i"; done

#build VMS
echo -e -n " building vms -$build_list"
doctl compute droplet create $build_list --region $zone --image $image --size $size --ssh-keys $key --wait --droplet-agent=false > /dev/null 2>&1
echo -e "$GREEN" "ok" "$NO_COLOR"

#check for SSH
echo -e -n " checking for ssh "
for ext in $(dolist | awk '{print $3}'); do
  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out\|refused' | wc -l) = 0 ]; do echo -e -n "." ; sleep 5; done
done
echo -e "$GREEN" "ok" "$NO_COLOR"

#get ips
host_list=$(dolist | awk '{printf $3","}' | sed 's/,$//')
server=$(dolist | sed -n 1p | awk '{print $3}')
worker_list=$(dolist | sed 1d | awk '{printf $3","}' | sed 's/,$//')

#update DNS
echo -e -n " updating dns"
doctl compute domain records create $domain --record-type A --record-name $prefix --record-ttl 60 --record-data $server > /dev/null 2>&1
doctl compute domain records create $domain --record-type CNAME --record-name "*" --record-ttl 60 --record-data $prefix.$domain. > /dev/null 2>&1
echo -e "$GREEN" "ok" "$NO_COLOR"

sleep 10

#host modifications
if [[ "$image" = *"ubuntu"* ]]; then
  echo -e -n " adding os packages"
  pdsh -l root -w $host_list 'mkdir -p /opt/kube; systemctl stop ufw; systemctl disable ufw; echo -e "PubkeyAcceptedKeyTypes=+ssh-rsa" >> /etc/ssh/sshd_config; systemctl restart sshd; export DEBIAN_FRONTEND=noninteractive; apt update; apt install nfs-common -y;  #apt upgrade -y; apt autoremove -y' > /dev/null 2>&1
  echo -e "$GREEN" "ok" "$NO_COLOR"
fi

if [[ "$image" = *"centos"* || "$image" = *"rocky"* || "$image" = *"alma"* ]]; then
  centos_packages
fi

#kernel tuning from functions
kernel

#or deploy k3s
if [ "$prefix" != k3s ] && [ "$prefix" != rke ]; then exit; fi

carbide_reg

if [ "$prefix" = k3s ]; then
  echo -e -n " deploying k3s"
  k3sup install --ip $server --user root --cluster --k3s-extra-args '' --k3s-channel $rke2_channel --local-path ~/.kube/config > /dev/null 2>&1
  # --k3s-extra-args '--disable traefik'

  for workeri in $(dolist | sed 1d | awk '{print $3}'); do 
    k3sup join --ip $workeri --server-ip $server --user root --k3s-extra-args '' --k3s-channel $rke2_channel > /dev/null 2>&1
  done 
  
  #rsync -avP ~/.kube/config root@$server:/opt/kube/config > /dev/null 2>&1
  
  echo -e "$GREEN" "ok" "$NO_COLOR"
fi

#or deploy rke2
# https://docs.rke2.io/install/methods/#enterprise-linux-8
if [ "$prefix" = rke ]; then
  echo -e -n "$BLUE" "deploying rke2" "$NO_COLOR"
  if [ "$ingress" = nginx ]; then ingress_file="#disable: rke2-ingress-nginx"; else ingress_file="disable: rke2-ingress-nginx"; fi

  ssh root@$server 'mkdir -p /var/lib/rancher/rke2/server/manifests/; useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U; echo -e "apiVersion: audit.k8s.io/v1\nkind: Policy\nrules:\n- level: RequestResponse" > /etc/rancher/rke2/audit-policy.yaml; echo -e "'$ingress_file'\n#profile: cis-1.6\nselinux: true\nsecrets-encryption: true\ntls-san:\n- rke."'$domain'"\nwrite-kubeconfig-mode: 0600\nuse-service-account-credentials: true\nkube-controller-manager-arg:\n- bind-address=127.0.0.1\n- use-service-account-credentials=true\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-scheduler-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-apiserver-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\n- authorization-mode=RBAC,Node\n- anonymous-auth=false\n- audit-policy-file=/etc/rancher/rke2/audit-policy.yaml\n- audit-log-mode=blocking-strict\n- audit-log-maxage=30\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml ; echo -e "apiVersion: helm.cattle.io/v1\nkind: HelmChartConfig\nmetadata:\n  name: rke2-ingress-nginx\n  namespace: kube-system\nspec:\n  valuesContent: |-\n    controller:\n      config:\n        use-forwarded-headers: true\n      extraArgs:\n        enable-ssl-passthrough: true" > /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml; curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL='$rke2_channel' sh - ; systemctl enable --now rke2-server.service' > /dev/null 2>&1

# for CIS
#  cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf; systemctl restart systemd-sysctl;

  sleep 10

  token=$(ssh root@$server 'cat /var/lib/rancher/rke2/server/node-token')

  pdsh -l root -w $worker_list 'curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL='$rke2_channel' INSTALL_RKE2_TYPE=agent sh - && echo -e "selinux: true\nserver: https://"'$server'":9345\ntoken: "'$token'"\nwrite-kubeconfig-mode: 0600\n#profile: cis-1.6\nkube-apiserver-arg:\n- authorization-mode=RBAC,Node\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml; systemctl enable --now rke2-agent.service' > /dev/null 2>&1

  ssh root@$server cat /etc/rancher/rke2/rke2.yaml | sed  -e "s/127.0.0.1/$server/g" > ~/.kube/config 
  chmod 0600 ~/.kube/config

  echo -e "$GREEN" "ok" "$NO_COLOR"
fi

echo -e -n " - cluster active "
sleep 5
until [ $(kubectl get node|grep NotReady|wc -l) = 0 ]; do echo -e -n "."; sleep 2; done
echo -e "$GREEN" "ok" "$NO_COLOR"
}

############################## kill ################################
#remove the vms
function kill () {

if [ ! -z $(dolist | awk '{printf $3","}' | sed 's/,$//') ]; then
  echo -e -n " killing it all "
  for i in $(dolist | awk '{print $2}'); do doctl compute droplet delete --force $i; done
  for i in $(dolist | awk '{print $3}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
  for i in $(doctl compute domain records list $domain|grep $prefix |awk '{print $1}'); do doctl compute domain records delete -f $domain $i; done
  until [ $(dolist | wc -l | sed 's/ //g') == 0 ]; do echo -e -n "."; sleep 2; done
  for i in $(doctl compute volume list --no-header |awk '{print $1}'); do doctl compute volume delete -f $i; done

  rm -rf *.txt *.log *.zip *.pub env.* certs backup.tar ~/.kube/config central* sensor* *token kubeconfig *TOKEN 

else
  echo -e -n " no cluster found "
fi

echo -e "$GREEN" "ok" "$NO_COLOR"
}

case "$1" in
        up) up;;
        tl) up && traefik && longhorn;;
        kill) kill;;
        rox) rox;;
        neu) neu;;
        dolist) dolist;;
        traefik) traefik;;
        keycloak) keycloak;;
        longhorn) longhorn;;
        rancher) rancher;;
        demo) demo;;
        fleet) fleet;;
        hobbyfarm ) hobbyfarm;;
        *) usage;;
esac
