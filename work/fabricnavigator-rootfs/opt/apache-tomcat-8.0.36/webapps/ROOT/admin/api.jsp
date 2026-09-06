<%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %>
<%@ page import="java.text.SimpleDateFormat,java.util.Date,com.fabricnavigator.api.FabricNavigatorApiToken,com.fabricnavigator.security.AuditLog,com.fabricnavigator.security.EdmSecurity" %>
<%!
private static String h(String value) {
    if (value == null) return "";
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&#39;");
}
%>
<%
response.setHeader("Cache-Control", "no-store");
if (!EdmSecurity.isAdmin(request)) {
    response.sendError(403);
    return;
}
String csrf = EdmSecurity.csrf(session);
String flash = "";
String error = "";
String token = (String) session.getAttribute("fabricnavigator.api.token");
session.removeAttribute("fabricnavigator.api.token");

if ("POST".equalsIgnoreCase(request.getMethod())) {
    if (!EdmSecurity.validCsrf(request)) {
        response.sendError(403);
        return;
    }
    String action = request.getParameter("action");
    try {
        if ("generate".equals(action)) {
            String label = request.getParameter("label");
            token = FabricNavigatorApiToken.generate(label);
            AuditLog.log(EdmSecurity.currentUser(request), "FABRICNAVIGATOR_API_TOKEN_CREATE",
                "label=" + FabricNavigatorApiToken.label(), request.getRemoteAddr());
            flash = "API-Token wurde erstellt. Kopiere ihn jetzt; er wird nicht erneut angezeigt.";
        } else if ("revoke".equals(action)) {
            String oldLabel = FabricNavigatorApiToken.label();
            FabricNavigatorApiToken.revoke();
            AuditLog.log(EdmSecurity.currentUser(request), "FABRICNAVIGATOR_API_TOKEN_REVOKE",
                "label=" + oldLabel, request.getRemoteAddr());
            flash = "API-Token wurde widerrufen.";
        } else {
            throw new IllegalArgumentException("invalidAction");
        }
    } catch (Exception ex) {
        application.log("FabricNavigator API token operation failed", ex);
        error = "Die API-Einstellung konnte nicht gespeichert werden.";
    }
}

