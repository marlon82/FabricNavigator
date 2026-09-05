<%@ page import="java.io.*,java.nio.charset.StandardCharsets,java.nio.file.*,java.util.*,com.fabricnavigator.security.EdmSecurity" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static String json(String value){if(value==null)return "";StringBuilder out=new StringBuilder(value.length()+16);for(int i=0;i<value.length();i++){char c=value.charAt(i);if(c=='"'||c=='\\')out.append('\\').append(c);else if(c=='\n')out.append("\\n");else if(c=='\r')out.append("\\r");else if(c=='\t')out.append("\\t");else if(c<32)out.append(String.format("\\u%04x",(int)c));else out.append(c);}return out.toString();}
private static String safeUser(String value){return value==null?"":value.replaceAll("[^A-Za-z0-9._-]","_");}
%><%
response.setHeader("Cache-Control","no-store");request.setCharacterEncoding("UTF-8");
String user=EdmSecurity.currentUser(request);if(user==null||user.length()==0){response.setStatus(401);out.print("{\"error\":\"authentication required\"}");return;}
Path directory=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"user-preferences");Path target=directory.resolve(safeUser(user)+".json");
if("GET".equalsIgnoreCase(request.getMethod())){String settings="{}";boolean exists=Files.isRegularFile(target);if(exists){byte[] bytes=Files.readAllBytes(target);if(bytes.length<=2097152)settings=new String(bytes,StandardCharsets.UTF_8);}out.print("{\"csrf\":\""+json(EdmSecurity.csrf(session))+"\",\"exists\":"+exists+",\"settings\":"+settings+"}");return;}
if(!"POST".equalsIgnoreCase(request.getMethod())){response.setStatus(405);out.print("{\"error\":\"method not allowed\"}");return;}
if(!EdmSecurity.validCsrf(request)){response.setStatus(403);out.print("{\"error\":\"invalid session\"}");return;}
String settings=request.getParameter("settings");if(settings==null)settings="{}";String trimmed=settings.trim();if(settings.getBytes(StandardCharsets.UTF_8).length>2097152||!trimmed.startsWith("{")||!trimmed.endsWith("}")){response.setStatus(400);out.print("{\"error\":\"invalid settings\"}");return;}
Files.createDirectories(directory);Path temporary=Files.createTempFile(directory,safeUser(user)+"-",".tmp");try{Files.write(temporary,settings.getBytes(StandardCharsets.UTF_8),StandardOpenOption.TRUNCATE_EXISTING);try{Files.move(temporary,target,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}catch(AtomicMoveNotSupportedException ignored){Files.move(temporary,target,StandardCopyOption.REPLACE_EXISTING);}}finally{Files.deleteIfExists(temporary);}
out.print("{\"saved\":true}");
%>
