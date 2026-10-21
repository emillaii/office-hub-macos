#!/usr/bin/env python3
"""Local scheduled check; the Mac app reads Mail only with macOS consent."""
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / 'runtime'
DEFAULTS = dict(enabled=False, mail_access=False, interval_minutes=10, start_minutes=420,
                end_minutes=720, notify_all=False, include_summary=True)

def read_json(path, fallback):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback

def load_accounts(path):
    values = read_json(path, [])
    if not isinstance(values, list) or not all(isinstance(v, str) and "@" in v and not any(c in v for c in "\r\n\\\"") for v in values):
        return []
    return list(dict.fromkeys(v.strip() for v in values if v.strip()))

ACCOUNTS = load_accounts(ROOT / "accounts.json")

def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    tmp.chmod(0o600)
    tmp.replace(path)

def in_window(now, start, end):
    minute = now.hour * 60 + now.minute
    return start <= minute <= end if start <= end else minute >= start or minute <= end

def due(config, state, now, manual=False):
    if manual:
        return True
    if not config.get('enabled', True):
        return False
    if not in_window(now, config['start_minutes'], config['end_minutes']):
        return False
    return now.timestamp() - state.get('last_started', 0) >= config['interval_minutes'] * 60 - 1

def normalize(result, previous, started):
    coverage = result.get('accounts', [])
    checked = {a.get('account') for a in coverage if a.get('status') == 'checked'}
    complete = bool(ACCOUNTS) and result.get('complete') is True and checked == set(ACCOUNTS)
    seen_order = list(previous.get('seen_ids', []))
    seen = set(seen_order)
    new = []
    for item in result.get('messages', []):
        if item.get('account') not in ACCOUNTS:
            continue
        identity = item.get('account', '') + '|' + (item.get('message_id') or '|'.join(str(item.get(k, '')) for k in ('sender', 'subject', 'received_at')))
        key = hashlib.sha256(identity.encode()).hexdigest()
        if key not in seen:
            item['id'] = key
            item['important'] = bool(item.get('important', False))
            item['needs_reply'] = bool(item.get('needs_reply', False))
            new.append(item)
            seen.add(key)
            seen_order.append(key)
    alerts = [m for m in new if (m['important'] or m['needs_reply']) and m.get('category') != 'promotion']
    report = dict(checked_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  status='ok' if complete else 'incomplete', complete=complete,
                  summary=result.get('summary', 'Mail check returned no summary.'),
                  accounts=coverage, messages=new, alerts=alerts,
                  new_count=len(new), detail=result.get('detail', ''))
    next_state = dict(previous, seen_ids=seen_order[-20000:])
    if complete:
        next_state['last_success'] = started
    return report, next_state

