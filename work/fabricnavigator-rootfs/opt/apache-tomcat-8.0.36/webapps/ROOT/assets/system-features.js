(function(){
  'use strict';
  function init(){
    var page=document.querySelector('.page'),tab=document.querySelector('[data-system-tab="features"]'),panel=document.querySelector('[data-system-panel="features"]');
    if(!page||!tab||!panel)return;
    var language=(document.documentElement.lang||'de').toLowerCase().indexOf('de')===0?'de':'en',enabled=page.dataset.configurationBackupEnabled==='true';
    var message=document.querySelector('[data-message-key]');
    if(message&&message.dataset.messageKey==='featureEnabled')message.textContent=language==='de'?'Das Konfigurations-Backup wurde freigeschaltet.':'Configuration backup was enabled.';
    if(message&&message.dataset.messageKey==='featureDisabled')message.textContent=language==='de'?'Das Konfigurations-Backup wurde entfernt. Gespeicherte Sicherungen bleiben erhalten.':'Configuration backup was removed. Stored backups are retained.';
    var featureCards=panel.querySelectorAll('article.card'),featureCard=featureCards.length?featureCards[0]:null,csrfInput=document.querySelector('input[name="csrfToken"]');
    if(featureCards.length>1)featureCards[1].remove();
    if(featureCard){
      Array.prototype.slice.call(featureCard.children,2).forEach(function(child){child.remove();});
      var style=document.createElement('style');
      style.textContent='.fn-feature-list{display:grid;gap:8px;margin:18px 0}.fn-feature-row{display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:12px;align-items:center;padding:11px 12px;border:1px solid var(--fn-border);border-radius:10px;background:color-mix(in srgb,var(--fn-accent) 6%,var(--fn-panel))}.fn-feature-row strong{color:var(--fn-text)}.fn-feature-row form{margin:0}.fn-feature-unlock{display:grid;grid-template-columns:minmax(220px,1fr) auto;gap:12px;align-items:end;margin-top:20px;padding-top:18px;border-top:1px solid var(--fn-border)}.fn-feature-unlock label{margin:0}@media(max-width:650px){.fn-feature-row,.fn-feature-unlock{grid-template-columns:1fr}.fn-feature-row form button,.fn-feature-unlock button{width:100%}}';
      featureCard.appendChild(style);
      var list=document.createElement('div');list.className='fn-feature-list';
      if(enabled){
        var row=document.createElement('div'),name=document.createElement('strong'),state=document.createElement('span'),removeForm=document.createElement('form'),removeAction=document.createElement('input'),removeCsrf=document.createElement('input'),removeButton=document.createElement('button');
        row.className='fn-feature-row';name.textContent=language==='de'?'Konfigurations-Backup':'Configuration backup';
        state.className='status-pill active';state.textContent=language==='de'?'Freigeschaltet':'Enabled';
        removeForm.method='post';removeAction.type='hidden';removeAction.name='action';removeAction.value='disableConfigurationBackup';removeCsrf.type='hidden';removeCsrf.name='csrfToken';removeCsrf.value=csrfInput?csrfInput.value:'';
        removeButton.type='submit';removeButton.className='danger';removeButton.setAttribute('data-de','Löschen');removeButton.setAttribute('data-en','Delete');removeButton.textContent=language==='de'?'Löschen':'Delete';
        removeForm.appendChild(removeAction);removeForm.appendChild(removeCsrf);removeForm.appendChild(removeButton);row.appendChild(name);row.appendChild(state);row.appendChild(removeForm);list.appendChild(row);
      }
      featureCard.appendChild(list);
      var unlockForm=document.createElement('form'),unlockAction=document.createElement('input'),unlockCsrf=document.createElement('input'),label=document.createElement('label'),caption=document.createElement('span'),password=document.createElement('input'),unlockButton=document.createElement('button');
      unlockForm.method='post';unlockForm.className='fn-feature-unlock';unlockAction.type='hidden';unlockAction.name='action';unlockAction.value='enableConfigurationBackup';unlockCsrf.type='hidden';unlockCsrf.name='csrfToken';unlockCsrf.value=csrfInput?csrfInput.value:'';
      caption.setAttribute('data-de','Feature-Kennwort');caption.setAttribute('data-en','Feature password');caption.textContent=language==='de'?'Feature-Kennwort':'Feature password';password.type='password';password.name='featurePassword';password.required=true;password.autocomplete='off';
      unlockButton.type='submit';unlockButton.setAttribute('data-de','Feature freischalten');unlockButton.setAttribute('data-en','Unlock feature');unlockButton.textContent=language==='de'?'Feature freischalten':'Unlock feature';
      label.appendChild(caption);label.appendChild(password);unlockForm.appendChild(unlockAction);unlockForm.appendChild(unlockCsrf);unlockForm.appendChild(label);unlockForm.appendChild(unlockButton);featureCard.appendChild(unlockForm);
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
