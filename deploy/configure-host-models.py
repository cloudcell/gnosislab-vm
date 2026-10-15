#!/usr/bin/env python3
"""Register any reachable OpenAI-compatible host models with OpenCode.

Run inside a GnosisLab VM as lab:
    python3 ~/Desktop/configure-host-models.py --url http://192.168.122.1:8002/v1
    python3 ~/Desktop/configure-host-models.py --url http://192.168.122.1:8002/v1 --context 262144

The exact IDs come from /v1/models. No vendor-specific model guesses.
The dedicated local-provider file is JSONC-compatible; other OpenCode
settings in opencode.json are left unchanged.
"""
import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request


def model_ids(data):
    if not isinstance(data, dict) or not isinstance(data.get("data"), list):
        raise ValueError("endpoint did not return an OpenAI-compatible models list")
    ids = [m.get("id") for m in data["data"] if isinstance(m, dict)
           and isinstance(m.get("id"), str) and m["id"].strip()]
    if not ids:
        raise ValueError("no models advertised by /v1/models")
    return list(dict.fromkeys(ids))


def build_provider(ids, url, context, output):
    models = {}
    for model in ids:
        definition = {"name": model}
        if context:
            definition["limit"] = {"context": context, "output": output}
        models[model] = definition
    return {
        "$schema": "https://opencode.ai/config.json",
        "providers": {
            "host-local": {
                "package": "aisdk:@ai-sdk/openai-compatible",
                "name": "Host local models",
                "settings": {"baseURL": url},
                "models": models,
            }
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://192.168.122.1:8002/v1")
    parser.add_argument("--context", type=int, default=0,
                        help="actual context window of the running server (0: omit)")
    parser.add_argument("--output", type=int, default=8192)
    parser.add_argument("--model", action="append", default=[],
                        help="explicit served model ID; repeat to register several")
    parser.add_argument("--file", type=pathlib.Path,
                        default=pathlib.Path.home()/".config/opencode/opencode.jsonc")
    parser.add_argument("--api-key", default=os.environ.get("HOST_LLM_API_KEY", ""),
                        help="API key for discovery only; use env for sensitive credentials")
    args = parser.parse_args()
    parts = urllib.parse.urlsplit(args.url)
    if parts.scheme not in {"http", "https"} or not parts.netloc or parts.query or parts.fragment:
        parser.error("--url must be an http(s) API base URL")
    if args.context < 0 or args.output <= 0 or (args.context and args.output >= args.context):
        parser.error("invalid --context/--output limits")
    url = args.url.rstrip("/")
    if args.model:
        ids = list(dict.fromkeys(args.model))
    else:
        req = urllib.request.Request(url + "/models")
        if args.api_key:
            req.add_header("Authorization", "Bearer " + args.api_key)
        try:
            with urllib.request.urlopen(req, timeout=8) as response:
                ids = model_ids(json.load(response))
        except (OSError, ValueError, urllib.error.HTTPError) as exc:
            parser.exit(1, f"Cannot discover host models at {url}/models: {exc}\n"
                        "Check host bind address, listener, and firewall.\n")
    config = build_provider(ids, url, args.context, args.output)
    args.file.parent.mkdir(parents=True, exist_ok=True)
    if args.file.exists():
        old = args.file.read_text()
        # Preserve unrelated providers if the file is already plain JSON.
        # Never silently discard hand-written JSONC with comments.
        try:
            existing = json.loads(old)
        except json.JSONDecodeError:
            # Migrate the exact legacy bundled provider; don't erase custom JSONC.
            if ('"Local vLLM (host)"' in old and
                    '"http://192.168.122.1:8002/v1"' in old and
                    '"models": {}' in old):
                existing = {"$schema": "https://opencode.ai/config.json", "providers": {}}
            else:
                parser.exit(1, f"{args.file} contains custom commented JSONC; "
                            "back it up and migrate manually.\\n")
        providers = existing.pop("providers", existing.pop("provider", {}))
        providers.pop("vllm", None)
        providers.update(config["providers"])
        existing["providers"] = providers
        config = existing
    tmp = args.file.with_name(args.file.name + ".new")
    tmp.write_text(json.dumps(config, indent=2) + "\n")
    tmp.chmod(0o600)
    tmp.replace(args.file)
    print(f"Registered {len(ids)} host model(s) from {url}:")
    for ident in ids:
        print(f"  host-local/{ident}")
    print("Restart OpenCode to load the updated provider.")


if __name__ == "__main__":
    main()
