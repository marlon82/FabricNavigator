package com.fabricnavigator.firmware;

import com.fabricnavigator.features.FeatureFlags;
import com.fabricnavigator.security.AuditLog;
import com.fabricnavigator.security.EdmSecurity;
import com.fabricnavigator.web.ClientAddress;
import java.io.*;
import java.util.*;
import javax.servlet.annotation.MultipartConfig;
import javax.servlet.http.*;

@MultipartConfig(fileSizeThreshold=1048576,maxFileSize=1073741824L,maxRequestSize=1074790400L)
public final class FirmwareManagementServlet extends HttpServlet {
    private static final long serialVersionUID = 1L;
    protected void doGet(HttpServletRequest request,HttpServletResponse response)throws IOException {handle(request,response);}
    protected void doPost(HttpServletRequest request,HttpServletResponse response)throws IOException {handle(request,response);}
    private void handle(HttpServletRequest request,HttpServletResponse response)throws IOException {
        response.setHeader("Cache-Control","no-store");
        response.setContentType("application/json; charset=UTF-8");
        if(!EdmSecurity.isAdmin(request)){response.setStatus(403);write(response,"{\"ok\":false,\"error\":\"forbidden\"}");return;}if(!FeatureFlags.firmwareLifecycleEnabled()){response.setStatus(404);write(response,"{\"ok\":false,\"error\":\"featureDisabled\"}");return;}
        String action=request.getParameter("action");if(action==null)action="status";
        if("downloadReleaseNotes".equals(action)){try{FirmwareReleaseNotesStore.Document d=FirmwareReleaseNotesStore.get(request.getParameter("documentId"));response.setContentType("application/pdf");response.setHeader("Content-Disposition","attachment; filename=\""+d.fileName.replace("\"","")+"\"");response.setContentLengthLong(d.size);try(InputStream input=new BufferedInputStream(new FileInputStream(d.file.toFile()));OutputStream output=response.getOutputStream()){byte[] buffer=new byte[65536];int n;while((n=input.read(buffer))>=0)if(n>0)output.write(buffer,0,n);}}catch(Exception ex){response.sendError(404);}return;}
        if("status".equals(action)){FirmwareDeploymentManager.Status s=FirmwareDeploymentManager.status();StringBuilder out=new StringBuilder("{\"ok\":true,\"state\":\"").append(j(s.state)).append("\",\"message\":\"").append(j(s.message)).append("\",\"currentDevice\":\"").append(j(s.currentDevice)).append("\",\"completed\":").append(s.completed).append(",\"total\":").append(s.total).append(",\"failed\":").append(s.failed).append(",\"results\":[");for(int i=0;i<s.results.size();i++){if(i>0)out.append(',');out.append('"').append(j(s.results.get(i))).append('"');}out.append("]}");write(response,out.toString());return;}
        if(!"POST".equalsIgnoreCase(request.getMethod())||!EdmSecurity.validCsrf(request)){response.setStatus(403);write(response,"{\"ok\":false,\"error\":\"invalidSession\"}");return;}
        try{
            String actor=EdmSecurity.currentUser(request),remote=ClientAddress.of(request);
            if("upload".equals(action)){Part part=request.getPart("firmwareFile");if(part==null||part.getSize()==0)throw new IllegalArgumentException("Firmware file is required");FirmwarePackageStore.Package p;try(InputStream input=part.getInputStream()){p=FirmwarePackageStore.store(input,part.getSubmittedFileName(),actor);}AuditLog.log(actor,"FIRMWARE_PACKAGE_UPLOADED","package="+p.id+" · file="+p.fileName+" · detectedModel="+p.model+" · compatibleModels="+p.compatibleModels+" · version="+p.version+" · platform="+p.platform+" · metadata="+p.inspectionSource+" · size="+p.size+" · sha256="+p.sha256,remote);write(response,"{\"ok\":true,\"packageId\":\""+j(p.id)+"\",\"sha256\":\""+j(p.sha256)+"\",\"model\":\""+j(p.model)+"\",\"version\":\""+j(p.version)+"\",\"platform\":\""+j(p.platform)+"\",\"activation\":\""+j(p.activation)+"\",\"compatibleModels\":\""+j(p.compatibleModels)+"\",\"metadataSource\":\""+j(p.inspectionSource)+"\"}");return;}
            if("uploadReleaseNotes".equals(action)){Part part=request.getPart("releaseNotesFile");if(part==null||part.getSize()==0)throw new IllegalArgumentException("Release-notes PDF is required");FirmwareReleaseNotesStore.Document d;try(InputStream input=part.getInputStream()){d=FirmwareReleaseNotesStore.store(input,part.getSubmittedFileName(),actor,request.getParameter("sourceUrl"));}AuditLog.log(actor,"FIRMWARE_RELEASE_NOTES_IMPORTED","document="+d.id+" · file="+d.fileName+" · product="+d.product+" · release="+d.releaseVersion+" · sources="+d.validatedSources+" · models="+d.models+" · status="+d.status+" · sha256="+d.sha256,remote);write(response,"{\"ok\":true,\"documentId\":\""+j(d.id)+"\",\"release\":\""+j(d.releaseVersion)+"\",\"status\":\""+j(d.status)+"\",\"message\":\""+j(d.message)+"\"}");return;}
            if("applyReleaseNotes".equals(action)){String id=request.getParameter("documentId");int count=FirmwareReleaseNotesStore.apply(id);AuditLog.log(actor,"FIRMWARE_RELEASE_NOTES_POLICIES_APPLIED","document="+id+" · policies="+count,remote);write(response,"{\"ok\":true,\"policies\":"+count+"}");return;}
            if("deleteReleaseNotes".equals(action)){String id=request.getParameter("documentId");FirmwareReleaseNotesStore.Document d=FirmwareReleaseNotesStore.get(id);FirmwareReleaseNotesStore.delete(id);AuditLog.log(actor,"FIRMWARE_RELEASE_NOTES_DELETED","document="+id+" · file="+d.fileName+" · derivedPoliciesRemoved=true",remote);write(response,"{\"ok\":true}");return;}
            if("delete".equals(action)){FirmwarePackageStore.Package p=FirmwarePackageStore.get(request.getParameter("packageId"));FirmwarePackageStore.delete(p.id);AuditLog.log(actor,"FIRMWARE_PACKAGE_DELETED","package="+p.id+" · file="+p.fileName+" · sha256="+p.sha256,remote);write(response,"{\"ok\":true}");return;}
            if("start".equals(action)){String[] values=request.getParameterValues("device");boolean started=FirmwareDeploymentManager.start(request.getParameter("packageId"),values==null?Collections.<String>emptyList():Arrays.asList(values),"true".equals(request.getParameter("reboot")),actor,remote);if(!started){response.setStatus(409);write(response,"{\"ok\":false,\"error\":\"deploymentAlreadyRunning\"}");}else write(response,"{\"ok\":true}");return;}
            response.setStatus(400);write(response,"{\"ok\":false,\"error\":\"unknownAction\"}");
        }catch(Exception ex){getServletContext().log("Firmware management operation failed",ex);response.setStatus(400);write(response,"{\"ok\":false,\"error\":\""+j(ex.getMessage()==null?ex.getClass().getSimpleName():ex.getMessage())+"\"}");}
    }
    private static void write(HttpServletResponse response,String value)throws IOException{response.getWriter().write(value);}
    private static String j(String value){if(value==null)return "";return value.replace("\\","\\\\").replace("\"","\\\"").replace("\r"," ").replace("\n"," ").replace("<","\\u003c");}
}
