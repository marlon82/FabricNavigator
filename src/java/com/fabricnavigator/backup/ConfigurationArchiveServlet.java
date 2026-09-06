package com.fabricnavigator.backup;

import com.fabricnavigator.security.EdmSecurity;
import com.fabricnavigator.features.FeatureFlags;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

public final class ConfigurationArchiveServlet extends HttpServlet {
    private static final long serialVersionUID=1L;
    protected void doGet(HttpServletRequest request,HttpServletResponse response) throws ServletException,IOException {
        if(!EdmSecurity.isAdmin(request)){response.sendError(HttpServletResponse.SC_FORBIDDEN);return;}
        if(!FeatureFlags.configurationBackupEnabled()){response.sendError(HttpServletResponse.SC_NOT_FOUND);return;}
        String device=request.getParameter("device"),id=request.getParameter("version");
        try{
            ConfigurationBackupScheduler.Record record=ConfigurationBackupScheduler.find(device,id);
            if(record.archive==null||!Files.isRegularFile(record.archive)){response.sendError(HttpServletResponse.SC_NOT_FOUND);return;}
            response.reset();response.setHeader("Cache-Control","no-store");response.setContentType("application/gzip");
            response.setHeader("Content-Disposition","attachment; filename=\"FabricNavigator-"+device+"-"+id+".tgz\"");response.setContentLengthLong(Files.size(record.archive));
            try(InputStream input=Files.newInputStream(record.archive)){byte[] buffer=new byte[16384];int read;while((read=input.read(buffer))>=0)response.getOutputStream().write(buffer,0,read);}
        }catch(IllegalArgumentException ex){response.sendError(HttpServletResponse.SC_BAD_REQUEST);}catch(Exception ex){response.sendError(HttpServletResponse.SC_NOT_FOUND);}
    }
}
