"""Configure development inputs and verify the private saved-plan handoff."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re


def configure(env, directory):
    for key in ("ARM_SUBSCRIPTION_ID", "OPERATOR_OBJECT_ID", "STATE_ACCOUNT"):
        if not env.get(key):
            raise ValueError(f"Missing configuration: {key}")
    settings = {
        "subscription_id": env["ARM_SUBSCRIPTION_ID"],
        "operator_object_id": env["OPERATOR_OBJECT_ID"],
        "environment": "dev",
        "name_suffix": env.get("NAME_SUFFIX") or "mike2026",
        "location": env.get("LOCATION") or "northeurope",
        "sql_location": env.get("SQL_LOCATION") or "francecentral",
        "static_web_app_location": env.get("STATIC_WEB_APP_LOCATION") or "eastus2",
        "resource_group_name": env.get("RESOURCE_GROUP_NAME") or "rg-ecommerce-dev",
        "operator_ipv4": env.get("OPERATOR_IPV4") or None,
    }
    if env["STATE_ACCOUNT"] != f"stecomdev{settings['name_suffix']}":
        raise ValueError("The step-2 backend must use the shared business Storage account")
    path = directory / "ci.auto.tfvars.json"
    path.write_text(json.dumps(settings, sort_keys=True, indent=2) + "\n")
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(env, directory):
    # The fingerprint stays beside the confidential plan, never in public output.
    inputs = [
        (directory / "ci.auto.tfvars.json").read_text(),
        env["TF_VAR_sql_admin_password"], env["TF_VAR_mongo_admin_password"],
        env["ARM_TENANT_ID"], env["ARM_CLIENT_ID"],
        env["STATE_ACCOUNT"], env["STATE_KEY"],
    ]
    return hashlib.sha256(json.dumps(inputs).encode()).hexdigest()


def record(env, directory, now=None):
    now = now or datetime.now(timezone.utc)
    metadata = {
        "schema": 1, "operation": "plan",
        "run_id": env["GITHUB_RUN_ID"], "source_sha": env["GITHUB_SHA"],
        "repository": env["GITHUB_REPOSITORY"], "source_ref": env["GITHUB_REF"],
        "created_at": now.isoformat(), "inputs_sha256": fingerprint(env, directory),
        "plan_sha256": digest(directory / "deploy.tfplan"),
    }
    (directory / "metadata.json").write_text(json.dumps(metadata, sort_keys=True) + "\n")
    return metadata


def verify(env, directory, now=None):
    now = now or datetime.now(timezone.utc)
    run_id = env.get("PLAN_RUN_ID", "")
    if not re.fullmatch(r"[0-9]+", run_id):
        raise ValueError("Supply the numeric successful plan run ID")
    metadata = json.loads((directory / "metadata.json").read_text())
    expected = {
        "schema": 1, "operation": "plan", "run_id": run_id,
        "source_sha": env["GITHUB_SHA"], "repository": env["GITHUB_REPOSITORY"],
        "source_ref": "refs/heads/main", "inputs_sha256": fingerprint(env, directory),
        "plan_sha256": digest(directory / "deploy.tfplan"),
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f"Saved plan mismatch: {key}; run plan again")
    if env["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Apply is restricted to main")
    created = datetime.fromisoformat(metadata["created_at"])
    if created.tzinfo is None or not timedelta(minutes=-2) <= now - created <= timedelta(hours=24):
        raise ValueError("Saved plan is expired or has an invalid timestamp; run plan again")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["configure", "record", "verify"])
    args = parser.parse_args()
    try:
        {"configure": configure, "record": record, "verify": verify}[args.operation](os.environ, Path.cwd())
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
