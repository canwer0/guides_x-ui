import hashlib,json,os,pathlib,sqlite3,sys,time
from deploy import Deployment,INBOUND_NAMES,VLESS_AUTH,EXTRA,compact,core_inbound,dump,generate_vlessenc,log,run,wait_for_port

def main():
    domain=sys.argv[1];work=pathlib.Path(sys.argv[2])
    if os.geteuid()!=0:raise SystemExit('Run as root')
    key=hashlib.sha256(domain.encode()).hexdigest()[:12]
    state=json.loads((pathlib.Path('/root/obsidian-cloud-'+key)/'deployment.json').read_text())
    if state.get('schema')!=2 or state.get('domain')!=domain:
        raise SystemExit('Expected an existing deployment made by this installer')
    d=Deployment({'domain':domain,'siteName':state['siteName']},work)
    try:
        run(['nginx','-t']);run(['systemctl','is-active','x-ui'])
        d.web=pathlib.Path(state['webroot']);d.path=state['xhttp']['path']
        d.xport=state['xhttp']['internalPort'];d.rport=state['reality']['internalPort']
        d.ids={kind:state[kind]['id'] for kind in ('xhttp','reality')}
        with sqlite3.connect(d.db) as db:
            db.row_factory=sqlite3.Row
            d.rows={kind:dict(db.execute('select * from inbounds where id=?',(ident,)).fetchone()) for kind,ident in d.ids.items()}
        d.encpairs={kind:generate_vlessenc(d.xray) for kind in ('xhttp','reality')}
        for kind,row in d.rows.items():
            if row['listen']!='127.0.0.1' or row['port']!=state[kind]['internalPort']:
                raise RuntimeError('Inbound listeners differ from deployment state')
            settings=json.loads(row['settings']);stream=json.loads(row['stream_settings'])
            if len(settings['clients'])!=1:raise RuntimeError('Expected one existing client per managed inbound')
            settings.update(d.encpairs[kind]);settings['selectedAuth']=VLESS_AUTH
            settings['clients'][0]['flow']='xtls-rprx-vision' if kind=='reality' else ''
            if kind=='reality':
                settings['testseed']=[900,500,900,256]
                rs=stream['realitySettings'];rs.setdefault('settings',{})['fingerprint']='firefox'
                d.public=rs['settings']['publicKey'];d.sid=rs['shortIds'][0]
                d.ruid=settings['clients'][0]['id']
                stream['externalProxy']=[{'forceTls':'same','dest':domain,'port':443,'remark':INBOUND_NAMES[kind]}]
            else:
                if stream.get('network')!='xhttp' or stream.get('security')!='none':
                    raise RuntimeError('Expected local XHTTP behind Nginx TLS')
                stream['xhttpSettings']={'path':d.path,'host':domain,**EXTRA}
                stream['externalProxy']=[{'forceTls':'tls','dest':domain,'port':443,'remark':'bot:'+compact({'path':d.path,'host':domain})}]
                d.xuid=settings['clients'][0]['id']
            row.update(remark=INBOUND_NAMES[kind],settings=compact(settings),stream_settings=compact(stream))
        test={'inbounds':[core_inbound(row) for row in d.rows.values()],'outbounds':[{'protocol':'freedom'}]}
        dump(work/'server-test.json',test);run([str(d.xray),'run','-test','-config',str(work/'server-test.json')])
        for path in [d.state,*[d.result/name for name in ('client-xhttp.json','client-reality.json','vless-xhttp-tls.txt','vless-tcp-reality.txt')]]:
            d.save(path)
        log('Enabling ML-KEM-768 on both inbounds, Firefox for REALITY and short names')
        run(['systemctl','stop','x-ui']);d.stopped=True
        with sqlite3.connect(d.db) as db:
            with sqlite3.connect(d.backup/'x-ui.db') as backup:db.backup(backup)
            (d.backup/'x-ui.db').chmod(0o600);d.db_saved=True
            with db:
                for kind,row in d.rows.items():
                    db.execute('update inbounds set remark=?,settings=?,stream_settings=? where id=?',
                        (row['remark'],row['settings'],row['stream_settings'],d.ids[kind]))
        run(['systemctl','start','x-ui']);d.stopped=False
        wait_for_port(d.xport);wait_for_port(d.rport)
        run([str(d.xray),'run','-test','-config',str(d.runtime)])
        runtime=json.loads(d.runtime.read_text())
        for kind,row in d.rows.items():
            actual=next(i for i in runtime['inbounds'] if i.get('tag')==row['tag'])
            if actual['settings'].get('decryption')!=d.encpairs[kind]['decryption']:
                raise RuntimeError('Panel generated different ML-KEM decryption settings')
        d.verify();d.write_profiles()
        state['tests']=d.results;state['authentication']=VLESS_AUTH
        state['reality']['fingerprint']='firefox'
        state['lastConfigUpdate']={'backup':str(d.backup),'completedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
        dump(d.state,state);d.committed=True
        log('Updated both inbounds; UUIDs, ports, site and XHTTP path preserved')
        log('Import the updated links from '+str(d.result))
        log('Backup: '+str(d.backup))
    except BaseException:
        if not d.committed:d.rollback()
        raise

if __name__=='__main__':main()
