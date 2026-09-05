<%@ page import="java.util.concurrent.TimeUnit,java.io.*,java.nio.charset.StandardCharsets,java.util.regex.*,com.fabricnavigator.security.EdmSecurity" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String j(String value){if(value==null)return "";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r","").replace("\n","\\n");}
private static boolean ipv4(String value){if(value==null||!value.matches("^[0-9.]{7,15}$"))return false;String[] parts=value.split("\\.",-1);if(parts.length!=4)return false;for(String part:parts)try{if(part.length()==0||(part.length()>1&&part.startsWith("0")))return false;int number=Integer.parseInt(part);if(number<0||number>255)return false;}catch(Exception error){return false;}return true;}
private static String read(Process process)throws Exception{BufferedReader reader=new BufferedReader(new InputStreamReader(process.getInputStream(),StandardCharsets.UTF_8));StringBuilder text=new StringBuilder();try{String line;while((line=reader.readLine())!=null&&text.length()<8192)text.append(line).append('\n');}finally{reader.close();}return text.toString();}
%><%
response.setHeader("Cache-Control","no-store");response.setCharacterEncoding("UTF-8");
String actor=EdmSecurity.currentUser(request),host=request.getParameter("host");
if(actor==null||actor.trim().length()==0){response.sendError(403);return;}
if(!"POST".equalsIgnoreCase(request.getMethod())||!EdmSecurity.validCsrf(request)){response.sendError(403);return;}
if(!ipv4(host)){response.sendError(400);return;}
boolean reachable=false,timedOut=false;String latency="";
try{
 Process process=new ProcessBuilder("/usr/bin/ping","-n","-c","2","-W","2",host).redirectErrorStream(true).start();
 if(!process.waitFor(6,TimeUnit.SECONDS)){timedOut=true;process.destroyForcibly();}else{String output=read(process);reachable=process.exitValue()==0;Matcher match=Pattern.compile("time[=<]([0-9.]+)\\s*ms").matcher(output);if(match.find())latency=match.group(1);}
}catch(Exception error){response.setStatus(500);out.print("{\"ok\":false,\"host\":\""+j(host)+"\",\"error\":\"Ping could not be started\"}");return;}
out.print("{\"ok\":true,\"host\":\""+j(host)+"\",\"reachable\":"+reachable+",\"timedOut\":"+timedOut+",\"latencyMs\":\""+j(latency)+"\"}");
%>
