package com.fabricnavigator.firmware;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Stores release notes and derives reviewable upgrade-path policies from their text. */
public final class FirmwareReleaseNotesStore {
    private static final Path ROOT=Paths.get(System.getProperty("fabricnavigator.data.dir","/opt/fabricnavigator/data"),"firmware-release-notes");
    private static final String PDFBOX=System.getProperty("fabricnavigator.pdfbox.jar","/opt/fabricnavigator/pdfbox-app.jar");
    private static final long MAX_SIZE=50L*1024L*1024L;
    private static final Pattern VERSION=Pattern.compile("(?i)(?:VOSS|Fabric[ _-]?Engine|Switch[ _-]?Engine|ExtremeXOS|EXOS)(?:\\s+(?:software|version|release|v))*[ _-]*([0-9]+(?:\\.[0-9]+){1,3})");
    private static final Pattern FILE_VERSION=Pattern.compile("(?i)(?:VOSS|Fabric[ _-]?Engine|Switch[ _-]?Engine|EXOS)[^0-9]{0,20}([0-9]+(?:[_.][0-9]+){1,3})");
    private static final Pattern SOURCE=Pattern.compile("(?i)([0-9]+(?:\\.[0-9]+)*(?:\\.x)?)\\s+to\\s+(?:(?:VOSS|Fabric[ _-]?Engine|Switch[ _-]?Engine|ExtremeXOS|EXOS)\\s+)?[0-9]+(?:\\.[0-9]+)*");
    private static final Pattern UPGRADE_TABLE=Pattern.compile("(?i)Table\\s+[0-9]+\\s*:\\s*(?:Validated|Supported)\\s+upgrade\\s+paths");
    private static final Pattern MODEL_ROW=Pattern.compile("(?i)^\\s*(.+?)\\s+((?:Y|N)(?:\\s+(?:Y|N)){1,12})\\s*$");
    private FirmwareReleaseNotesStore(){}

    public static final class Document {
        public String id="",fileName="",product="",releaseVersion="",validatedSources="",models="",status="",message="",sha256="",uploadedAt="",uploadedBy="",sourceUrl="";
        public long size;
        public Path file;
        public final List<Rule> rules=new ArrayList<Rule>();
    }

    public static final class Rule {
        public String model="",validatedSources="";
    }

    public static synchronized Document store(InputStream input,String originalName,String actor,String sourceUrl)throws Exception{
        String fileName=fileName(originalName);if(!fileName.toLowerCase(Locale.ENGLISH).endsWith(".pdf"))throw new IllegalArgumentException("Only PDF release notes are supported");
        Files.createDirectories(ROOT);secure(ROOT);String id=System.currentTimeMillis()+"-"+UUID.randomUUID().toString().substring(0,8);Path dir=ROOT.resolve(id);Files.createDirectory(dir);secure(dir);Path pdf=dir.resolve(fileName),part=dir.resolve(fileName+".part");MessageDigest digest=MessageDigest.getInstance("SHA-256");long size=0;byte[] buffer=new byte[65536];
        try{
            try(OutputStream out=Files.newOutputStream(part,StandardOpenOption.CREATE_NEW)){int n;while((n=input.read(buffer))>=0){if(n==0)continue;size+=n;if(size>MAX_SIZE)throw new IOException("Release notes exceed 50 MiB");digest.update(buffer,0,n);out.write(buffer,0,n);}}
            if(size<5||!isPdf(part))throw new IOException("The uploaded file is not a valid PDF document");Files.move(part,pdf,StandardCopyOption.ATOMIC_MOVE);secureFile(pdf);
            Path text=dir.resolve("release-notes.txt");extractText(pdf,text,dir.resolve("extract.log"));Parsed parsed=parse(Files.readAllBytes(text),fileName);
            Properties p=new Properties();p.setProperty("id",id);p.setProperty("fileName",fileName);p.setProperty("product",parsed.product);p.setProperty("releaseVersion",parsed.releaseVersion);p.setProperty("validatedSources",join(parsed.sources,","));p.setProperty("models",join(parsed.rules.keySet(),"|"));p.setProperty("rule.count",Integer.toString(parsed.rules.size()));int ruleIndex=0;for(Map.Entry<String,LinkedHashSet<String>> rule:parsed.rules.entrySet()){String prefix="rule."+(ruleIndex++)+".";p.setProperty(prefix+"model",rule.getKey());p.setProperty(prefix+"sources",join(rule.getValue(),","));}p.setProperty("status",parsed.rules.isEmpty()||parsed.sources.isEmpty()||parsed.releaseVersion.length()==0?"review":"ready");p.setProperty("message",parsed.message);p.setProperty("sha256",hex(digest.digest()));p.setProperty("size",Long.toString(size));p.setProperty("uploadedAt",Instant.now().toString());p.setProperty("uploadedBy",clean(actor,80));p.setProperty("sourceUrl",clean(sourceUrl,500));write(dir.resolve("document.properties"),p);return read(dir);
        }catch(Exception ex){cleanup(dir);throw ex;}
    }

