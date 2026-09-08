package com.fabricnavigator.features;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Properties;

public final class FeatureFlags {
    private static final Path FILE=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"features.properties");
    private FeatureFlags(){}

    public static synchronized boolean configurationBackupEnabled(){
        return enabled("configurationBackup");
    }

    public static synchronized boolean firmwareLifecycleEnabled(){
        return enabled("firmwareLifecycle");
    }

    private static boolean enabled(String key){
        Properties values=new Properties();
        if(Files.isRegularFile(FILE))try(InputStream input=Files.newInputStream(FILE)){values.load(input);}catch(Exception ignored){}
        return Boolean.parseBoolean(values.getProperty(key,"false"));
    }

    public static synchronized void enableConfigurationBackup() throws Exception {
        setConfigurationBackupEnabled(true);
    }

    public static synchronized void disableConfigurationBackup() throws Exception {
        setConfigurationBackupEnabled(false);
    }

    public static synchronized void enableFirmwareLifecycle() throws Exception {
        setEnabled("firmwareLifecycle",true);
    }

    public static synchronized void disableFirmwareLifecycle() throws Exception {
        setEnabled("firmwareLifecycle",false);
    }

    private static void setConfigurationBackupEnabled(boolean enabled) throws Exception {
        setEnabled("configurationBackup",enabled);
    }

    private static void setEnabled(String key,boolean enabled) throws Exception {
        Properties values=new Properties();
        if(Files.isRegularFile(FILE))try(InputStream input=Files.newInputStream(FILE)){values.load(input);}
        values.setProperty(key,Boolean.toString(enabled));
        Files.createDirectories(FILE.getParent());
        Path temporary=Files.createTempFile(FILE.getParent(),"features.",".tmp");
        try{
            try(OutputStream output=Files.newOutputStream(temporary)){values.store(output,"FabricNavigator feature configuration");}
            try{Files.move(temporary,FILE,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException ex){Files.move(temporary,FILE,StandardCopyOption.REPLACE_EXISTING);}
            try{Files.setPosixFilePermissions(FILE,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}
        }finally{Files.deleteIfExists(temporary);}
    }

    public static boolean unlockConfigurationBackup(String password) throws Exception {
        String expected=System.getenv("FABRICNAVIGATOR_CONFIG_BACKUP_UNLOCK_PASSWORD");
        if(expected==null||expected.length()==0)expected="CONFIGBACKUP";
        byte[] supplied=(password==null?"":password).getBytes(StandardCharsets.UTF_8);
        byte[] required=expected.getBytes(StandardCharsets.UTF_8);
        if(!MessageDigest.isEqual(supplied,required))return false;
        enableConfigurationBackup();
        return true;
    }

    public static String unlockFeature(String password) throws Exception {
        byte[] supplied=(password==null?"":password).getBytes(StandardCharsets.UTF_8);
        String backupPassword=System.getenv("FABRICNAVIGATOR_CONFIG_BACKUP_UNLOCK_PASSWORD");
        if(backupPassword==null||backupPassword.length()==0)backupPassword="CONFIGBACKUP";
        String firmwarePassword=System.getenv("FABRICNAVIGATOR_FIRMWARE_UPDATE_UNLOCK_PASSWORD");
        if(firmwarePassword==null||firmwarePassword.length()==0)firmwarePassword="FIRMWAREUPDATE";
        if(MessageDigest.isEqual(supplied,backupPassword.getBytes(StandardCharsets.UTF_8))){enableConfigurationBackup();return "configurationBackup";}
        if(MessageDigest.isEqual(supplied,firmwarePassword.getBytes(StandardCharsets.UTF_8))){enableFirmwareLifecycle();return "firmwareLifecycle";}
        return "";
    }

    public static void requireConfigurationBackup(){
        if(!configurationBackupEnabled())throw new SecurityException("Configuration backup feature is not enabled");
    }

    public static void requireFirmwareLifecycle(){
        if(!firmwareLifecycleEnabled())throw new SecurityException("Firmware lifecycle feature is not enabled");
    }
}
