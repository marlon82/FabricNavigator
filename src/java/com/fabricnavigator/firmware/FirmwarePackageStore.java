package com.fabricnavigator.firmware;

import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;

public final class FirmwarePackageStore {
    private static final Path ROOT=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"firmware-packages");
    private static final long MAX_SIZE=1024L*1024L*1024L;
    private FirmwarePackageStore(){}
    public static final class Package {public String id="",fileName="",model="",version="",platform="",activation="",compatibleModels="",architecture="",inspectionSource="",sha256="",uploadedAt="",uploadedBy="";public long size;public Path file;}
    public static synchronized Package store(InputStream input,String originalName,String actor) throws Exception {
        String fileName=fileName(originalName);
        if(!fileName.toLowerCase(Locale.ENGLISH).matches(".*\\.(?:voss|xos|xmod)$"))throw new IllegalArgumentException("Unsupported firmware file extension. Upload a .voss, .xos, or .xmod image.");
        Files.createDirectories(ROOT);secure(ROOT);String id=System.currentTimeMillis()+"-"+UUID.randomUUID().toString().substring(0,8);Path directory=ROOT.resolve(id);Files.createDirectory(directory);secure(directory);Path target=directory.resolve(fileName),temporary=directory.resolve(fileName+".part");MessageDigest digest=MessageDigest.getInstance("SHA-256");long size=0;byte[] buffer=new byte[65536];
        try {
            try(OutputStream output=Files.newOutputStream(temporary,StandardOpenOption.CREATE_NEW)){int read;while((read=input.read(buffer))>=0){if(read==0)continue;size+=read;if(size>MAX_SIZE)throw new IOException("Firmware file exceeds 1 GiB");digest.update(buffer,0,read);output.write(buffer,0,read);}}
            if(size<1024)throw new IOException("Firmware file is unexpectedly small");Files.move(temporary,target,StandardCopyOption.ATOMIC_MOVE);try{Files.setPosixFilePermissions(target,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}
            FirmwarePackageInspector.Result detected=FirmwarePackageInspector.inspect(target,fileName);
            Properties meta=new Properties();meta.setProperty("id",id);meta.setProperty("fileName",fileName);meta.setProperty("model",detected.model);meta.setProperty("version",detected.version);meta.setProperty("platform",detected.platform);meta.setProperty("activation",detected.activation);meta.setProperty("compatibleModels",detected.compatibleModels);meta.setProperty("architecture",detected.architecture);meta.setProperty("inspectionSource",detected.source);meta.setProperty("sha256",hex(digest.digest()));meta.setProperty("size",Long.toString(size));meta.setProperty("uploadedAt",Instant.now().toString());meta.setProperty("uploadedBy",clean(actor,80));write(directory.resolve("package.properties"),meta);return get(id);
        } catch(Exception ex) {
            cleanup(directory);
            throw ex;
        }
    }
    public static synchronized List<Package> list() throws Exception {List<Package> out=new ArrayList<Package>();if(!Files.isDirectory(ROOT))return out;try(DirectoryStream<Path> stream=Files.newDirectoryStream(ROOT)){for(Path directory:stream)if(Files.isDirectory(directory))try{out.add(read(directory));}catch(Exception ignored){}}Collections.sort(out,new Comparator<Package>(){public int compare(Package a,Package b){return b.uploadedAt.compareTo(a.uploadedAt);}});return out;}
    public static synchronized Package get(String id) throws Exception {if(id==null||!id.matches("[0-9]{10,}-[a-f0-9]{8}"))throw new IllegalArgumentException("Invalid firmware package ID");return read(ROOT.resolve(id));}
    public static synchronized void delete(String id) throws Exception {Package p=get(id);Files.deleteIfExists(p.file);Files.deleteIfExists(ROOT.resolve(id).resolve("package.properties"));Files.deleteIfExists(ROOT.resolve(id));}
    private static Package read(Path directory) throws Exception {Properties p=new Properties();try(InputStream input=Files.newInputStream(directory.resolve("package.properties"))){p.load(input);}Package value=new Package();value.id=p.getProperty("id","");value.fileName=p.getProperty("fileName","");value.model=p.getProperty("model","");value.version=p.getProperty("version","");value.platform=p.getProperty("platform","");value.activation=p.getProperty("activation","");value.compatibleModels=p.getProperty("compatibleModels",value.model);value.architecture=p.getProperty("architecture","");value.inspectionSource=p.getProperty("inspectionSource","");value.sha256=p.getProperty("sha256","");value.size=Long.parseLong(p.getProperty("size","0"));value.uploadedAt=p.getProperty("uploadedAt","");value.uploadedBy=p.getProperty("uploadedBy","");value.file=directory.resolve(value.fileName);if(!Files.isRegularFile(value.file)||Files.size(value.file)!=value.size)throw new IOException("Firmware package is incomplete");return value;}
    private static void write(Path file,Properties values) throws Exception {try(OutputStream out=Files.newOutputStream(file,StandardOpenOption.CREATE_NEW)){values.store(out,"FabricNavigator firmware package metadata");}try{Files.setPosixFilePermissions(file,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}}
    private static void secure(Path path){try{Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rwx------"));}catch(Exception ignored){}}
    private static void cleanup(Path directory){try{if(!Files.isDirectory(directory))return;try(DirectoryStream<Path> stream=Files.newDirectoryStream(directory)){for(Path file:stream)Files.deleteIfExists(file);}Files.deleteIfExists(directory);}catch(Exception ignored){}}
    private static String fileName(String value){String name=Paths.get(value==null?"firmware.bin":value).getFileName().toString().replaceAll("[^A-Za-z0-9._-]","_");if(name.length()>180)name=name.substring(name.length()-180);return name.length()==0?"firmware.bin":name;}
    private static String clean(String value,int max){String out=value==null?"":value.trim().replace('\r',' ').replace('\n',' ');return out.length()>max?out.substring(0,max):out;}
    private static String hex(byte[] bytes){StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format("%02x",b&255));return out.toString();}
}
