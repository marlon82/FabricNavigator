(function(){'use strict';
var form=document.querySelector('.fn-capture-all-form'),panel=document.querySelector('.fn-backup-page-job');
if(!form||!panel)return;
var button=form.querySelector('button'),title=panel.querySelector('strong'),summary=panel.querySelector('small'),message=panel.querySelector('p'),bar=panel.querySelector('.fn-backup-page-job-track span'),close=panel.querySelector('button'),timer=0,removeTimer=0;
function german(){return(document.documentElement.lang||'en').toLowerCase().indexOf('de')===0;}
function hide(){panel.hidden=true;if(timer){clearTimeout(timer);timer=0;}if(removeTimer){clearTimeout(removeTimer);removeTimer=0;}}
function showError(value){panel.hidden=false;panel.className='fn-backup-page-job failed';title.textContent=german()?'Backup konnte nicht gestartet werden':'Backup could not be started';summary.textContent='';message.textContent=value||'';bar.style.width='100%';button.disabled=false;}
function render(status){
 var state=status.state||'idle',done=(Number(status.success)||0)+(Number(status.failed)||0),total=Math.max(Number(status.total)||0,done),running=state==='running',complete=state==='success'||state==='warning'||state==='error';
 if(!running&&!complete)return;
 panel.hidden=false;panel.className='fn-backup-page-job'+(state==='success'?' complete':state==='warning'||state==='error'?' failed':'');
 title.textContent=running?(german()?'Konfigurations-Backups laufen':'Configuration backups in progress'):(state==='success'?(german()?'Backups abgeschlossen':'Backups complete'):(german()?'Backups mit Fehlern beendet':'Backups completed with errors'));
 summary.textContent=total?done+' / '+total:'';message.textContent=status.message||'';bar.style.width=(total?Math.round(done/total*100):(running?12:100))+'%';button.disabled=running;
 if(running){timer=setTimeout(poll,900);}else{button.disabled=false;if(!removeTimer)removeTimer=setTimeout(hide,20000);}
}
function poll(){timer=0;fetch('/admin/config-backups.jsp?status=1&_='+Date.now(),{credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json'}}).then(function(response){if(!response.ok)throw new Error('HTTP '+response.status);return response.json();}).then(render).catch(function(error){showError(error.message);});}
close.addEventListener('click',hide);
form.addEventListener('submit',function(event){event.preventDefault();if(button.disabled)return;button.disabled=true;panel.hidden=false;panel.className='fn-backup-page-job';title.textContent=german()?'Backups werden gestartet':'Starting backups';summary.textContent='';message.textContent=german()?'Die Seite bleibt während der Sicherung vollständig nutzbar.':'The page remains fully usable while backups run.';bar.style.width='4%';fetch(form.action||location.href,{method:'POST',credentials:'same-origin',cache:'no-store',body:new FormData(form)}).then(function(response){if(!response.ok||response.url.indexOf('/login.jsp')>=0)throw new Error('HTTP '+response.status);poll();}).catch(function(error){showError(error.message);});});
poll();
}());