    public static synchronized List<Document> list()throws Exception{List<Document> out=new ArrayList<Document>();if(!Files.isDirectory(ROOT))return out;try(DirectoryStream<Path> stream=Files.newDirectoryStream(ROOT)){for(Path dir:stream)if(Files.isDirectory(dir))try{out.add(read(dir));}catch(Exception ignored){}}Collections.sort(out,new Comparator<Document>(){public int compare(Document a,Document b){return b.uploadedAt.compareTo(a.uploadedAt);}});return out;}
    public static synchronized Document get(String id)throws Exception{if(id==null||!id.matches("[0-9]{10,}-[a-f0-9]{8}"))throw new IllegalArgumentException("Invalid release-notes ID");return read(ROOT.resolve(id));}
    public static synchronized int apply(String id)throws Exception{Document d=get(id);if(!"ready".equals(d.status))throw new IllegalStateException("No complete validated upgrade-path table was detected");int count=0;for(Rule rule:d.rules){FirmwareLifecycleSettings.saveDerived(rule.model,d.releaseVersion,rule.validatedSources,d.id,d.fileName,d.sourceUrl);count++;}Properties p=properties(ROOT.resolve(id).resolve("document.properties"));p.setProperty("status","applied");p.setProperty("message",count+" compatibility policies applied");writeReplace(ROOT.resolve(id).resolve("document.properties"),p);return count;}
    public static synchronized void delete(String id)throws Exception{Document d=get(id);FirmwareLifecycleSettings.deleteBySource(id);Path dir=ROOT.resolve(id);Files.deleteIfExists(dir.resolve("release-notes.txt"));Files.deleteIfExists(dir.resolve("extract.log"));Files.deleteIfExists(dir.resolve("document.properties"));Files.deleteIfExists(d.file);Files.deleteIfExists(dir);}

