<%@ page import="com.fabricnavigator.security.EdmSecurity" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String j(String value){if(value==null)return "";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r"," ").replace("\n"," ");}
%><%
response.setHeader("Cache-Control","no-store");response.setHeader("X-Content-Type-Options","nosniff");String user=EdmSecurity.currentUser(request);
if(user==null||user.length()==0){response.setStatus(401);out.print("{\"authenticated\":false}");return;}
out.print("{\"authenticated\":true,\"user\":\""+j(user)+"\",\"role\":\""+(EdmSecurity.isAdmin(request)?"admin":"user")+"\"}");
%>
