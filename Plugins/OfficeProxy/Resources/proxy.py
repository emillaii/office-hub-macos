#!/usr/bin/python3
"""Loopback-only HTTP proxy. Listed hosts go through the office SSH SOCKS tunnel."""
import json
import select
import socket
import socketserver
import struct
import sys
from pathlib import Path
from urllib.parse import urlsplit

MAX_HEADER = 65536


def normalize_rule(value):
    value = value.strip().lower()
    if not value:
        return None
    if '://' in value:
        value = urlsplit(value).hostname or ''
    else:
        value = value.split('/')[0]
        if value.startswith('['):
            value = value[1:value.index(']')]
        elif value.count(':') == 1:
            value = value.split(':')[0]
    value = value.rstrip('.')
    wildcard = value.startswith('*.') or value.startswith('.')
    value = value.lstrip('*.') if wildcard else value
    if not value or any(c.isspace() for c in value) or any(c in value for c in '\\@?#;'):
        raise ValueError('Invalid domain: ' + value)
    value = value.encode('idna').decode('ascii')
    return '*.' + value if wildcard else value


def matches(host, rules):
    host = host.lower().rstrip('.')
    for value in rules:
        rule = normalize_rule(value)
        if not rule:
            continue
        if rule.startswith('*.'):
            suffix = rule[2:]
            if host == suffix or host.endswith('.' + suffix):
                return True
        elif host == rule:
            return True
    return False


def receive(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(count - len(data))
        if not block:
            raise ConnectionError('Connection closed during SOCKS handshake')
        data.extend(block)
    return bytes(data)


def connect_office(host, port, socks_port):
    sock = socket.create_connection(('127.0.0.1', socks_port), timeout=15)
    try:
        sock.sendall(b'\x05\x01\x00')
        if receive(sock, 2) != b'\x05\x00':
            raise ConnectionError('SOCKS authentication rejected')
        name = host.encode('idna')
        if len(name) > 255:
            raise ValueError('Hostname too long')
        sock.sendall(b'\x05\x01\x00\x03' + bytes([len(name)]) + name + struct.pack('!H', port))
        reply = receive(sock, 4)
        if reply[0] != 5 or reply[1] != 0:
            raise ConnectionError('Office connection refused (SOCKS code %s)' % reply[1])
        if reply[3] == 1:
            receive(sock, 4)
        elif reply[3] == 4:
            receive(sock, 16)
        elif reply[3] == 3:
            receive(sock, receive(sock, 1)[0])
        else:
            raise ConnectionError('Invalid SOCKS response')
        receive(sock, 2)
        return sock
    except Exception:
        sock.close()
        raise


def relay(client, upstream):
    # Bounded queues and nonblocking I/O keep large uploads and downloads bounded.
    client.setblocking(False)
    upstream.setblocking(False)
    pending = {client: bytearray(), upstream: bytearray()}
    peer = {client: upstream, upstream: client}
    reading = {client, upstream}
    try:
        while reading or any(pending.values()):
            reads = [s for s in reading if len(pending[peer[s]]) < 1024 * 1024]
            writes = [s for s in pending if pending[s]]
            ready_r, ready_w, _ = select.select(reads, writes, [], 120)
            if not ready_r and not ready_w:
                break
            for s in ready_r:
                block = s.recv(65536)
                if block:
                    pending[peer[s]].extend(block)
                else:
                    reading.remove(s)
                    if not pending[peer[s]]:
                        try:
                            peer[s].shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
            for s in ready_w:
                written = s.send(pending[s])
                del pending[s][:written]
                if not pending[s] and peer[s] not in reading:
                    try:
                        s.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
    finally:
        upstream.close()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        established = False
        try:
            self.request.settimeout(20)
            data = bytearray()
            while b'\r\n\r\n' not in data:
                block = self.request.recv(4096)
                if not block:
                    return
                data.extend(block)
                if len(data) > MAX_HEADER:
                    raise ValueError('Request headers too large')
            header, body = bytes(data).split(b'\r\n\r\n', 1)
            lines = header.split(b'\r\n')
            method, target, version = lines[0].decode('ascii').split(' ', 2)
            if method == 'CONNECT':
                parsed = urlsplit('//' + target)
                host, port = parsed.hostname, parsed.port or 443
            else:
                parsed = urlsplit(target)
                if parsed.scheme != 'http':
                    raise ValueError('Use CONNECT for HTTPS')
                host, port = parsed.hostname, parsed.port or 80
            if not host or not 1 <= port <= 65535:
                raise ValueError('Invalid destination')
            # Atomic writes by the app ensure a complete configuration per request.
            config = json.loads(self.server.config_path.read_text())
            use_office = config.get('enabled', False) and matches(host, config.get('domains', []))
            if use_office:
                upstream = connect_office(host, port, config.get('socksPort', 1080))
            else:
                upstream = socket.create_connection((host, port), timeout=15)
            if method == 'CONNECT':
                self.request.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
                established = True
                if body:
                    upstream.sendall(body)
            else:
                path = parsed.path or '/'
                if parsed.query:
                    path += '?' + parsed.query
                # One plain HTTP request per origin connection; CONNECT supports keep-alive.
                clean = [line for line in lines[1:] if line.split(b':', 1)[0].lower()
                         not in (b'proxy-connection', b'proxy-authorization', b'connection')]
                request = ('%s %s %s\r\n' % (method, path, version)).encode('ascii')
                upstream.sendall(request + b'\r\n'.join(clean) + b'\r\nConnection: close\r\n\r\n' + body)
                established = True
            relay(self.request, upstream)
            upstream = None
        except (OSError, ValueError, ConnectionError, KeyError) as error:
            if not established:
                message = b'Office Proxy could not connect. Check the app status, domain list and office PC.\n'
                try:
                    self.request.sendall(b'HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: '
                                         + str(len(message)).encode() + b'\r\n\r\n' + message)
                except OSError:
                    pass
        finally:
            if upstream is not None:
                upstream.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    config_path = Path(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18081
    with Server(('127.0.0.1', port), Handler) as server:
        server.config_path = config_path
        print('READY 127.0.0.1:%s' % port, flush=True)
        server.serve_forever()
