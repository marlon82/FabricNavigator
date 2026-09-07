<%@ page import="com.fabricnavigator.security.EdmSecurity" %><%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String firstForwarded(String value){if(value==null)return"";int comma=value.indexOf(',');return(comma<0?value:value.substring(0,comma)).trim();}
private static boolean sameOriginLogin(javax.servlet.http.HttpServletRequest request){
 String site=request.getHeader("Sec-Fetch-Site");if("same-origin".equalsIgnoreCase(site))return true;
 String origin=request.getHeader("Origin");if(origin==null||origin.trim().length()==0||"null".equalsIgnoreCase(origin.trim()))return false;
 String scheme=firstForwarded(request.getHeader("X-Forwarded-Proto"));if(scheme.length()==0)scheme=request.getScheme();
 String host=firstForwarded(request.getHeader("X-Forwarded-Host"));if(host.length()==0)host=request.getHeader("Host");
 return host!=null&&origin.trim().equalsIgnoreCase(scheme+"://"+host.trim());
}
%><%
response.setHeader("Cache-Control","no-store");
String error="",next=request.getParameter("next");if(next==null||!next.startsWith("/")||next.startsWith("//"))next="/";
String csrf=EdmSecurity.csrf(session);
if("POST".equalsIgnoreCase(request.getMethod())){
 // A container replacement invalidates the server-side session while the update
 // screen may already have rendered this login form. In that case accept the
 // stale form token only for a browser-confirmed same-origin submission.
 if(!EdmSecurity.validCsrf(request)&&!sameOriginLogin(request)){response.setStatus(403);error="Die Sitzung ist abgelaufen. Bitte erneut versuchen.";}
 else {String username=request.getParameter("username"),password=request.getParameter("password");
  try{EdmSecurity.User user=EdmSecurity.login(username,password,com.fabricnavigator.web.ClientAddress.of(request));if(user==null){Thread.sleep(350);error=EdmSecurity.isLoginBlocked(username,com.fabricnavigator.web.ClientAddress.of(request))?"Zu viele Fehlversuche. Anmeldung vorübergehend gesperrt.":"Benutzername oder Passwort ist ungültig.";}else{request.changeSessionId();session.setMaxInactiveInterval(1800);session.setAttribute("edm.auth.user",user.username);session.setAttribute("edm.auth.role",user.role);EdmSecurity.setAuthCookie(response,EdmSecurity.createAuthToken(user.username));response.sendRedirect(next);return;}}
  catch(Exception ex){response.setStatus(500);error="Die Anmeldung ist momentan nicht verfügbar.";}
 }
}
%><!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Anmeldung · FabricNavigator</title><script>(function(){if(window.top!==window.self){var destination='/';try{destination=window.top.location.pathname+window.top.location.search+window.top.location.hash;if(window.top.fnAllowTopologyUnload)window.top.fnAllowTopologyUnload();}catch(ignored){}window.top.location.replace('/login.jsp?next='+encodeURIComponent(destination));return;}try{document.documentElement.setAttribute("data-theme",localStorage.getItem("edmTheme")||((window.matchMedia&&matchMedia("(prefers-color-scheme: dark)").matches)?"dark":"light"));}catch(e){document.documentElement.setAttribute("data-theme","light");}}());</script><link rel="icon" type="image/png" href="/assets/FabricNavigator_modern_favicon.png"><link rel="stylesheet" href="/assets/security.css?v=20260825-146"></head><body class="auth-page"><main class="auth-card"><img src="/assets/FabricNavigator_modern_schwarz.png" alt="FabricNavigator" class="auth-logo auth-logo-light"><img src="/assets/FabricNavigator_modern.png" alt="FabricNavigator" class="auth-logo auth-logo-dark"><h1>Anmelden</h1><p class="muted">Lokale, geschützte Anmeldung für Topologie, Geräteverwaltung und Webterminal.</p><%if(error.length()>0){%><div class="alert error" role="alert"><%=error%></div><%}%><form method="post" autocomplete="on"><input type="hidden" name="csrfToken" value="<%=csrf%>"><input type="hidden" name="next" value="<%=next.replace("&","&amp;").replace("\"","&quot;")%>"><label>Benutzername<input name="username" required maxlength="32" autocomplete="username" autofocus></label><label>Passwort<input name="password" type="password" required maxlength="128" autocomplete="current-password"></label><button type="submit">Anmelden</button></form></main></body></html>
