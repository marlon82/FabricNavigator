(function(){
  'use strict';
  function init(){
    var page=document.querySelector('.page'),nav=document.querySelector('.system-tabs');if(!page||!nav||document.querySelector('[data-system-tab="api"]'))return;
    var tab=document.createElement('button');tab.type='button';tab.className='fn-admin-subtab';tab.setAttribute('role','tab');tab.dataset.systemTab='api';tab.textContent='API';
    var features=nav.querySelector('[data-system-tab="features"]');if(features&&features.nextSibling)nav.insertBefore(tab,features.nextSibling);else nav.appendChild(tab);
    var panel=document.createElement('section');panel.className='system-panel';panel.dataset.systemPanel='api';panel.hidden=true;panel.innerHTML='<div class="system-grid"><article class="card wide" style="padding:0!important;border-top-width:0!important"><iframe title="FabricNavigator API" src="/admin/api.jsp" style="display:block;width:100%;min-height:620px;border:0;background:transparent"></iframe></article></div>';
    document.querySelector('.system-panels').appendChild(panel);
    function fit(){var frame=panel.querySelector('iframe');try{var body=frame.contentDocument&&frame.contentDocument.body;if(body)frame.style.height=Math.max(620,body.scrollHeight+8)+'px';}catch(ignored){}}
    function show(){document.querySelectorAll('[data-system-panel]').forEach(function(item){item.hidden=item!==panel;});document.querySelectorAll('[data-system-tab]').forEach(function(item){var active=item===tab;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});try{localStorage.setItem('fnAdminSystemTab','api');}catch(ignored){}fit();}
    tab.addEventListener('click',function(event){event.stopImmediatePropagation();show();},true);panel.querySelector('iframe').addEventListener('load',fit);
    try{if(localStorage.getItem('fnAdminSystemTab')==='api')show();}catch(ignored){}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
}());
