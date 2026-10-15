# Optional OpenCode V2 host-model configuration

The single `configure-host-models.py` script discovers and registers OpenAI-compatible host models. It never assumes that a model supports reasoning efforts.

Inside the VM as `lab`:

```bash
python3 ~/Desktop/optional-patches/configure-host-models.py
```

By default it discovers model IDs through `/v1/models` on `http://192.168.122.1:8002/v1`, adds new entries without deleting existing model settings or variants, and leaves the server's default reasoning behavior unchanged.

For a different endpoint or an explicit context window:

```bash
python3 ~/Desktop/optional-patches/configure-host-models.py \
  --url http://192.168.122.1:8002/v1 --context 262144 --output 8192
```

Only specify context/output limits that the running model actually supports. To test reasoning support for a particular model, first run a dry run:

```bash
python3 ~/Desktop/optional-patches/configure-host-models.py \
  --model qwen38 --probe-reasoning --dry-run
```

Then omit `--dry-run` to save its verified efforts. To probe every model returned by discovery, use `--probe-reasoning` without `--model`. This sends real inference requests, so it may be slow. An invalid-effort negative control detects endpoints which ignore `reasoning_effort`; rejected or uncertain efforts are never advertised as supported. Any inconclusive model aborts the whole change, leaving the config unchanged.

The script writes a private backup before modifying `~/.config/opencode/opencode.jsonc`, does not overwrite unrelated providers, and retains user settings. A changed endpoint requires effort revalidation; existing manually defined variants are not deleted automatically. If comments occur inside the managed host-local provider, the script refuses to rewrite them rather than discarding those comments. Reload/restart OpenCode after saving.

**Important:** API validation alone cannot prove that OpenCode forwards each selected variant. Confirm Ctrl+T cycles over the expected variants and inspect outgoing API requests where possible. Do not expose the trusted MCP network or hostile experiment container to the host to support model discovery.
