<%@ page import="java.io.*,java.nio.charset.StandardCharsets,java.nio.file.*,java.nio.file.attribute.PosixFilePermission,java.security.SecureRandom,java.util.*,com.fabricnavigator.security.EdmSecurity,com.fabricnavigator.security.CredentialVault" %>
<%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %>
<%!
private static final SecureRandom RANDOM=new SecureRandom();
private static final Path TICKETS=Paths.get("/opt/fabricnavigator/data/webview-tickets");
private static final Path ASSIGNMENTS=Paths.get("/opt/fabricnavigator/data/webview-assignments.properties");
private static final Path PROFILE_IDS=Paths.get("/opt/fabricnavigator/data/webview-profile-ids.properties");
private static String json(String value){return value.replace("\\","\\\\").replace("\"","\\\"");}
private static String token(){byte[] bytes=new byte[24];RANDOM.nextBytes(bytes);StringBuilder out=new StringBuilder();for(byte value:bytes)out.append(String.format(Locale.ROOT,"%02x",value&255));return out.toString();}
private static boolean privateIpv4(String value){try{String[] parts=value.split("\\.",-1);if(parts.length!=4)return false;int[] octets=new int[4];for(int i=0;i<4;i++){octets[i]=Integer.parseInt(parts[i]);if(octets[i]<0||octets[i]>255)return false;}return octets[0]==10||(octets[0]==172&&octets[1]>=16&&octets[1]<=31)||(octets[0]==192&&octets[1]==168)||(octets[0]==169&&octets[1]==254);}catch(Exception ignored){return false;}}
private static String b64(String value){return Base64.getEncoder().encodeToString((value==null?"":value).getBytes(StandardCharsets.UTF_8));}
private static String assignedProfile(String device){try{Properties p=new Properties(),ids=new Properties();if(Files.isRegularFile(ASSIGNMENTS))try(InputStream in=Files.newInputStream(ASSIGNMENTS)){p.load(in);}if(Files.isRegularFile(PROFILE_IDS))try(InputStream in=Files.newInputStream(PROFILE_IDS)){ids.load(in);}String id=p.getProperty(device,"");return ids.containsKey(id)?id:"";}catch(Exception ignored){return "";}}
%>
<%
response.setHeader("Cache-Control","no-store");response.setHeader("X-Content-Type-Options","nosniff");
String user=EdmSecurity.currentUser(request),device=request.getParameter("device");
if(user==null||user.length()==0){response.setStatus(401);out.print("{\"error\":\"loginRequired\"}");return;}
if(device==null||!privateIpv4(device)){response.setStatus(400);out.print("{\"error\":\"invalidDevice\"}");return;}
Files.createDirectories(TICKETS);long now=System.currentTimeMillis(),expires=now+10L*60L*1000L;
try(DirectoryStream<Path> files=Files.newDirectoryStream(TICKETS)){for(Path file:files)try{if(now-Files.getLastModifiedTime(file).toMillis()>15L*60L*1000L)Files.deleteIfExists(file);}catch(Exception ignored){}}
String username="",password="",profileId=assignedProfile(device);if(profileId.length()>0)try{Properties credential=CredentialVault.getCredential(profileId);username=credential.getProperty("username","");password=credential.getProperty("sshPassword","");}catch(Exception ignored){profileId="";username="";password="";}
String ticket=token();Path target=TICKETS.resolve(ticket),temporary=Files.createTempFile(TICKETS,"ticket.",".tmp");
try{String contents=device+"\n"+expires+"\n"+b64(username)+"\n"+b64(password)+"\n";Files.write(temporary,contents.getBytes(StandardCharsets.UTF_8));try{Files.setPosixFilePermissions(temporary,EnumSet.of(PosixFilePermission.OWNER_READ,PosixFilePermission.OWNER_WRITE));}catch(Exception ignored){}try{Files.move(temporary,target,StandardCopyOption.ATOMIC_MOVE);}catch(AtomicMoveNotSupportedException ex){Files.move(temporary,target,StandardCopyOption.REPLACE_EXISTING);}}finally{Files.deleteIfExists(temporary);}
out.print("{\"url\":\"/webview-tunnel/"+json(device)+"/login.html?ticket="+ticket+"\"}");
%>
