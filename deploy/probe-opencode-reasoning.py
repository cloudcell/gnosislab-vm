#!/usr/bin/env python3
"""Probe a model's real Chat Completions reasoning efforts and update V2 variants.

Only modify the selected model in an OpenCode V2 JSON/JSONC config.
An invalid-effort negative control detects endpoints which ignore the knob.
This proves server-side validation; separately verify OpenCode outgoing traffic.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.error
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
    existing['variants'] = remaining + [
        {'id': value, 'settings': {'reasoningEffort': value}} for value in accepted
    ]
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', type=Path, default=Path.home()/'.config/opencode/opencode.jsonc')
    parser.add_argument('--provider', default='host-local')
    parser.add_argument('--model', required=True, help='OpenCode catalog model ID, e.g. qwen38')
    parser.add_argument('--url', help='Optional API URL; by default use provider settings.baseURL')
    parser.add_argument('--default-effort', choices=EFFORTS,
                        help='An explicitly known supported default; otherwise use server default')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--max-tokens', type=int, default=64)
    parser.add_argument('--api-key', default=os.environ.get('HOST_LLM_API_KEY', ''))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.max_tokens <= 0:
        parser.error('--timeout and --max-tokens must be positive')
    if not args.file.is_file():
        parser.error(f'configuration missing: {args.file}')
    source = args.file.read_text()
    try:
        full = json.loads(strip_trailing_commas(source))
        definition = full['providers'][args.provider]['models'][args.model]
        url = args.url or full['providers'][args.provider]['settings']['baseURL']
        upstream_id = definition.get('modelID', args.model)
        start, end = model_span(source, args.provider, args.model)
        if source[start:end] != mask_comments(source[start:end]):
            raise ValueError('target model has comments which cannot be preserved')
    except (KeyError, TypeError, ValueError) as exc:
        parser.error(str(exc))
    print(f'Probing {url} model={upstream_id} (OpenCode {args.provider}/{args.model})')
    try:
        accepted, results = probe(url, upstream_id, args.api_key, args.timeout, args.max_tokens)
        for effort, (outcome, detail) in results.items():
            print(f'  {effort:7s}: {outcome:8s} {detail}')
        print('Server-validated efforts: ' + (', '.join(accepted) or '(none)'))
        revised = updated_model(source, args.provider, args.model, accepted, args.default_effort)
    except (RuntimeError, ValueError) as exc:
        parser.exit(1, f'No changes: {exc}\n')
    if args.dry_run:
        print('Dry-run; configuration unchanged')
        return 0
    if revised == source:
        print('No change necessary')
        return 0
    backup = args.file.with_name(args.file.name + '.reasoning-backup')
    if not backup.exists():
        shutil.copy2(args.file, backup)
    temp = args.file.with_name(args.file.name + '.reasoning-new')
    temp.write_text(revised)
    temp.chmod(0o600)
    temp.replace(args.file)
    print(f'Updated only {args.provider}/{args.model}; backup: {backup}')
    print('Still verify that OpenCode forwards each variant in the outgoing request body.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
