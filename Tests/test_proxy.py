import http.client
import http.server
import importlib.util
import json
import socket
import socketserver
import struct
import tempfile
import threading
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('office_proxy', Path(__file__).resolve().parents[1] / 'Plugins' / 'OfficeProxy' / 'Resources' / 'proxy.py')
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'HOME DIRECT'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *args):
        pass


class FakeSOCKS(socketserver.BaseRequestHandler):
    def handle(self):
        assert proxy.receive(self.request, 3) == b'\x05\x01\x00'
        self.request.sendall(b'\x05\x00')
        header = proxy.receive(self.request, 4)
        assert header == b'\x05\x01\x00\x03'
        host = proxy.receive(self.request, proxy.receive(self.request, 1)[0]).decode()
        port = struct.unpack('!H', proxy.receive(self.request, 2))[0]
        self.server.destinations.append((host, port))
        self.request.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50')
        if port == 443:
            while True:
                data = self.request.recv(65536)
                if not data: break
                self.request.sendall(data)
        else:
            data = b''
            while b'\r\n\r\n' not in data: data += self.request.recv(4096)
            self.server.last_request = data
            self.request.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nOFFICE')


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.config = Path(cls.temp.name)/'runtime.json'
        cls.origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        cls.socks = proxy.Server(('127.0.0.1', 0), FakeSOCKS)
        cls.socks.destinations = []
        cls.gateway = proxy.Server(('127.0.0.1', 0), proxy.Handler)
        cls.gateway.config_path = cls.config
        for server in [cls.origin, cls.socks, cls.gateway]:
            threading.Thread(target=server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for server in [cls.gateway, cls.socks, cls.origin]: server.shutdown(); server.server_close()
        cls.temp.cleanup()

    def configure(self, enabled=True, domains=None):
        self.config.write_text(json.dumps({'enabled': enabled, 'domains': domains or ['office.invalid'], 'socksPort': self.socks.server_address[1]}))

    def get(self, url):
        client = http.client.HTTPConnection(*self.gateway.server_address, timeout=5)
        client.request('GET', url, headers={'Proxy-Authorization': 'never-forward-this'})
        result = client.getresponse(); status = result.status; body = result.read(); client.close()
        return status, body

    def test_rule_boundaries_and_url_normalization(self):
        self.assertTrue(proxy.matches('a.example.com', ['*.example.com']))
        self.assertTrue(proxy.matches('example.com', ['*.example.com']))
        self.assertFalse(proxy.matches('notexample.com', ['*.example.com']))
        self.assertFalse(proxy.matches('intranet.example.com.evil.invalid', ['intranet.example.com']))
        self.assertEqual(proxy.normalize_rule('https://INTRANET.example.com:8443/project'), 'intranet.example.com')
        self.assertEqual(proxy.normalize_rule('192.0.2.10:80'), '192.0.2.10')

    def test_listed_host_and_remote_dns(self):
        self.configure()
        self.assertEqual(self.get('http://office.invalid/course?test=1'), (200, b'OFFICE'))
        self.assertEqual(self.socks.destinations[-1], ('office.invalid', 80))
        self.assertTrue(self.socks.last_request.startswith(b'GET /course?test=1 HTTP/1.1'))
        self.assertNotIn(b'Proxy-Authorization', self.socks.last_request)

    def test_unlisted_host_is_direct(self):
        self.configure(); before = len(self.socks.destinations)
        self.assertEqual(self.get('http://127.0.0.1:%s/' % self.origin.server_address[1]), (200, b'HOME DIRECT'))
        self.assertEqual(before, len(self.socks.destinations))

    def test_off_disables_office_routing(self):
        self.configure(enabled=False, domains=['127.0.0.1']); before = len(self.socks.destinations)
        self.assertEqual(self.get('http://127.0.0.1:%s/' % self.origin.server_address[1]), (200, b'HOME DIRECT'))
        self.assertEqual(before, len(self.socks.destinations))

    def test_domain_change_applies_to_new_connection(self):
        self.configure(domains=['office.invalid'])
        self.assertEqual(self.get('http://127.0.0.1:%s/' % self.origin.server_address[1])[1], b'HOME DIRECT')
        self.configure(domains=['127.0.0.1'])
        self.assertEqual(self.get('http://127.0.0.1:%s/' % self.origin.server_address[1])[1], b'OFFICE')

    def test_connect_tunnel_and_large_bidirectional_transfer(self):
        self.configure()
        client = socket.create_connection(self.gateway.server_address, timeout=10)
        client.sendall(b'CONNECT office.invalid:443 HTTP/1.1\r\nHost: office.invalid:443\r\n\r\n')
        header = b''
        while b'\r\n\r\n' not in header: header += client.recv(1)
        self.assertIn(b'200 Connection Established', header)
        payload = b'hello TLS tunnel\x00' * 150000
        def send():
            client.sendall(payload); client.shutdown(socket.SHUT_WR)
        sender = threading.Thread(target=send); sender.start()
        received = bytearray()
        while True:
            block = client.recv(65536)
            if not block: break
            received.extend(block)
        sender.join(); client.close()
        self.assertEqual(received, payload)


if __name__ == '__main__':
    unittest.main(verbosity=2)
