import datetime as dt
import unittest
from zoneinfo import ZoneInfo
import runner
from runner import due, in_window, normalize, DEFAULTS
from unittest.mock import patch
from pathlib import Path
from tempfile import TemporaryDirectory

ACCOUNTS = [f"inbox{i}@example.com" for i in range(4)]

class RunnerTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.object(runner, "ACCOUNTS", ACCOUNTS)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_account_configuration(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "accounts.json"
            self.assertEqual(runner.load_accounts(path), [])
            path.write_text('["first@example.com", "first@example.com", "second@example.com"]')
            self.assertEqual(runner.load_accounts(path), ["first@example.com", "second@example.com"])
            for invalid in ['{"account":"first@example.com"}', '["bad\\\"@example.com"]', '[42]']:
                path.write_text(invalid)
                self.assertEqual(runner.load_accounts(path), [])

    def test_empty_configuration_never_completes(self):
        with patch.object(runner, "ACCOUNTS", []):
            report, state = normalize(dict(complete=True, accounts=[], messages=[]), {}, 200)
            self.assertFalse(report["complete"])
            self.assertNotIn("last_success", state)

    def now(self, hour, minute=0):
        return dt.datetime(2026,10,21,hour,minute,tzinfo=ZoneInfo('Asia/Hong_Kong'))
    def result(self, messages=None, complete=True):
        return dict(complete=complete,summary='Test',accounts=[dict(account=a,status='checked',detail='') for a in ACCOUNTS],messages=messages or [])
    def test_noon_is_noon(self):
        self.assertTrue(in_window(self.now(7),420,720))
        self.assertTrue(in_window(self.now(12),420,720))
        self.assertFalse(in_window(self.now(12,1),420,720))
        self.assertFalse(in_window(self.now(6,59),420,720))
    def test_overnight(self):
        self.assertTrue(in_window(self.now(23),1320,120))
        self.assertTrue(in_window(self.now(1),1320,120))
        self.assertFalse(in_window(self.now(12),1320,120))
    def test_pause_and_interval(self):
        now=self.now(10)
        self.assertFalse(due(dict(DEFAULTS,enabled=False),{},now))
        active=dict(DEFAULTS,enabled=True)
        self.assertFalse(due(active,dict(last_started=now.timestamp()-300),now))
        self.assertTrue(due(active,dict(last_started=now.timestamp()-600),now))
    def test_incomplete_never_advances_checkpoint(self):
        source=self.result();source['accounts'][0]['status']='blocked'
        report,state=normalize(source,dict(last_success=100),200)
        self.assertFalse(report['complete'])
        self.assertEqual(state['last_success'],100)
    def test_success_advances_checkpoint(self):
        report,state=normalize(self.result(),{},200)
        self.assertTrue(report['complete'])
        self.assertEqual(state['last_success'],200)
    def test_duplicate_and_promotion_suppression(self):
        item=dict(account=ACCOUNTS[0],sender='A',subject='Hello',received_at='2026-10-21T10:00:00+08:00',important=True,needs_reply=False,category='promotion')
        report,state=normalize(self.result([item,item.copy()]),{},200)
        self.assertEqual(len(report['messages']),1)
        self.assertEqual(report['alerts'],[])
        report2,_=normalize(self.result([item.copy()]),state,300)
        self.assertEqual(report2['new_count'],0)
    def test_reply_needed_alert(self):
        item=dict(account=ACCOUNTS[3],sender='B',subject='Meeting',received_at='2026-10-21T10:00:00+08:00',important=False,needs_reply=True,category='school')
        report,_=normalize(self.result([item]),{},200)
        self.assertEqual(len(report['alerts']),1)

if __name__=='__main__':unittest.main()
