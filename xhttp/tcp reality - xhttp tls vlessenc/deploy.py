import contextlib,copy,hashlib,html,json,os,pathlib,re,secrets,shutil,socket,sqlite3,subprocess,sys,time,uuid
from urllib.parse import quote,urlencode

P=pathlib.Path
def log(message): print('[cloud] '+message,flush=True)
def run(args,check=True,**kw):
    result=subprocess.run(args,capture_output=True,text=True,**kw)
    if check and result.returncode:
        raise RuntimeError('Command failed: '+str(args[0])+' '+str(args[1])+'; '+result.stderr[-300:])
    return result
def write(path,data,mode=0o600):
    path=P(path);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(data,encoding='utf-8');path.chmod(mode)
def compact(value): return json.dumps(value,separators=(',',':'),ensure_ascii=False)
def dump(path,value): write(path,json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def port_open(port):
    with socket.socket() as sock:
        sock.settimeout(.3);return sock.connect_ex(('127.0.0.1',port))==0
def free_port(excluded):
    for _ in range(200):
        port=secrets.randbelow(30000)+22000
        if port not in excluded and not port_open(port): excluded.add(port);return port
    raise RuntimeError('No free local port')
def wait_for_port(port,timeout=25):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if port_open(port):return
        time.sleep(.3)
    raise RuntimeError('Listener did not start: '+str(port))
def mask_nginx(text):
    result=list(text);comment=False;string=None;escape=False
    for i,c in enumerate(text):
        if comment:
            if c=='\n':comment=False
            else:result[i]=' '
        elif string:
            result[i]=' '
            if escape:escape=False
            elif c=='\\':escape=True
            elif c==string:string=None
        elif c in ('"',"'"):string=c;result[i]=' '
        elif c=='#':comment=True;result[i]=' '
    return ''.join(result)
def blocks(text):
    masked=mask_nginx(text);stack=[];start=0;found=[]
    for i,c in enumerate(masked):
        if c=='{':
            head=masked[start:i].strip();kind=head.split()[0] if head else ''
            stack.append((kind,i,tuple(x[0] for x in stack)));start=i+1
        elif c=='}':
            if not stack:raise RuntimeError('Unbalanced Nginx configuration')
            kind,begin,parents=stack.pop();found.append((kind,begin,i,parents));start=i+1
        elif c==';':start=i+1
    if stack:raise RuntimeError('Unbalanced Nginx configuration')
    return found

# Match canwer0/guides_x-ui/xhttp/stream-one-tls-reality. The patched
# panel edits server fields directly; client imports use the extra object.
EXTRA={'mode':'stream-one','xPaddingBytes':'128-1120','xPaddingObfsMode':True,'xPaddingKey':'X-Amz-Meta-Trace','xPaddingHeader':'X-Amz-Security-Token','xPaddingPlacement':'header','xPaddingMethod':'tokenish','sessionIDPlacement':'header','sessionIDKey':'x-amz-cf-id','sessionIDTable':'Base62','sessionIDLength':'16-32','seqPlacement':'header','seqKey':'x-amz-cf-pop','uplinkHTTPMethod':'POST'}
VLESS_AUTH='ML-KEM-768, Post-Quantum'
INBOUND_NAMES={'xhttp':'xhttp stream-one Vlessenc','reality':'tcp reality'}

def generate_vlessenc(xray):
    raw=run([str(xray),'vlessenc']).stdout
    profiles=[];profile=None
    for line in raw.splitlines():
        match=re.search(r'Authentication:\s*(.+)',line)
        if match:
            profile={'label':match[1].strip()};profiles.append(profile)
        elif profile is not None:
            match=re.search(r'"(decryption|encryption)"\s*:\s*"([^"]+)"',line)
            if match:profile[match[1]]=match[2]
    pair=next((p for p in profiles if p['label']==VLESS_AUTH),None)
    if not pair or any(not pair.get(k,'').startswith('mlkem768x25519plus.native.') for k in ('decryption','encryption')):
        raise RuntimeError('Xray must support xray vlessenc with ML-KEM-768 authentication')
    return {k:pair[k] for k in ('decryption','encryption')}

def make_inbounds(domain,name,xport,rport,tlsport,xuid,ruid,private,public,sid,path,key,pairs):
    client=lambda uid,flow,email:{'id':uid,'flow':flow,'email':email,'enable':True,'limitIp':0,'totalGB':0,'expiryTime':0,'subId':secrets.token_hex(8),'reset':0,'created_at':int(time.time()*1000),'updated_at':int(time.time()*1000)}
    common={'user_id':0,'up':0,'down':0,'total':0,'all_time':0,'enable':1,'expiry_time':0,'traffic_reset':'never','last_traffic_reset_time':0,'listen':'127.0.0.1','protocol':'vless','sniffing':compact({'enabled':True,'destOverride':['http','tls'],'routeOnly':True})}
    xsettings={'clients':[client(xuid,'','cloud-xhttp-'+key)],**pairs['xhttp'],'selectedAuth':VLESS_AUTH}
    rsettings={'clients':[client(ruid,'xtls-rprx-vision','cloud-reality-'+key)],**pairs['reality'],'selectedAuth':VLESS_AUTH,'testseed':[900,500,900,256]}
    xstream={'network':'xhttp','security':'none','xhttpSettings':{'host':domain,'path':path,**EXTRA},'externalProxy':[{'forceTls':'tls','dest':domain,'port':443,'remark':'bot:'+compact({'path':path,'host':domain})}]}
    rstream={'network':'tcp','security':'reality','realitySettings':{'show':False,'target':'127.0.0.1:'+str(tlsport),'xver':0,'serverNames':[domain],'privateKey':private,'shortIds':[sid],'settings':{'publicKey':public,'fingerprint':'firefox','serverName':domain,'spiderX':'/'}},'externalProxy':[{'forceTls':'same','dest':domain,'port':443,'remark':INBOUND_NAMES['reality']}]}
    x={**common,'port':xport,'remark':INBOUND_NAMES['xhttp'],'settings':compact(xsettings),'stream_settings':compact(xstream),'tag':'inbound-127.0.0.1:'+str(xport)}
    r={**common,'port':rport,'remark':INBOUND_NAMES['reality'],'settings':compact(rsettings),'stream_settings':compact(rstream),'tag':'inbound-127.0.0.1:'+str(rport)}
    return x,r
def core_inbound(row):
    stream=json.loads(row['stream_settings']);stream.pop('externalProxy',None)
    if stream.get('realitySettings'):stream['realitySettings'].pop('settings',None)
    settings=json.loads(row['settings'])
    settings['clients']=[{k:v for k,v in c.items() if k in ('id','email','flow')} for c in settings['clients']]
    return {'listen':row['listen'],'port':row['port'],'protocol':row['protocol'],'tag':row['tag'],'settings':settings,'streamSettings':stream,'sniffing':json.loads(row['sniffing'])}
def client_config(kind,domain,address,edge,socks_port,xuid,ruid,public,sid,path,encryption):
    stream={'network':'tcp','security':'reality','realitySettings':{'fingerprint':'firefox','serverName':domain,'password':public,'shortId':sid,'spiderX':'/'}} if kind=='reality' else {'network':'xhttp','security':'tls','tlsSettings':{'serverName':domain,'alpn':['h2'],'fingerprint':'chrome','allowInsecure':False},'xhttpSettings':{'host':domain,'path':path,'mode':'stream-one','extra':EXTRA}}
    user={'id':ruid if kind=='reality' else xuid,'encryption':encryption,'flow':'xtls-rprx-vision' if kind=='reality' else ''}
    if kind=='reality':user['testseed']=[900,500,900,256]
    return {'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':socks_port,'protocol':'socks','settings':{'auth':'noauth','udp':False}}],'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':address,'port':edge,'users':[user]}]},'streamSettings':stream}]}

