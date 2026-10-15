#!/usr/bin/env python3
"""Register OpenAI-compatible host models and optionally verify reasoning.

Inside the VM (as lab):
  python3 ~/Desktop/optional-patches/configure-host-models.py
  python3 ~/Desktop/optional-patches/configure-host-models.py --probe-reasoning
  python3 ~/Desktop/optional-patches/configure-host-models.py --model qwen38 --probe-reasoning --dry-run

Registration is safe without probing: the server selects default reasoning.
Probing is opt-in, model-specific and fail-closed. Existing model definitions,
MCP servers, other providers and JSONC comments outside the managed provider
are preserved. No model-specific values are inferred from its name.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

EFFORTS = ("none", "minimal", "low", "medium", "high", "xhigh", "max")
INVALID = "__gnosislab_invalid_reasoning_effort__"


def mask_comments(source):
    """Mask JSONC comments in-place by offsets while preserving actual strings."""
    out = list(source)
    i, n, quoted = 0, len(source), False
    while i < n:
        ch = source[i]
        if quoted:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                quoted = False
            i += 1
            continue
        if ch == '"':
            quoted = True
            i += 1
            continue
        if ch == '/' and i + 1 < n and source[i + 1] in ('/', '*'):
            start = i
            line = source[i + 1] == '/'
            i += 2
            if line:
                while i < n and source[i] != '\n':
                    i += 1
            else:
                end = source.find('*/', i)
                if end < 0:
                    raise ValueError("unclosed JSONC comment")
                i = end + 2
            for j in range(start, i):
                if out[j] not in '\n\r':
                    out[j] = ' '
            continue
        i += 1
    return ''.join(out)


def value_end(clean, start):
    """Return the end offset of a JSON value without disturbing text layout."""
    if clean[start] in '{[':
        close = {'{': '}', '[': ']'}
        stack = [close[clean[start]]]
        i, quoted = start + 1, False
        while i < len(clean):
            c = clean[i]
            if quoted:
                if c == '\\':
                    i += 2
                    continue
                if c == '"':
                    quoted = False
            elif c == '"':
                quoted = True
            elif c in close:
                stack.append(close[c])
            elif c in '}]':
                if not stack or c != stack.pop():
                    raise ValueError("malformed JSONC containers")
                if not stack:
                    return i + 1
            i += 1
        raise ValueError("unclosed JSONC object/array")
    if clean[start] == '"':
        _, end = json.JSONDecoder().raw_decode(clean[start:])
        return start + end
    i = start
    while i < len(clean) and clean[i] not in ',}]\n\r \t':
        i += 1
    return i


def find_property(source, object_start, name):
    clean = mask_comments(source)
    if clean[object_start] != '{':
        raise ValueError('expected object at JSONC path')
    end = value_end(clean, object_start)
    i = object_start + 1
    while i < end:
        while i < end and clean[i] in ', \t\r\n':
            i += 1
        if clean[i] == '}':
            break
        key, offset = json.JSONDecoder().raw_decode(clean[i:])
        i += offset
        while clean[i] in ' \t\r\n':
            i += 1
        if clean[i] != ':':
            raise ValueError('malformed JSONC key/value')
        i += 1
        while clean[i] in ' \t\r\n':
            i += 1
        start = i
        finish = value_end(clean, start)
        if key == name:
            return start, finish
        i = finish
    raise ValueError(f'V2 config lacks {name!r} at expected location')


def strip_trailing_commas(source):
    """Allow normal JSONC trailing commas without rewriting original file."""
    chars = list(mask_comments(source))
    quoted = False
    i = 0
    while i < len(chars):
        ch = chars[i]
        if quoted:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
        elif ch == ',':
            j = i + 1
            while j < len(chars) and chars[j] in ' \t\r\n':
                j += 1
            if j < len(chars) and chars[j] in '}]':
                chars[i] = ' '
        i += 1
    return ''.join(chars)


def model_span(source, provider, model):
    start = source.index('{')
    for key in ('providers', provider, 'models', model):
        start, end = find_property(source, start, key)
    if source[start] != '{':
        raise ValueError('selected model must be an object')
    return start, end


def request_effort(url, model_id, effort, api_key, timeout, max_tokens):
    payload = {
        'model': model_id,
        'messages': [{'role': 'user',
                      'content': 'Calculate 17 * 23, then answer with only the result.'}],
        'stream': False,
        'max_tokens': max_tokens,
        'reasoning_effort': effort,
    }
    req = urllib.request.Request(
        url.rstrip('/') + '/chat/completions',
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json',
                 **({'Authorization': 'Bearer ' + api_key} if api_key else {})},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status, data = response.status, json.load(response)
    except urllib.error.HTTPError as err:
        status = err.code
        try:
            data = json.loads(err.read(16384))
        except (ValueError, UnicodeDecodeError):
            data = {'error': {'message': 'unparseable server error'}}
    except (OSError, TimeoutError, ValueError) as exc:
        return 'uncertain', str(exc)
    if status in (400, 422):
        msg = json.dumps(data.get('error', data)).lower() if isinstance(data, dict) else ''
        if any(s in msg for s in ('reasoning_effort', 'reasoning effort', 'reasoning.effort')):
            return 'rejected', f'HTTP {status} reasoning-effort validation'
        return 'uncertain', f'HTTP {status} without reasoning-specific validation'
    if status != 200:
        return 'uncertain', f'HTTP {status}'
    if not isinstance(data, dict) or not isinstance(data.get('choices'), list) or not data['choices']:
        return 'uncertain', 'HTTP 200 missing Chat Completions choices'
    details = (data.get('usage') or {}).get('completion_tokens_details') or {}
    tokens = details.get('reasoning_tokens')
    message = data['choices'][0].get('message') or {}
    trace = message.get('reasoning_content') or message.get('reasoning') or message.get('reasoning_text')
    telemetry = f'reasoning_tokens={tokens}' if tokens is not None else 'reasoning_tokens=n/a'
    if isinstance(trace, str) and trace:
        telemetry += ', reasoning_content=present'
    if effort == 'none' and ((isinstance(tokens, int) and tokens > 0) or
                             (isinstance(trace, str) and trace)):
        return 'uncertain', 'none returned reasoning content/tokens: cannot validate disabling'
    return 'accepted', f'HTTP 200 ({telemetry})'


def probe(url, model_id, api_key, timeout, max_tokens, request=request_effort):
    control, detail = request(url, model_id, INVALID, api_key, timeout, max_tokens)
    if control != 'rejected':
        raise RuntimeError(
            f'Negative control was {control} ({detail}); backend may ignore reasoning_effort. '
            'No variants generated.'
        )
    accepted, results = [], {}
    for effort in EFFORTS:
        outcome, detail = request(url, model_id, effort, api_key, timeout, max_tokens)
        results[effort] = (outcome, detail)
        if outcome == 'accepted':
            accepted.append(effort)
    if any(outcome == 'uncertain' for outcome, _ in results.values()):
        raise RuntimeError('Some probes were inconclusive; config unchanged. Retry later.')
    return accepted, results


def updated_model(source, provider, model, accepted, default=None):
    start, end = model_span(source, provider, model)
    if default and default not in accepted:
        raise ValueError(f'Default {default!r} was not accepted by this model')
    if source[start:end] != mask_comments(source[start:end]):
        raise ValueError('Target model contains comments; refusing to discard them')
    existing = json.loads(strip_trailing_commas(source[start:end]))
    variants = existing.get('variants', [])
    if not isinstance(variants, list):
        raise ValueError('V2 variants must be an array')
    # Replace only known reasoning-effort variants. Preserve all custom,
    # non-effort variants, all model metadata and the rest of the JSONC file.
    remaining = [
        v for v in variants
        if not (isinstance(v, dict) and v.get('id') in EFFORTS
                and isinstance(v.get('settings'), dict)
                and v['settings'].get('reasoningEffort') in EFFORTS)
    ]
    overlap = set(accepted) & {v.get('id') for v in remaining if isinstance(v, dict)}
    if overlap:
        raise ValueError(f'Custom variant IDs conflict with efforts: {sorted(overlap)}')
    new_variants = remaining + [
        {'id': value, 'settings': {'reasoningEffort': value}} for value in accepted
    ]
    if new_variants:
        existing['variants'] = new_variants
    else:
        existing.pop('variants', None)
    if default:
        existing.setdefault('settings', {})['reasoningEffort'] = default
    else:
        settings = existing.get('settings', {})
        if settings.get('reasoningEffort') in EFFORTS and settings['reasoningEffort'] not in accepted:
            del settings['reasoningEffort']  # let the server choose its default
    prefix = source[source.rfind('\n', 0, start) + 1:start]
    if prefix.strip():
        prefix = re.match(r'\s*', prefix).group(0)
    rendered = json.dumps(existing, indent=2, ensure_ascii=False).replace('\n', '\n' + prefix)
    return source[:start] + rendered + source[end:]




def model_ids(data):
    if not isinstance(data, dict) or not isinstance(data.get('data'), list):
        raise ValueError('endpoint did not return an OpenAI-compatible models list')
    ids = [x.get('id') for x in data['data']
           if isinstance(x, dict) and isinstance(x.get('id'), str) and x['id'].strip()]
    if not ids:
        raise ValueError('no models advertised by /v1/models')
    return list(dict.fromkeys(ids))


def discover(url, api_key, timeout):
    headers = {'Authorization': 'Bearer ' + api_key} if api_key else {}
    req = urllib.request.Request(url.rstrip('/') + '/models', headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return model_ids(json.load(response))


def value_at(source, path):
    """Span of a nested JSONC object value."""
    begin = source.index('{')
    for key in path:
        begin, finish = find_property(source, begin, key)
    return begin, finish


def insert_property(source, object_start, name, value):
    """Insert a missing JSONC member without rewriting sibling properties.

    Preserve comments and existing formatting; handle existing trailing commas.
    """
    clean = mask_comments(source)
    end = value_end(clean, object_start)
    before = clean[object_start + 1:end - 1].rstrip()
    has_members = bool(before)
    ends_comma = before.endswith(',')
    parent_indent = re.match(r'[ \t]*', source[source.rfind('\n', 0, object_start) + 1:]).group(0)
    child_indent = parent_indent + '  '
    rendered = json.dumps(value, indent=2, ensure_ascii=False)
    rendered = rendered.replace('\n', '\n' + child_indent)
    comma = '' if not has_members or ends_comma else ','
    member = comma + '\n' + child_indent + json.dumps(name) + ': ' + rendered + '\n' + parent_indent
    return source[:end - 1] + member + source[end - 1:]


def update_path(source, path, value):
    """Update one JSONC subtree, keeping unrelated providers and comments."""
    try:
        start, end = value_at(source, path)
    except ValueError as exc:
        if 'lacks' not in str(exc):
            raise
        parent = path[:-1]
        try:
            pstart, _ = value_at(source, parent) if parent else (source.index('{'), None)
        except ValueError as parent_exc:
            if 'lacks' not in str(parent_exc):
                raise
            return update_path(source, parent, {path[-1]: value})
        return insert_property(source, pstart, path[-1], value)
    old = source[start:end]
    if old != mask_comments(old):
        raise ValueError('comments inside managed host-local provider cannot be overwritten; '
                         'move comments outside that object or edit it manually')
    prefix = re.match(r'[ \t]*', source[source.rfind('\n', 0, start) + 1:]).group(0)
    rendered = json.dumps(value, indent=2, ensure_ascii=False).replace('\n', '\n' + prefix)
    return source[:start] + rendered + source[end:]


def merge_registry(source, ids, url, context=0, output=8192):
    """Retain all registered models and settings. Add or update only discovered IDs."""
    current = json.loads(strip_trailing_commas(source))
    if not isinstance(current, dict):
        raise ValueError('OpenCode config root is not an object')
    providers = current.get('providers', {})
    if not isinstance(providers, dict):
        raise ValueError('V2 providers must be an object')
    old = providers.get('host-local', {})
    if not isinstance(old, dict):
        raise ValueError('host-local provider must be an object')
    # Copy nested settings; never mutate caller input.
    host = json.loads(json.dumps(old))
    host.setdefault('name', 'Host local models')
    host.setdefault('package', 'aisdk:@ai-sdk/openai-compatible')
    settings = host.setdefault('settings', {})
    if not isinstance(settings, dict):
        raise ValueError('provider settings must be an object')
    previous_url = settings.get('baseURL')
    settings['baseURL'] = url
    models = host.setdefault('models', {})
    if not isinstance(models, dict):
        raise ValueError('provider models must be an object')
    for model_id in ids:
        model = models.setdefault(model_id, {'name': model_id})
        if not isinstance(model, dict):
            raise ValueError(f'model {model_id!r} is not an object')
        model.setdefault('name', model_id)
        if context:
            limits = model.setdefault('limit', {})
            if not isinstance(limits, dict):
                raise ValueError(f'model {model_id!r} limit must be an object')
            limits.update({'context': context, 'output': output})
    merged = update_path(source, ('providers', 'host-local'), host)
    return merged, previous_url


def save_config(path, original, updated):
    """Atomic private write and one-time backup; refuse symlinks."""
    if updated == original:
        return False
    if path.is_symlink():
        raise ValueError(f'refusing symlinked OpenCode configuration: {path}')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_file():
        backup = path.with_name(path.name + '.before-host-models')
        if not backup.exists():
            shutil.copy2(path, backup)
            backup.chmod(0o600)
    fd, name = tempfile.mkstemp(prefix='.gnosislab-config-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://192.168.122.1:8002/v1',
                        help='OpenAI-compatible API base URL ending in /v1')
    parser.add_argument('--file', type=Path, default=Path.home()/'.config/opencode/opencode.jsonc')
    parser.add_argument('--model', action='append', default=[],
                        help='model ID; repeat to select several; otherwise discover via /models')
    parser.add_argument('--context', type=int, default=0,
                        help='actual context tokens (0 preserves existing settings)')
    parser.add_argument('--output', type=int, default=8192)
    parser.add_argument('--api-key', default=os.environ.get('HOST_LLM_API_KEY', ''))
    parser.add_argument('--probe-reasoning', action='store_true',
                        help='opt-in validation of reasoning_effort for each selected model')
    parser.add_argument('--default-effort', choices=EFFORTS,
                        help='verified default for probed models (never inferred)')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--max-tokens', type=int, default=64)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)

    parts = urllib.parse.urlsplit(args.url)
    if (parts.scheme not in {'http', 'https'} or not parts.netloc or
            parts.query or parts.fragment or parts.username or parts.password):
        parser.error('--url must be a valid http(s) API base URL without credentials/query')
    if args.context < 0 or args.output <= 0 or (args.context and args.output >= args.context):
        parser.error('invalid --context/--output limits')
    if args.timeout <= 0 or args.max_tokens <= 0:
        parser.error('--timeout and --max-tokens must be positive')
    if args.default_effort and not args.probe_reasoning:
        parser.error('--default-effort requires --probe-reasoning')
    if args.file.is_symlink():
        parser.error('refusing symlinked config file')

    url = args.url.rstrip('/')
    try:
        ids = list(dict.fromkeys(args.model)) if args.model else discover(url, args.api_key, args.timeout)
        if not ids or any(not m.strip() for m in ids):
            raise ValueError('no valid model IDs')
        source = args.file.read_text() if args.file.exists() else '{}\n'
        merged, previous_url = merge_registry(source, ids, url, args.context, args.output)

        if previous_url and previous_url != url and not args.probe_reasoning:
            print('NOTICE: endpoint changed. Existing variants retained as user settings, '
                  'but must be revalidated with --probe-reasoning.', file=sys.stderr)

        if args.probe_reasoning:
            for model in ids:
                current = json.loads(strip_trailing_commas(merged))
                upstream = current['providers']['host-local']['models'][model].get('modelID', model)
                print(f'Probing {model} ({upstream}) at {url}', flush=True)
                accepted, results = probe(url, upstream, args.api_key,
                                          args.timeout, args.max_tokens)
                for effort, (status, detail) in results.items():
                    print(f'  {effort:8s} {status:9s} {detail}', flush=True)
                merged = updated_model(merged, 'host-local', model,
                                       accepted, args.default_effort)
                print(f'  accepted: {", ".join(accepted) or "(no configurable efforts)"}')
        # Parse again after all updates, before any write.
        json.loads(strip_trailing_commas(merged))
        if args.dry_run:
            print('DRY RUN: no changes written')
            return 0
        saved = save_config(args.file, source, merged)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as exc:
        parser.exit(1, f'No changes written: {exc}\n')
    print(f'{"Updated" if saved else "Unchanged"} {args.file}')
    print(f'Registered/discovered {len(ids)} model(s): ' + ', '.join(ids))
    if args.probe_reasoning:
        print('Server validation completed. Verify Ctrl+T cycling AND OpenCode wire requests; '
              'server acceptance does not prove OpenCode forwards reasoning_effort.')
    print('Reload OpenCode configuration or restart its TUI to load changes.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
