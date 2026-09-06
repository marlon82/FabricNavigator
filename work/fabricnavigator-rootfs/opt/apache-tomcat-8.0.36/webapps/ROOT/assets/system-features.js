(function(){
  'use strict';
  function init(){
    var page=document.querySelector('.page'),tab=document.querySelector('[data-system-tab="features"]'),panel=document.querySelector('[data-system-panel="features"]');
    if(!page||!tab||!panel)return;
    var language=(document.documentElement.lang||'de').toLowerCase().indexOf('de')===0?'de':'en';
    var message=document.querySelector('[data-message-key]');
    if(message&&message.dataset.messageKey==='featureEnabled')message.textContent=language==='de'?'Das Konfigurations-Backup wurde freigeschaltet.':'Configuration backup was enabled.';
    if(message&&message.dataset.messageKey==='featureDisabled')message.textContent=language==='de'?'Das Konfigurations-Backup wurde wieder gesperrt.':'Configuration backup was locked again.';
    if(page.dataset.configurationBackupEnabled==='true'){
      var featureCard=panel.querySelector('article.card');
      if(featureCard){
        var csrfInput=document.querySelector('input[name="csrfToken"]'),form=document.createElement('form'),action=document.createElement('input'),csrf=document.createElement('input'),button=document.createElement('button'),hint=document.createElement('p');
        form.method='post';form.className='feature-lock-form';
        action.type='hidden';action.name='action';action.value='disableConfigurationBackup';form.appendChild(action);
        csrf.type='hidden';csrf.name='csrfToken';csrf.value=csrfInput?csrfInput.value:'';form.appendChild(csrf);
        button.type='submit';button.className='danger';button.setAttribute('data-de','Konfigurations-Backup wieder sperren');button.setAttribute('data-en','Lock configuration backup again');button.textContent=language==='de'?'Konfigurations-Backup wieder sperren':'Lock configuration backup again';form.appendChild(button);
        hint.className='hint';hint.setAttribute('data-de','Gespeicherte Sicherungen bleiben erhalten und werden durch das Sperren nicht gelöscht.');hint.setAttribute('data-en','Stored backups are retained and are not deleted when the feature is locked.');hint.textContent=language==='de'?'Gespeicherte Sicherungen bleiben erhalten und werden durch das Sperren nicht gelöscht.':'Stored backups are retained and are not deleted when the feature is locked.';
        featureCard.appendChild(form);featureCard.appendChild(hint);
      }
    }
    function show(){
      document.querySelectorAll('[data-system-panel]').forEach(function(item){item.hidden=item!==panel;});
      document.querySelectorAll('[data-system-tab]').forEach(function(item){var active=item===tab;item.classList.toggle('active',active);item.setAttribute('aria-selected',active?'true':'false');item.tabIndex=active?0:-1;});
      try{localStorage.setItem('fnAdminSystemTab','features');}catch(ignored){}
      try{window.parent.postMessage({type:'fn-admin-frame-resize'},location.origin);}catch(ignored){}
    }
    tab.addEventListener('click',function(event){event.stopImmediatePropagation();show();},true);
    var initial=page.dataset.initialTab||'';
    try{if(initial==='features'||(!initial&&localStorage.getItem('fnAdminSystemTab')==='features'))show();}catch(ignored){if(initial==='features')show();}
    if(page.dataset.featureNavigationChange==='featureEnabled'){
      try{window.parent.localStorage.setItem('fnAdminTab','config-backups');window.parent.location.reload();}catch(ignored){location.reload();}
    }else if(page.dataset.featureNavigationChange==='featureDisabled'){
      try{window.parent.location.reload();}catch(ignored){location.reload();}
    }
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
}());
