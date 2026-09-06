(function(){
  'use strict';
  function init(){
    var group=document.querySelector('.fn-admin-credentials-panel');if(!group)return;
    var heading=group.querySelector(':scope > .fn-admin-group-heading');if(heading)heading.remove();
    var nav=group.querySelector('.fn-admin-subtabs'),content=group.querySelector('.fn-admin-subcontent');if(!nav||!content||nav.querySelector('[data-subtab="device-api"]'))return;
    var de=(document.documentElement.lang||'de').toLowerCase().indexOf('de')===0,tab=document.createElement('button'),panel=document.createElement('section');
    tab.type='button';tab.className='fn-admin-subtab';tab.dataset.subtab='device-api';tab.setAttribute('role','tab');tab.setAttribute('aria-selected','false');tab.tabIndex=-1;tab.textContent=de?'Geräte-API':'Device API';nav.appendChild(tab);
    panel.className='fn-admin-tab-panel fn-admin-system-panel fn-device-api-panel';panel.dataset.adminCredentialPanel='device-api';panel.hidden=true;panel.innerHTML='<iframe class="fn-admin-system-frame" title="'+(de?'Geräte-API':'Device API')+'" src="/admin/device-api.jsp"></iframe>';content.appendChild(panel);
    function fit(){var frame=panel.querySelector('iframe');try{var body=frame.contentDocument&&frame.contentDocument.body;if(body)frame.style.height=Math.max(410,body.scrollHeight+8)+'px';}catch(ignored){}}
    function show(){Array.prototype.forEach.call(content.children,function(child){child.hidden=child!==panel;});nav.querySelectorAll('.fn-admin-subtab').forEach(function(item){var active=item===tab;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});try{localStorage.setItem('fnAdminCredentialTab','device-api');localStorage.setItem('fnAdminTab','credentials');}catch(ignored){}fit();}
    tab.addEventListener('click',show);panel.querySelector('iframe').addEventListener('load',fit);
    try{if(localStorage.getItem('fnAdminTab')==='credentials'&&localStorage.getItem('fnAdminCredentialTab')==='device-api')show();}catch(ignored){}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
}());
