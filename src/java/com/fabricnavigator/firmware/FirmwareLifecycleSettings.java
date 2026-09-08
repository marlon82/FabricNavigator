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
        public String model="",targetVersion="",minimumSourceVersion="",role="access",notes="";
    }

    private static String id(String model){return Base64.getUrlEncoder().withoutPadding().encodeToString(model.trim().getBytes(StandardCharsets.UTF_8));}
    private static Properties read() throws Exception {Properties p=new Properties();if(Files.isRegularFile(FILE))try(InputStream in=Files.newInputStream(FILE)){p.load(in);}return p;}
    public static synchronized List<Policy> list() throws Exception {
        Properties p=read();List<Policy> out=new ArrayList<Policy>();
        for(String key:p.stringPropertyNames())if(key.startsWith("model.")&&key.endsWith(".name")){
            String prefix=key.substring(0,key.length()-4);Policy policy=new Policy();policy.model=p.getProperty(key,"");policy.targetVersion=p.getProperty(prefix+".target","");policy.minimumSourceVersion=p.getProperty(prefix+".minimum","");policy.role=p.getProperty(prefix+".role","access");policy.notes=p.getProperty(prefix+".notes","");if(policy.model.length()>0)out.add(policy);
        }
        Collections.sort(out,new Comparator<Policy>(){public int compare(Policy a,Policy b){return a.model.compareToIgnoreCase(b.model);}});return out;
    }
    public static synchronized void save(String model,String target,String minimum,String role,String notes) throws Exception {
        model=clean(model,160);target=clean(target,80);minimum=clean(minimum,80);role=clean(role,20);notes=clean(notes,600);
        if(model.length()==0||target.length()==0)throw new IllegalArgumentException("modelAndTargetRequired");
        if(!role.matches("access|distribution|core|other"))role="other";
        Properties p=read();String prefix="model."+id(model);p.setProperty(prefix+".name",model);p.setProperty(prefix+".target",target);p.setProperty(prefix+".minimum",minimum);p.setProperty(prefix+".role",role);p.setProperty(prefix+".notes",notes);write(p);
    }
    public static synchronized void delete(String model) throws Exception {Properties p=read();String prefix="model."+id(clean(model,160))+".";List<String> keys=new ArrayList<String>(p.stringPropertyNames());for(String key:keys)if(key.startsWith(prefix))p.remove(key);write(p);}
    private static String clean(String value,int max){String out=value==null?"":value.trim().replace('\r',' ').replace('\n',' ');return out.length()>max?out.substring(0,max):out;}
    private static void write(Properties p) throws Exception {
        Files.createDirectories(FILE.getParent());Path tmp=Files.createTempFile(FILE.getParent(),"firmware-lifecycle.",".tmp");
        try{try(OutputStream out=Files.newOutputStream(tmp)){p.store(out,"FabricNavigator firmware lifecycle policies");}try{Files.move(tmp,FILE,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException ex){Files.move(tmp,FILE,StandardCopyOption.REPLACE_EXISTING);}try{Files.setPosixFilePermissions(FILE,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}}finally{Files.deleteIfExists(tmp);}
    }
}
