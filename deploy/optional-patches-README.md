# Optional OpenCode local-model setup

Use `configure-host-models.py` **inside the VM** as the `lab` user.
It is opt-in, does not launch any models, and discovers their exact IDs
from a reachable OpenAI-compatible server.

Typical setup with a vLLM server on the libvirt host:

```bash
python3 ~/Desktop/optional-patches/configure-host-models.py \
  --url http://192.168.122.1:8002/v1
```

If the server advertises a 262144-token context window, you can set it
explicitly after verifying that the model and runtime actually support it:

```bash
python3 ~/Desktop/optional-patches/configure-host-models.py \
  --url http://192.168.122.1:8002/v1 \
  --context 262144 --output 8192
```

The script writes the local provider to `~/.config/opencode/opencode.jsonc`,
retaining unrelated settings in plain JSON configuration and refusing to
overwrite unrecognized commented JSONC. Restart OpenCode afterward.

For an endpoint that is not reachable, fix its bind address, firewall or
guest-to-host networking first. Do not open the trusted MCP network or
grant the experiment container access to the host to make this work.

Additional operator-supplied patches may be installed via
`LABLOOP_PATCHES_DIR=/path/to/private/patches` on the **host** when
running the desktop repair. Nothing in this directory is executed
automatically.

## Per-model reasoning efforts (OpenCode V2)

Do not assume every served model accepts the same effort levels. Probe **each model separately** using the real `/v1/chat/completions` API:

```bash
python3 ~/Desktop/optional-patches/probe-opencode-reasoning.py \
  --model qwen38 --dry-run
```

Once the results match the served model, remove `--dry-run` to update **only** that model's V2 `variants` array. For a verified server default of `xhigh` you may additionally pass `--default-effort xhigh`; otherwise the script leaves the server default in control. It will never infer a default from the largest effort name.

The script sends an invalid effort negative control, then probes `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max` individually. It rejects inconclusive probes and refuses to overwrite JSONC comments inside the target model. Other model entries, MCP servers, instructions, and unrelated JSONC remain untouched. It creates a one-time `.reasoning-backup`.

**Two independent verification requirements:** This script establishes that the API endpoint validates and accepts particular values. It **cannot prove** OpenCode forwards each selected variant. For that, check the actual outgoing `reasoning_effort` in OpenCode's request body using a trusted HTTP logging reverse proxy or equivalent, and verify Ctrl+T cycles through exactly the configured variants without HTTP 400 responses. Never treat a TUI variant label or HTTP 200 alone as transport verification.
