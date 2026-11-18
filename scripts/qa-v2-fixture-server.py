#!/usr/bin/env python3
"""Loopback server for an agent-created page only. Never receives user content."""
import http.server, json, pathlib
root=pathlib.Path(__file__).resolve().parent
state={}
command={'sequence':0,'action':''}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if self.path=='/command': data=json.dumps(command).encode(); kind='application/json'
        elif self.path=='/state': data=json.dumps(state).encode(); kind='application/json'
        else: data=(root/'qa-v2-fixture.html').read_bytes(); kind='text/html; charset=utf-8'
        self.send_response(200);self.send_header('Content-Type',kind);self.end_headers();self.wfile.write(data)
    def do_POST(self):
        global state,command
        body=json.loads(self.rfile.read(min(int(self.headers.get('Content-Length','0')),4096)))
        if self.path=='/state': state=body
        elif self.path=='/command': command={'sequence':command['sequence']+1,'action':body['action']}
        self.send_response(200);self.end_headers();self.wfile.write(b'{}')
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
