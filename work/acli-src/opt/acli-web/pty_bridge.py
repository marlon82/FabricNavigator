#!/usr/bin/python3
import argparse,base64,fcntl,json,os,pty,re,selectors,signal,struct,sys,termios,time
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--cols',type=int,default=120)
parser.add_argument('--rows',type=int,default=34)
parser.add_argument('command',nargs=argparse.REMAINDER)
args=parser.parse_args()
if args.command and args.command[0]=='--': args.command=args.command[1:]
if not args.command: raise SystemExit('missing command')
args.cols=max(20,min(args.cols,400));args.rows=max(5,min(args.rows,200))
session_started=time.time()
acli_config=Path('/opt/fabricnavigator/data/acli.ini')
acli_log_root=Path('/opt/fabricnavigator/data/acli-logs')

def acli_auto_log_enabled():
    try:
        for raw in acli_config.read_text(encoding='utf-8',errors='replace').splitlines():
            line=raw.strip()
            if not line or line.startswith('#'): continue
            parts=line.split(None,1)
            if len(parts)==2 and parts[0]=='auto_log_to_file_flg': return parts[1].strip().strip("'")=='1'
    except OSError: pass
    return False

def finalize_acli_logs():
    if not acli_auto_log_enabled() or not acli_log_root.is_dir(): return
    cutoff=session_started-5
    try:
        for source in acli_log_root.rglob('*.log'):
            try:
                if source.stat().st_mtime<cutoff: continue
                stem=source.stem
                with_port=re.match(r'^(\d{2}-\d{2}-\d{2}_.+)-\d{1,5}$',stem)
                target=source.with_name((with_port.group(1) if with_port else stem)+'.txt')
                if target.exists():
                    index=2
                    while target.with_name(target.stem+'_'+str(index)+'.txt').exists(): index+=1
                    target=target.with_name(target.stem+'_'+str(index)+'.txt')
                source.replace(target)
            except OSError: pass
    except OSError: pass

def winsize(fd,cols,rows):
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))

def emit(kind,**values):
    values['type']=kind
    sys.stdout.write(json.dumps(values,separators=(',',':'))+'\n');sys.stdout.flush()
    # TerminalEndpoint uses AsyncRemote without waiting for the previous send.
    # A short pacing delay prevents overlapping Tomcat 8 WebSocket writes.
    if kind == 'output':
        time.sleep(0.025)

pid,master=pty.fork()
if pid==0:
    os.execvpe(args.command[0],args.command,os.environ)
winsize(master,args.cols,args.rows)
fcntl.fcntl(master,fcntl.F_SETFL,fcntl.fcntl(master,fcntl.F_GETFL)|os.O_NONBLOCK)
fcntl.fcntl(0,fcntl.F_SETFL,fcntl.fcntl(0,fcntl.F_GETFL)|os.O_NONBLOCK)
selector=selectors.DefaultSelector();selector.register(master,selectors.EVENT_READ,'pty');selector.register(0,selectors.EVENT_READ,'stdin')
buffer=b'';running=True

def terminate(signum=None,frame=None):
    global running
    reason='stdin closed' if signum is None else 'signal {}'.format(signum)
    try: emit('output',data=base64.b64encode(('[FabricNavigator PTY] Beendet: '+reason+'\r\n').encode('utf-8')).decode('ascii'))
    except Exception: pass
    running=False
    try: os.killpg(pid,signal.SIGTERM)
    except ProcessLookupError: pass
signal.signal(signal.SIGTERM,terminate);signal.signal(signal.SIGINT,terminate)
try:
    while running:
        ended,status=os.waitpid(pid,os.WNOHANG)
        if ended:
            while True:
                try: data=os.read(master,16384)
                except (BlockingIOError,OSError): break
                if not data: break
                emit('output',data=base64.b64encode(data).decode('ascii'))
            exit_code=os.waitstatus_to_exitcode(status)
            diagnostic='[FabricNavigator PTY] ACLI-Exit: {}\r\n'.format(exit_code).encode('utf-8')
            emit('output',data=base64.b64encode(diagnostic).decode('ascii'))
            time.sleep(0.5)
            emit('exit',code=exit_code);break
        for key,_ in selector.select(0.5):
            if key.data=='pty':
                try: data=os.read(master,16384)
                except BlockingIOError: continue
                except OSError: data=b''
                if data: emit('output',data=base64.b64encode(data).decode('ascii'))
            else:
                try: chunk=os.read(0,16384)
                except BlockingIOError: continue
                if not chunk: terminate();break
                buffer+=chunk
                while b'\n' in buffer:
                    line,buffer=buffer.split(b'\n',1)
                    try: message=json.loads(line.decode('utf-8'))
                    except Exception: continue
                    kind=message.get('type')
                    if kind=='input':
                        try: data=base64.b64decode(message.get('data',''),validate=True)
                        except Exception: continue
                        if len(data)<=16384: os.write(master,data)
                    elif kind=='resize':
                        cols=max(20,min(int(message.get('cols',120)),400));rows=max(5,min(int(message.get('rows',34)),200));winsize(master,cols,rows)
                    elif kind=='close': terminate()
except Exception as exc:
    diagnostic='[FabricNavigator PTY] Bridge-Fehler: {}: {}\r\n'.format(type(exc).__name__,exc).encode('utf-8','replace')
    emit('output',data=base64.b64encode(diagnostic).decode('ascii'))
    time.sleep(0.5)
finally:
    try: selector.close()
    except Exception: pass
    try: os.close(master)
    except OSError: pass
    if running:
        try: os.killpg(pid,signal.SIGTERM)
        except ProcessLookupError: pass
    finalize_acli_logs()
