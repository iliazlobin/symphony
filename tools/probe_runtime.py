"""Select the service's reviewed launch inputs without forwarding host secrets."""
from __future__ import annotations

import json
from pathlib import Path
import re


def fixture_parent_path(value):
    path = Path(value).expanduser()
    if not path.is_absolute() or path != path.resolve(strict=True) or not path.is_dir():
        raise ValueError("Fixture parent must be an existing canonical absolute directory")
    return path


def resolve_runtime(profile, repository, image=None, seccomp_policy=None, apparmor_profile=None,
                    fixture_parent=None, operator_config=None):
    if operator_config is not None:
        if any(value is not None for value in (image, seccomp_policy, apparmor_profile)):
            raise ValueError("Operator-config probes cannot override the pinned image or reviewed policies")
        config = profile.load_config(operator_config)
        # This is the same selector used by profile.py codex-server. It checks
        # the configured workspace root and policy hashes before returning args.
        selector = getattr(profile, "container_launch_options", None)
        if not callable(selector):
            raise ValueError("The service policy selector is unavailable; update probes and launcher together")
        options = selector(config)
        if (not isinstance(options, list) or len(options) != 4 or options[0] != "--seccomp-policy"
                or options[2:] not in (["--apparmor-profile", "symphony-codex"],
                                      ["--apparmor-profile", "symphony-self-codex"])):
            raise ValueError("The service did not select the required reviewed container policies")
        image = config.get("worker_image_id")
        workspace_root = fixture_parent_path(config["workspace_root"])
        parent = fixture_parent_path(fixture_parent) if fixture_parent is not None else workspace_root
        if parent != workspace_root and workspace_root not in parent.parents:
            raise ValueError("Operational fixtures must stay inside the configured workspace root")
        seccomp_policy, apparmor_profile = options[1], options[3]
    else:
        options = []
        if seccomp_policy is not None:
            seccomp_policy = str(Path(seccomp_policy).resolve(strict=True))
            options += ["--seccomp-policy", seccomp_policy]
        if apparmor_profile is not None:
            options += ["--apparmor-profile", apparmor_profile]
        parent = (fixture_parent_path(fixture_parent) if fixture_parent is not None
                  else Path(repository) / ".runtime" if image is not None else None)
    if image is not None and (not isinstance(image, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", image)):
        raise ValueError("Container probes require the pinned immutable worker image ID")
    if image is None and (fixture_parent is not None or operator_config is not None or options):
        raise ValueError("Container launch inputs require an immutable worker image")
    return {"image": image, "options": options, "parent": parent,
            "seccomp_policy": seccomp_policy, "apparmor_profile": apparmor_profile,
            "operational": operator_config is not None}


def verify_container_policy(info, runtime):
    if info.get("Image") != runtime["image"]:
        raise RuntimeError("The container is not running the selected immutable worker image")
    options = info.get("HostConfig", {}).get("SecurityOpt", [])
    if runtime["apparmor_profile"] is not None:
        expected = runtime["apparmor_profile"]
        selected = [value for value in options if value.startswith("apparmor=")]
        if info.get("AppArmorProfile") != expected or selected != ["apparmor=" + expected]:
            raise RuntimeError("The container is not enforcing the selected AppArmor profile")
    if runtime["seccomp_policy"] is not None:
        selected = [value.removeprefix("seccomp=") for value in options if value.startswith("seccomp=")]
        expected = json.loads(Path(runtime["seccomp_policy"]).read_text())
        try:
            if len(selected) != 1 or json.loads(selected[0]) != expected:
                raise ValueError("different seccomp policy")
        except (TypeError, ValueError):
            raise RuntimeError("The container is not enforcing the selected seccomp policy") from None
