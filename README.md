# Shop.WebApi on k3s (macOS)

This guide shows how to build, load, and run the minimal .NET 9 Web API on a local k3s using either k3d or Rancher Desktop. The manifests in `Shop.WebApi/k8s` are already set up for k3s/Traefik.

- App listens on port 8080 in the container (via `ASPNETCORE_URLS`)
- Service exposes port 80 -> 8080
- Ingress uses Traefik with host `api.127.0.0.1.nip.io`
- Health endpoint: `/health`

## Option A: k3d (Docker-backed k3s)

1) Create a local registry and k3d cluster (once):

```bash
# create local registry
k3d registry create registry.localhost --port 5500

# create cluster and connect registry
k3d cluster create shop --registry-use k3d-registry.localhost:5500 --api-port 6550 -p "80:80@loadbalancer"
```

2) Build and push image to local registry:

```bash
# from repo root
cd Shop.WebApi

# build image
docker build -t registry.localhost:5500/webapi:0.1.0 .

# push image to local registry
docker push registry.localhost:5500/webapi:0.1.0
```

3) IMPORTANT for k3d only: update image hostname used inside the cluster

Inside the cluster, k3d resolves the registry as `k3d-registry.localhost:5500`. Patch the deployment image to match:

```bash
kubectl -n webapi-demo set image deploy/webapi webapi=k3d-registry.localhost:5500/webapi:0.1.0
```

4) Deploy manifests via kustomize:

```bash
kubectl apply -k k8s/
```

5) Check rollout and test:

```bash
kubectl -n webapi-demo rollout status deploy/webapi
kubectl -n webapi-demo get ingresses

# open in browser or curl
curl -i http://api.127.0.0.1.nip.io/health
```

## Option B: Rancher Desktop (containerd-backed k3s)

Rancher Desktop comes with a built-in local registry "rd" (or you can use nerdctl to load images). Two common approaches:

- Push to registry if configured and referenced in deployment (update `image:` if needed)
- Or import image directly into containerd used by k3s

Direct import approach:

```bash
cd Shop.WebApi

# build Docker image locally
docker build -t webapi:0.1.0 .

# export and import into k3s containerd
docker save webapi:0.1.0 | nerdctl -n k8s.io load

# update deployment to use `webapi:0.1.0` (no registry prefix) if you prefer this path
# then apply
kubectl apply -k k8s/
```

If you keep the default image `registry.localhost:5500/webapi:0.1.0`, configure a registry mirror in Rancher Desktop or push to a registry Rancher can reach.

## Verify

- Pods healthy:

```bash
kubectl -n webapi-demo get pods -w
```

- Service reachable inside cluster:

```bash
kubectl -n webapi-demo run -it tester --image=curlimages/curl --rm --restart=Never -- sh -c 'curl -sS http://webapi/health'
```

- Ingress reachable from host:

```bash
curl -i http://api.127.0.0.1.nip.io/health
```

If your environment doesn't expose port 80 from k3s to the host, you can port-forward the Service as a quick check:

```bash
kubectl -n webapi-demo port-forward svc/webapi 8080:80
# then
curl -i http://127.0.0.1:8080/health
```

### Multiple worker nodes (agents)

To simulate multiple VPS app servers locally, run the deploy script with a configurable number of worker nodes:

```bash
AGENTS=2 ./scripts/deploy_k3d.sh   # default is 2; increase to 3+ as needed
```

The script will create a cluster with that many agent nodes (or add agents if the cluster already exists) and print a summary of pod distribution per node after rollout. You can also verify manually:

```bash
kubectl -n webapi-demo get pods -o wide
```

## Notes

- Ingress class set to `traefik` which is the default for k3s.
- Probes use `/health` for accurate readiness/liveness.
- Adjust image tag in `k8s/deployment.yaml` to match what you build/push.
- Architecture: on Apple Silicon (arm64), your Docker build will default to `linux/arm64` which matches k3d/Rancher nodes on macOS. If you need a different arch, specify it when building, e.g. `docker build --platform linux/amd64 -t ...` and ensure the cluster nodes support it.