    private static Document read(Path dir)throws Exception{Properties p=properties(dir.resolve("document.properties"));Document d=new Document();d.id=p.getProperty("id","");d.fileName=p.getProperty("fileName","");d.product=p.getProperty("product","");d.releaseVersion=p.getProperty("releaseVersion","");d.validatedSources=p.getProperty("validatedSources","");d.models=p.getProperty("models","");d.status=p.getProperty("status","");d.message=p.getProperty("message","");d.sha256=p.getProperty("sha256","");d.size=Long.parseLong(p.getProperty("size","0"));d.uploadedAt=p.getProperty("uploadedAt","");d.uploadedBy=p.getProperty("uploadedBy","");d.sourceUrl=p.getProperty("sourceUrl","");int count=parseInt(p.getProperty("rule.count","0"));for(int i=0;i<count;i++){Rule rule=new Rule();rule.model=p.getProperty("rule."+i+".model","");rule.validatedSources=p.getProperty("rule."+i+".sources","");if(rule.model.length()>0&&rule.validatedSources.length()>0)d.rules.add(rule);}if(d.rules.isEmpty()){for(String model:split(d.models,"\\|")){Rule rule=new Rule();rule.model=model;rule.validatedSources=d.validatedSources;d.rules.add(rule);}}d.file=dir.resolve(d.fileName);if(!Files.isRegularFile(d.file)||Files.size(d.file)!=d.size)throw new IOException("Release-notes document is incomplete");return d;}
    private static void extractText(Path pdf,Path text,Path log)throws Exception{Path jar=Paths.get(PDFBOX);if(!Files.isRegularFile(jar))throw new IOException("The PDF analysis component is not installed");ProcessBuilder builder=new ProcessBuilder("/opt/java8/bin/java","-Xms32m","-Xmx256m","-jar",jar.toString(),"ExtractText","-encoding","UTF-8",pdf.toString(),text.toString());builder.redirectErrorStream(true);builder.redirectOutput(log.toFile());Process process=builder.start();if(!process.waitFor(180,TimeUnit.SECONDS)){process.destroyForcibly();throw new IOException("Release-notes analysis timed out");}if(process.exitValue()!=0||!Files.isRegularFile(text))throw new IOException("Text could not be extracted from the release notes");secureFile(text);secureFile(log);}
    private static Parsed parse(byte[] bytes,String fileName){String text=new String(bytes,StandardCharsets.UTF_8).replace('\u00a0',' '),lower=text.toLowerCase(Locale.ENGLISH),lowerName=fileName.toLowerCase(Locale.ENGLISH);Parsed p=new Parsed();p.product=(lowerName.contains("voss")||lowerName.contains("fabric")||lower.startsWith("voss ")||lower.startsWith("fabric engine "))?"FabricEngine / VOSS":"SwitchEngine / EXOS";Matcher version=VERSION.matcher(text.substring(0,Math.min(text.length(),30000)));if(version.find())p.releaseVersion=version.group(1);if(p.releaseVersion.length()==0){version=FILE_VERSION.matcher(fileName);if(version.find())p.releaseVersion=version.group(1).replace('_','.');}
        int section=-1;Matcher heading=UPGRADE_TABLE.matcher(text);while(heading.find())section=heading.start();if(section>=0){String table=text.substring(section,Math.min(text.length(),section+12000));Matcher source=SOURCE.matcher(table);while(source.find())p.sources.add(source.group(1));List<String> columns=new ArrayList<String>(p.sources);for(String line:table.split("\\r?\\n")){Matcher row=MODEL_ROW.matcher(line);if(row.matches()){String model=cleanModel(row.group(1));if(model.length()==0)continue;String[] states=row.group(2).trim().split("\\s+");LinkedHashSet<String> allowed=new LinkedHashSet<String>();for(int i=0;i<states.length&&i<columns.size();i++)if("Y".equalsIgnoreCase(states[i]))allowed.add(columns.get(i));if(!allowed.isEmpty())p.rules.put(model,allowed);}}}
        if(section<0)p.message="No validated upgrade-path section was detected";else if(p.releaseVersion.length()==0)p.message="Target release could not be identified";else if(p.sources.isEmpty())p.message="Validated source releases could not be identified";else if(p.rules.isEmpty())p.message="Device rows in the validated upgrade table require review";else p.message=p.rules.size()+" device families and "+p.sources.size()+" validated source branches detected";return p;}
    private static String cleanModel(String value){String model=value.replaceAll("(?i)^.*?(?:Table\\s+[0-9]+:?\\s*)","").trim().replaceAll("\\s+"," ");if(model.length()>160)model=model.substring(model.length()-160);if(!model.matches("(?i).*(?:VSP|ERS|ExtremeSwitching|Switch|Series|[0-9]{3,4}).*"))return "";return model;}
    private static boolean isPdf(Path file)throws Exception{byte[] h=new byte[5];try(InputStream in=Files.newInputStream(file)){return in.read(h)==5&&"%PDF-".equals(new String(h,StandardCharsets.US_ASCII));}}
    private static Properties properties(Path file)throws Exception{Properties p=new Properties();try(InputStream in=Files.newInputStream(file)){p.load(in);}return p;}
    private static void write(Path file,Properties p)throws Exception{try(OutputStream out=Files.newOutputStream(file,StandardOpenOption.CREATE_NEW)){p.store(out,"FabricNavigator firmware release notes");}secureFile(file);}
    private static void writeReplace(Path file,Properties p)throws Exception{Path tmp=Files.createTempFile(file.getParent(),"release-notes.",".tmp");try{try(OutputStream out=Files.newOutputStream(tmp)){p.store(out,"FabricNavigator firmware release notes");}Files.move(tmp,file,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(tmp);}secureFile(file);}
    private static String fileName(String value){String name=Paths.get(value==null?"release-notes.pdf":value).getFileName().toString().replaceAll("[^A-Za-z0-9._-]","_");if(name.length()>180)name=name.substring(name.length()-180);return name.length()==0?"release-notes.pdf":name;}
    private static String clean(String value,int max){String out=value==null?"":value.trim().replace('\r',' ').replace('\n',' ');return out.length()>max?out.substring(0,max):out;}
    private static void secure(Path path){try{Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rwx------"));}catch(Exception ignored){}}
    private static void secureFile(Path path){try{Files.setPosixFilePermissions(path,PosixFilePermissions.fromString("rw-------"));}catch(Exception ignored){}}
    private static void cleanup(Path dir){try{if(!Files.isDirectory(dir))return;try(DirectoryStream<Path> files=Files.newDirectoryStream(dir)){for(Path file:files)Files.deleteIfExists(file);}Files.deleteIfExists(dir);}catch(Exception ignored){}}
    private static String hex(byte[] value){StringBuilder out=new StringBuilder();for(byte b:value)out.append(String.format("%02x",b&255));return out.toString();}
    private static String join(Collection<String> values,String delimiter){StringBuilder out=new StringBuilder();for(String value:values){if(out.length()>0)out.append(delimiter);out.append(value);}return out.toString();}
    private static List<String> split(String value,String regex){List<String> out=new ArrayList<String>();for(String item:value.split(regex)){item=item.trim();if(item.length()>0)out.add(item);}return out;}
    private static int parseInt(String value){try{return Integer.parseInt(value);}catch(Exception ignored){return 0;}}
    private static final class Parsed {String product="",releaseVersion="",message="";Set<String> sources=new LinkedHashSet<String>();Map<String,LinkedHashSet<String>> rules=new LinkedHashMap<String,LinkedHashSet<String>>();}
}
