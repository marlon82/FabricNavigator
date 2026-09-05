<%@ page import="com.fabricnavigator.security.EdmSecurity,java.io.*,java.nio.file.*,java.util.*,java.util.regex.*" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%!
private static final File UPDATE_DIR=new File(System.getenv("FABRICNAVIGATOR_UPDATE_DIR")!=null?System.getenv("FABRICNAVIGATOR_UPDATE_DIR"):"/opt/fabricnavigator/update");
private static Properties properties(File file){Properties p=new Properties();if(!file.isFile())return p;try(InputStream in=new FileInputStream(file)){p.load(new InputStreamReader(in,"UTF-8"));}catch(Exception ignored){}return p;}
private static String jsonField(String json,String name){Matcher m=Pattern.compile("\\\""+Pattern.quote(name)+"\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"").matcher(json);return m.find()?m.group(1):"";}
private static String j(String value){if(value==null)return"";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r","").replace("\n","\\n").replace("</","<\\/");}
%><%
response.setHeader("Cache-Control","no-store");response.setCharacterEncoding("UTF-8");String actor=EdmSecurity.currentUser(request);if(actor==null||actor.trim().length()==0){response.sendError(401);return;}
Properties plugin=properties(new File(UPDATE_DIR,"plugin-status.properties"));File manifest=new File("/opt/tomcat/webapps/ROOT/assets/product-switches/plugin.json");String version="";try{if(manifest.isFile())version=jsonField(new String(Files.readAllBytes(manifest.toPath()),"UTF-8"),"version");}catch(Exception ignored){}
String state=plugin.getProperty("state",version.length()>0?"installed":"not-installed");if(version.length()==0&&"installed".equals(state))version=plugin.getProperty("version","").trim();boolean installed="installed".equals(state)&&version.length()>0;
out.print("{\"installed\":"+installed+",\"version\":\""+j(version)+"\",\"state\":\""+j(state)+"\",\"message\":\""+j(plugin.getProperty("message",""))+"\"}");
%>
