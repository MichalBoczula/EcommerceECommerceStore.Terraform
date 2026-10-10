import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("ci_plan", Path(__file__).parents[1] / "scripts/ci-plan.py")
ci_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_plan)


class PlanHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = {
            "ARM_SUBSCRIPTION_ID": "11111111-1111-1111-1111-111111111111",
            "ARM_TENANT_ID": "22222222-2222-2222-2222-222222222222",
            "ARM_CLIENT_ID": "44444444-4444-4444-4444-444444444444",
            "OPERATOR_OBJECT_ID": "33333333-3333-3333-3333-333333333333",
            "STATE_ACCOUNT": "stecomdevmike2026", "STATE_KEY": "development.terraform.tfstate",
            "TF_VAR_sql_admin_password": "TestOnly-Sql-123456!",
            "TF_VAR_mongo_admin_password": "TestOnly-Mongo-123456!",
            "GITHUB_RUN_ID": "100", "PLAN_RUN_ID": "100", "GITHUB_SHA": "a" * 40,
            "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "owner/repo",
        }
        self.now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        ci_plan.configure(self.env, self.directory)
        (self.directory / "deploy.tfplan").write_bytes(b"test saved plan")
        ci_plan.record(self.env, self.directory, self.now)

    def test_exact_plan_is_accepted(self):
        ci_plan.verify(self.env, self.directory, self.now + timedelta(minutes=5))

    def test_different_source_run_commit_or_repository_is_rejected(self):
        for key, value in [("PLAN_RUN_ID", "101"), ("GITHUB_SHA", "b" * 40),
                           ("GITHUB_REPOSITORY", "other/repo"), ("GITHUB_REF", "refs/heads/feature")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                ci_plan.verify(dict(self.env, **{key: value}), self.directory, self.now)

    def test_tampered_plan_is_rejected(self):
        (self.directory / "deploy.tfplan").write_bytes(b"different plan")
        with self.assertRaisesRegex(ValueError, "plan_sha256"):
            ci_plan.verify(self.env, self.directory, self.now)

    def test_changed_password_identity_or_backend_is_rejected(self):
        for key in ["TF_VAR_sql_admin_password", "TF_VAR_mongo_admin_password",
                    "ARM_CLIENT_ID", "ARM_TENANT_ID", "STATE_ACCOUNT", "STATE_KEY"]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "inputs_sha256"):
                ci_plan.verify(dict(self.env, **{key: "changed"}), self.directory, self.now)

    def test_changed_settings_are_rejected(self):
        ci_plan.configure(dict(self.env, STATIC_WEB_APP_LOCATION="westus2"), self.directory)
        with self.assertRaisesRegex(ValueError, "inputs_sha256"):
            ci_plan.verify(self.env, self.directory, self.now)

    def test_expired_or_future_plan_is_rejected(self):
        for now in [self.now + timedelta(hours=25), self.now - timedelta(minutes=3)]:
            with self.subTest(now=now), self.assertRaisesRegex(ValueError, "timestamp"):
                ci_plan.verify(self.env, self.directory, now)

    def test_other_operation_is_rejected(self):
        path = self.directory / "metadata.json"
        metadata = json.loads(path.read_text())
        metadata["operation"] = "destroy"
        path.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "operation"):
            ci_plan.verify(self.env, self.directory, self.now)

    def test_non_numeric_run_id_is_rejected(self):
        for value in ["", "../100", "100;echo secret"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                ci_plan.verify(dict(self.env, PLAN_RUN_ID=value), self.directory, self.now)

    def test_backend_must_match_shared_account(self):
        with self.assertRaisesRegex(ValueError, "shared business"):
            ci_plan.configure(dict(self.env, STATE_ACCOUNT="otheraccount"), self.directory)

    def test_missing_setup_is_reported_without_secret_values(self):
        with self.assertRaisesRegex(ValueError, "Missing configuration: OPERATOR_OBJECT_ID"):
            ci_plan.configure(dict(self.env, OPERATOR_OBJECT_ID=""), self.directory)


if __name__ == "__main__":
    unittest.main()
