<%@ page import="com.fabricnavigator.security.EdmSecurity,com.fabricnavigator.security.AuditLog,java.io.*,java.nio.file.*,java.util.*" %><%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String h(String value){if(value==null)return "";return value.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace("\"","&quot;").replace("'","&#39;");}
private static final File UPDATE_DIR=new File(System.getenv("FABRICNAVIGATOR_UPDATE_DIR")!=null?System.getenv("FABRICNAVIGATOR_UPDATE_DIR"):"/opt/fabricnavigator/update");
private static Properties readProperties(File file){Properties result=new Properties();if(!file.isFile())return result;try{InputStream in=new FileInputStream(file);try{result.load(new InputStreamReader(in,"UTF-8"));}finally{in.close();}}catch(Exception ignored){}return result;}
private static void writeRequest(File file,Properties values)throws Exception{UPDATE_DIR.mkdirs();File temporary=File.createTempFile(file.getName()+".",".tmp",UPDATE_DIR);Writer writer=new OutputStreamWriter(new FileOutputStream(temporary),"UTF-8");try{values.store(writer,"FabricNavigator update request");}finally{writer.close();}Files.move(temporary.toPath(),file.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}
private static void markInstallRequested(File statusFile,String version,long requestedAt)throws Exception{Properties pending=new Properties();pending.setProperty("state","requested");pending.setProperty("version",version);pending.setProperty("updatedAt",new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX").format(new Date(requestedAt)));pending.setProperty("message","The new update request is waiting for the host updater.");writeRequest(statusFile,pending);}
private static String readText(File file)throws Exception{if(!file.isFile())return "";byte[] bytes=Files.readAllBytes(file.toPath());if(bytes.length>200000)return new String(bytes,0,200000,"UTF-8");return new String(bytes,"UTF-8");}
private static boolean safeVersion(String value){return value!=null&&value.matches("\\d+\\.\\d+\\.\\d+\\.\\d+");}
private static String j(String value){if(value==null)return "";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r","").replace("\n","\\n").replace("</","<\\/");}
%><%
response.setHeader("Cache-Control","no-store");response.setCharacterEncoding("UTF-8");if(!EdmSecurity.isAdmin(request)){response.sendError(403);return;}String csrf=EdmSecurity.csrf(session),actor=EdmSecurity.currentUser(request),flash="",error="";long installRequestedAt=0L;File statusFile=new File(UPDATE_DIR,"status.properties"),hostStatusFile=new File(UPDATE_DIR,"host-status.properties"),tokenStatusFile=new File(UPDATE_DIR,"github-token-status.properties"),settingsFile=new File(UPDATE_DIR,"update-settings.properties"),notesFile=new File(UPDATE_DIR,"release-notes.txt"),offlineFile=new File(UPDATE_DIR,"offline-update.properties"),offlineDirectory=new File(UPDATE_DIR,"offline"),acliStatusFile=new File(UPDATE_DIR,"acli-status.properties");
if("status".equals(request.getParameter("view"))){Properties live=readProperties(hostStatusFile);String installed=System.getenv("FABRICNAVIGATOR_VERSION");if(installed==null||installed.length()==0)installed="26.08.10.116";boolean activeRequest=new File(UPDATE_DIR,"install.request").isFile()||new File(UPDATE_DIR,"install.processing").isFile()||new File(UPDATE_DIR,"install.request.processing").isFile();response.setContentType("application/json; charset=UTF-8");out.print("{\"state\":\""+j(live.getProperty("state","waiting"))+"\",\"version\":\""+j(live.getProperty("version",""))+"\",\"updatedAt\":\""+j(live.getProperty("updatedAt",""))+"\",\"message\":\""+j(live.getProperty("message",""))+"\",\"installedVersion\":\""+j(installed)+"\",\"activeRequest\":"+activeRequest+"}");return;}
if("POST".equalsIgnoreCase(request.getMethod())){if(!EdmSecurity.validCsrf(request)){response.sendError(403);return;}String action=request.getParameter("action");try{
 if("check".equals(action)){long requestedAt=System.currentTimeMillis();Properties check=new Properties();check.setProperty("requestedAt",Long.toString(requestedAt));check.setProperty("requestedBy",actor);writeRequest(new File(UPDATE_DIR,"check.request"),check);Properties result=new Properties();boolean completed=false;for(int i=0;i<240;i++){Thread.sleep(250);result=readProperties(statusFile);String resultState=result.getProperty("state","");boolean terminal="available".equals(resultState)||"current".equals(resultState)||"error".equals(resultState)||"not-configured".equals(resultState);long checkedAtMillis=0;try{checkedAtMillis=Long.parseLong(result.getProperty("checkedAtMillis","0"));}catch(Exception ignored){}if(terminal&&checkedAtMillis>=requestedAt){completed=true;break;}}if(!completed)throw new IOException("Der Update-Prüfdienst hat nicht innerhalb von 60 Sekunden geantwortet.");String resultState=result.getProperty("state","");if("error".equals(resultState)||"not-configured".equals(resultState))throw new IOException(result.getProperty("message","Die Updateprüfung ist fehlgeschlagen."));String checkedVersion=result.getProperty("latestVersion","").trim();if(checkedVersion.length()==0)throw new IOException("Die Updateprüfung hat keine Versionsnummer geliefert.");AuditLog.log(actor,"UPDATE_CHECK","repository="+System.getenv("FABRICNAVIGATOR_GITHUB_REPOSITORY")+" · channel="+result.getProperty("channel","stable")+" · installed="+result.getProperty("installedVersion",System.getenv("FABRICNAVIGATOR_VERSION"))+" · latest="+checkedVersion+" · result="+resultState,request.getRemoteAddr());flash="available".equals(resultState)?"Neue Version "+checkedVersion+" ist verfügbar.":"FabricNavigator ist aktuell (Version "+checkedVersion+").";}
 else if("install".equals(action)){Properties available=readProperties(statusFile);String version=available.getProperty("latestVersion","");if(!"true".equals(available.getProperty("updateAvailable"))||!safeVersion(version)||!available.getProperty("assetDigest","").matches("sha256:[0-9a-fA-F]{64}"))throw new IllegalStateException("Es steht kein verifiziertes Update zur Installation bereit.");installRequestedAt=System.currentTimeMillis();Properties install=new Properties();install.setProperty("version",version);install.setProperty("channel","beta".equals(available.getProperty("channel"))?"beta":"stable");install.setProperty("requestedAt",Long.toString(installRequestedAt));install.setProperty("requestedBy",actor);markInstallRequested(hostStatusFile,version,installRequestedAt);writeRequest(new File(UPDATE_DIR,"install.request"),install);AuditLog.log(actor,"UPDATE_REQUEST",version,request.getRemoteAddr());flash="Das Update wurde angefordert. Der Fortschritt wird unten live angezeigt.";}
 else if("installOffline".equals(action)){Properties available=readProperties(offlineFile);String version=available.getProperty("version",""),file=available.getProperty("file",""),digest=available.getProperty("digest","");if(!"ready".equals(available.getProperty("state"))||!safeVersion(version)||!file.equals("FabricNavigator-Update-"+version+".zip")||!digest.matches("sha256:[0-9a-fA-F]{64}")||!new File(offlineDirectory,file).isFile())throw new IllegalStateException("Es steht kein geprüftes Offline-Update zur Installation bereit.");installRequestedAt=System.currentTimeMillis();Properties install=new Properties();install.setProperty("version",version);install.setProperty("source","offline");install.setProperty("file",file);install.setProperty("assetDigest",digest);install.setProperty("requestedAt",Long.toString(installRequestedAt));install.setProperty("requestedBy",actor);markInstallRequested(hostStatusFile,version,installRequestedAt);writeRequest(new File(UPDATE_DIR,"install.request"),install);AuditLog.log(actor,"OFFLINE_UPDATE_REQUEST",version,request.getRemoteAddr());flash="Das Offline-Update wurde angefordert. Der Fortschritt wird unten live angezeigt.";}
 else if("removeOffline".equals(action)){Properties available=readProperties(offlineFile);String version=available.getProperty("version",""),file=available.getProperty("file","");if(safeVersion(version)&&file.equals("FabricNavigator-Update-"+version+".zip"))new File(offlineDirectory,file).delete();offlineFile.delete();AuditLog.log(actor,"OFFLINE_UPDATE_REMOVED",version,request.getRemoteAddr());flash="Das bereitgestellte Offline-Update wurde entfernt.";}
 else if("saveToken".equals(action)){String token=request.getParameter("githubToken");if(token!=null)token=token.trim();if(token==null||!token.matches("[A-Za-z0-9_]{20,512}"))throw new IllegalArgumentException("Das GitHub-Token hat ein ungültiges Format.");long before=tokenStatusFile.isFile()?tokenStatusFile.lastModified():0;Properties values=new Properties();values.setProperty("action","install");values.setProperty("token",token);values.setProperty("requestedAt",Long.toString(System.currentTimeMillis()));writeRequest(new File(UPDATE_DIR,"github-token.request"),values);token=null;Properties result=new Properties();for(int i=0;i<120;i++){Thread.sleep(125);result=readProperties(tokenStatusFile);if(tokenStatusFile.lastModified()>before)break;}if(!"configured".equals(result.getProperty("state")))throw new IOException(result.getProperty("message","Der Host-Dienst hat das Token nicht gespeichert."));AuditLog.log(actor,"GITHUB_TOKEN_CONFIGURED","host secret",request.getRemoteAddr());flash="GitHub-Token wurde sicher auf dem Docker-Host gespeichert.";}
 else if("removeToken".equals(action)){long before=tokenStatusFile.isFile()?tokenStatusFile.lastModified():0;Properties values=new Properties();values.setProperty("action","remove");values.setProperty("requestedAt",Long.toString(System.currentTimeMillis()));writeRequest(new File(UPDATE_DIR,"github-token.request"),values);Properties result=new Properties();for(int i=0;i<80;i++){Thread.sleep(125);result=readProperties(tokenStatusFile);if(tokenStatusFile.lastModified()>before)break;}if(!"removed".equals(result.getProperty("state")))throw new IOException(result.getProperty("message","Der Host-Dienst hat das Token nicht entfernt."));AuditLog.log(actor,"GITHUB_TOKEN_REMOVED","host secret",request.getRemoteAddr());flash="GitHub-Token wurde vom Docker-Host entfernt.";}
 else if("checkAcli".equals(action)){long before=acliStatusFile.isFile()?acliStatusFile.lastModified():0;Properties values=new Properties();values.setProperty("requestedAt",Long.toString(System.currentTimeMillis()));values.setProperty("requestedBy",actor);writeRequest(new File(UPDATE_DIR,"acli-check.request"),values);Properties result=new Properties();boolean completed=false;for(int i=0;i<480;i++){Thread.sleep(125);result=readProperties(acliStatusFile);String state=result.getProperty("state","");if(acliStatusFile.lastModified()>before&&Arrays.asList("available","current","error").contains(state)){completed=true;break;}}if(!completed)throw new IOException("The ACLI update checker did not respond within 60 seconds.");if("error".equals(result.getProperty("state")))throw new IOException(result.getProperty("message","The ACLI update check failed."));AuditLog.log(actor,"ACLI_UPDATE_CHECK","lgastevens/ACLI-terminal",request.getRemoteAddr());flash="available".equals(result.getProperty("state"))?result.getProperty("updateCount","0")+" ACLI file(s) can be updated.":"ACLI is current.";}
 else if("installAcli".equals(action)){Properties available=readProperties(acliStatusFile);if(!"true".equals(available.getProperty("updateAvailable")))throw new IllegalStateException("No verified ACLI component update is available.");long before=acliStatusFile.lastModified();Properties values=new Properties();values.setProperty("requestedAt",Long.toString(System.currentTimeMillis()));values.setProperty("requestedBy",actor);writeRequest(new File(UPDATE_DIR,"acli-install.request"),values);Properties result=new Properties();boolean completed=false;for(int i=0;i<960;i++){Thread.sleep(125);result=readProperties(acliStatusFile);String state=result.getProperty("state","");if(acliStatusFile.lastModified()>before&&Arrays.asList("installed","current","error").contains(state)){completed=true;break;}}if(!completed)throw new IOException("The ACLI component update did not finish within 120 seconds.");if("error".equals(result.getProperty("state")))throw new IOException(result.getProperty("message","The ACLI component update failed."));AuditLog.log(actor,"ACLI_UPDATE_INSTALL",result.getProperty("installedVersion",""),request.getRemoteAddr());flash="ACLI was updated. New SSH sessions use the updated component.";}
 else if("saveAutomaticCheck".equals(action)){boolean enabled="true".equals(request.getParameter("automaticCheck"));Properties values=readProperties(settingsFile);values.setProperty("automaticCheck",enabled?"true":"false");values.setProperty("updatedAt",Long.toString(System.currentTimeMillis()));writeRequest(settingsFile,values);AuditLog.log(actor,"AUTOMATIC_UPDATE_CHECK",enabled?"enabled":"disabled",request.getRemoteAddr());flash=enabled?"Die automatische Updateprüfung ist aktiviert.":"Die automatische Updateprüfung ist deaktiviert.";}
 }catch(Exception ex){error=ex.getMessage()==null?"Updateaktion fehlgeschlagen.":ex.getMessage();}
}
Properties update=readProperties(statusFile),host=readProperties(hostStatusFile),tokenState=readProperties(tokenStatusFile),settings=readProperties(settingsFile),offline=readProperties(offlineFile),acli=readProperties(acliStatusFile);boolean tokenConfigured="true".equals(tokenState.getProperty("configured")),automaticCheck=!"false".equalsIgnoreCase(settings.getProperty("automaticCheck","true")),offlineReady="ready".equals(offline.getProperty("state"))&&safeVersion(offline.getProperty("version",""));String currentVersion=System.getenv("FABRICNAVIGATOR_VERSION");if(currentVersion==null||currentVersion.length()==0)currentVersion="26.08.10.116";String updateState=update.getProperty("state","idle"),latestVersion=update.getProperty("latestVersion","").trim(),latestVersionDisplay=latestVersion;if(latestVersionDisplay.length()==0)latestVersionDisplay="error".equals(updateState)?"Prüfung fehlgeschlagen":"Noch nicht geprüft";update.setProperty("latestVersion",latestVersionDisplay);String repository=System.getenv("FABRICNAVIGATOR_GITHUB_REPOSITORY");if(repository==null)repository="";String notes="";try{notes=readText(notesFile);}catch(Exception ignored){}
%><!doctype html>
<html lang="de" class="fn-shell-loading">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Updates · FabricNavigator</title>
<script>(function(){try{var theme=localStorage.getItem('edmTheme');if(!theme&&window.matchMedia)theme=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';document.documentElement.setAttribute('data-theme',theme||'light');}catch(error){document.documentElement.setAttribute('data-theme','light');}})();</script>
<link rel="stylesheet" href="/assets/security.css?v=20260825-146">
<link rel="stylesheet" href="/assets/app-shell.css?v=20260828-170">
<style>html.fn-shell-loading body{visibility:hidden}[data-theme="dark"] .schedule-form{border-color:color-mix(in srgb,var(--fn-accent) 46%,var(--fn-border))!important;background:color-mix(in srgb,var(--fn-accent) 9%,var(--fn-panel))!important;color:var(--fn-text)!important}[data-theme="dark"] .schedule-form label{color:var(--fn-text)!important}[data-theme="dark"] .schedule-form input[type="checkbox"]{accent-color:#b77aff!important}[data-theme="dark"] .schedule-form button{border:1px solid color-mix(in srgb,var(--fn-accent) 55%,var(--fn-border))!important}</style>
<style>html,body{background:transparent}body{margin:0;padding:2px}.update-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}.update-card{padding:22px;border:1px solid #d7dce7;border-top:4px solid #6f1bb1;border-radius:14px;background:#fff;box-shadow:0 18px 45px -35px #07152f}.wide{grid-column:1/-1}.version-line{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:10px 0;border-bottom:1px solid #e6e8ef}.version-line strong{overflow-wrap:anywhere}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:18px}.schedule-form{display:flex;align-items:center;justify-content:space-between;gap:14px;margin-top:18px;padding:14px;border:1px solid #d7dce7;border-radius:10px;background:#faf7ff}.schedule-form label{display:flex;align-items:center;gap:9px;font-weight:800}.schedule-form input{width:auto}.token-form{display:grid;grid-template-columns:minmax(260px,1fr) auto;gap:12px;align-items:end;margin-top:16px}.token-form label{margin:0}.status{display:inline-flex;padding:5px 10px;border-radius:8px;background:#eee4fb;color:#54149a;font-weight:800}.status.error{background:#fdecec;color:#8d1f25}.status.success{background:#e8f8ee;color:#176b36}.release-notes{max-height:360px;overflow:auto;white-space:pre-wrap;padding:16px;border-radius:10px;background:#f5f0ff;line-height:1.5}.token-details>summary{display:flex;align-items:center;justify-content:space-between;gap:12px;cursor:pointer;font-size:22px;font-weight:800;list-style:none}.token-details>summary::-webkit-details-marker{display:none}.token-details>summary:after{content:'+';font-size:24px;color:#6f1bb1}.token-details[open]>summary:after{content:'−'}.token-body{padding-top:12px}.hint{color:#667085;font-size:13px;line-height:1.5}.alert{padding:12px;border-radius:9px;margin-bottom:14px}.success{background:#e8f8ee;color:#176b36}.error{background:#fdecec;color:#8d1f25}.fn-offline-uploader{display:grid;grid-template-columns:minmax(240px,1fr) auto;gap:12px;align-items:end;margin-top:15px;padding:15px;border:1px solid #d9c1f5;border-radius:11px;background:#faf7ff}.fn-offline-uploader input[type=file]{width:100%;padding:9px;border:1px solid #c9ceda;border-radius:9px;background:#fff}.fn-package-progress{grid-column:1/-1;height:7px;overflow:hidden;border-radius:99px;background:#e6def1}.fn-package-progress span{display:block;width:0;height:100%;background:linear-gradient(90deg,#6315bd,#b36df2);transition:width .2s}.fn-package-status{grid-column:1/-1;margin:0;color:#667085;font-size:13px;font-weight:700}button[disabled]{opacity:.55;cursor:not-allowed}@media(max-width:760px){.update-grid{grid-template-columns:1fr}.token-form,.fn-offline-uploader{grid-template-columns:1fr}.schedule-form{align-items:stretch;flex-direction:column}.wide{grid-column:auto}}</style>
<script>(function(){var requestedKey='fnUpdateInstallRequestedAt',buildKey='fnUpdateInstallSourceBuild',active=<%=new File(UPDATE_DIR,"install.request").isFile()||new File(UPDATE_DIR,"install.processing").isFile()||new File(UPDATE_DIR,"install.request.processing").isFile()%>,current='<%=j(currentVersion)%>',acceptedAt=<%=installRequestedAt%>;try{if(acceptedAt>0){sessionStorage.setItem(requestedKey,String(acceptedAt));sessionStorage.setItem(buildKey,current);sessionStorage.removeItem('fnUpdateLastAutoRefreshAt');}var requested=sessionStorage.getItem(requestedKey),source=sessionStorage.getItem(buildKey);if(requested&&(!active||(source&&source!==current))){sessionStorage.removeItem(requestedKey);sessionStorage.removeItem(buildKey);sessionStorage.removeItem('fnUpdateLastAutoRefreshAt');}document.addEventListener('submit',function(event){var form=event.target,action=form&&form.querySelector('input[name="action"]');if(action&&(action.value==='install'||action.value==='installOffline'))sessionStorage.setItem(buildKey,current);},true);}catch(ignored){}})();</script>
<script defer src="/assets/app-shell.js?v=20260906-241">
</script>
</head>
<body>
<%if(flash.length()>0){%>
<div class="alert success">
<%=h(flash)%>
</div>
<%}if(error.length()>0){%>
<div class="alert error">
<%=h(error)%>
</div>
<%}%>
<div class="update-grid">
<section class="update-card wide fn-software-update-card">
<h2>Softwareupdate</h2>
<div class="version-line">
<span>Installierte Version</span>
<strong>
<%=h(currentVersion)%>
</strong>
</div>
<div class="version-line">
<span>Neueste Version</span>
<strong>
<%=h(update.getProperty("latestVersion","Noch nicht geprüft"))%>
</strong>
</div>
<div class="version-line">
<span>Status</span>
<span class="status <%="error".equals(update.getProperty("state"))?"error":("current".equals(update.getProperty("state"))?"success":"")%>">
<%=h(update.getProperty("state","idle"))%>
</span>
</div>
<%if(update.getProperty("message","").length()>0){%>
<p class="hint">
<%=h(update.getProperty("message"))%>
</p>
<%}%>
<div class="actions">
<form method="post">
<input type="hidden" name="csrfToken" value="<%=h(csrf)%>">
<input type="hidden" name="action" value="check">
<button type="submit">Auf Updates prüfen</button>
</form>
<form method="post" onsubmit="return confirm('Update jetzt herunterladen, installieren und FabricNavigator neu starten?')">
<input type="hidden" name="csrfToken" value="<%=h(csrf)%>">
<input type="hidden" name="action" value="install">
<button type="submit" <%="true".equals(update.getProperty("updateAvailable"))?"":"disabled"%>>Update installieren</button>
</form>
</div>
<form method="post" class="schedule-form">
<input type="hidden" name="csrfToken" value="<%=h(csrf)%>">
<input type="hidden" name="action" value="saveAutomaticCheck">
<label><input type="checkbox" name="automaticCheck" value="true" <%=automaticCheck?"checked":""%>> Automatisch alle 6 Stunden auf Updates prüfen</label>
<button type="submit">Einstellung speichern</button>
</form>
<%if(repository.length()==0){%>
<p class="hint">Trage <code>FABRICNAVIGATOR_GITHUB_REPOSITORY=BENUTZER/REPOSITORY</code> in der Datei <code>.env</code> des Installationsordners ein und starte den Container anschließend neu.</p>
<%}%>
</section>
<section class="update-card" <%=Arrays.asList("requested","waiting","downloading","validating","installing","restarting","rollback").contains(host.getProperty("state","").toLowerCase(Locale.ROOT))&&safeVersion(host.getProperty("version",""))?"":"hidden"%>>
<h2>Installationsstatus</h2>
<div class="version-line">
<span>Status des Host-Updaters</span>
<strong>
<%=h(host.getProperty("state","Wartet"))%>
</strong>
</div>
<div class="version-line">
<span>Zielversion</span>
<strong>
<%=h(host.getProperty("version","—"))%>
</strong>
</div>
<div class="version-line">
<span>Letzte Änderung</span>
<strong>
<%=h(host.getProperty("updatedAt","—"))%>
</strong>
</div>
<%if(host.getProperty("message","").length()>0){%>
<p class="hint">
<%=h(host.getProperty("message"))%>
</p>
<%}%>
<p class="hint">Der Windows-Updater validiert Repository, Release-Version und SHA-256-Digest erneut. Bei einem fehlgeschlagenen Healthcheck wird automatisch auf die vorherige Compose-Konfiguration zurückgerollt.</p>
</section>
<section class="update-card wide">
<h2>Offline-Update</h2>
<p class="hint">Lade ein zuvor heruntergeladenes <code>FabricNavigator-Update-VERSION.zip</code> hoch. Das Paket wird lokal auf Struktur, Version und SHA-256 geprüft und benötigt weder GitHub noch ein Update-Token.</p>
<div class="fn-offline-uploader" data-package-kind="core" data-csrf="<%=h(csrf)%>"><label>Update-Paket<input type="file" accept=".zip,application/zip"></label><button type="button">Paket prüfen und bereitstellen</button><div class="fn-package-progress" hidden><span></span></div><p class="fn-package-status" role="status"><%=offlineReady?"Bereit: FabricNavigator "+h(offline.getProperty("version")):"Noch kein Offline-Update bereitgestellt."%></p></div>
<%if(offlineReady){%><div class="actions"><form method="post" class="fn-offline-install-form"><input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="installOffline"><button type="submit">Offline-Update installieren</button></form><form method="post"><input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="removeOffline"><button class="secondary" type="submit">Paket entfernen</button></form></div><%}%>
</section>
<section class="update-card wide">
<h2>Release Notes</h2>
<%if(notes.length()>0){%>
<div class="release-notes">
<%=h(notes)%>
</div>
<%}else{%>
<p class="hint">Nach der ersten erfolgreichen Updateprüfung werden hier die Release Notes des neuesten GitHub-Releases angezeigt.</p>
<%}if(update.getProperty("releaseUrl","").startsWith("https://github.com/")){%>
<p>
<a href="<%=h(update.getProperty("releaseUrl"))%>" target="_blank" rel="noopener">Release auf GitHub öffnen</a>
</p>
<%}%>
</section>
<section class="update-card wide fn-github-token-panel" hidden>
<details class="token-details" <%=tokenConfigured?"":"open"%>>
<summary><span>GitHub Update-Token</span><span class="status <%=tokenConfigured?"success":""%>"><%=tokenConfigured?"Konfiguriert":"Nicht konfiguriert"%></span></summary>
<div class="token-body">
<%if(tokenState.getProperty("message","").length()>0){%>
<p class="hint"><%=h(tokenState.getProperty("message"))%></p>
<%}%>
<p class="hint" data-de="Für das öffentliche FabricNavigator-Repository ist kein Token erforderlich. Optional kann ein Token für private Forks oder höhere GitHub-API-Limits einmalig über HTTPS übertragen werden; der privilegierte Host-Dienst speichert ihn mit eingeschränkten Dateirechten und zeigt oder protokolliert ihn niemals." data-en="The public FabricNavigator repository requires no token. An optional token for private forks or higher GitHub API limits is transmitted once over HTTPS; the privileged host service stores it with restricted permissions and never displays or logs it.">Für das öffentliche FabricNavigator-Repository ist kein Token erforderlich. Optional kann ein Token für private Forks oder höhere GitHub-API-Limits einmalig über HTTPS übertragen werden; der privilegierte Host-Dienst speichert ihn mit eingeschränkten Dateirechten und zeigt oder protokolliert ihn niemals.</p>
<form method="post" class="token-form" autocomplete="off">
<input type="hidden" name="csrfToken" value="<%=h(csrf)%>">
<input type="hidden" name="action" value="saveToken">
<label>Fine-grained GitHub-Token<input type="password" name="githubToken" required minlength="20" maxlength="512" autocomplete="new-password" spellcheck="false"></label>
<button type="submit">Token sicher speichern</button>
</form>
<%if(tokenConfigured){%>
<form method="post" class="actions" onsubmit="return confirm('Gespeichertes GitHub-Token wirklich entfernen?')">
<input type="hidden" name="csrfToken" value="<%=h(csrf)%>">
<input type="hidden" name="action" value="removeToken">
<button class="danger" type="submit">Token entfernen</button>
</form>
<%}%>
</div>
</details>
</section>
<section class="update-card wide" id="fn-acli-plugin-card">
<h2>ACLI-Komponente</h2>
<p class="hint">Prüft den offiziellen dateibasierten ACLI-Updatekanal. Downloads werden per SHA-256 validiert, FabricNavigator-Anpassungen erneut angewendet und die Perl-Syntax vor der Aktivierung geprüft. Bei einem Fehler bleibt die bisherige Komponente aktiv.</p>
<div class="version-line"><span>Installierte ACLI-Version</span><strong><%=h(acli.getProperty("installedVersion","Noch nicht geprüft"))%></strong></div>
<div class="version-line"><span>Verfügbare ACLI-Version</span><strong><%=h(acli.getProperty("availableVersion","Noch nicht geprüft"))%></strong></div>
<div class="version-line"><span>Status</span><span class="status <%=acli.getProperty("state","").equals("error")?"error":(Arrays.asList("current","installed").contains(acli.getProperty("state",""))?"success":"")%>"><%=h(acli.getProperty("state","idle"))%></span></div>
<%if(acli.getProperty("message","").length()>0){%><p class="hint fn-acli-message" data-state="<%=h(acli.getProperty("state","idle"))%>" data-count="<%=h(acli.getProperty("updateCount","0"))%>"><%=h(acli.getProperty("message"))%></p><%}%>
<%String acliUpdates=acli.getProperty("updates","");if(acliUpdates.length()>0){%>
<div class="scroll"><table class="fn-acli-update-table"><thead><tr><th>Datei</th><th>Installiert</th><th>Verfügbar</th></tr></thead><tbody>
<%for(String item:acliUpdates.split(";")){String[] parts=item.split("\\|",-1);if(parts.length!=3)continue;%><tr><td><code><%=h(parts[0])%></code></td><td><%=h(parts[1].length()>0?parts[1]:"Nicht installiert")%></td><td><%=h(parts[2])%></td></tr><%}%>
</tbody></table></div><%}%>
<div class="actions">
<form method="post" action="/admin/update.jsp?subtab=plugins" class="fn-acli-check-form"><input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="checkAcli"><button type="submit">ACLI-Updates prüfen</button></form>
<form method="post" action="/admin/update.jsp?subtab=plugins" class="fn-acli-install-form"><input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="installAcli"><button type="submit" <%="true".equals(acli.getProperty("updateAvailable"))?"":"disabled"%>>ACLI aktualisieren</button></form>
</div>
<p class="hint">Aktive SSH-Sitzungen laufen unverändert weiter. Neue Sitzungen verwenden nach erfolgreicher Installation automatisch die aktualisierte ACLI-Komponente.</p>
<p class="hint fn-acli-runtime-scope">FabricNavigator aktualisiert ausschließlich die unter Linux benötigten ACLI-Terminal- und Laufzeitdateien. Strawberry Perl, Windows-GUI, XMC-Client und Dokumentation gehören nicht zur Container-Laufzeit und werden deshalb nicht aufgeführt.</p>
<script>(function(){var note=document.currentScript.previousElementSibling;if(note&&(document.documentElement.lang||'de').toLowerCase().indexOf('de')!==0)note.textContent='FabricNavigator updates only the ACLI terminal and runtime files required on Linux. Strawberry Perl, the Windows GUI, XMC client, and documentation are not part of the container runtime and are therefore not listed.';}());</script>
</section>
</div>
<script src="/assets/update-channel.js?v=20260825-147"></script></body>
</html>
