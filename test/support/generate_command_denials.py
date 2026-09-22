#!/usr/bin/env python3
"""Regenerate public denial fixtures on a disposable isolated test kernel only."""
import subprocess, uuid, json, urllib.request, urllib.error, time, base64, pathlib
name='r5e-recurse-command-fixture-'+uuid.uuid4().hex[:12]
def run(args): return subprocess.check_output(args, text=True).strip()
def request(path, body=None):
    data=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(url+path, data=data, headers={'Content-Type':'application/json'})
    try: response=urllib.request.urlopen(req)
    except urllib.error.HTTPError as error: response=error
    return json.loads(response.read())
try:
    run(['docker','run','--detach','--rm','--name',name,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges:true','--tmpfs','/tmp:rw,nosuid,size=64m','--tmpfs','/data:rw,nosuid,noexec,size=256m,mode=0700','--publish','127.0.0.1::4545','--env','R5E_DATA_DIR=/data/r5e-recurse-test','--env','R5E_PORT=4545','r5e/kernel:recurse-a1-debian-352b0e0d'])
    port=run(['docker','port',name,'4545/tcp']).split(':')[-1]
    url='http://127.0.0.1:'+port
    for _ in range(100):
        try:
            events=request('/events')['events']; break
        except Exception: time.sleep(.1)
    origin=request('/cas/'+events[0]['payload'])['origin']
    target={'group':'recurse.r5e.io','version':'v1alpha1','kind':'Command','name':None}
    spec={'commandId':'fixture-original','operation':'submit_task','payloadDigest':'sha256:'+'1'*64,'target':'fixture-node'}
    def sign(origin_value, nonce, actor=None):
        encoded=base64.b64encode(json.dumps({'target':target,'spec':spec,'origin':origin_value,'nonce':nonce,'actor':actor}).encode()).decode()
        script='Application.put_env(:r5e, :data_dir, System.fetch_env!("R5E_DATA_DIR")); x = Jason.decode!(Base.decode64!("'+encoded+'")); opts = [origin: x["origin"], nonce: x["nonce"]]; opts = if x["actor"], do: Keyword.put(opts, :actor, x["actor"]), else: opts; IO.puts(Jason.encode!(R5e.Request.sign(%{target: x["target"], spec: x["spec"]}, [:node], opts)))'
        return json.loads(run(['docker','exec',name,'/app/bin/audit_console','eval',script]))
    def admit(envelope, body):
        receipt=request('/apis/recurse.r5e.io/v1alpha1/Command',{'envelope':envelope,'spec':body,'name':None})
        event=request('/events')['events'][-1]
        payload=request('/cas/'+event['payload'])
        assert receipt['eventRef']=='event:'+event['hash']
        return {'event':event,'payload':payload}
    nonce=base64.b64encode(bytes(range(16))).decode()
    envelope=sign(origin,nonce)
    original=admit(envelope,spec)
    poison={**spec,'commandId':'fixture-victim'}
    replay=admit(envelope,poison)
    mismatch=admit(sign(origin,base64.b64encode(bytes(range(1,17))).decode(),'key:ed25519:sha256:'+'2'*64),poison)
    wrong_origin=admit(sign('sha256:'+'3'*64,base64.b64encode(bytes(range(2,18))).decode()),spec)
    out={'source':{'kernel_image':'r5e/kernel:recurse-a1-debian-352b0e0d','kernel_revision':'352b0e0d79eba23b1883f83a2a654fc19d6699c2','scope':'Generated on a disposable isolated chain; public records only; no private key exported.'},'origin':origin,'original':original,'replay':replay,'actor_mismatch':mismatch,'wrong_origin':wrong_origin}
    destination = pathlib.Path(__file__).resolve().parents[1] / 'fixtures' / 'commands'
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'authentication-denials.json').write_text(json.dumps(out,indent=2)+'\n')
    print(json.dumps({k:out[k]['payload']['reason'] for k in ['original','replay','actor_mismatch','wrong_origin']},indent=2))
finally:
    subprocess.run(['docker','rm','--force',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
