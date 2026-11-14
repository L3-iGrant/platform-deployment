#!/usr/bin/env python3
"""Checks the NetworkPolicies of one "helm template" output against the
connection matrix (policies/network-matrix.yaml), without a cluster.

Usage: check_network_matrix.py <render.yaml> <network-matrix.yaml> [<pods.yaml> <name>]

The render must have networkPolicy.enabled. The script applies the
NetworkPolicies of the release namespace to the release pods as Kubernetes
does: a pod that an Ingress (or Egress) policy selects accepts (or opens)
only the connections that one of these policies allows, and a connection
needs both the egress of its source and the ingress of its destination. A
peer with an ipBlock is never a pod (pod addresses are in the cluster
CIDRs, which the egress profiles exclude). For the roles that run in the
release:
- each release pod has a role from the matrix;
- each connection of the matrix is allowed on its port;
- each allowed connection between two release pods is in the matrix (no
  other port, no other pair);
- each forbidden pair of the matrix is denied on every port.
With <pods.yaml> <name> (tests/fixtures/ingress-controller-pods.yaml and
one of its lists), the script also models these pods outside the release
(the release has no policy in their namespaces):
- a pod with a "source" (for example ingressController) opens each
  connection of the matrix from that source, and no other release port;
- the roles open each connection of externalConnections to that source,
  and no other port of its pods;
- a pod without a source has no connection with the release.
The script prints one line per failed check and exits 1 if a check fails.
"""

import sys

import yaml

NAMESPACE = "ow"
ROLE = "netpol.igrant.io/role"


def selects(selector: dict, labels: dict) -> bool:
    """True if the label selector matches the labels."""
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for expression in selector.get("matchExpressions") or []:
        key, operator = expression["key"], expression["operator"]
        values = expression.get("values") or []
        if operator == "Exists" and key not in labels:
            return False
        if operator == "DoesNotExist" and key in labels:
            return False
        if operator == "In" and labels.get(key) not in values:
            return False
        if operator == "NotIn" and labels.get(key) in values:
            return False
    return True


def peer_selects(peer: dict, pod: dict) -> bool:
    """True if a peer of a policy (in the release namespace) selects the pod.
    A namespaceSelector knows only the name label of a namespace."""
    if "ipBlock" in peer:
        return False
    selector = peer.get("namespaceSelector")
    if selector is None:
        if pod["namespace"] != NAMESPACE:
            return False
    elif not selects(selector, {"kubernetes.io/metadata.name": pod["namespace"]}):
        return False
    return selects(peer.get("podSelector") or {}, pod["labels"])


def port_matches(rule: dict, number: int, name: str) -> bool:
    ports = rule.get("ports")
    if not ports:
        return True
    return any(item.get("port") in (number, name) and item.get("protocol", "TCP") == "TCP" for item in ports)


