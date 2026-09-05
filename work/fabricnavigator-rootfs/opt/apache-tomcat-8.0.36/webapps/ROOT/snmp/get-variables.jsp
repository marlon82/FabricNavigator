<%@ page contentType="text/plain; charset=UTF-8" pageEncoding="UTF-8" import="java.util.*,com.fabricnavigator.snmp.SnmpUtilV3,com.fabricnavigator.security.CredentialVault" %><%
response.setHeader("Cache-Control","no-store");
String ip=request.getParameter("ipAddr"),command=request.getParameter("command"),names=request.getParameter("varNames"),bases=request.getParameter("baseVarNames");
if(ip==null||!ip.matches("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$")){response.sendError(400,"Invalid device address");return;}
if(names==null||names.length()>1024||!("getVariables".equals(command)||"getNextVariables".equals(command))){response.sendError(400,"Invalid SNMP request");return;}
SnmpUtilV3 snmp=new SnmpUtilV3();
try{
 Properties c=CredentialVault.getSnmpForDevice(ip);String version=c.getProperty("version","v2c");
 if("v3".equals(version)){
  String level=c.getProperty("securityLevel","authPriv"),authName=c.getProperty("authProtocol","SHA"),privName=c.getProperty("privProtocol","AES");
  int auth="MD5".equals(authName)?1:"SHA".equals(authName)?2:0,priv="DES".equals(privName)?1:"AES".equals(privName)?2:"3DES".equals(privName)?3:0;
  if("noAuthNoPriv".equals(level)){auth=0;priv=0;}else if("authNoPriv".equals(level))priv=0;
  snmp.openSessionV3(ip,c.getProperty("username",""),auth,c.getProperty("v3AuthPassword",""),priv,c.getProperty("v3PrivPassword",""),c.getProperty("context",""));
 }else{snmp.setSnmpVersion("v1".equals(version)?0:1);snmp.openSession(ip,c.getProperty("roCommunity",""),c.getProperty("rwCommunity",""));}
 String[] variables=SnmpUtilV3.tokenize(names,", "),base=bases==null?new String[variables.length]:SnmpUtilV3.tokenize(bases,", ");
 if(bases==null)for(int i=0;i<variables.length;i++){int dot=variables[i].indexOf('.');base[i]=dot<0?variables[i]:variables[i].substring(0,dot);}
 String[] values;
 try{values=snmp.getAttribute(variables,"getNextVariables".equals(command));}
 catch(IllegalArgumentException unsupported){
  values=new String[variables.length];
  for(int i=0;i<variables.length;i++)try{values[i]=snmp.getAttribute(new String[]{variables[i]},"getNextVariables".equals(command))[0];}catch(IllegalArgumentException ignored){values[i]="";}
 }
 for(int i=0;i<values.length;i++)out.print("getNextVariables".equals(command)?values[i]+"\r\n":base[i]+":"+values[i]+"\r\n");
}catch(Exception error){response.setStatus(502);out.print("SNMP request failed\r\n");}
finally{snmp.closeSession();}
%>
