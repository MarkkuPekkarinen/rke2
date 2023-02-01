# air gap notes

### get the script

script: https://github.com/clemenko/rke_airgap_install/blob/main/air_gap_all_the_things.sh

```bash
mkdir /opt/rancher && cd /opt/rancher && curl -#OL https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/air_gap_all_the_things.sh && chmod 755 air_gap_all_the_things.sh 
```

### uncompress

```bash
tar -I zstd -vxf rke2_rancher_longhorn.zst -C /opt/rancher
```

### Longhorn

docs : https://longhorn.io/docs/1.3.2/advanced-resources/deploy/airgap/#using-a-helm-chart

```bash
helm upgrade -i longhorn /opt/rancher/helm/longhorn-1.3.2.tgz --namespace longhorn-system --create-namespace --set ingress.enabled=true --set ingress.host=longhorn.awesome.sauce --set global.cattle.systemDefaultRegistry=localhost:5000
```

### Cert-Manager

```bash
helm upgrade -i cert-manager /opt/rancher/helm/cert-manager-v1.10.0.tgz --namespace cert-manager --create-namespace --set installCRDs=true --set image.repository=localhost:5000/cert-manager-controller --set webhook.image.repository=localhost:5000/cert-manager-webhook --set cainjector.image.repository=localhost:5000/cert-manager-cainjector --set startupapicheck.image.repository=localhost:5000/cert-manager-ctl
```

### Rancher

docs : https://docs.ranchermanager.rancher.io/pages-for-subheaders/air-gapped-helm-cli-install

```bash
helm upgrade -i rancher /opt/rancher/helm/rancher-2.7.0.tgz --namespace cattle-system --create-namespace --set hostname=rancher.awesome.sauce --set bootstrapPassword=bootStrapAllTheThings --set replicas=1 --set auditLog.level=2 --set auditLog.destination=hostPath --set useBundledSystemChart=true --set rancherImage=localhost:5000/rancher/rancher --set systemDefaultRegistry=localhost:5000

#  --no-hooks --set rancherImageTag=v2.7.0
```


### bonus

```bash
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/var/lib/rancher/rke2/bin
ln -s /var/run/k3s/containerd/containerd.sock /var/run/containerd/containerd.sock
```