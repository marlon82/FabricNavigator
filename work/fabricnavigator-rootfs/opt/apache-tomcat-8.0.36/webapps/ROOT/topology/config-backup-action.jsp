<%@ page import="com.fabricnavigator.backup.ConfigurationBackupScheduler,com.fabricnavigator.backup.ConfigurationBackupScheduler.Record,com.fabricnavigator.features.FeatureFlags,com.fabricnavigator.security.EdmSecurity" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String j(String value){if(value==null)return "";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r"," ").replace("\n"," ");}
%><%
response.setHeader("Cache-Control","no-store");
if(!"POST".equalsIgnoreCase(request.getMethod())){response.setStatus(405);out.print("{\"ok\":false,\"error\":\"Method not allowed\"}");return;}
if(!EdmSecurity.isAdmin(request)){response.setStatus(403);out.print("{\"ok\":false,\"error\":\"Administrator access required\"}");return;}
if(!EdmSecurity.validCsrf(request)){response.setStatus(403);out.print("{\"ok\":false,\"error\":\"Session expired\"}");return;}
if(!FeatureFlags.configurationBackupEnabled()){response.setStatus(404);out.print("{\"ok\":false,\"error\":\"Configuration backup feature is not enabled\"}");return;}
String host=request.getParameter("host");
try{
    Record record=ConfigurationBackupScheduler.capture(host,EdmSecurity.currentUser(request),"topology-context",request.getRemoteAddr());
    out.print("{\"ok\":true,\"host\":\""+j(host)+"\",\"version\":\""+j(record.id)+"\",\"platform\":\""+j(record.platform)+"\",\"capturedAt\":\""+j(record.capturedAt)+"\"}");
}catch(Exception error){
    response.setStatus(422);
    String message=error.getMessage()==null?error.getClass().getSimpleName():error.getMessage();
    out.print("{\"ok\":false,\"host\":\""+j(host)+"\",\"error\":\""+j(message)+"\"}");
}
%>
