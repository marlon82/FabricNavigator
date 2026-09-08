<%@ page import="com.fabricnavigator.features.FeatureFlags,com.fabricnavigator.security.EdmSecurity,com.fabricnavigator.backup.ConfigurationBackupScheduler" %><%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" %><%
response.setHeader("Cache-Control","no-store");
if(!EdmSecurity.isAdmin(request)){response.sendError(403);return;}
out.print("{\"configurationBackup\":"+FeatureFlags.configurationBackupEnabled()+",\"firmwareLifecycle\":"+FeatureFlags.firmwareLifecycleEnabled()+",\"backupParallelism\":"+ConfigurationBackupScheduler.parallelism()+"}");
%>
