(function(){
  'use strict';
  function init(){
    var page=document.querySelector('.page'),tab=document.querySelector('[data-system-tab="features"]'),panel=document.querySelector('[data-system-panel="features"]');
    if(!page||!tab||!panel)return;
    function show(){
      document.querySelectorAll('[data-system-panel]').forEach(function(item){item.hidden=item!==panel;});
      document.querySelectorAll('[data-system-tab]').forEach(function(item){var active=item===tab;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});
      try{localStorage.setItem('fnAdminSystemTab','features');}catch(ignored){}
      try{window.parent.postMessage({type:'fn-admin-frame-resize'},location.origin);}catch(ignored){}
    }
    tab.addEventListener('click',function(event){event.stopImmediatePropagation();show();},true);
    var initial=page.dataset.initialTab||'';
    try{if(initial==='features'||(!initial&&localStorage.getItem('fnAdminSystemTab')==='features'))show();}catch(ignored){if(initial==='features')show();}
    if(page.dataset.featureJustEnabled==='true'){
      try{window.parent.localStorage.setItem('fnAdminTab','config-backups');window.parent.location.reload();}catch(ignored){location.reload();}
    }
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
}());
