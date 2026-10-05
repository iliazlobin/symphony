"""Read-only check that shared ARC CRDs match the checksum-verified chart."""

import copy
import json
from pathlib import Path
import sys


CRD_NAMES = {
    "autoscalinglisteners.actions.github.com",
    "autoscalingrunnersets.actions.github.com",
    "ephemeralrunners.actions.github.com",
    "ephemeralrunnersets.actions.github.com",
}


def read_document(path):
    # kubectl create prints successive objects; kubectl get may print one List.
    path = Path(path)
    if path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError("ARC CRD input exceeds the bounded size.")
    decoder, text, items = json.JSONDecoder(), path.read_text(), []
    while text.strip():
        document, end = decoder.raw_decode(text.lstrip())
        text = text.lstrip()[end:]
        if not isinstance(document, dict):
            raise ValueError("ARC CRD input must contain JSON objects.")
        members = document.get("items", [document])
        if not isinstance(members, list):
            raise ValueError("ARC CRD List must contain an items array.")
        items.extend(members)
        if len(items) > len(CRD_NAMES):
            raise ValueError("ARC CRD input contains extra definitions.")
    return {"items": items}


def definitions(document):
    items = document.get("items", [document])
    result = {}
    for item in items:
        name = item["metadata"]["name"]
        if (item.get("apiVersion") != "apiextensions.k8s.io/v1"
                or item.get("kind") != "CustomResourceDefinition" or name in result):
            raise ValueError("Invalid or duplicate ARC CRD.")
        result[name] = item
    if set(result) != CRD_NAMES:
        raise ValueError("Require all four shared ARC CRDs; foundation must prepare them.")
    return result


def normalized_spec(spec):
    # v1 defaults/serialization only; never omit schemas, versions or unknown fields.
    spec = copy.deepcopy(spec)
    spec.setdefault("conversion", {"strategy": "None"})
    spec.setdefault("preserveUnknownFields", False)
    return spec


def verify(expected_document, live_document):
    expected, live = definitions(expected_document), definitions(live_document)
    for name in sorted(CRD_NAMES):
        actual = live[name]
        if normalized_spec(expected[name]["spec"]) != normalized_spec(actual["spec"]):
            raise ValueError(f"Shared ARC CRD differs from pinned chart: {name}")
        if actual["metadata"].get("deletionTimestamp"):
            raise ValueError(f"Shared ARC CRD is being deleted: {name}")
        conditions = {c["type"]: c["status"] for c in actual.get("status", {}).get("conditions", [])}
        if any(conditions.get(key) != "True" for key in ("Established", "NamesAccepted")):
            raise ValueError(f"Shared ARC CRD is not established: {name}")
        storage = [v["name"] for v in expected[name]["spec"]["versions"] if v.get("storage")]
        if len(storage) != 1 or actual.get("status", {}).get("storedVersions") != storage:
            raise ValueError(f"Shared ARC CRD storage versions require foundation review: {name}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_arc_crds.py <expected-chart-json> <live-crds-json>")
    try:
        verify(*(read_document(path) for path in sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"Shared ARC CRD verification stopped: {error}") from error