boolean configured = FabricNavigatorApiToken.isConfigured();
String created = "&mdash;";
if (configured && FabricNavigatorApiToken.createdAt() > 0) {
    created = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date(FabricNavigatorApiToken.createdAt()));
}
%>
<!doctype html>
<html lang="de" class="fn-shell-loading">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>API &middot; FabricNavigator</title>
  <script>(function(){try{document.documentElement.setAttribute('data-theme',parent.document.documentElement.getAttribute('data-theme')||localStorage.getItem('edmTheme')||'light');document.documentElement.lang=parent.document.documentElement.lang||'de';}catch(e){}})();</script>
  <link rel="stylesheet" href="/assets/security.css">
  <link rel="stylesheet" href="/assets/app-shell.css?v=20260906-242">
  <style>
    html,body{background:transparent!important}body{margin:0;padding:2px}.fn-api-grid{display:grid;gap:18px}
    .fn-api-card{background:var(--fn-panel);border:1px solid var(--fn-border);border-top:4px solid var(--fn-accent);border-radius:14px;padding:22px;color:var(--fn-text)}
    .fn-api-status{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:16px 0}.fn-api-status div{padding:12px;border:1px solid var(--fn-border);border-radius:10px;background:color-mix(in srgb,var(--fn-accent) 5%,var(--fn-panel))}
    .fn-api-status small{display:block;color:var(--fn-muted);margin-bottom:5px}.fn-api-note{background:color-mix(in srgb,var(--fn-accent) 10%,var(--fn-panel));border-left:4px solid var(--fn-accent);padding:12px;border-radius:8px;color:var(--fn-text)}
    .fn-token{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px;align-items:center}.fn-token code{padding:12px;border:1px solid var(--fn-border);border-radius:9px;overflow-wrap:anywhere;background:var(--fn-bg);color:var(--fn-text)}
    label{display:grid;gap:7px}input{border:1px solid var(--fn-border);border-radius:9px;padding:10px;background:var(--fn-panel);color:var(--fn-text)}.actions{display:flex;gap:9px;flex-wrap:wrap;margin-top:14px}.danger{background:#a4262c}
    .alert{padding:12px;border-radius:9px;margin-bottom:14px}.success{background:#e8f8ee;color:#176b36}.error{background:#fdecec;color:#8d1f25}@media(max-width:700px){.fn-api-status{grid-template-columns:1fr}.fn-token{grid-template-columns:1fr}}
  </style>
</head>
<body>
<% if (flash.length() > 0) { %><div class="alert success"><%=h(flash)%></div><% } %>
<% if (error.length() > 0) { %><div class="alert error"><%=h(error)%></div><% } %>
<main class="fn-api-grid">
  <section class="fn-api-card">
    <h2>FabricNavigator API</h2>
    <p class="fn-api-note"
       data-de="Die schreibgeschützte API exportiert verwaltete Geräte und ihre zugewiesenen SSH-Zugangsdaten an autorisierte Clients, beispielsweise den ACLI Session Manager. Token und Geheimnisse dürfen niemals in Protokolle oder URLs geschrieben werden."
       data-en="The read-only API exports managed devices and their assigned SSH credentials to authorized clients such as ACLI Session Manager. Never put tokens or secrets in logs or URLs.">
       Die schreibgeschützte API exportiert Geräte und zugewiesene SSH-Zugangsdaten.
    </p>
    <div class="fn-api-status">
      <div><small data-de="Status" data-en="Status">Status</small><strong data-de="<%=configured ? "Konfiguriert" : "Nicht konfiguriert"%>" data-en="<%=configured ? "Configured" : "Not configured"%>"><%=configured ? "Konfiguriert" : "Nicht konfiguriert"%></strong></div>
      <div><small data-de="Bezeichnung" data-en="Label">Bezeichnung</small><strong><%=configured ? h(FabricNavigatorApiToken.label()) : "&mdash;"%></strong></div>
      <div><small data-de="Erstellt" data-en="Created">Erstellt</small><strong><%=created%></strong></div>
    </div>
    <label><span data-de="API-Endpunkt" data-en="API endpoint">API-Endpunkt</span><input readonly value="https://HOST:8443/api/v1/sessions"></label>
    <% if (token != null && token.length() > 0) { %>
      <h3 data-de="Neuer Token &ndash; nur jetzt sichtbar" data-en="New token &ndash; shown once">Neuer Token &ndash; nur jetzt sichtbar</h3>
      <div class="fn-token"><code id="fn-api-token"><%=h(token)%></code><button type="button" id="fn-copy-token" data-de="Kopieren" data-en="Copy">Kopieren</button></div>
    <% } %>
    <% if (!configured) { %>
      <form method="post" autocomplete="off">
        <input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="generate">
        <label><span data-de="Bezeichnung" data-en="Label">Bezeichnung</span><input name="label" value="ACLI Session Manager" required maxlength="80"></label>
        <div class="actions"><button type="submit" data-de="API-Token erstellen" data-en="Create API token">API-Token erstellen</button></div>
      </form>
    <% } else { %>
      <form method="post"><input type="hidden" name="csrfToken" value="<%=h(csrf)%>"><input type="hidden" name="action" value="revoke"><div class="actions"><button class="danger" type="submit" data-de="API-Token widerrufen" data-en="Revoke API token">API-Token widerrufen</button></div></form>
    <% } %>
  </section>
  <section class="fn-api-card">
    <h2 data-de="Verwendung" data-en="Usage">Verwendung</h2>
    <pre><code>Authorization: Bearer fn_api_&hellip;&#10;Accept: application/json</code></pre>
    <p data-de="Die Antwort enthält Gerätename, IP-Adresse, SSH-Port, Plattform, Gerätetyp, sysLocation, Softwareversion und die zugewiesenen SSH-Anmeldedaten. Geräte ohne aktiviertes SSH-Profil werden nicht exportiert."
       data-en="The response includes device name, IP address, SSH port, platform, device type, sysLocation, software version, and the assigned SSH credentials. Devices without an enabled SSH profile are not exported.">
       Die Antwort enthält Geräte-, Plattform-, Standort-, Software- und SSH-Daten.
    </p>
  </section>
</main>
<script>(function(){var lang=document.documentElement.lang==='de'?'de':'en';document.querySelectorAll('[data-'+lang+']').forEach(function(node){node.textContent=node.getAttribute('data-'+lang);});var copy=document.getElementById('fn-copy-token'),token=document.getElementById('fn-api-token');if(copy&&token)copy.addEventListener('click',function(){navigator.clipboard.writeText(token.textContent).then(function(){copy.textContent=lang==='de'?'Kopiert':'Copied';});});document.documentElement.classList.remove('fn-shell-loading');}());</script>
</body>
</html>
