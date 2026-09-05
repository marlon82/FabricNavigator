package com.fabricnavigator.snmp.model;

import java.io.InputStream;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * FabricNavigator compatibility facade for the small set of MIB objects used
 * by discovery. This is original FabricNavigator code and does not parse the
 * former proprietary mib.dat file.
 */
public final class MibNode {
    private static final Map<String, int[]> OIDS;
    static {
        Map<String, int[]> values = new LinkedHashMap<String, int[]>();
        put(values, "sysDescr", "1.3.6.1.2.1.1.1");
        put(values, "sysObjectID", "1.3.6.1.2.1.1.2");
        put(values, "sysName", "1.3.6.1.2.1.1.5");
        put(values, "sysLocation", "1.3.6.1.2.1.1.6");
        put(values, "rcChasModelName", "1.3.6.1.4.1.2272.1.4.67");
        put(values, "lldpRemSysName", "1.0.8802.1.1.2.1.4.1.1.9");
        put(values, "lldpRemSysDesc", "1.0.8802.1.1.2.1.4.1.1.10");
        put(values, "lldpRemPortId", "1.0.8802.1.1.2.1.4.1.1.7");
        put(values, "lldpRemPortDesc", "1.0.8802.1.1.2.1.4.1.1.8");
        put(values, "lldpRemChassisId", "1.0.8802.1.1.2.1.4.1.1.5");
        put(values, "lldpLocPortId", "1.0.8802.1.1.2.1.3.7.1.3");
        put(values, "lldpLocPortDesc", "1.0.8802.1.1.2.1.3.7.1.4");
        put(values, "lldpRemManAddrIfSubtype", "1.0.8802.1.1.2.1.4.2.1.3");
        put(values, "pethPsePortDetectionStatus", "1.3.6.1.2.1.105.1.1.1.6");
        put(values, "avFabricAttachDiscElemsElementType", "1.3.6.1.4.1.45.5.46.1.11.1.2");
        put(values, "lldpRemOrgDefInfo", "1.0.8802.1.1.2.1.4.4.1.4");
        put(values, "ifName", "1.3.6.1.2.1.31.1.1.1.1");
        put(values, "ifDescr", "1.3.6.1.2.1.2.2.1.2");
        put(values, "ifType", "1.3.6.1.2.1.2.2.1.3");
        put(values, "ifHighSpeed", "1.3.6.1.2.1.31.1.1.1.15");
        put(values, "ifSpeed", "1.3.6.1.2.1.2.2.1.5");
        put(values, "dot3StatsDuplexStatus", "1.3.6.1.2.1.10.7.2.1.19");
        put(values, "ifMauType", "1.3.6.1.2.1.26.2.1.1.3");
        put(values, "lldpXdot3LocPortOperMauType", "1.0.8802.1.1.2.1.5.4623.1.2.1.1.4");
        put(values, "entPhysicalDescr", "1.3.6.1.2.1.47.1.1.1.1.2");
        put(values, "entPhysicalName", "1.3.6.1.2.1.47.1.1.1.1.7");
        put(values, "entAliasMappingIdentifier", "1.3.6.1.2.1.47.1.3.2.1.2");
        OIDS = Collections.unmodifiableMap(values);
    }

    private final int[] oid;
    private MibNode(int[] oid) { this.oid = oid.clone(); }
    public int[] getOid() { return oid.clone(); }
    public static void load(InputStream ignored) { }

    public static MibNode get(String name) {
        if (name == null) return null;
        String base = name.trim();
        int dot = base.indexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        int[] oid = OIDS.get(base);
        return oid == null ? null : new MibNode(oid);
    }

    public static int[] parseName(String value) {
        if (value == null) return null;
        String text = value.trim();
        if (text.startsWith(".")) text = text.substring(1);
        if (text.matches("[0-9]+(?:\\.[0-9]+)*")) return parseOid(text);
        int dot = text.indexOf('.');
        String base = dot < 0 ? text : text.substring(0, dot);
        int[] prefix = OIDS.get(base);
        if (prefix == null) return null;
        if (dot < 0) return prefix.clone();
        int[] suffix = parseOid(text.substring(dot + 1));
        int[] result = new int[prefix.length + suffix.length];
        System.arraycopy(prefix, 0, result, 0, prefix.length);
        System.arraycopy(suffix, 0, result, prefix.length, suffix.length);
        return result;
    }

    private static void put(Map<String, int[]> target, String name, String oid) {
        target.put(name, parseOid(oid));
    }

    private static int[] parseOid(String oid) {
        if (oid == null || oid.length() == 0) return new int[0];
        String[] parts = oid.split("\\.");
        int[] result = new int[parts.length];
        for (int i = 0; i < parts.length; i++) result[i] = Integer.parseInt(parts[i]);
        return result;
    }
}
