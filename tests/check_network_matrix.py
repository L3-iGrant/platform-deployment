#!/usr/bin/env python3
"""Checks the NetworkPolicies of one "helm template" output against the
connection matrix (policies/network-matrix.yaml), without a cluster.

Usage: check_network_matrix.py <render.yaml> <network-matrix.yaml>

The render has networkPolicy.enabled. The script applies the NetworkPolicies
of the release namespace to the pods of the release as Kubernetes does: a
pod that a policy of the type Ingress (Egress) selects accepts (opens) only
the connections that one of these policies allows, and a connection needs
the egress of its source and the ingress of its destination. A peer with an
ipBlock is never a pod of the release (the pod addresses are in the cluster
CIDRs, which the egress profiles exclude). For the roles that run in the
release:
- each pod of the release has a role of the matrix;
- each connection of the matrix is allowed on its port;
- each allowed connection between two pods of the release is in the
  matrix (no other port, no other pair);
- each forbidden pair of the matrix is denied on every port.
The script writes one line for each failed check and exits 1 when a check
fails.
"""

import sys

import yaml

NAMESPACE = "ow"
ROLE = "netpol.igrant.io/role"


def selects(selector: dict, labels: dict) -> bool:
    """True when a label selector selects the labels."""
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


def namespace_selects(selector) -> bool:
    """True when a namespaceSelector selects the release namespace (the only label known: its name)."""
    if selector is None:
        return True
    return selects(selector, {"kubernetes.io/metadata.name": NAMESPACE})


def peer_selects(peer: dict, labels: dict) -> bool:
    if "ipBlock" in peer:
        return False
    if not namespace_selects(peer.get("namespaceSelector")):
        return False
    return selects(peer.get("podSelector") or {}, labels)


def port_matches(rule: dict, number: int, name: str) -> bool:
    ports = rule.get("ports")
    if not ports:
        return True
    return any(item.get("port") in (number, name) and item.get("protocol", "TCP") == "TCP" for item in ports)


def main() -> int:
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
            failures.append(f"{doc['kind']} {doc['metadata']['name']} has the role {role!r}, not a role of the matrix")
            continue
        ports = {port["name"]: port["containerPort"]
                 for container in doc["spec"]["template"]["spec"]["containers"] for port in container.get("ports", []) if "name" in port}
        entry = pods.setdefault(role, {"labels": labels, "ports": {}})
        entry["ports"].update(ports)
    policies = [doc for doc in docs if doc.get("kind") == "NetworkPolicy" and doc["metadata"].get("namespace", NAMESPACE) == NAMESPACE]
    if not policies:
        failures.append("no NetworkPolicy in the render")

    def allowed(source: str, target: str, number: int, name: str) -> bool:
        source_labels, target_labels = pods[source]["labels"], pods[target]["labels"]
        egress = [p for p in policies if "Egress" in p["spec"].get("policyTypes", []) and selects(p["spec"]["podSelector"], source_labels)]
        ingress = [p for p in policies if "Ingress" in p["spec"].get("policyTypes", []) and selects(p["spec"]["podSelector"], target_labels)]
        egress_ok = not egress or any(
            (not rule.get("to") or any(peer_selects(peer, target_labels) for peer in rule["to"])) and port_matches(rule, number, name)
            for policy in egress for rule in policy["spec"].get("egress") or [])
        ingress_ok = not ingress or any(
            (not rule.get("from") or any(peer_selects(peer, source_labels) for peer in rule["from"])) and port_matches(rule, number, name)
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
                # The port number of the container (a value can change the
                # default of the matrix, for example gateway.listenPort).
                actual = pods[target]["ports"].get(port, number)
                if not allowed(source, target, actual, port):
                    failures.append(f"the connection {source} -> {target}:{port} of the matrix is denied")
    def expected_port(source: str, target: str, number: int, name: str) -> bool:
        """The matrix names the port, or a port of the matrix has its number (the database port)."""
        return any((source, target, port) in expected and (port == name or matrix["roles"][target]["ports"][port] == number)
                   for port in matrix["roles"][target]["ports"])

    for source in sorted(present):
        for target in sorted(present):
            for name, number in sorted(pods[target]["ports"].items()):
                if allowed(source, target, number, name) and not expected_port(source, target, number, name):
                    failures.append(f"the connection {source} -> {target}:{name} is allowed, but it is not in the matrix")
    for rule in matrix["forbidden"]:
        source = rule["from"]
        for target in rule["to"]:
            if source in present and target in present:
                for name, number in sorted(pods[target]["ports"].items()):
                    if allowed(source, target, number, name):
                        failures.append(f"the forbidden connection {source} -> {target}:{name} is allowed")

    for failure in failures:
        print(f"  FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