class Deployment:
    def __init__(self,options,work):
        self.options=options;self.work=P(work);self.domain=options['domain'];self.name=options['siteName']
        self.key=hashlib.sha256(self.domain.encode()).hexdigest()[:12]
        self.result=P('/root/obsidian-cloud-'+self.key);self.state=self.result/'deployment.json'
        self.backup=P('/root/obsidian-cloud-backups')/(time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+secrets.token_hex(4))
        self.backup.mkdir(parents=True,mode=0o700);self.backup.parent.chmod(0o700)
        self.files={};self.db=P(os.environ.get('XUI_DB_PATH','/etc/x-ui/x-ui.db'))
        self.xui=P(os.environ.get('XUI_MAIN_FOLDER','/usr/local/x-ui'))
        self.runtime=self.xui/'bin/config.json'
        self.xray=next((p for p in (self.xui/'bin').glob('xray-linux-*') if p.is_file() and os.access(p,os.X_OK)),None)
        if not self.xray or not self.db.exists():raise RuntimeError('Install 3X-UI/Xray before running this script')
        self.db_saved=False;self.stopped=False;self.committed=False
        self.http=P('/etc/nginx/conf.d/obsidian-cloud-'+self.key+'.conf')
        self.stream=P('/etc/nginx/obsidian-cloud-stream/'+self.key+'.conf')
        self.web=P('/var/www/obsidian-cloud-'+self.key+'-'+secrets.token_hex(4))
        self.oldfiles=set();self.ids={};self.excluded=set()
    def save(self,path):
        path=P(path)
        if str(path) in self.files:return
        entry={'exists':path.exists(),'mode':0o600}
        if path.exists():
            entry['mode']=path.stat().st_mode&0o777;entry['snapshot']=str(len(self.files))+'.original'
            shutil.copyfile(path,self.backup/entry['snapshot']);(self.backup/entry['snapshot']).chmod(0o600)
        self.files[str(path)]=entry;dump(self.backup/'files.json',self.files)
    def preflight(self):
        if run(['systemctl','is-active','x-ui'],check=False).returncode:raise RuntimeError('3X-UI must be running')
        run(['nginx','-t'])
        self.loaded={}
        data=run(['nginx','-T']).stdout
        for path in re.findall(r'^# configuration file (.+):\s*$',data,re.M):
            resolved=P(path).resolve()
            if resolved.is_file():self.loaded[str(resolved)]=resolved.read_text()
        if self.state.exists():
            old=json.loads(self.state.read_text())
            if old.get('domain')!=self.domain:raise RuntimeError('Deployment state domain mismatch')
            self.ids={k:old[k]['id'] for k in ('xhttp','reality')}
            self.oldfiles.update([self.http,self.stream])
        else:
            candidates=[]
            for p in P('/root').glob('luma-notes-*/deployment.json'):
                with contextlib.suppress(OSError,ValueError,KeyError):
                    value=json.loads(p.read_text())
                    if value['domain']==self.domain:candidates.append((p,value))
            if len(candidates)>1:raise RuntimeError('Multiple older deployments; select the active one before installing')
            if candidates:
                p,old=candidates[0];suffix=p.parent.name.removeprefix('luma-notes-')
                if not re.fullmatch('[a-f0-9]{12}',suffix):raise RuntimeError('Unexpected older deployment path')
                self.ids={k:old[k]['id'] for k in ('xhttp','reality')}
                self.oldfiles.update([P('/etc/nginx/conf.d/luma-notes-'+suffix+'.conf'),P('/etc/nginx/luma-stream/'+suffix+'.conf')])
        conn=sqlite3.connect(self.db);conn.row_factory=sqlite3.Row
        self.oldrows={}
        self.users=conn.execute('select id from users order by id limit 1').fetchone()
        if not self.users:raise RuntimeError('No panel user found')
        for kind,ident in self.ids.items():
            row=conn.execute('select * from inbounds where id=?',(ident,)).fetchone()
            if not row:raise RuntimeError('Managed inbound ID is missing: '+str(ident))
            row=dict(row);stream=json.loads(row['stream_settings'])
            expected=stream.get('security')=='reality' if kind=='reality' else stream.get('network')=='xhttp'
            if not expected or self.domain not in row['remark']:raise RuntimeError('Managed inbound differs from stored deployment')
            self.oldrows[kind]=row
        self.excluded.update(r[0] for r in conn.execute('select port from inbounds'));conn.close()
        owned={str(p.resolve()) for p in self.oldfiles}|{str(self.http),str(self.stream)}
        for path,text in self.loaded.items():
            if path in owned:continue
            clean=mask_nginx(text)
            if re.search(r'(?m)^\s*listen\s+[^;]*\b443\b',clean):raise RuntimeError('Another Nginx config owns 443: '+path)
            if re.search(r'(?m)^\s*server_name\s+[^;]*\b'+re.escape(self.domain)+r'(?=[;\s])',clean):raise RuntimeError('Domain already belongs to another Nginx config: '+path)
        listener=run(['ss','-H','-ltnp','sport = :443']).stdout
        if listener and 'nginx' not in listener:
            allowed=any(row['port']==443 for row in self.oldrows.values())
            if not allowed or 'xray' not in listener:raise RuntimeError('Another service owns TCP 443')
        streams=[(P(path),begin,end) for path,text in self.loaded.items() for kind,begin,end,parents in blocks(text) if kind=='stream' and not parents]
        if len(streams)>1:raise RuntimeError('Multiple Nginx stream blocks')
        if streams:self.stream_owner,self.stream_begin,self.stream_end=streams[0]
        else:self.stream_owner=P('/etc/nginx/nginx.conf');self.stream_begin=self.stream_end=None
        for p in {*self.oldfiles,self.http,self.stream,self.stream_owner,self.state,self.result/'vless-tcp-reality.txt',self.result/'vless-xhttp-tls.txt',self.result/'client-reality.json',self.result/'client-xhttp.json'}:self.save(p)
        self.tlsport=free_port(self.excluded);self.xport=free_port(self.excluded);self.rport=free_port(self.excluded)
        self.cert=P('/etc/letsencrypt/live')/self.domain/'fullchain.pem';self.certkey=self.cert.with_name('privkey.pem')
    def apply_nginx(self):
        run(['nginx','-t'])
        if run(['systemctl','is-active','nginx'],check=False).returncode:run(['systemctl','start','nginx'])
        else:run(['systemctl','reload','nginx'])
    def provision_certificate(self):
        self.web.mkdir(parents=True,mode=0o755);self.web.chmod(0o755)
        acme=self.web/'.well-known/acme-challenge';acme.mkdir(parents=True,mode=0o755);acme.parent.chmod(0o755);acme.chmod(0o755)
        page=(self.work/'site.html').read_text().replace('__SITE_NAME__',html.escape(self.name,quote=True))
        write(self.web/'index.html',page,0o644)
        write(self.web/'robots.txt','User-agent: *\nDisallow: /account\n',0o644)
        if not (self.cert.exists() and self.certkey.exists()):
            if not self.options.get('certEmail'):raise RuntimeError('Certificate email is required')
            for p in self.oldfiles:
                if p.exists():p.unlink()
            write(self.http,f'server {{ listen 80; server_name {self.domain}; root {self.web}; location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }} location / {{ return 404; }} }}\n',0o644)
            self.apply_nginx()
            run(['certbot','certonly','--webroot','-w',str(self.web),'--non-interactive','--agree-tos','-m',self.options['certEmail'],'-d',self.domain])
        run(['openssl','x509','-in',str(self.cert),'-noout','-checkhost',self.domain])
        run(['openssl','x509','-in',str(self.cert),'-noout','-checkend','0'])
        # Keep the renewal webroot stable across subsequent installations.
        for path in self.cert.parent.parent.parent.joinpath('renewal').glob(self.domain+'.conf'):
            self.save(path);text=path.read_text()
            text=re.sub(r'(?m)^(webroot_path\s*=\s*).+$',lambda m:m.group(1)+str(self.web)+',',text)
            text=re.sub(r'(?m)^('+re.escape(self.domain)+r'\s*=\s*).+$',lambda m:m.group(1)+str(self.web),text)
            write(path,text,0o600)
    def prepare(self):
        log('Generating independent ML-KEM-768 VLESS Encryption keys for both inbounds')
        self.encpairs={kind:generate_vlessenc(self.xray) for kind in ('xhttp','reality')}
        pair=run([str(self.xray),'x25519']).stdout
        keys={}
        for line in pair.splitlines():
            match=re.match(r'\s*(Private\s*Key|Public\s*Key|Password(?:\s*\(Public\s*Key\))?)\s*:\s*(\S+)',line,re.I)
            if match:keys['private' if re.sub(r'\s+','',match[1]).lower()=='privatekey' else 'public']=match[2]
        if 'private' not in keys or 'public' not in keys:raise RuntimeError('Cannot parse Xray x25519 output')
        self.private=keys['private'];self.public=keys['public'];self.sid=secrets.token_hex(8)
        self.xuid=str(uuid.uuid4());self.ruid=str(uuid.uuid4());self.path='/sync/'+secrets.token_hex(18)+'/'
        self.rows=dict(zip(('xhttp','reality'),make_inbounds(self.domain,self.name,self.xport,self.rport,self.tlsport,self.xuid,self.ruid,self.private,self.public,self.sid,self.path,self.key,self.encpairs)))
        test={'log':{'loglevel':'warning'},'inbounds':[core_inbound(row) for row in self.rows.values()],'outbounds':[{'protocol':'freedom','tag':'direct'}]}
        dump(self.work/'server-test.json',test);run([str(self.xray),'run','-test','-config',str(self.work/'server-test.json')])
    def configure_database(self):
        log('Backing up 3X-UI and configuring two loopback inbounds')
        run(['systemctl','stop','x-ui']);self.stopped=True
        connection=sqlite3.connect(self.db)
        with sqlite3.connect(self.backup/'x-ui.db') as backup:connection.backup(backup)
        (self.backup/'x-ui.db').chmod(0o600);self.db_saved=True
        try:
            with connection:
                for kind,row in self.rows.items():
                    row['user_id']=self.users[0]
                    if kind in self.ids:
                        ident=self.ids[kind]
                        connection.execute('update inbounds set '+','.join(k+'=?' for k in row)+' where id=?',[*row.values(),ident])
                        connection.execute('delete from client_traffics where inbound_id=?',(ident,))
                    else:
                        cursor=connection.execute('insert into inbounds ('+','.join(row)+') values ('+','.join('?' for _ in row)+')',list(row.values()));ident=cursor.lastrowid;self.ids[kind]=ident
                    email=json.loads(row['settings'])['clients'][0]['email']
                    connection.execute('insert into client_traffics (inbound_id,enable,email,up,down,all_time,expiry_time,total,reset,last_online) values (?,1,?,0,0,0,0,0,0,0)',(ident,email))
        finally:connection.close()
    def configure_nginx(self):
        log('Configuring Nginx TCP 443, local HTTPS and XHTTP gRPC route')
        for path in self.oldfiles:
            if path.exists():path.unlink()
        self.http.parent.mkdir(parents=True,exist_ok=True);self.stream.parent.mkdir(parents=True,exist_ok=True)
        version=run(['nginx','-v'],check=False).stderr;match=re.search(r'nginx/(\d+)\.(\d+)\.(\d+)',version)
        modern=match and tuple(map(int,match.groups()))>=(1,25,1)
        listen=f'listen 127.0.0.1:{self.tlsport} ssl'+(';' if modern else ' http2;')
        http2='http2 on;' if modern else ''
        ipv6='listen [::]:80;' if P('/proc/net/if_inet6').exists() else ''
        config=f'''server {{
    listen 80; {ipv6}
    server_name {self.domain};
    root {self.web};
    location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }}
    location / {{ return 301 https://{self.domain}$request_uri; }}
}}
server {{
    {listen}
    {http2}
    server_name {self.domain};
    root {self.web}; index index.html;
    ssl_certificate {self.cert};
    ssl_certificate_key {self.certkey};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    location ^~ {self.path} {{
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_connect_timeout 10s;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For "";
        grpc_set_header X-Forwarded-Proto https;
        grpc_pass grpc://127.0.0.1:{self.xport};
        access_log off;
    }}
    location ^~ /.well-known/acme-challenge/ {{ try_files $uri =404; }}
    location / {{ try_files $uri $uri/ =404; }}
}}
'''
        write(self.http,config,0o644)
        edge_v6='listen [::]:443 ipv6only=on;' if P('/proc/net/if_inet6').exists() else ''
        write(self.stream,f'''server {{
    listen 443; {edge_v6}
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
    proxy_socket_keepalive on;
    proxy_half_close on;
    proxy_pass 127.0.0.1:{self.rport};
}}
''',0o644)
        include='include '+str(self.stream)+';'
        text=self.stream_owner.read_text()
        if include not in text:
            if self.stream_end is None:text+='\n# Obsidian cloud TCP frontend\nstream { '+include+' }\n'
            else:text=text[:self.stream_end]+'\n    '+include+'\n'+text[self.stream_end:]
            write(self.stream_owner,text,0o644)
        self.apply_nginx()
        run(['systemctl','start','x-ui']);self.stopped=False
        wait_for_port(self.xport);wait_for_port(self.rport);wait_for_port(443)
        run([str(self.xray),'run','-test','-config',str(self.runtime)])
        current=json.loads(self.runtime.read_text())
        for kind,row in self.rows.items():
            found=[i for i in current.get('inbounds',[]) if i.get('tag')==row['tag']]
            if len(found)!=1 or not found[0].get('settings',{}).get('clients'):raise RuntimeError('Panel generated an inbound without an enabled client: '+kind)
    def verify(self):
        log('Testing HTTPS and real data transfer through both client profiles on 443')
        site=self.work/'https.html'
        run(['curl','--noproxy','*','-fsS','--max-time','20','--resolve',self.domain+':443:127.0.0.1','-o',str(site),'https://'+self.domain+'/'])
        if 'data-cloud-site="v2"' not in site.read_text():raise RuntimeError('Public HTTPS site is unexpected')
        probe='test-'+secrets.token_hex(12);data=secrets.token_hex(65536).encode()
        target=self.web/'.well-known/acme-challenge'/probe;target.write_bytes(data);target.chmod(0o644)
        self.results={}
        try:
            for kind in ('reality','xhttp'):
                port=free_port(self.excluded)
                client=client_config(kind,self.domain,'127.0.0.1',443,port,self.xuid,self.ruid,self.public,self.sid,self.path,self.encpairs[kind]['encryption'])
                cfg=self.work/('test-'+kind+'.json');dump(cfg,client)
                logfile=self.work/('test-'+kind+'.log')
                with logfile.open('w') as out:
                    process=subprocess.Popen([str(self.xray),'run','-config',str(cfg)],stdout=out,stderr=out,cwd=self.xui/'bin')
                    try:
                        wait_for_port(port,10)
                        result=run(['curl','--noproxy','','--socks5-hostname','127.0.0.1:'+str(port),'-fsS','--connect-timeout','15','--max-time','45','-o',str(self.work/('result-'+kind)), 'https://'+self.domain+'/.well-known/acme-challenge/'+probe],check=False)
                        if result.returncode or (self.work/('result-'+kind)).read_bytes()!=data:
                            shutil.copyfile(logfile,self.backup/('failed-'+kind+'.log'))
                            raise RuntimeError(kind+' failed actual transfer test: '+result.stderr[-200:]+'; diagnostics: '+str(self.backup))
                        self.results[kind]={'bytes':len(data),'passed':True};log(kind+' OK: '+str(len(data))+' bytes through public TCP 443')
                    finally:
                        process.terminate()
                        try:process.wait(timeout=5)
                        except subprocess.TimeoutExpired:process.kill();process.wait()
        finally:target.unlink(missing_ok=True)
    def write_profiles(self):
        self.result.mkdir(parents=True,exist_ok=True,mode=0o700);self.result.chmod(0o700)
        query={'type':'xhttp','encryption':self.encpairs['xhttp']['encryption'],'security':'tls','sni':self.domain,'host':self.domain,'path':self.path,'mode':'stream-one','alpn':'h2','fp':'chrome','extra':compact(EXTRA)}
        reality={'type':'tcp','encryption':self.encpairs['reality']['encryption'],'security':'reality','sni':self.domain,'fp':'firefox','pbk':self.public,'sid':self.sid,'spx':'/','flow':'xtls-rprx-vision'}
        for kind,uid,q in [('xhttp',self.xuid,query),('reality',self.ruid,reality)]:
            filename='vless-xhttp-tls.txt' if kind=='xhttp' else 'vless-tcp-reality.txt'
            link=f'vless://{uid}@{self.domain}:443?'+urlencode(q,quote_via=quote)+'#'+quote(INBOUND_NAMES[kind])+'\n'
            write(self.result/filename,link)
            dump(self.result/('client-'+kind+'.json'),client_config(kind,self.domain,self.domain,443,10808,self.xuid,self.ruid,self.public,self.sid,self.path,self.encpairs[kind]['encryption']))
    def finish(self):
        self.write_profiles()
        state={'schema':2,'domain':self.domain,'siteName':self.name,'webroot':str(self.web),'nginxHttpConfig':str(self.http),'nginxStreamConfig':str(self.stream),'nginxTlsListen':'127.0.0.1:'+str(self.tlsport),'xhttp':{'id':self.ids['xhttp'],'listen':'127.0.0.1','internalPort':self.xport,'publicPort':443,'path':self.path,'mode':'stream-one'},'reality':{'id':self.ids['reality'],'listen':'127.0.0.1','internalPort':self.rport,'publicPort':443,'serverName':self.domain,'target':'127.0.0.1:'+str(self.tlsport)},'tests':self.results,'backup':str(self.backup)}
        state['authentication']=VLESS_AUTH;state['reality']['fingerprint']='firefox'
        dump(self.state,state);self.committed=True
        log('Installed https://'+self.domain+'/');log('Client links and full Xray client JSON: '+str(self.result));log('Backup: '+str(self.backup))
    def rollback(self):
        log('Installation failed; restoring previous Nginx and 3X-UI configuration')
        errors=[]
        if self.db_saved:
            run(['systemctl','stop','x-ui'],check=False)
            try:
                with sqlite3.connect(self.backup/'x-ui.db') as src,sqlite3.connect(self.db) as dest:src.backup(dest)
            except Exception as error:errors.append(str(error))
        for path,entry in self.files.items():
            try:
                if entry['exists']:
                    shutil.copyfile(self.backup/entry['snapshot'],path);P(path).chmod(entry['mode'])
                else:P(path).unlink(missing_ok=True)
            except Exception as error:errors.append(str(error))
        try:self.apply_nginx()
        except Exception as error:errors.append(str(error))
        if self.db_saved or self.stopped:
            if run(['systemctl','start','x-ui'],check=False).returncode:errors.append('Could not restart x-ui')
        if errors:log('Rollback needs attention: '+'; '.join(errors))
        else:log('Previous configuration restored')
        log('Backup: '+str(self.backup))

def main():
    options=json.loads(P(sys.argv[1]).read_text());work=P(sys.argv[2])
    if os.geteuid()!=0:raise SystemExit('Run as root')
    if not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',options['domain']):raise SystemExit('Invalid domain')
    if not 2<=len(options['siteName'])<=64 or any(ord(c)<32 for c in options['siteName']):raise SystemExit('Site name must be 2–64 characters')
    deploy=Deployment(options,work)
    try:
        deploy.preflight();deploy.provision_certificate();deploy.prepare();deploy.configure_database();deploy.configure_nginx();deploy.verify();deploy.finish()
    except BaseException as error:
        if not deploy.committed:deploy.rollback()
        raise SystemExit('ERROR: '+str(error)) from None
if __name__=='__main__':main()
