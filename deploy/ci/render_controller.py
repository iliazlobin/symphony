"""Set one named controller Deployment to Recreate without altering other resources."""

import json
import sys


def render(text, name, namespace):
    if len(text.encode()) > 8 * 1024 * 1024:
        raise ValueError("Controller render exceeds the bounded size.")
    decoder, resources = json.JSONDecoder(), []
    while text.strip():
        document, end = decoder.raw_decode(text.lstrip())
        text = text.lstrip()[end:]
        if not isinstance(document, dict):
            raise ValueError("Controller render must contain JSON objects.")
        members = document.get("items", [document])
        if not isinstance(members, list) or not all(isinstance(r, dict) for r in members):
            raise ValueError("Invalid controller resource List.")
        resources.extend(members)
    deployments = [r for r in resources if r.get("kind") == "Deployment"]
    if (len(deployments) != 1 or deployments[0].get("apiVersion") != "apps/v1"
            or deployments[0].get("metadata", {}).get("name") != name
            or deployments[0].get("metadata", {}).get("namespace") != namespace):
        raise ValueError("Require exactly the expected controller Deployment.")
    deployments[0]["spec"]["strategy"] = {"type": "Recreate"}
    # JSON is valid YAML; document separators preserve all Helm object identities.
    return "\n---\n".join(json.dumps(r, sort_keys=True) for r in resources) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_controller.py <controller-name> <namespace>")
    try:
        sys.stdout.write(render(sys.stdin.read(), sys.argv[1], sys.argv[2]))
    except (ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"Controller post-render stopped: {error}") from error