def run(manual=False):
    os.umask(0o077)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    lock = (RUNTIME / 'check.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    config = dict(DEFAULTS, **read_json(ROOT / 'settings.json', {}))
    config['interval_minutes'] = max(1, min(1440, int(config['interval_minutes'])))
    state = read_json(RUNTIME / 'state.json', {})
    now = dt.datetime.now(ZoneInfo('Asia/Hong_Kong'))
    if not due(config, state, now, manual):
        return 0
    started = time.time()
    baseline = state.setdefault('monitoring_since', started - 600)
    since = max(baseline, state.get('last_success', baseline) - 86400)
    state['last_started'] = started
    write_json(RUNTIME / 'state.json', state)
    write_json(RUNTIME / 'activity.json', {'running': True, 'started_at': started})
    last_good = read_json(RUNTIME / 'report.json', {})
    since_iso = dt.datetime.fromtimestamp(since, dt.timezone.utc).astimezone(ZoneInfo('Asia/Hong_Kong')).isoformat()
    prompt = (ROOT / 'source' / 'check-instructions.txt').read_text().replace('{{SINCE}}', since_iso).replace('{{NOW}}', now.isoformat())
    output = RUNTIME / 'model-result.json'
    output.unlink(missing_ok=True)
    codex = shutil.which('codex', path='/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', '')) or 'codex'
    cmd = [codex, 'exec', '--ignore-user-config', '--ephemeral',
           '--skip-git-repo-check', '-C', str(ROOT), '-s', 'read-only',
           '-m', 'gpt-6-luna', '-c', 'model_reasoning_effort="high"',
           '--output-schema', str(ROOT / 'source' / 'report-schema.json'),
           '-o', str(output), '-']
    log_path = RUNTIME / 'last-run.log'
    snapshot = None
    try:
        if not ACCOUNTS:
            raise RuntimeError('No valid accounts configured. Add Apple Mail addresses to accounts.json and restart Mail Memo.')
        if not config.get('mail_access', False):
            raise RuntimeError('Automatic checks are paused. Open Preferences in Mail Memo and choose Connect Apple Mail to approve native macOS Automation access.')
        request_id = str(started)
        response_path = RUNTIME / 'collect-result.json'
        response_path.unlink(missing_ok=True)
        write_json(RUNTIME / 'collect-request.json', dict(request_id=request_id, since=since))
        deadline = time.monotonic() + 150
        snapshot = None
        while time.monotonic() < deadline:
            snapshot = read_json(response_path, {})
            if snapshot.get('request_id') == request_id:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Mail Memo did not respond. Keep the app running and approve any macOS Apple Mail Automation prompt.')
        if not snapshot.get('success'):
            raise RuntimeError(snapshot.get('detail', 'Apple Mail access needs approval.'))
        # No repeat model requests for previously classified messages in the overlap.
        seen = set(state.get('seen_ids', []))
        fresh = []
        for item in snapshot.get('messages', []):
            identity = item.get('account', '') + '|' + (item.get('message_id') or '|'.join(str(item.get(k, '')) for k in ('sender', 'subject', 'received_at')))
            if hashlib.sha256(identity.encode()).hexdigest() not in seen:
                fresh.append(item)
        snapshot['messages'] = fresh
        expected_complete = bool(ACCOUNTS) and not snapshot.get('syncing', True) and {a.get('account') for a in snapshot.get('accounts', []) if a.get('status') == 'checked'} == set(ACCOUNTS)
        if not fresh:
            result = dict(complete=expected_complete, accounts=snapshot.get('accounts', []), messages=[],
                          summary='No new messages in the checked period.' if expected_complete else 'No new downloaded messages were found, but Apple Mail is still syncing or an account could not be checked.',
                          detail=snapshot.get('detail', ''))
        else:
            prompt += '\n<untrusted_email_data>\n' + json.dumps(snapshot, ensure_ascii=False) + '\n</untrusted_email_data>\n'
            env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
            process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, env=env, start_new_session=True)
            try:
                process.communicate(prompt, timeout=300)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=15)
                raise RuntimeError('Luna timed out. No successful checkpoint was advanced.')
            log_path.write_text(json.dumps(dict(model='gpt-6-luna', exit_code=process.returncode, checked_at=now.isoformat())))
            if process.returncode != 0 or not output.exists():
                raise RuntimeError('Luna could not create a summary. Check your Codex sign-in and model availability.')
            result = read_json(output, None)
            if not isinstance(result, dict):
                raise RuntimeError('Luna returned an invalid report.')
            # Coverage is determined by the collector, never by model confidence.
            result['accounts'] = snapshot.get('accounts', [])
            originals = {(m['account'], m['message_id']): m for m in fresh}
            accepted = []
            handled = set()
            for classified in result.get('messages', []):
                key = (classified.get('account'), classified.get('message_id'))
                if key not in originals or key in handled:
                    continue
                item = dict(classified)
                for field in ('account', 'sender', 'subject', 'received_at', 'message_id'):
                    item[field] = originals[key][field]
                accepted.append(item)
                handled.add(key)
            result['messages'] = accepted
            result['complete'] = expected_complete and handled == set(originals)
            if handled != set(originals):
                result['detail'] = 'Luna did not classify every supplied message; this check is incomplete.'
        report, state = normalize(result, state, started)
        # Preserve recent important memos across quiet checks, without repeating notifications.
        recent = last_good.get('recent_alerts', [])
        recent = report['alerts'] + [m for m in recent if m.get('id') not in {a['id'] for a in report['alerts']}]
        report['recent_alerts'] = recent[:100]
        report['notification_id'] = str(started)
        write_json(RUNTIME / 'report.json', report)
        write_json(RUNTIME / 'state.json', state)
        with (RUNTIME / 'history.jsonl').open('a') as history:
            history.write(json.dumps(report, ensure_ascii=False) + '\n')
        # Bound local history, which contains summaries rather than full message bodies.
        history_path = RUNTIME / 'history.jsonl'
        lines = history_path.read_text().splitlines()
        if len(lines) > 200:
            history_path.write_text('\n'.join(lines[-200:]) + '\n')
        return 0 if report['complete'] else 2
    except Exception as exc:
        report = dict({'accounts': [], 'messages': [], 'recent_alerts': [], **last_good})
        if snapshot:
            report['accounts'] = snapshot.get('accounts', [])
        report.update(checked_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                      status='error', complete=False, summary=str(exc), alerts=[],
                      new_count=0, notification_id=str(started))
        write_json(RUNTIME / 'report.json', report)
        return 1
    finally:
        (RUNTIME / 'collect-request.json').unlink(missing_ok=True)
        (RUNTIME / 'collect-result.json').unlink(missing_ok=True)
        output.unlink(missing_ok=True)
        write_json(RUNTIME / 'activity.json', {'running': False, 'started_at': started})

if __name__ == '__main__':
    sys.exit(run('--manual' in sys.argv))
