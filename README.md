# Shop.WebApi on k3s (macOS)

This guide shows how to build and run the minimal .NET 9 Web API on a local k3s using k3d or Rancher Desktop. The manifests in `Shop.WebApi/k8s` are ready for k3s/Traefik.

- App listens on port 8080 in the container (via `ASPNETCORE_URLS`)
- Service exposes port 80 -> 8080
- Ingress uses Traefik with host `api.127.0.0.1.nip.io`
- Health endpoint: `/health`
- Diagnostics endpoint: `/whoami` returns `{ pod, node, podIp, timeUtc }` and all responses include `X-Pod-Name` and `X-Node-Name` headers so you can see which node/pod served a request.

## Quick start (one command, k3d)

Run everything with one script. It will create a local registry and a k3d cluster (with multiple agents), build + import the image, apply manifests, patch the Deployment to the local image, wait for rollout, print pod distribution per node, and probe health.

```bash
# from repo root
./scripts/deploy_k3d.sh

# simulate multiple VPS app servers
AGENTS=2 ./scripts/deploy_k3d.sh   # default is 2; increase as needed
```

What the script does:
- Ensures a registry `registry.localhost:<port>` is running (auto-picks a free port if needed)
- Creates/updates a k3d cluster named `shop` with the requested number of agents
- Builds the image and imports it into the k3d nodes; patches the Deployment to use `webapi:0.1.0` (local tag)
- Applies K8s manifests via Kustomize
- Prints a node distribution summary and probes `GET /health` via Ingress
- Pins Traefik (Ingress controller) to the control-plane (server) node for a predictable entry point

After completion you can open:

```bash
# Health
open http://api.127.0.0.1.nip.io:8081/health
# Who am I (shows which node/pod served the request)
open http://api.127.0.0.1.nip.io:8081/whoami
```

Notes:
- The host port for the k3d load balancer may not be 80; the script auto-detects it (commonly 8081). If you’re running commands manually, adjust the port accordingly.
- App pods are scheduled only on agent nodes (not the server) and spread across nodes (topology spread + anti-affinity).
- Traefik is pinned to the server (control-plane) node by the script. You can change this if you prefer ingress on agents.

Helper scripts:
- `./scripts/probe_routing.sh 10` — calls `/whoami` multiple times and summarizes which node/pod served each call.
- `./scripts/failover_demo.sh` — cordons + drains one agent to simulate a VPS outage, probes routing to show traffic shifting, then (by default) uncordons.
- `./scripts/clean.sh` — tears down the k3d cluster and local registry.

## k3d (Docker-backed k3s)

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

Tip: If you use the quick start script, you don’t need to patch the in-cluster image host. The script imports the image into the nodes and patches the Deployment to `webapi:0.1.0` directly for reliability during local dev.


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
# If using manual Option A and mapped host port 80:
curl -i http://api.127.0.0.1.nip.io/health

# If using the quick start script, the load balancer is often on 8081:
curl -i http://api.127.0.0.1.nip.io:8081/health
```

- See which node/pod handled the request (headers added by the app):

```bash
curl -i http://api.127.0.0.1.nip.io:8081/whoami | grep -i '^x-.*-name' || curl -s http://api.127.0.0.1.nip.io:8081/whoami
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

The Deployment enforces cross-node spreading and is restricted to agent nodes. After rollout, the script prints a pods-per-node summary. You can also verify manually:

```bash
kubectl -n webapi-demo get pods -o wide
```

## Notes

- Ingress class set to `traefik` which is the default for k3s.
- Probes use `/health` for accurate readiness/liveness.
- Adjust image tag in `k8s/deployment.yaml` to match what you build/push.
- Architecture: on Apple Silicon (arm64), your Docker build will default to `linux/arm64` which matches k3d/Rancher nodes on macOS. If you need a different arch, specify it when building, e.g. `docker build --platform linux/amd64 -t ...` and ensure the cluster nodes support it.
- By default, the deploy script pins Traefik to the control-plane (server) node and runs app pods only on agents (with anti-affinity), giving you a predictable “ingress on server, app on agents” topology for local testing.