def main() -> int:
    if len(sys.argv) not in (3, 5):
        sys.exit(__doc__)
    render, matrix_file = sys.argv[1:3]
    docs = [doc for doc in yaml.safe_load_all(open(render, encoding="utf-8")) if doc]
    matrix = yaml.safe_load(open(matrix_file, encoding="utf-8"))
    failures: list[str] = []

    pods = {}
    for doc in docs:
        if doc.get("kind") not in ("Deployment", "StatefulSet", "Job") or doc["metadata"].get("namespace", NAMESPACE) != NAMESPACE:
            continue
        labels = doc["spec"]["template"]["metadata"].get("labels") or {}
        role = labels.get(ROLE)
        if role not in matrix["roles"]:
            failures.append(f"{doc['kind']} {doc['metadata']['name']} has the role {role!r}, which is not in the matrix")
            continue
        ports = {port["name"]: port["containerPort"]
                 for container in doc["spec"]["template"]["spec"]["containers"] for port in container.get("ports", []) if "name" in port}
        entry = pods.setdefault(role, {"labels": labels, "namespace": NAMESPACE, "ports": {}})
        entry["ports"].update(ports)
    policies = [doc for doc in docs if doc.get("kind") == "NetworkPolicy" and doc["metadata"].get("namespace", NAMESPACE) == NAMESPACE]
    if not policies:
        failures.append("no NetworkPolicy in the render")

    def allowed(source: dict, target: dict, number: int, name: str) -> bool:
        """The policies of the release namespace select only its pods: a pod
        outside it has no egress (as a source) or ingress (as a target) policy here."""
        egress = [p for p in policies if source["namespace"] == NAMESPACE
                  and "Egress" in p["spec"].get("policyTypes", []) and selects(p["spec"]["podSelector"], source["labels"])]
        ingress = [p for p in policies if target["namespace"] == NAMESPACE
                   and "Ingress" in p["spec"].get("policyTypes", []) and selects(p["spec"]["podSelector"], target["labels"])]
        egress_ok = not egress or any(
            (not rule.get("to") or any(peer_selects(peer, target) for peer in rule["to"])) and port_matches(rule, number, name)
            for policy in egress for rule in policy["spec"].get("egress") or [])
        ingress_ok = not ingress or any(
            (not rule.get("from") or any(peer_selects(peer, source) for peer in rule["from"])) and port_matches(rule, number, name)
            for policy in ingress for rule in policy["spec"].get("ingress") or [])
        return egress_ok and ingress_ok

    present = set(pods)
    expected = set()
    for connection in matrix["connections"]:
        target, port = connection["to"], connection["port"]
        number = matrix["roles"][target]["ports"][port]
        for source in connection["from"]:
            expected.add((source, target, port))
            if source in present and target in present:
                # The container's port number (a value can override the
                # matrix default, for example gateway.listenPort).
                actual = pods[target]["ports"].get(port, number)
                if not allowed(pods[source], pods[target], actual, port):
                    failures.append(f"the matrix connection {source} -> {target}:{port} is denied")
    def expected_port(source: str, target: str, number: int, name: str) -> bool:
        """True if the matrix names the port, or a matrix port has the same number (the database port)."""
        return any((source, target, port) in expected and (port == name or matrix["roles"][target]["ports"][port] == number)
                   for port in matrix["roles"][target]["ports"])

    for source in sorted(present):
        for target in sorted(present):
            for name, number in sorted(pods[target]["ports"].items()):
                if allowed(pods[source], pods[target], number, name) and not expected_port(source, target, number, name):
                    failures.append(f"the connection {source} -> {target}:{name} is allowed but not in the matrix")
    for rule in matrix["forbidden"]:
        source = rule["from"]
        for target in rule["to"]:
            if source in present and target in present:
                for name, number in sorted(pods[target]["ports"].items()):
                    if allowed(pods[source], pods[target], number, name):
                        failures.append(f"the forbidden connection {source} -> {target}:{name} is allowed")

    # Pods outside the release (tests/fixtures/ingress-controller-pods.yaml).
    if len(sys.argv) == 5:
        outside = yaml.safe_load(open(sys.argv[3], encoding="utf-8"))[sys.argv[4]]
        external = {(c["to"], c["port"], role) for c in matrix.get("externalConnections") or [] for role in c["from"]}
        for pod in outside:
            pod = {**pod, "ports": pod.get("ports") or {}}
            what, source = pod["name"], pod.get("source")
            # From the pod to the release.
            for target in sorted(present):
                for name, number in sorted(pods[target]["ports"].items()):
                    is_allowed = allowed(pod, pods[target], number, name)
                    wanted = source is not None and expected_port(source, target, number, name)
                    if wanted and not is_allowed:
                        failures.append(f"the matrix connection {what} ({source}) -> {target}:{name} is denied")
                    elif is_allowed and not wanted:
                        failures.append(f"the connection {what} -> {target}:{name} is allowed but not in the matrix")
            # From the release to the pod.
            for role in sorted(present):
                for name, number in sorted(pod["ports"].items()):
                    is_allowed = allowed(pods[role], pod, number, name)
                    wanted = source is not None and (source, name, role) in external
                    if wanted and not is_allowed:
                        failures.append(f"the matrix connection {role} -> {what}:{name} ({number}) is denied")
                    elif is_allowed and not wanted:
                        failures.append(f"the connection {role} -> {what}:{name} ({number}) is allowed but not in the matrix")

    for failure in failures:
        print(f"  FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
