package com.fabricnavigator.firmware;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.GZIPInputStream;

/** Reads the vendor metadata embedded in Fabric Engine and Switch Engine images. */
public final class FirmwarePackageInspector {
    private static final int SCAN_LIMIT=8*1024*1024;
    private static final long TAR_SCAN_LIMIT=64L*1024L*1024L;
    private static final int METADATA_LIMIT=1024*1024;
    private FirmwarePackageInspector(){}

    public static final class Result {
        public String platform="",model="",version="",activation="",compatibleModels="",architecture="",source="";
    }

    public static Result inspect(Path file,String fileName) throws Exception {
        List<Long> candidates=gzipOffsets(file);
        for(Long offset:candidates){
            Map<String,String> entries=readMetadataTar(file,offset.longValue());
            if(entries.isEmpty())continue;
            if(entries.containsKey("distribution.info")||entries.containsKey("validate.txt")){
                Result result=parseFabricEngine(entries);
                if(valid(result)){result.source="Fabric Engine distribution.info / validate.txt";return result;}
            }
            if(entries.containsKey("exos_version")||entries.containsKey("exos_platforms")||entries.containsKey("spec")){
                Result result=parseSwitchEngine(entries);
                if(valid(result)){result.source="Switch Engine exos_version / exos_platforms / spec";return result;}
            }
        }
        throw new IOException("The firmware metadata could not be identified from the uploaded image");
    }

    private static boolean valid(Result value){return value.platform.length()>0&&value.model.length()>0&&value.version.length()>0&&(!"fabricengine".equals(value.platform)||value.activation.length()>0);}

    private static Result parseFabricEngine(Map<String,String> entries){
        Properties distribution=lines(entries.get("distribution.info"));Properties validation=lines(entries.get("validate.txt"));Result result=new Result();
        result.platform="fabricengine";result.model=clean(distribution.getProperty("PLATFORM"),160);result.version=clean(distribution.getProperty("VERSION"),80);result.activation=clean(distribution.getProperty("LABEL"),120);result.architecture=clean(distribution.getProperty("ARCHITECTURE"),80);
        String models=cleanModels(validation.getProperty("Product"));if(models.length()==0)models=cleanModels(distribution.getProperty("CHASSIS"));result.compatibleModels=models;
        if(result.model.length()==0&&models.length()>0)result.model=family(models.split(",")[0]);
        return result;
    }

    private static Result parseSwitchEngine(Map<String,String> entries){
        Result result=new Result();result.platform="switchengine";String rawVersion=clean(entries.get("exos_version"),80);result.version=rawVersion.replaceAll("\\s+",".").replaceAll("^\\.+|\\.+$","");
        List<String> models=new ArrayList<String>();String platforms=entries.get("exos_platforms");if(platforms!=null)for(String line:platforms.split("\\r?\\n")){line=line.trim();if(line.length()>0&&!line.startsWith("#")&&line.matches("[A-Za-z0-9][A-Za-z0-9._-]{1,79}"))models.add(line);}
        Properties spec=colonLines(entries.get("spec"));if(result.version.length()==0)result.version=clean(spec.getProperty("version"),80);result.architecture=clean(spec.getProperty("platform"),80);result.compatibleModels=join(models);result.model=models.isEmpty()?familyFromImage(result.architecture):family(models.get(0));
        return result;
    }

    private static List<Long> gzipOffsets(Path file)throws IOException {List<Long> offsets=new ArrayList<Long>();try(RandomAccessFile input=new RandomAccessFile(file.toFile(),"r")){long limit=Math.min(input.length(),SCAN_LIMIT);int previous=-1,current;for(long position=0;position<limit;position++){current=input.read();if(current<0)break;if(previous==0x1f&&current==0x8b){long candidate=position-1;int method=input.read();if(method==8)offsets.add(candidate);position++;previous=-1;}else previous=current;}}return offsets;}

