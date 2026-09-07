(function(){
  'use strict';
  function init(){
    if(location.pathname!=='/admin/'||document.querySelector('.fn-admin-general-panel'))return;
    var grid=document.querySelector('main.page .grid'),nav=document.querySelector('.fn-admin-tabs');
    if(!grid||!nav)return;
    var de=(document.documentElement.lang||'de').toLowerCase().indexOf('de')===0;
    var tab=document.createElement('button');
    tab.type='button';tab.className='fn-admin-tab';tab.dataset.tab='general';tab.id='fn-admin-tab-general';
    tab.setAttribute('role','tab');tab.textContent=de?'Allgemein':'General';
    nav.insertBefore(tab,nav.firstChild);
    var panel=document.createElement('section');
    panel.className='fn-admin-tab-panel fn-admin-group-panel fn-admin-general-panel';panel.hidden=true;
    panel.setAttribute('role','tabpanel');panel.setAttribute('aria-labelledby',tab.id);
    panel.innerHTML='<nav class="fn-admin-subtabs" role="tablist"></nav><div class="fn-admin-subcontent"></div>';
    grid.appendChild(panel);
    var subnav=panel.querySelector('.fn-admin-subtabs'),content=panel.querySelector('.fn-admin-subcontent');
    function add(key,labelDe,labelEn,url){
      var button=document.createElement('button'),section=document.createElement('section'),frame=document.createElement('iframe');
      button.type='button';button.className='fn-admin-subtab';button.dataset.subtab=key;button.setAttribute('role','tab');button.textContent=de?labelDe:labelEn;
      section.className='fn-admin-tab-panel fn-admin-system-panel';section.dataset.adminGeneralPanel=key;section.hidden=true;
      frame.className='fn-admin-system-frame';frame.title=de?labelDe:labelEn;frame.dataset.src=url;section.appendChild(frame);content.appendChild(section);subnav.appendChild(button);
      function fit(){try{var body=frame.contentDocument&&frame.contentDocument.body;if(body)frame.style.height=Math.max(360,body.scrollHeight+8)+'px';}catch(ignored){}}
      frame.addEventListener('load',fit);button.addEventListener('click',function(){activateSub(key);});
    }
    add('api','API','API','/admin/device-api.jsp');
    add('session','Web-Sitzung','Web session','/admin/session-settings.jsp');
    function activateSub(key){
      Array.prototype.forEach.call(content.children,function(item){item.hidden=item.dataset.adminGeneralPanel!==key;if(!item.hidden){var frame=item.querySelector('iframe');if(frame&&!frame.src)frame.src=frame.dataset.src;}});
      subnav.querySelectorAll('.fn-admin-subtab').forEach(function(item){var active=item.dataset.subtab===key;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});
      try{localStorage.setItem('fnAdminGeneralTab',key);localStorage.setItem('fnAdminTab','general');}catch(ignored){}
    }
    function activate(){
      grid.querySelectorAll(':scope > .fn-admin-tab-panel').forEach(function(item){item.hidden=item!==panel;});
      nav.querySelectorAll(':scope > [role="tab"]').forEach(function(item){var active=item===tab;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});
      panel.hidden=false;var key='api';try{key=localStorage.getItem('fnAdminGeneralTab')||'api';}catch(ignored){}activateSub(key==='session'?'session':'api');
    }
    tab.addEventListener('click',activate);
    try{
      if(localStorage.getItem('fnAdminCredentialTab')==='device-api'){localStorage.removeItem('fnAdminCredentialTab');localStorage.setItem('fnAdminTab','general');localStorage.setItem('fnAdminGeneralTab','api');}
      if(localStorage.getItem('fnAdminTab')==='general')activate();
    }catch(ignored){}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
}());
