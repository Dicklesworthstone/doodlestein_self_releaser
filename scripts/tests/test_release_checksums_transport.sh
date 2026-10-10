#!/usr/bin/env bash
# Real curl, TLS verification, cross-origin redirects and streamed byte limits.
# An explicitly trusted local HTTPS proxy serves owned release fixtures only;
# this is transport integration, not contact with public or private GitHub assets.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for tool in python3 bash jq curl openssl; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlparse

root=Path(sys.argv[1])
work=Path(tempfile.mkdtemp(prefix='dsr-checksum-transport-'))
print('Retained evidence: '+str(work),flush=True)
passed=0
trace=[]
errors=[]
mode='valid'
token='owned_tls_test_token'
cert,key=work/'certificate.pem',work/'fixture-key.pem'
with (work/'openssl.log').open('wb') as log:
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
        '-keyout',str(key),'-out',str(cert),'-subj','/CN=api.github.com',
        '-addext','subjectAltName=DNS:api.github.com,DNS:release-assets.example.invalid'],check=True,stdout=log,stderr=log)
key.chmod(0o600)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert,key)
payloads={i:('Real TLS payload %d\n'%i).encode() for i in range(1,6)}
assets=[dict(id=i,name='payload-%d.tar.gz'%i,size=len(data),state='uploaded',
             digest='sha256:'+hashlib.sha256(data).hexdigest()) for i,data in payloads.items()]
payloads[6]=''.join(a['digest'][7:]+'  '+a['name']+'\n' for a in assets).encode()
assets.append(dict(id=6,name='SHA256SUMS',size=len(payloads[6]),state='uploaded',
                   digest='sha256:'+hashlib.sha256(payloads[6]).hexdigest()))
release=dict(id=321,tag_name='v1.2.3',draft=False,prerelease=False,target_commitish='main')

def check(label,condition):
    global passed
    if not condition:raise AssertionError(label)
    passed+=1; print('PASS: '+label,flush=True)

def headers(stream):
    value=b''
    while not value.endswith(b'\r\n\r\n'):
        block=stream.recv(1)
        if not block:raise EOFError()
        value+=block
        if len(value)>65536:raise ValueError('oversized test request')
    lines=value.decode('iso-8859-1').split('\r\n')
    return lines[0].split(),dict(line.split(': ',1) for line in lines[1:] if line)

def respond(stream,status,body=b'',extra=None,chunked=False):
    fields={'Connection':'close',**(extra or {})}
    if chunked:fields['Transfer-Encoding']='chunked'
    else:fields['Content-Length']=str(len(body))
    stream.sendall(('HTTP/1.1 '+status+'\r\n'+''.join(k+': '+v+'\r\n' for k,v in fields.items())+'\r\n').encode())
    if chunked:
        for offset in range(0,len(body),256):
            chunk=body[offset:offset+256]
            stream.sendall(('%x\r\n'%len(chunk)).encode()+chunk+b'\r\n')
        stream.sendall(b'0\r\n\r\n')
    else:stream.sendall(body)

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(5)
            first,_=headers(self.request)
            assert first[0]=='CONNECT' and first[1] in ('api.github.com:443','release-assets.example.invalid:443')
            host=first[1].split(':')[0]
            self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            with context.wrap_socket(self.request,server_side=True) as secure:
                request,fields=headers(secure)
                assert request[0]=='GET'
                auth=next((v for k,v in fields.items() if k.lower()=='authorization'),None)
                trace.append(dict(host=host,path=request[1],has_authorization=auth is not None))
                if host=='api.github.com':
                    assert auth=='Bearer '+token
                    if '/releases/tags/' in request[1]:
                        respond(secure,'200 OK',json.dumps(release).encode())
                    elif '/releases/321/assets?' in request[1]:
                        respond(secure,'200 OK',json.dumps(assets).encode())
                    else:
                        assert '/releases/assets/' in request[1]
                        identity=int(request[1].rsplit('/',1)[1])
                        scheme='http' if mode=='insecure-redirect' else 'https'
                        respond(secure,'302 Found',extra={'Location':scheme+'://release-assets.example.invalid/asset/'+str(identity)})
                else:
                    assert auth is None, 'authorization leaked across origins'
                    identity=int(urlparse(request[1]).path.rsplit('/',1)[1])
                    if mode=='redirect-loop':
                        respond(secure,'302 Found',extra={'Location':'https://release-assets.example.invalid/asset/'+str(identity)})
                    elif mode=='http-error':respond(secure,'403 Forbidden',b'refused')
                    elif mode=='slow' and identity==1:
                        time.sleep(3); respond(secure,'200 OK',payloads[identity])
                    elif mode=='chunked-overflow' and identity==1:
                        respond(secure,'200 OK',b'X'*65536,chunked=True)
                    else:respond(secure,'200 OK',payloads[identity],chunked=(mode=='chunked'))
        except (BrokenPipeError,ConnectionResetError,EOFError,ssl.SSLError,socket.timeout):
            # Refused certificates, byte limits and timeouts intentionally
            # terminate a connection; these are not successful download claims.
            pass
        except Exception as error:
            errors.append(str(error))