    private static Map<String,String> readMetadataTar(Path file,long offset){Map<String,String> values=new HashMap<String,String>();try(InputStream raw=Files.newInputStream(file)){skipFully(raw,offset);try(GZIPInputStream gzip=new GZIPInputStream(raw,65536)){long scanned=0;byte[] header=new byte[512];while(scanned<TAR_SCAN_LIMIT){if(!readFully(gzip,header))break;scanned+=512;if(zero(header))break;if(!tarHeader(header))return Collections.emptyMap();String name=tarString(header,0,100);if(name.startsWith("./"))name=name.substring(2);long size=octal(header,124,12);if(size<0||size>TAR_SCAN_LIMIT)return Collections.emptyMap();boolean wanted=name.equals("distribution.info")||name.equals("validate.txt")||name.equals("package.info")||name.equals("exos_version")||name.equals("exos_platforms")||name.equals("spec");if(wanted&&size<=METADATA_LIMIT){byte[] data=new byte[(int)size];if(!readFully(gzip,data))return Collections.emptyMap();values.put(name,new String(data,StandardCharsets.UTF_8).replace("\u0000",""));}else skipFully(gzip,size);scanned+=size;long padding=(512-(size%512))%512;skipFully(gzip,padding);scanned+=padding;if((values.containsKey("distribution.info")&&values.containsKey("validate.txt"))||(values.containsKey("exos_version")&&values.containsKey("exos_platforms")&&values.containsKey("spec")))break;}}}catch(Exception ignored){return Collections.emptyMap();}return values;}

    private static boolean tarHeader(byte[] header){String magic=tarString(header,257,6);return magic.startsWith("ustar");}
    private static boolean zero(byte[] value){for(byte b:value)if(b!=0)return false;return true;}
    private static String tarString(byte[] value,int start,int length){int end=start;while(end<start+length&&value[end]!=0)end++;return new String(value,start,end-start,StandardCharsets.US_ASCII).trim();}
    private static long octal(byte[] value,int start,int length){String raw=tarString(value,start,length).trim();if(raw.length()==0)return 0;try{return Long.parseLong(raw,8);}catch(Exception ex){return -1;}}
    private static boolean readFully(InputStream input,byte[] target)throws IOException {int offset=0;while(offset<target.length){int count=input.read(target,offset,target.length-offset);if(count<0)return false;if(count>0)offset+=count;}return true;}
    private static void skipFully(InputStream input,long count)throws IOException {while(count>0){long skipped=input.skip(count);if(skipped>0){count-=skipped;continue;}if(input.read()<0)throw new EOFException("Unexpected end of firmware image");count--;}}
    private static Properties lines(String value){Properties out=new Properties();if(value==null)return out;for(String line:value.split("\\r?\\n")){int split=line.indexOf('=');if(split>0)out.setProperty(line.substring(0,split).trim(),line.substring(split+1).trim());}return out;}
    private static Properties colonLines(String value){Properties out=new Properties();if(value==null)return out;for(String line:value.split("\\r?\\n")){int split=line.indexOf('=');if(split>0){String item=line.substring(split+1).trim();if(item.endsWith(":"))item=item.substring(0,item.length()-1);out.setProperty(line.substring(0,split).trim(),item.replace("\"",""));}}return out;}
    private static String cleanModels(String value){if(value==null)return "";List<String> out=new ArrayList<String>();for(String item:value.split(",")){item=clean(item,120);item=item.replaceAll("-(?:VOSS|FabricEngine)$","");if(item.length()>0&&!out.contains(item))out.add(item);}return join(out);}
    private static String join(List<String> values){StringBuilder out=new StringBuilder();for(String value:values){if(out.length()>0)out.append(',');out.append(value);}return out.toString();}
    private static String family(String model){String value=clean(model,160);int split=value.indexOf('-');return split>0?value.substring(0,split):value;}
    private static String familyFromImage(String value){String lower=clean(value,160).toLowerCase(Locale.ENGLISH);if(lower.contains("summitlite"))return "X435";return clean(value,160);}
    private static String clean(String value,int max){String out=value==null?"":value.trim().replace('\r',' ').replace('\n',' ');return out.length()>max?out.substring(0,max):out;}
}
