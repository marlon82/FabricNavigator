package com.fabricnavigator.firmware;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Properties;

public final class FirmwareLifecycleSettings {
    private static final Path FILE=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"firmware-lifecycle.properties");
    private FirmwareLifecycleSettings(){}

    public static final class Policy {
        public String model="",targetVersion="",minimumSourceVersion="",role="access",notes="",validatedSources="",sourceDocumentId="",sourceName="",sourceUrl="";
    }

    private static String id(String model){return Base64.getUrlEncoder().withoutPadding().encodeToString(model.trim().getBytes(StandardCharsets.UTF_8));}
    private static Properties read() throws Exception {Properties p=new Properties();if(Files.isRegularFile(FILE))try(InputStream in=Files.newInputStream(FILE)){p.load(in);}return p;}
    public static synchronized List<Policy> list() throws Exception {
        Properties p=read();List<Policy> out=new ArrayList<Policy>();
        for(String key:p.stringPropertyNames())if(key.startsWith("model.")&&key.endsWith(".name")){
            String prefix=key.substring(0,key.length()-4);Policy policy=new Policy();policy.model=p.getProperty(key,"");policy.targetVersion=p.getProperty(prefix+".target","");policy.minimumSourceVersion=p.getProperty(prefix+".minimum","");policy.role=p.getProperty(prefix+".role","access");policy.notes=p.getProperty(prefix+".notes","");policy.validatedSources=p.getProperty(prefix+".validatedSources","");policy.sourceDocumentId=p.getProperty(prefix+".sourceDocumentId","");policy.sourceName=p.getProperty(prefix+".sourceName","");policy.sourceUrl=p.getProperty(prefix+".sourceUrl","");if(policy.model.length()>0)out.add(policy);
        }
        Collections.sort(out,new Comparator<Policy>(){public int compare(Policy a,Policy b){return a.model.compareToIgnoreCase(b.model);}});return out;
    }
    public static synchronized void save(String model,String target,String minimum,String role,String notes) throws Exception {
        model=clean(model,160);target=clean(target,80);minimum=clean(minimum,80);role=clean(role,20);notes=clean(notes,600);
        if(model.length()==0||target.length()==0)throw new IllegalArgumentException("modelAndTargetRequired");
        if(!role.matches("access|distribution|core|other"))role="other";
        Properties p=read();String prefix="model."+id(model);removePrefix(p,prefix+".");p.setProperty(prefix+".name",model);p.setProperty(prefix+".target",target);p.setProperty(prefix+".minimum",minimum);p.setProperty(prefix+".role",role);p.setProperty(prefix+".notes",notes);write(p);
    }
    public static synchronized void saveDerived(String model,String target,String validatedSources,String sourceDocumentId,String sourceName,String sourceUrl) throws Exception {
        model=clean(model,160);target=clean(target,80);validatedSources=clean(validatedSources,500);sourceDocumentId=clean(sourceDocumentId,80);sourceName=clean(sourceName,180);sourceUrl=clean(sourceUrl,500);
        if(model.length()==0||target.length()==0||sourceDocumentId.length()==0)throw new IllegalArgumentException("releaseNotesPolicyIncomplete");
        Properties p=read();String prefix="model."+id(model);removePrefix(p,prefix+".");p.setProperty(prefix+".name",model);p.setProperty(prefix+".target",target);p.setProperty(prefix+".minimum","");p.setProperty(prefix+".role",inferRole(model));p.setProperty(prefix+".notes","Validated upgrade paths imported from "+sourceName);p.setProperty(prefix+".validatedSources",validatedSources);p.setProperty(prefix+".sourceDocumentId",sourceDocumentId);p.setProperty(prefix+".sourceName",sourceName);p.setProperty(prefix+".sourceUrl",sourceUrl);write(p);
    }
    public static synchronized void delete(String model) throws Exception {Properties p=read();removePrefix(p,"model."+id(clean(model,160))+".");write(p);}
    public static synchronized void deleteBySource(String sourceDocumentId) throws Exception {Properties p=read();List<String> prefixes=new ArrayList<String>();for(String key:p.stringPropertyNames())if(key.endsWith(".sourceDocumentId")&&sourceDocumentId.equals(p.getProperty(key)))prefixes.add(key.substring(0,key.length()-".sourceDocumentId".length())+".");for(String prefix:prefixes)removePrefix(p,prefix);write(p);}
    private static void removePrefix(Properties p,String prefix){List<String> keys=new ArrayList<String>(p.stringPropertyNames());for(String key:keys)if(key.startsWith(prefix))p.remove(key);}
    private static String inferRole(String model){String value=model.toLowerCase();if(value.matches(".*(?:7720|7400|8600).*"))return "core";if(value.matches(".*(?:7520|5520|5720|4900).*"))return "distribution";return "access";}
    private static String clean(String value,int max){String out=value==null?"":value.trim().replace('\r',' ').replace('\n',' ');return out.length()>max?out.substring(0,max):out;}
    private static void write(Properties p) throws Exception {
        Files.createDirectories(FILE.getParent());Path tmp=Files.createTempFile(FILE.getParent(),"firmware-lifecycle.",".tmp");
        try{try(OutputStream out=Files.newOutputStream(tmp)){p.store(out,"FabricNavigator firmware lifecycle policies");}try{Files.move(tmp,FILE,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException ex){Files.move(tmp,FILE,StandardCopyOption.REPLACE_EXISTING);}try{Files.setPosixFilePermissions(FILE,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}}finally{Files.deleteIfExists(tmp);}
    }
}