class Server(socketserver.ThreadingTCPServer):
    daemon_threads=True
    allow_reuse_address=True

server=Server(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
proxy='http://127.0.0.1:%d'%server.server_address[1]
env=dict(os.environ,GH_TOKEN=token,GITHUB_TOKEN='',CURL_CA_BUNDLE=str(cert),
         HTTPS_PROXY=proxy,https_proxy=proxy,HTTP_PROXY=proxy,http_proxy=proxy,
         ALL_PROXY='',all_proxy='',NO_PROXY='',no_proxy='')
try:
    for selected,expected in (('valid',0),('chunked',0),('chunked-overflow',8),('http-error',8),
                              ('insecure-redirect',8),('redirect-loop',8),('slow',8),('untrusted-certificate',8)):
        mode=selected; trace.clear(); errors.clear()
        output=work/selected
        selected_env=dict(env)
        if selected=='untrusted-certificate':
            for k in ('CURL_CA_BUNDLE','SSL_CERT_FILE','SSL_CERT_DIR'):selected_env.pop(k,None)
        start=time.monotonic()
        proc=subprocess.run(['bash',str(root/'src/release_checksums.sh'),'--repo','owner/app','--tag','v1.2.3',
                             '--output-dir',str(output),'--timeout','1' if selected=='slow' else '5'],
                            env=selected_env,capture_output=True,timeout=30)
        elapsed=time.monotonic()-start
        (work/(selected+'.stdout')).write_bytes(proc.stdout)
        (work/(selected+'.stderr')).write_bytes(proc.stderr)
        (work/(selected+'.trace.json')).write_text(json.dumps(trace,indent=2)+'\n')
        result=json.loads(proc.stdout)
        check(selected+': actual curl exit becomes a truthful audit result',proc.returncode==expected and result['exit_code']==expected)
        check(selected+': no transport assertion was violated',not errors)
        check(selected+': authorization never reaches the redirect origin',all(not r['has_authorization'] for r in trace if r['host']!='api.github.com'))
        if expected==0:
            check(selected+': every redirected payload was actually hashed',result['verified_count']==5 and result['eligible_count']==5 and result['status']=='verified')
            check(selected+': exported checksums match the real TLS payloads',(output/'checksums.normalized').read_bytes()==payloads[6])
        else:
            check(selected+': no incomplete transfer can export verified checksums',result['status']=='error' and 'normalized_manifest' not in result)
        if selected=='chunked-overflow':
            retained=output/'artifacts/payload-1.tar.gz'
            check('streamed overflow stays within its on-disk byte cap',not retained.exists() or retained.stat().st_size<=len(payloads[1]))
        if selected=='insecure-redirect':
            check('HTTP redirect is refused before reaching the alternate origin',not any(r['host']!='api.github.com' for r in trace))
        if selected=='redirect-loop':
            check('actual redirect requests obey the five-hop limit',sum(r['host']!='api.github.com' for r in trace)<=5)
        if selected=='slow':check('actual slow response respects the bounded transfer time',elapsed<5)
    print('Results: %d passed, 0 failed\nEvidence: %s'%(passed,work),flush=True)
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=5)
PY
