# Networking

## Public hostnames (Cloudflare Tunnel)

| Hostname | Service |
| --- | --- |
| `git.huukiet.com` | Gitea |
| `argocd.huukiet.com` | Argo CD (GitHub OAuth via Dex) |
| `home.huukiet.com` | Homepage dashboard |
| `wiki.huukiet.com` | This wiki |

## Private access (Tailscale)

A Tailscale Connector named `homeserver` advertises the LAN (`192.168.100.0/24`), Pod
CIDR (`10.42.0.0/16`), and Service CIDR (`10.43.0.0/16`). Remote tailnet devices
reach the homeserver and cluster internals without exposing ports to the internet.

## Host PostgreSQL

Gitea connects to PostgreSQL running natively on the Ubuntu host. PostgreSQL listens
on localhost and the LAN IP; `pg_hba.conf` allows only the k3s Pod CIDR. This keeps
database backups and upgrades outside the Kubernetes lifecycle.

## k3s worker nodes (UFW)

The cluster runs on `192.168.100.0/24`. Worker nodes need UFW rules that match this
subnet and allow routed traffic on the k3s bridge interfaces. Without them, pods on
a worker cannot reach services or other pods on the control-plane node (DNS, Gitea,
and any `ClusterIP` service will time out).

On each **worker** node (not the control plane, which already has the correct rules):

```bash
# k3s node traffic from the LAN
sudo ufw allow from 192.168.100.0/24 to any port 10250 proto tcp comment 'k3s kubelet from LAN'
sudo ufw allow from 192.168.100.0/24 to any port 8472 proto udp comment 'k3s flannel from LAN'

# cross-node pod routing through flannel and the CNI bridge
sudo ufw route allow in on flannel.1 out on flannel.1 comment 'k3s flannel pod routing'
sudo ufw route allow in on cni0 out on cni0 comment 'k3s cni pod routing'
```

If a worker was set up with rules for the wrong subnet (for example `192.168.1.0/24`),
remove them first:

```bash
sudo ufw status numbered   # note rule numbers for stale 192.168.1.0/24 entries
sudo ufw delete <number>
```

Verify from a pod scheduled on the worker:

```bash
kubectl run nettest --rm -it --restart=Never --image=busybox:1.38.0 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<worker-node>"}}}' \
  -n gitea -- sh -c \
  'nslookup gitea.gitea.svc.cluster.local && wget -qO- --timeout=5 http://gitea.gitea.svc.cluster.local:3000/ | head -c 80'
```

Both DNS resolution and an HTTP response from Gitea should succeed. UFW persists
these rules across reboots automatically.
