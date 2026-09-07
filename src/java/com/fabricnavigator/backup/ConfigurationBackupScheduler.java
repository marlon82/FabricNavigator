package com.fabricnavigator.backup;

import com.fabricnavigator.security.AuditLog;
import com.fabricnavigator.security.CredentialVault;
import com.fabricnavigator.security.KnownHostsManager;
import com.fabricnavigator.features.FeatureFlags;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import javax.servlet.ServletContextEvent;
import javax.servlet.ServletContextListener;

public final class ConfigurationBackupScheduler implements ServletContextListener {
    private static final Path ROOT=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"config-backups");
    private static final Path SETTINGS=ROOT.resolve("settings.properties");
    private static final Path STATUS=ROOT.resolve("status.properties");
    private static final Object LOCK=new Object();
    private static final ConcurrentMap<String,Object> DEVICE_LOCKS=new ConcurrentHashMap<String,Object>();
    private static final ExecutorService MANUAL_EXECUTOR=Executors.newSingleThreadExecutor(new ThreadFactory(){public Thread newThread(Runnable r){Thread t=new Thread(r,"fabricnavigator-manual-config-backup");t.setDaemon(true);return t;}});
    private static boolean MANUAL_RUNNING=false;
    private ScheduledExecutorService executor;

    public static final class Record {
        public String id="",device="",platform="",capturedAt="",capturedBy="",source="",changeActor="",sha256="",archiveSha256="";
        public long capturedAtMillis;
        public Path configuration,archive;
    }

    public void contextInitialized(ServletContextEvent event){
        try{secureDirectory(ROOT);}catch(Exception ignored){}
        executor=Executors.newSingleThreadScheduledExecutor(new ThreadFactory(){public Thread newThread(Runnable r){Thread t=new Thread(r,"fabricnavigator-config-backup");t.setDaemon(true);return t;}});
        executor.scheduleWithFixedDelay(new Runnable(){public void run(){scheduledRun();}},2,15,TimeUnit.MINUTES);
    }
    public void contextDestroyed(ServletContextEvent event){if(executor!=null)executor.shutdownNow();}

    public static Properties settings(){Properties p=readProperties(SETTINGS);if(!p.containsKey("enabled"))p.setProperty("enabled","false");if(!p.containsKey("intervalHours"))p.setProperty("intervalHours","24");if(!p.containsKey("retention"))p.setProperty("retention","10");if(!p.containsKey("parallelism"))p.setProperty("parallelism","3");return p;}
    public static int parallelism(){return Math.max(1,Math.min(10,parseInt(settings().getProperty("parallelism"),3)));}
    public static void saveSettings(boolean enabled,int intervalHours,int retention,int parallelism,String actor,String remote) throws Exception{
        FeatureFlags.requireConfigurationBackup();
        if(intervalHours<1||intervalHours>720||retention<1||retention>500||parallelism<1||parallelism>10)throw new IllegalArgumentException("Invalid backup settings");
        Properties p=settings();p.setProperty("enabled",Boolean.toString(enabled));p.setProperty("intervalHours",Integer.toString(intervalHours));p.setProperty("retention",Integer.toString(retention));p.setProperty("parallelism",Integer.toString(parallelism));p.setProperty("updatedAt",Instant.now().toString());p.setProperty("updatedBy",clean(actor));writeProperties(SETTINGS,p,"FabricNavigator configuration backup settings");AuditLog.log(actor,"CONFIG_BACKUP_SETTINGS","enabled="+enabled+" · interval="+intervalHours+"h · retention="+retention+" · parallelism="+parallelism,remote);
    }
    public static Properties status(){return readProperties(STATUS);}

    public static synchronized boolean startCaptureAll(final String actor,final String source,final String remote){
        FeatureFlags.requireConfigurationBackup();
        if(MANUAL_RUNNING)return false;
        MANUAL_RUNNING=true;
        writeStatus("running","Configuration backup is queued",0,0,0);
        MANUAL_EXECUTOR.submit(new Runnable(){public void run(){try{captureAll(actor,source,remote);}catch(Exception ex){writeStatus("error",safeMessage(ex),0,1,0);}finally{synchronized(ConfigurationBackupScheduler.class){MANUAL_RUNNING=false;}}}});
        return true;
    }

    private static void scheduledRun(){
        try{
            if(!FeatureFlags.configurationBackupEnabled())return;
            Properties p=settings();if(!Boolean.parseBoolean(p.getProperty("enabled")))return;
            long interval=Long.parseLong(p.getProperty("intervalHours","24"))*3600000L,last=Long.parseLong(p.getProperty("lastAutomaticAt","0"));if(System.currentTimeMillis()-last<interval)return;
            p.setProperty("lastAutomaticAt",Long.toString(System.currentTimeMillis()));writeProperties(SETTINGS,p,"FabricNavigator configuration backup settings");captureAll("system","scheduled","127.0.0.1");
        }catch(Exception ex){writeStatus("error",ex.getMessage(),0,1);}
    }

    public static int[] captureAll(String actor,String source,String remote) throws Exception{
        FeatureFlags.requireConfigurationBackup();
        int ok=0,failed=0;List<String> devices=new ArrayList<String>();
        for(String device:new TreeSet<String>(CredentialVault.listAssignedDevices())){String sshId=CredentialVault.getDeviceCredentialId(device,CredentialVault.TYPE_SSH);if(sshId!=null&&sshId.length()>0)devices.add(device);}
        writeStatus("running","Configuration backup is running",0,0,devices.size());
        ExecutorService workers=Executors.newFixedThreadPool(Math.min(parallelism(),Math.max(1,devices.size())));CompletionService<Boolean> completed=new ExecutorCompletionService<Boolean>(workers);
        for(final String device:devices)completed.submit(new Callable<Boolean>(){public Boolean call(){try{capture(device,actor,source,remote);return Boolean.TRUE;}catch(Exception ex){try{AuditLog.log(actor,"FAILED_CONFIG_BACKUP",device+" · "+safeMessage(ex),remote);}catch(Exception ignored){}return Boolean.FALSE;}}});
        try{for(int index=0;index<devices.size();index++){if(Boolean.TRUE.equals(completed.take().get()))ok++;else failed++;writeStatus("running","Configuration backup is running",ok,failed,devices.size());}}finally{workers.shutdownNow();}
        writeStatus(failed>0?"warning":"success",ok+" device(s) backed up · "+failed+" failed",ok,failed,devices.size());return new int[]{ok,failed};
    }

    public static Record capture(String device,String actor,String source,String remote) throws Exception{
        FeatureFlags.requireConfigurationBackup();
        validateDevice(device);synchronized(deviceLock(device)){
            Properties credential=CredentialVault.getSshForDevice(device);int port=parseInt(credential.getProperty("port"),22);
            String approved=KnownHostsManager.approvedFingerprint(device,port);if(approved==null||approved.length()==0)throw new SecurityException("SSH host key is not approved");
            KnownHostsManager.Pending pending=scanHostKey(device,port);if(!approved.equals(pending.fingerprint))throw new SecurityException("SSH host key changed");
            ProcessResult result=run(device,credential,"backup","","",new byte[0]);if(result.code!=0)throw new IOException(result.error());
            int marker=result.output.indexOf("FN_CONFIG_BEGIN\n");if(marker<0)throw new IOException("Invalid configuration response");
            String first=result.output.substring(0,marker),platform=first.indexOf("FN_PLATFORM=switchengine")>=0?"switchengine":first.indexOf("FN_PLATFORM=fabricengine")>=0?"fabricengine":"";if(platform.length()==0)throw new IOException("Unsupported device platform");
            byte[] archive=new byte[0];int archiveMarker=result.output.indexOf("FN_ARCHIVE_BEGIN\n");if(archiveMarker>=0&&archiveMarker<marker){String encoded=result.output.substring(archiveMarker+"FN_ARCHIVE_BEGIN\n".length(),marker).trim();try{archive=Base64.getDecoder().decode(encoded);}catch(Exception ex){throw new IOException("Invalid full backup archive");}if(archive.length<32)throw new IOException("Invalid full backup archive");}
            if("fabricengine".equals(platform)&&archive.length==0)throw new IOException("FabricEngine full backup archive is missing");
            String configuration=normalize(result.output.substring(marker+"FN_CONFIG_BEGIN\n".length()));if(configuration.length()==0)throw new IOException("The device returned an empty configuration");
            String digest=sha256(configuration.getBytes(StandardCharsets.UTF_8)),archiveDigest=archive.length>0?sha256(archive):"";synchronized(LOCK){List<Record> existing=list(device);Record latest=existing.isEmpty()?null:existing.get(0);
            boolean unchanged=latest!=null&&digest.equals(latest.sha256)&&archiveDigest.equals(latest.archiveSha256);
            if(unchanged&&!"post-restore".equals(source)){AuditLog.log(actor,"CONFIG_BACKUP_UNCHANGED",device+" · version="+latest.id+" · platform="+platform,remote);return latest;}
            long now=System.currentTimeMillis();String id=now+"-"+UUID.randomUUID().toString().substring(0,8),changeActor="restore".equals(source)||"post-restore".equals(source)?clean(actor):existing.isEmpty()?"initial capture":"unknown on device";
            Path directory=deviceDirectory(device);secureDirectory(directory);Path cfg=directory.resolve(id+".cfg"),meta=directory.resolve(id+".properties"),archivePath=directory.resolve(id+".tgz");writeAtomic(cfg,configuration.getBytes(StandardCharsets.UTF_8));if(archive.length>0)writeAtomic(archivePath,archive);Properties values=new Properties();values.setProperty("id",id);values.setProperty("device",device);values.setProperty("platform",platform);values.setProperty("capturedAt",Instant.ofEpochMilli(now).toString());values.setProperty("capturedAtMillis",Long.toString(now));values.setProperty("capturedBy",clean(actor));values.setProperty("source",clean(source));values.setProperty("changeActor",changeActor);values.setProperty("sha256",digest);values.setProperty("archiveSha256",archiveDigest);values.setProperty("fullArchive",Boolean.toString(archive.length>0));writeProperties(meta,values,"FabricNavigator configuration version metadata");prune(device,parseInt(settings().getProperty("retention"),10));AuditLog.log(actor,"CONFIG_BACKUP_CREATED",device+" · version="+id+" · platform="+platform+" · fullArchive="+(archive.length>0)+" · sha256="+digest+(archiveDigest.length()>0?" · archiveSha256="+archiveDigest:""),remote);return record(meta);
        }}}

    public static void restore(String device,String version,String actor,String remote) throws Exception{
        FeatureFlags.requireConfigurationBackup();
        validateDevice(device);if(version==null||!version.matches("[0-9]{10,}-[a-f0-9]{8}"))throw new IllegalArgumentException("Invalid configuration version");synchronized(deviceLock(device)){
            Record target;synchronized(LOCK){target=find(device,version);}capture(device,actor,"pre-restore",remote);Properties credential=CredentialVault.getSshForDevice(device);String configuration=new String(Files.readAllBytes(target.configuration),StandardCharsets.UTF_8);byte[] archive=target.archive!=null&&Files.isRegularFile(target.archive)?Files.readAllBytes(target.archive):new byte[0];if("fabricengine".equals(target.platform)&&archive.length==0)throw new IOException("This FabricEngine version has no full backup archive and cannot be restored safely");ProcessResult result=run(device,credential,"restore",target.platform,configuration,archive);if(result.code!=0){AuditLog.log(actor,"FAILED_CONFIG_RESTORE",device+" · target="+version+" · "+result.error(),remote);throw new IOException(result.error());}AuditLog.log(actor,"CONFIG_RESTORE",device+" · target="+version+" · platform="+target.platform+" · fullArchive="+(archive.length>0),remote);try{Thread.sleep(1500L);capture(device,actor,"post-restore",remote);}catch(Exception verification){AuditLog.log(actor,"CONFIG_RESTORE_VERIFY_WARNING",device+" · target="+version+" · "+safeMessage(verification),remote);}
        }}

    public static List<Record> list(String device) throws Exception{
        FeatureFlags.requireConfigurationBackup();
        validateDevice(device);List<Record> records=new ArrayList<Record>();Path directory=deviceDirectory(device);if(!Files.isDirectory(directory))return records;try(DirectoryStream<Path> stream=Files.newDirectoryStream(directory,"*.properties")){for(Path path:stream)try{records.add(record(path));}catch(Exception ignored){}}Collections.sort(records,new Comparator<Record>(){public int compare(Record a,Record b){return Long.compare(b.capturedAtMillis,a.capturedAtMillis);}});return records;
    }
    public static Record find(String device,String id) throws Exception{for(Record r:list(device))if(r.id.equals(id))return r;throw new FileNotFoundException("Configuration version not found");}
    public static String configuration(String device,String id) throws Exception{return new String(Files.readAllBytes(find(device,id).configuration),StandardCharsets.UTF_8);}
    public static String archiveConfiguration(String device,String id) throws Exception{
        Record record=find(device,id);if(!"fabricengine".equals(record.platform)||record.archive==null||!Files.isRegularFile(record.archive))throw new IOException("This version has no FabricEngine/VSP/VOSS full archive");
        String info=new String(tarEntry(record.archive,"info.txt"),StandardCharsets.UTF_8),name="";
        for(String line:info.replace("\r","").split("\n")){int equals=line.indexOf('=');if(equals>0&&"ASCII_CONFIG".equals(line.substring(0,equals).trim())){name=line.substring(equals+1).trim();break;}}
        name=name.replace('\\','/');while(name.startsWith("/"))name=name.substring(1);if(name.startsWith("intflash/"))name=name.substring("intflash/".length());
        if(name.length()==0||name.contains("..")||!name.matches("[A-Za-z0-9._/-]+"))throw new IOException("The archive contains no valid ASCII_CONFIG entry");
        byte[] content=tarEntry(record.archive,name);if(content.length==0)throw new IOException("The ASCII_CONFIG file is empty");return new String(content,StandardCharsets.UTF_8);
    }
    public static void delete(String device,String id,String actor,String remote) throws Exception{
        validateDevice(device);if(id==null||!id.matches("[0-9]{10,}-[a-f0-9]{8}"))throw new IllegalArgumentException("Invalid configuration version");synchronized(LOCK){Record record=find(device,id);boolean fullArchive=record.archive!=null&&Files.isRegularFile(record.archive);Files.deleteIfExists(record.configuration);Files.deleteIfExists(record.archive);Files.deleteIfExists(deviceDirectory(device).resolve(id+".properties"));AuditLog.log(actor,"CONFIG_BACKUP_DELETED",device+" · version="+id+" · platform="+record.platform+" · fullArchive="+fullArchive,remote);}
    }

    public static List<String> backupDevices() throws Exception{
        FeatureFlags.requireConfigurationBackup();List<String> devices=new ArrayList<String>();if(!Files.isDirectory(ROOT))return devices;
        try(DirectoryStream<Path> stream=Files.newDirectoryStream(ROOT)){for(Path path:stream){if(!Files.isDirectory(path))continue;String device=path.getFileName().toString().replace('_','.');try{validateDevice(device);if(!list(device).isEmpty())devices.add(device);}catch(Exception ignored){}}}
        Collections.sort(devices);return devices;
    }

    public static int deleteAll(String actor,String remote) throws Exception{
        FeatureFlags.requireConfigurationBackup();synchronized(LOCK){int count=0,deviceCount=0;for(String device:backupDevices()){List<Record> records=list(device);if(records.isEmpty())continue;deviceCount++;for(Record record:records){Files.deleteIfExists(record.configuration);Files.deleteIfExists(record.archive);Files.deleteIfExists(deviceDirectory(device).resolve(record.id+".properties"));count++;}try{Files.deleteIfExists(deviceDirectory(device));}catch(DirectoryNotEmptyException ignored){}}
            AuditLog.log(actor,"CONFIG_BACKUPS_ALL_DELETED","versions="+count+" · devices="+deviceCount,remote);return count;}
    }

    private static Record record(Path metadata) throws Exception{Properties p=readProperties(metadata);Record r=new Record();r.id=p.getProperty("id","");r.device=p.getProperty("device","");r.platform=p.getProperty("platform","");r.capturedAt=p.getProperty("capturedAt","");r.capturedAtMillis=Long.parseLong(p.getProperty("capturedAtMillis","0"));r.capturedBy=p.getProperty("capturedBy","");r.source=p.getProperty("source","");r.changeActor=p.getProperty("changeActor","");r.sha256=p.getProperty("sha256","");r.archiveSha256=p.getProperty("archiveSha256","");r.configuration=metadata.resolveSibling(r.id+".cfg");r.archive=metadata.resolveSibling(r.id+".tgz");if(!Files.isRegularFile(r.configuration))throw new FileNotFoundException();return r;}
    private static Path deviceDirectory(String device){return ROOT.resolve(device.replace('.','_'));}
    private static Object deviceLock(String device){Object created=new Object(),existing=DEVICE_LOCKS.putIfAbsent(device,created);return existing==null?created:existing;}
    private static void validateDevice(String device){if(device==null||!device.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}"))throw new IllegalArgumentException("Invalid device IP");for(String part:device.split("\\."))if(Integer.parseInt(part)>255)throw new IllegalArgumentException("Invalid device IP");}
    private static void prune(String device,int retention) throws Exception{List<Record> records=list(device);for(int i=retention;i<records.size();i++){Files.deleteIfExists(records.get(i).configuration);Files.deleteIfExists(records.get(i).archive);Files.deleteIfExists(deviceDirectory(device).resolve(records.get(i).id+".properties"));}}
    private static byte[] tarEntry(Path archive,String entry) throws Exception{Process process=new ProcessBuilder("/bin/tar","-xOzf",archive.toString(),entry).start();Collector stdout=new Collector(process.getInputStream()),stderr=new Collector(process.getErrorStream());Thread a=new Thread(stdout),b=new Thread(stderr);a.start();b.start();if(!process.waitFor(20,TimeUnit.SECONDS)){process.destroyForcibly();throw new IOException("Archive extraction timed out");}a.join();b.join();byte[] value=stdout.bytes();if(process.exitValue()!=0)throw new IOException(stderr.value().trim().length()>0?stderr.value().trim():"Archive entry not found");if(value.length>16*1024*1024)throw new IOException("Archive configuration is too large to display");return value;}

    private static ProcessResult run(String device,Properties c,String action,String platform,String configuration,byte[] archive) throws Exception{
        Process process=new ProcessBuilder("/usr/bin/perl","/opt/fabricnavigator/config-backup.pl").start();BufferedWriter input=new BufferedWriter(new OutputStreamWriter(process.getOutputStream(),StandardCharsets.UTF_8));String[] values={device,c.getProperty("username",""),c.getProperty("sshPassword",""),c.getProperty("sshPrivateKey",""),c.getProperty("sshKeyPassphrase","")};for(String value:values){input.write(Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)));input.newLine();}input.write(c.getProperty("port","22"));input.newLine();for(String value:new String[]{action,platform,configuration}){input.write(Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8)));input.newLine();}input.write(Base64.getEncoder().encodeToString(archive==null?new byte[0]:archive));input.newLine();input.close();Collector stdout=new Collector(process.getInputStream()),stderr=new Collector(process.getErrorStream());Thread a=new Thread(stdout),b=new Thread(stderr);a.start();b.start();if(!process.waitFor("restore".equals(action)?420:240,TimeUnit.SECONDS)){process.destroyForcibly();throw new IOException("Configuration operation timed out");}a.join();b.join();return new ProcessResult(process.exitValue(),stdout.value(),stderr.value());
    }
    private static KnownHostsManager.Pending scanHostKey(String device,int port) throws Exception{Exception failure=null;for(int attempt=0;attempt<3;attempt++){try{return KnownHostsManager.scan(device,port);}catch(Exception ex){failure=ex;if(attempt<2)Thread.sleep(350L*(attempt+1));}}throw failure;}
    private static final class Collector implements Runnable{private final InputStream stream;private final ByteArrayOutputStream data=new ByteArrayOutputStream();Collector(InputStream stream){this.stream=stream;}public void run(){try{byte[] buffer=new byte[16384];int read;while((read=stream.read(buffer))>=0)data.write(buffer,0,read);}catch(Exception ignored){}}byte[] bytes(){return data.toByteArray();}String value(){return new String(bytes(),StandardCharsets.UTF_8);}}
    private static final class ProcessResult{final int code;final String output,stderr;ProcessResult(int code,String output,String stderr){this.code=code;this.output=output;this.stderr=stderr;}String error(){String value=stderr.trim();return value.length()>0?value:"Configuration command failed (exit "+code+")";}}
    private static Properties readProperties(Path path){Properties p=new Properties();if(Files.isRegularFile(path))try(InputStream in=Files.newInputStream(path)){p.load(in);}catch(Exception ignored){}return p;}
    private static void writeProperties(Path path,Properties p,String comment){try{secureDirectory(path.getParent());Path temporary=Files.createTempFile(path.getParent(),path.getFileName().toString(),".tmp");try(OutputStream out=Files.newOutputStream(temporary)){p.store(out,comment);}move(temporary,path);secureFile(path);}catch(Exception ex){throw new IllegalStateException(ex);}}
    private static void writeAtomic(Path path,byte[] data) throws Exception{secureDirectory(path.getParent());Path temporary=Files.createTempFile(path.getParent(),path.getFileName().toString(),".tmp");Files.write(temporary,data);move(temporary,path);secureFile(path);}
    private static void secureDirectory(Path path) throws Exception{Files.createDirectories(path);try{Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rwx------"));}catch(UnsupportedOperationException ignored){}}
    private static void secureFile(Path path) throws Exception{try{Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rw-------"));}catch(UnsupportedOperationException ignored){}}
    private static void move(Path source,Path target) throws Exception{try{Files.move(source,target,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException ex){Files.move(source,target,StandardCopyOption.REPLACE_EXISTING);}}
    private static String normalize(String value){StringBuilder out=new StringBuilder();for(String line:value.replace("\r","").split("\n")){line=line.replaceAll("[\\p{Cntrl}&&[^\\t]]","").replaceAll("\\s+$","");out.append(line).append('\n');}return out.toString().trim()+"\n";}
    private static String sha256(byte[] value) throws Exception{byte[] hash=MessageDigest.getInstance("SHA-256").digest(value);StringBuilder out=new StringBuilder();for(byte b:hash)out.append(String.format("%02x",b&255));return out.toString();}
    private static int parseInt(String value,int fallback){try{return Integer.parseInt(value);}catch(Exception ex){return fallback;}}
    private static String clean(String value){if(value==null)return "";return value.replaceAll("[\\r\\n\\t]"," ").trim();}
    private static String safeMessage(Exception ex){String message=ex.getMessage();return message==null?ex.getClass().getSimpleName():clean(message);}
    private static void writeStatus(String state,String message,int success,int failed){writeStatus(state,message,success,failed,success+failed);}
    private static void writeStatus(String state,String message,int success,int failed,int total){Properties p=new Properties();p.setProperty("state",state);p.setProperty("message",message==null?"":message);p.setProperty("success",Integer.toString(success));p.setProperty("failed",Integer.toString(failed));p.setProperty("total",Integer.toString(Math.max(total,success+failed)));p.setProperty("updatedAt",Instant.now().toString());writeProperties(STATUS,p,"FabricNavigator configuration backup status");}
}
