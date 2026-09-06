package com.fabricnavigator.features;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Properties;

public final class FeatureFlags {
    private static final Path FILE=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"features.properties");
    private FeatureFlags(){}

    public static synchronized boolean configurationBackupEnabled(){
        Properties values=new Properties();
        if(Files.isRegularFile(FILE))try(InputStream input=Files.newInputStream(FILE)){values.load(input);}catch(Exception ignored){}
        return Boolean.parseBoolean(values.getProperty("configurationBackup","false"));
    }

    public static synchronized void enableConfigurationBackup() throws Exception {
        Properties values=new Properties();
        if(Files.isRegularFile(FILE))try(InputStream input=Files.newInputStream(FILE)){values.load(input);}
        values.setProperty("configurationBackup","true");
        Files.createDirectories(FILE.getParent());
        Path temporary=Files.createTempFile(FILE.getParent(),"features.",".tmp");
        try{
            try(OutputStream output=Files.newOutputStream(temporary)){values.store(output,"FabricNavigator feature configuration");}
            try{Files.move(temporary,FILE,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException ex){Files.move(temporary,FILE,StandardCopyOption.REPLACE_EXISTING);}
            try{Files.setPosixFilePermissions(FILE,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}
        }finally{Files.deleteIfExists(temporary);}
    }

    public static void requireConfigurationBackup(){
        if(!configurationBackupEnabled())throw new SecurityException("Configuration backup feature is not enabled");
    }
}
