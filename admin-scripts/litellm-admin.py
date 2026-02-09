#!/usr/bin/env python3
"""
LiteLLM Admin CLI - Python version
For more complex operations and scripting
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta
from typing import Optional

try:
    import requests
except ImportError:
    print("Error: requests library required. Install with: pip install requests")
    sys.exit(1)


class LiteLLMAdmin:
    def __init__(self, base_url: str, master_key: str, verify_ssl: bool = True):
        self.base_url = base_url.rstrip("/")
        self.master_key = master_key
        self.verify_ssl = verify_ssl
        self.headers = {
            "Authorization": f"Bearer {master_key}",
            "Content-Type": "application/json",
        }
        # Suppress SSL warnings when verify is disabled
        if not verify_ssl:
            import urllib3
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def _get(self, endpoint: str, params: dict = None) -> dict:
        url = f"{self.base_url}{endpoint}"
        resp = requests.get(url, headers=self.headers, params=params, verify=self.verify_ssl)
        resp.raise_for_status()
        return resp.json()

    def _post(self, endpoint: str, data: dict = None) -> dict:
        url = f"{self.base_url}{endpoint}"
        resp = requests.post(url, headers=self.headers, json=data or {}, verify=self.verify_ssl)
        resp.raise_for_status()
        return resp.json()

    # ==================== TEAM ====================

    def list_teams(self) -> list:
        return self._get("/team/list")

    def get_team(self, team_id: str) -> dict:
        return self._get("/team/info", {"team_id": team_id})

    def create_team(
        self,
        team_alias: str,
        max_budget: float = None,
        models: list = None,
        budget_duration: str = None,
    ) -> dict:
        data = {"team_alias": team_alias}
        if max_budget is not None:
            data["max_budget"] = max_budget
        if models:
            data["models"] = models
        if budget_duration:
            data["budget_duration"] = budget_duration
        return self._post("/team/new", data)

    def update_team(self, team_id: str, **kwargs) -> dict:
        data = {"team_id": team_id, **kwargs}
        return self._post("/team/update", data)

    def delete_team(self, team_id: str) -> dict:
        return self._post("/team/delete", {"team_ids": [team_id]})

    def add_team_member(self, team_id: str, user_id: str, role: str = "user") -> dict:
        return self._post(
            "/team/member_add",
            {"team_id": team_id, "member": {"user_id": user_id, "role": role}},
        )

    def remove_team_member(self, team_id: str, user_id: str) -> dict:
        return self._post(
            "/team/member_delete", {"team_id": team_id, "user_id": user_id}
        )

    # ==================== KEY ====================

    def list_keys(self, team_id: str = None) -> list:
        params = {}
        if team_id:
            params["team_id"] = team_id
        return self._get("/key/list", params)

    def get_key(self, key: str) -> dict:
        return self._get("/key/info", {"key": key})

    def create_key(
        self,
        team_id: str = None,
        key_alias: str = None,
        max_budget: float = None,
        models: list = None,
        user_id: str = None,
        duration: str = None,
    ) -> dict:
        data = {}
        if team_id:
            data["team_id"] = team_id
        if key_alias:
            data["key_alias"] = key_alias
        if max_budget is not None:
            data["max_budget"] = max_budget
        if models:
            data["models"] = models
        if user_id:
            data["user_id"] = user_id
        if duration:
            data["duration"] = duration
        return self._post("/key/generate", data)

    def update_key(self, key: str, **kwargs) -> dict:
        data = {"key": key, **kwargs}
        return self._post("/key/update", data)

    def delete_key(self, key: str) -> dict:
        return self._post("/key/delete", {"keys": [key]})

    # ==================== USER ====================

    def list_users(self) -> list:
        return self._get("/user/list")

    def get_user(self, user_id: str) -> dict:
        return self._get("/user/info", {"user_id": user_id})

    def create_user(
        self, user_email: str = None, user_id: str = None, teams: list = None
    ) -> dict:
        data = {}
        if user_email:
            data["user_email"] = user_email
        if user_id:
            data["user_id"] = user_id
        if teams:
            data["teams"] = teams
        return self._post("/user/new", data)

    # ==================== AUDIT ====================

    def get_spend_report(
        self, start_date: str = None, end_date: str = None, team_id: str = None
    ) -> dict:
        params = {}
        if start_date:
            params["start_date"] = start_date
        if end_date:
            params["end_date"] = end_date
        if team_id:
            params["team_id"] = team_id
        return self._get("/spend/logs", params)

    def get_all_teams_spend(self) -> list:
        """Get spend summary for all teams."""
        teams = self.list_teams()
        summary = []
        for team in teams:
            summary.append(
                {
                    "team_id": team.get("team_id"),
                    "team_alias": team.get("team_alias", "N/A"),
                    "spend": team.get("spend", 0),
                    "max_budget": team.get("max_budget"),
                    "budget_remaining": (
                        (team.get("max_budget", 0) - team.get("spend", 0))
                        if team.get("max_budget")
                        else None
                    ),
                }
            )
        return sorted(summary, key=lambda x: x.get("spend", 0), reverse=True)

    # ==================== HEALTH ====================

    def health(self) -> dict:
        return self._get("/health")

    def list_models(self) -> list:
        resp = self._get("/models")
        return [m.get("id") for m in resp.get("data", [])]


def format_currency(value):
    if value is None:
        return "unlimited"
    return f"${value:.2f}"


def main():
    parser = argparse.ArgumentParser(
        description="LiteLLM Admin CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--base-url",
        default=os.environ.get("LITELLM_API_BASE"),
        help="LiteLLM API base URL (or set LITELLM_API_BASE)",
    )
    parser.add_argument(
        "--master-key",
        default=os.environ.get("LITELLM_MASTER_KEY"),
        help="Master key (or set LITELLM_MASTER_KEY)",
    )
    parser.add_argument(
        "-o",
        "--output",
        choices=["json", "table"],
        default="table",
        help="Output format",
    )
    parser.add_argument(
        "-k",
        "--insecure",
        action="store_true",
        default=os.environ.get("LITELLM_INSECURE") == "1",
        help="Skip SSL verification (for self-signed certs). Or set LITELLM_INSECURE=1",
    )

    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # Team commands
    team_parser = subparsers.add_parser("team", help="Team management")
    team_sub = team_parser.add_subparsers(dest="subcommand")

    team_sub.add_parser("list", help="List all teams")

    team_info_parser = team_sub.add_parser("info", help="Get team info")
    team_info_parser.add_argument("team_id", help="Team ID")

    team_create_parser = team_sub.add_parser("create", help="Create a team")
    team_create_parser.add_argument("team_alias", help="Team name/alias")
    team_create_parser.add_argument(
        "--budget", type=float, help="Max budget in USD"
    )
    team_create_parser.add_argument(
        "--models", help="Comma-separated list of allowed models"
    )
    team_create_parser.add_argument(
        "--budget-duration", help="Budget reset period (e.g., 1d, 7d, 30d)"
    )

    team_update_parser = team_sub.add_parser("update", help="Update a team")
    team_update_parser.add_argument("team_id", help="Team ID")
    team_update_parser.add_argument("--alias", help="New team alias")
    team_update_parser.add_argument("--budget", type=float, help="New max budget")
    team_update_parser.add_argument("--models", help="New models list")

    team_delete_parser = team_sub.add_parser("delete", help="Delete a team")
    team_delete_parser.add_argument("team_id", help="Team ID")
    team_delete_parser.add_argument("-f", "--force", action="store_true")

    # Key commands
    key_parser = subparsers.add_parser("key", help="API key management")
    key_sub = key_parser.add_subparsers(dest="subcommand")

    key_list_parser = key_sub.add_parser("list", help="List keys")
    key_list_parser.add_argument("--team", help="Filter by team ID")

    key_info_parser = key_sub.add_parser("info", help="Get key info")
    key_info_parser.add_argument("key", help="API key")

    key_create_parser = key_sub.add_parser("create", help="Create a key")
    key_create_parser.add_argument("--team", help="Team ID")
    key_create_parser.add_argument("--alias", help="Key alias")
    key_create_parser.add_argument("--budget", type=float, help="Max budget")
    key_create_parser.add_argument("--models", help="Allowed models")
    key_create_parser.add_argument("--user", help="User ID")
    key_create_parser.add_argument("--duration", help="Key validity duration")

    key_update_parser = key_sub.add_parser("update", help="Update a key")
    key_update_parser.add_argument("key", help="API key")
    key_update_parser.add_argument("--team", help="Move to team")
    key_update_parser.add_argument("--alias", help="New alias")
    key_update_parser.add_argument("--budget", type=float, help="New budget")

    key_delete_parser = key_sub.add_parser("delete", help="Delete a key")
    key_delete_parser.add_argument("key", help="API key")
    key_delete_parser.add_argument("-f", "--force", action="store_true")

    # User commands
    user_parser = subparsers.add_parser("user", help="User management")
    user_sub = user_parser.add_subparsers(dest="subcommand")

    user_sub.add_parser("list", help="List users")

    user_info_parser = user_sub.add_parser("info", help="Get user info")
    user_info_parser.add_argument("user_id", help="User ID")

    user_create_parser = user_sub.add_parser("create", help="Create user")
    user_create_parser.add_argument("--email", help="User email")
    user_create_parser.add_argument("--user-id", help="User ID")
    user_create_parser.add_argument("--team", help="Add to team")

    user_add_parser = user_sub.add_parser("add-to-team", help="Add user to team")
    user_add_parser.add_argument("user_id", help="User ID")
    user_add_parser.add_argument("team_id", help="Team ID")
    user_add_parser.add_argument("--role", default="user", help="Role (user/admin)")

    user_remove_parser = user_sub.add_parser(
        "remove-from-team", help="Remove from team"
    )
    user_remove_parser.add_argument("user_id", help="User ID")
    user_remove_parser.add_argument("team_id", help="Team ID")

    # Audit commands
    audit_parser = subparsers.add_parser("audit", help="Audit and reporting")
    audit_sub = audit_parser.add_subparsers(dest="subcommand")

    audit_spend_parser = audit_sub.add_parser("spend", help="Spend report")
    audit_spend_parser.add_argument("--start", help="Start date (YYYY-MM-DD)")
    audit_spend_parser.add_argument("--end", help="End date (YYYY-MM-DD)")
    audit_spend_parser.add_argument("--team", help="Filter by team")

    audit_sub.add_parser("all-teams", help="All teams spend summary")

    # Health
    subparsers.add_parser("health", help="Check health")
    subparsers.add_parser("models", help="List available models")

    args = parser.parse_args()

    if not args.base_url or not args.master_key:
        print("Error: LITELLM_API_BASE and LITELLM_MASTER_KEY are required")
        print("Set them as environment variables or use --base-url and --master-key")
        sys.exit(1)

    admin = LiteLLMAdmin(args.base_url, args.master_key, verify_ssl=not args.insecure)

    try:
        result = None

        if args.command == "team":
            if args.subcommand == "list":
                result = admin.list_teams()
                if args.output == "table":
                    print(f"{'TEAM ID':<40} {'ALIAS':<20} {'BUDGET':<12} {'SPEND':<12}")
                    print("-" * 84)
                    for t in result:
                        print(
                            f"{t.get('team_id', 'N/A'):<40} "
                            f"{t.get('team_alias', 'N/A'):<20} "
                            f"{format_currency(t.get('max_budget')):<12} "
                            f"{format_currency(t.get('spend', 0)):<12}"
                        )
                    return

            elif args.subcommand == "info":
                result = admin.get_team(args.team_id)

            elif args.subcommand == "create":
                models = args.models.split(",") if args.models else None
                result = admin.create_team(
                    args.team_alias,
                    max_budget=args.budget,
                    models=models,
                    budget_duration=args.budget_duration,
                )
                print(f"Created team: {result.get('team_id')}")

            elif args.subcommand == "update":
                kwargs = {}
                if args.alias:
                    kwargs["team_alias"] = args.alias
                if args.budget is not None:
                    kwargs["max_budget"] = args.budget
                if args.models:
                    kwargs["models"] = args.models.split(",")
                result = admin.update_team(args.team_id, **kwargs)

            elif args.subcommand == "delete":
                if not args.force:
                    confirm = input(f"Delete team {args.team_id}? (y/N): ")
                    if confirm.lower() != "y":
                        print("Aborted")
                        return
                result = admin.delete_team(args.team_id)

        elif args.command == "key":
            if args.subcommand == "list":
                result = admin.list_keys(team_id=args.team)
                if args.output == "table":
                    keys = result.get("keys", [])
                    print(f"{'KEY (truncated)':<25} {'ALIAS':<20} {'TEAM':<20} {'BUDGET':<12}")
                    print("-" * 77)
                    for k in keys:
                        token = k.get("token", "")[:20] + "..."
                        print(
                            f"{token:<25} "
                            f"{k.get('key_alias', 'N/A'):<20} "
                            f"{k.get('team_id', 'N/A')[:18]:<20} "
                            f"{format_currency(k.get('max_budget')):<12}"
                        )
                    return

            elif args.subcommand == "info":
                result = admin.get_key(args.key)

            elif args.subcommand == "create":
                models = args.models.split(",") if args.models else None
                result = admin.create_key(
                    team_id=args.team,
                    key_alias=args.alias,
                    max_budget=args.budget,
                    models=models,
                    user_id=args.user,
                    duration=args.duration,
                )
                print(f"\nNew API Key: {result.get('key')}")
                print("Save this key! It cannot be retrieved later.")

            elif args.subcommand == "update":
                kwargs = {}
                if args.team:
                    kwargs["team_id"] = args.team
                if args.alias:
                    kwargs["key_alias"] = args.alias
                if args.budget is not None:
                    kwargs["max_budget"] = args.budget
                result = admin.update_key(args.key, **kwargs)

            elif args.subcommand == "delete":
                if not args.force:
                    confirm = input("Delete this key? (y/N): ")
                    if confirm.lower() != "y":
                        print("Aborted")
                        return
                result = admin.delete_key(args.key)

        elif args.command == "user":
            if args.subcommand == "list":
                result = admin.list_users()

            elif args.subcommand == "info":
                result = admin.get_user(args.user_id)

            elif args.subcommand == "create":
                teams = [args.team] if args.team else None
                result = admin.create_user(
                    user_email=args.email, user_id=args.user_id, teams=teams
                )

            elif args.subcommand == "add-to-team":
                result = admin.add_team_member(args.team_id, args.user_id, args.role)

            elif args.subcommand == "remove-from-team":
                result = admin.remove_team_member(args.team_id, args.user_id)

        elif args.command == "audit":
            if args.subcommand == "spend":
                result = admin.get_spend_report(
                    start_date=args.start, end_date=args.end, team_id=args.team
                )

            elif args.subcommand == "all-teams":
                result = admin.get_all_teams_spend()
                if args.output == "table":
                    print(f"{'TEAM':<30} {'SPEND':<12} {'BUDGET':<12} {'REMAINING':<12}")
                    print("-" * 66)
                    for t in result:
                        print(
                            f"{t.get('team_alias', t.get('team_id', 'N/A'))[:28]:<30} "
                            f"{format_currency(t.get('spend', 0)):<12} "
                            f"{format_currency(t.get('max_budget')):<12} "
                            f"{format_currency(t.get('budget_remaining')):<12}"
                        )
                    return

        elif args.command == "health":
            result = admin.health()

        elif args.command == "models":
            result = admin.list_models()
            for model in sorted(result):
                print(model)
            return

        else:
            parser.print_help()
            return

        if result is not None:
            print(json.dumps(result, indent=2))

    except requests.exceptions.HTTPError as e:
        print(f"API Error: {e.response.status_code} - {e.response.text}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
