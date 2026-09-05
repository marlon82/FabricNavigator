/*
 * Copyright (C) 2026 Marlon Scheid
 *
 * This file is part of FabricNavigator and is licensed under the
 * GNU General Public License v3.0 or later. See the repository LICENSE.
 *
 * Recovered from the matching FabricNavigator class file with CFR 0.152
 * during public-source preparation; dependency warnings in the original
 * decompiler banner referred to project classes included in src/java.
 */
package com.fabricnavigator.topology;

import com.fabricnavigator.snmp.model.MibNode;
import com.fabricnavigator.snmp.model.SnmpOID;
import com.fabricnavigator.snmp.model.SnmpVarBind;
import com.fabricnavigator.snmp.SnmpUtilV3;
import java.io.FileInputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

public final class TopologyDiscoveryV7 {
    public static final int MAX_DEVICES = 64;
    public static final int MAX_DEPTH = 8;
    public static final int MAX_CREDENTIALS = 12;
    public static final long DEADLINE_MS = 120000L;
    private static final int MAX_ROWS = 256;
    private static final int[] ISIS_CIRC_IF_INDEX_OID = new int[]{1, 3, 6, 1, 2, 1, 138, 1, 3, 2, 1, 2};
    private static final int[] ISIS_ADJ_STATE_OID = new int[]{1, 3, 6, 1, 2, 1, 138, 1, 6, 1, 1, 2};
    private static final int[] RC_ISIS_ADJ_IF_INDEX_OID = new int[]{1, 3, 6, 1, 4, 1, 2272, 1, 63, 10, 1, 4};
    private static final int[] IF_NAME_OID = new int[]{1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1};
    private static final int[] IF_DESCR_OID = new int[]{1, 3, 6, 1, 2, 1, 2, 2, 1, 2};
    private static final String DISCOVERY_SETTINGS = "/opt/tomcat/conf/edm-security/discovery.properties";

    private static int configuredInt(String string, int n, int n2, int n3) {
        Properties properties = new Properties();
        try {
            try (FileInputStream fileInputStream = new FileInputStream(DISCOVERY_SETTINGS);){
                properties.load(fileInputStream);
            }
            int n4 = Integer.parseInt(properties.getProperty(string, Integer.toString(n)).trim());
            return Math.max(n2, Math.min(n3, n4));
        }
        catch (Exception exception) {
            return n;
        }
    }

    public Result discover(String string, List<Credential> list) throws Exception {
        if (!TopologyDiscoveryV7.isAllowedAddress(string)) {
            throw new IllegalArgumentException("Seed-IP muss eine private IPv4-Adresse sein.");
        }
        if (list == null || list.isEmpty()) {
            throw new IllegalArgumentException("Mindestens ein SNMP-Credential ist erforderlich.");
        }
        if (list.size() > 12) {
            throw new IllegalArgumentException("Maximal 12 Credentials sind erlaubt.");
        }
        long l = System.currentTimeMillis();
        long l2 = l + 120000L;
        Result result = new Result();
        LinkedHashMap<String, Node> linkedHashMap = new LinkedHashMap<String, Node>();
        LinkedHashMap<String, Link> linkedHashMap2 = new LinkedHashMap<String, Link>();
        HashSet<String> hashSet = new HashSet<String>();
        ArrayDeque<QueueItem> arrayDeque = new ArrayDeque<QueueItem>();
        arrayDeque.add(new QueueItem(string, 0));
        while (!arrayDeque.isEmpty() && linkedHashMap.size() < 64 && System.currentTimeMillis() < l2) {
            SessionMatch sessionMatch;
            QueueItem queueItem = (QueueItem)arrayDeque.removeFirst();
            if (!hashSet.add(queueItem.ip)) continue;
            Node node = (Node)linkedHashMap.get(queueItem.ip);
            if (node == null) {
                node = new Node();
                node.id = queueItem.ip;
                node.ip = queueItem.ip;
                node.name = queueItem.ip;
                node.depth = queueItem.depth;
                linkedHashMap.put(node.id, node);
            }
            if ((sessionMatch = this.connect(queueItem.ip, list, l2)) == null) {
                node.status = "unreachable";
                continue;
            }
            SnmpUtilV3 snmpUtilV3 = sessionMatch.snmp;
            try {
                try {
                    node.status = "reachable";
                    node.name = TopologyDiscoveryV7.clean(sessionMatch.name).length() == 0 ? queueItem.ip : TopologyDiscoveryV7.clean(sessionMatch.name);
                    node.sysDescr = TopologyDiscoveryV7.clean(sessionMatch.sysDescr);
                    node.credential = TopologyDiscoveryV7.safeCredentialLabel(sessionMatch.credential);
                    Map<String, String> map = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpRemSysName");
                    Map<String, String> map2 = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpRemPortId");
                    Map<String, String> map3 = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpRemPortDesc");
                    Map<String, String> map4 = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpRemChassisId");
                    Map<Integer, String> map5 = TopologyDiscoveryV7.localPortMap(snmpUtilV3);
                    Set<Integer> set = TopologyDiscoveryV7.poeDeliveringPorts(snmpUtilV3);
                    Set<Integer> set2 = TopologyDiscoveryV7.fabricEngineSystem(node.sysDescr) ? TopologyDiscoveryV7.activeIsisInterfaces(snmpUtilV3) : Collections.emptySet();
                    Set<String> set3 = TopologyDiscoveryV7.interfaceNames(snmpUtilV3, set2);
                    Set<Integer> set4 = TopologyDiscoveryV7.fabricEngineSystem(node.sysDescr) ? TopologyDiscoveryV7.fabricAttachInterfaces(snmpUtilV3) : Collections.emptySet();
                    Set<String> set5 = TopologyDiscoveryV7.interfaceNames(snmpUtilV3, set4);
                    Map<String, String> map6 = TopologyDiscoveryV7.managementAddressMap(snmpUtilV3);
                    LinkedHashSet<String> linkedHashSet = new LinkedHashSet<String>();
                    linkedHashSet.addAll(map.keySet());
                    linkedHashSet.addAll(map2.keySet());
                    linkedHashSet.addAll(map4.keySet());
                    for (String string2 : linkedHashSet) {
                        int n = TopologyDiscoveryV7.localPortNumber(TopologyDiscoveryV7.parseSuffix(string2));
                        String string3 = TopologyDiscoveryV7.clean(map6.get(string2));
                        String string4 = TopologyDiscoveryV7.clean(map4.get(string2));
                        String string5 = TopologyDiscoveryV7.clean(map.get(string2));
                        String string6 = string3.length() > 0 ? string3 : "lldp:" + TopologyDiscoveryV7.stableIdentity(string4, string5, string2);
                        Node node2 = (Node)linkedHashMap.get(string6);
                        if (node2 == null && linkedHashMap.size() < 64) {
                            node2 = new Node();
                            node2.id = string6;
                            node2.ip = string3;
                            node2.name = string5.length() == 0 ? (string3.length() == 0 ? string4 : string3) : string5;
                            node2.chassis = string4;
                            node2.depth = queueItem.depth + 1;
                            node2.status = string3.length() == 0 ? "lldp-only" : "pending";
                            linkedHashMap.put(string6, node2);
                        }
                        if (node2 == null) continue;
                        String string7 = map5.containsKey(n) ? map5.get(n) : String.valueOf(n);
                        String string8 = TopologyDiscoveryV7.preferredPort(TopologyDiscoveryV7.clean(map2.get(string2)), TopologyDiscoveryV7.clean(map3.get(string2)));
                        Link link = new Link();
                        link.source = node.id;
                        link.target = node2.id;
                        link.sourcePort = string7;
                        link.targetPort = string8;
                        link.poe = set.contains(n);
                        link.isis = TopologyDiscoveryV7.isActiveIsisLink(n, string7, set2, set3);
                        link.fabricAttach = TopologyDiscoveryV7.isActiveFabricAttachLink(n, string7, set4, set5);
                        String string9 = TopologyDiscoveryV7.edgeKey(link);
                        Link link2 = (Link)linkedHashMap2.get(string9);
                        if (link2 == null) {
                            linkedHashMap2.put(string9, link);
                        } else {
                            link2.poe = link2.poe || link.poe;
                            link2.isis = link2.isis || link.isis;
                            boolean bl = link2.fabricAttach = link2.fabricAttach || link.fabricAttach;
                        }
                        if (string3.length() <= 0 || queueItem.depth >= 8 || hashSet.contains(string3) || !TopologyDiscoveryV7.isAllowedAddress(string3)) continue;
                        arrayDeque.addLast(new QueueItem(string3, queueItem.depth + 1));
                    }
                }
                catch (Exception exception) {
                    node.status = "partial";
                    result.warnings.add("LLDP-Daten f\u00fcr " + queueItem.ip + " konnten nicht vollst\u00e4ndig gelesen werden.");
                    try {
                        snmpUtilV3.closeSession();
                    }
                    catch (Exception exception2) {}
                    continue;
                }
            }
            catch (Throwable throwable) {
                try {
                    snmpUtilV3.closeSession();
                }
                catch (Exception exception) {}
                throw throwable;
            }
            try {
                snmpUtilV3.closeSession();
            }
            catch (Exception exception) {}
        }
        if (!arrayDeque.isEmpty()) {
            result.warnings.add("Discovery-Limit erreicht; Ergebnis ist m\u00f6glicherweise unvollst\u00e4ndig.");
        }
        result.nodes.addAll(linkedHashMap.values());
        result.links.addAll(linkedHashMap2.values());
        result.elapsedMs = System.currentTimeMillis() - l;
        return result;
    }

    private SessionMatch connect(String string, List<Credential> list, long l) {
        int n = TopologyDiscoveryV7.configuredInt("snmpTimeoutMs", 2500, 500, 30000);
        int n2 = TopologyDiscoveryV7.configuredInt("snmpRetries", 0, 0, 5);
        for (Credential credential : list) {
            int n3 = 0;
            while (n3 <= n2) {
                if (System.currentTimeMillis() >= l) {
                    return null;
                }
                SnmpUtilV3 snmpUtilV3 = new SnmpUtilV3();
                try {
                    snmpUtilV3.setTimeout(n);
                    if ("v3".equals(credential.version)) {
                        int n4 = "DES".equals(credential.privProtocol) ? 1 : ("AES".equals(credential.privProtocol) ? 2 : ("3DES".equals(credential.privProtocol) ? 3 : 0));
                        int n5 = "MD5".equals(credential.authProtocol) ? 1 : ("SHA".equals(credential.authProtocol) ? 2 : 0);
                        snmpUtilV3.openSession(string, "", "");
                        snmpUtilV3.setTimeout(n);
                        if ("noAuthNoPriv".equals(credential.level)) {
                            n5 = 0;
                            n4 = 0;
                        } else if ("authNoPriv".equals(credential.level)) {
                            n4 = 0;
                        }
                        snmpUtilV3.openSessionV3(string, credential.user, n5, credential.authPassword, n4, credential.privPassword, credential.context);
                    } else {
                        snmpUtilV3.setSnmpVersion("v1".equals(credential.version) ? 0 : 1);
                        snmpUtilV3.openSession(string, credential.community, credential.community);
                        snmpUtilV3.setTimeout(n);
                    }
                    String[] stringArray = snmpUtilV3.getAttribute(new String[]{"sysName.0", "sysDescr.0"}, false);
                    if (stringArray != null && stringArray.length >= 1 && TopologyDiscoveryV7.clean(stringArray[0]).length() > 0) {
                        SessionMatch sessionMatch = new SessionMatch();
                        sessionMatch.snmp = snmpUtilV3;
                        sessionMatch.credential = credential;
                        sessionMatch.name = stringArray[0];
                        sessionMatch.sysDescr = stringArray.length > 1 ? stringArray[1] : "";
                        return sessionMatch;
                    }
                }
                catch (Exception exception) {}
                try {
                    snmpUtilV3.closeSession();
                }
                catch (Exception exception) {}
                ++n3;
            }
        }
        return null;
    }

    private static List<WalkEntry> walk(SnmpUtilV3 snmpUtilV3, String string) throws Exception {
        MibNode mibNode = MibNode.get((String)string);
        if (mibNode == null) {
            return Collections.emptyList();
        }
        return TopologyDiscoveryV7.walkOid(snmpUtilV3, mibNode.getOid());
    }

    private static List<WalkEntry> walkOid(SnmpUtilV3 snmpUtilV3, int[] nArray) throws Exception {
        SnmpOID snmpOID = new SnmpOID(nArray);
        ArrayList<WalkEntry> arrayList = new ArrayList<WalkEntry>();
        int n = 0;
        while (n < 256) {
            SnmpVarBind snmpVarBind;
            SnmpOID snmpOID2;
            List list = snmpUtilV3.snmpGetNext(Collections.singletonList(snmpOID));
            if (list == null || list.isEmpty() || !(snmpOID2 = (snmpVarBind = (SnmpVarBind)list.get(0)).getOid()).startsWith(nArray) || snmpOID2.compareTo(snmpOID) <= 0 || snmpVarBind.getError() != 0) break;
            int[] nArray2 = snmpOID2.getValue();
            int[] nArray3 = new int[nArray2.length - nArray.length];
            System.arraycopy((Object)nArray2, nArray.length, (Object)nArray3, 0, nArray3.length);
            arrayList.add(new WalkEntry(nArray3, snmpVarBind.getVar() == null ? "" : snmpVarBind.getVar().toString()));
            snmpOID = snmpOID2;
            ++n;
        }
        return arrayList;
    }

    private static Map<String, String> walkMap(SnmpUtilV3 snmpUtilV3, String string) throws Exception {
        LinkedHashMap<String, String> linkedHashMap = new LinkedHashMap<String, String>();
        for (WalkEntry walkEntry : TopologyDiscoveryV7.walk(snmpUtilV3, string)) {
            linkedHashMap.put(TopologyDiscoveryV7.join(walkEntry.suffix), TopologyDiscoveryV7.clean(walkEntry.value));
        }
        return linkedHashMap;
    }

    private static Map<Integer, String> localPortMap(SnmpUtilV3 snmpUtilV3) throws Exception {
        Map<String, String> map = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpLocPortId");
        Map<String, String> map2 = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpLocPortDesc");
        LinkedHashMap<Integer, String> linkedHashMap = new LinkedHashMap<Integer, String>();
        LinkedHashSet<String> linkedHashSet = new LinkedHashSet<String>();
        linkedHashSet.addAll(map.keySet());
        linkedHashSet.addAll(map2.keySet());
        for (String string : linkedHashSet) {
            int n = TopologyDiscoveryV7.localTablePortNumber(TopologyDiscoveryV7.parseSuffix(string));
            linkedHashMap.put(n, TopologyDiscoveryV7.preferredPort(map.get(string), map2.get(string)));
        }
        return linkedHashMap;
    }

    private static Map<String, String> managementAddressMap(SnmpUtilV3 snmpUtilV3) throws Exception {
        LinkedHashMap<String, String> linkedHashMap = new LinkedHashMap<String, String>();
        for (WalkEntry walkEntry : TopologyDiscoveryV7.walk(snmpUtilV3, "lldpRemManAddrIfSubtype")) {
            String string = TopologyDiscoveryV7.ipv4FromManagementSuffix(walkEntry.suffix);
            if (string.length() <= 0) continue;
            linkedHashMap.put(TopologyDiscoveryV7.neighborKey(walkEntry.suffix), string);
        }
        return linkedHashMap;
    }

    private static Set<Integer> poeDeliveringPorts(SnmpUtilV3 snmpUtilV3) {
        LinkedHashSet<Integer> linkedHashSet = new LinkedHashSet<Integer>();
        try {
            for (WalkEntry walkEntry : TopologyDiscoveryV7.walk(snmpUtilV3, "pethPsePortDetectionStatus")) {
                int n = TopologyDiscoveryV7.poePortNumber(walkEntry.suffix);
                if (n < 0 || !TopologyDiscoveryV7.isDeliveringPowerStatus(walkEntry.value)) continue;
                linkedHashSet.add(n);
            }
        }
        catch (Exception exception) {}
        return linkedHashSet;
    }

    private static Set<Integer> activeIsisInterfaces(SnmpUtilV3 snmpUtilV3) {
        Set<Integer> set = TopologyDiscoveryV7.vendorActiveIsisInterfaces(snmpUtilV3);
        if (!set.isEmpty()) {
            return set;
        }
        LinkedHashMap<Integer, Integer> linkedHashMap = new LinkedHashMap<Integer, Integer>();
        LinkedHashSet<Integer> linkedHashSet = new LinkedHashSet<Integer>();
        try {
            for (WalkEntry walkEntry : TopologyDiscoveryV7.walkOid(snmpUtilV3, ISIS_CIRC_IF_INDEX_OID)) {
                if (walkEntry.suffix.length <= 0) continue;
                linkedHashMap.put(walkEntry.suffix[0], TopologyDiscoveryV7.integerValue(walkEntry.value));
            }
            for (WalkEntry walkEntry : TopologyDiscoveryV7.walkOid(snmpUtilV3, ISIS_ADJ_STATE_OID)) {
                int n = TopologyDiscoveryV7.isisCircuitIndex(walkEntry.suffix);
                Integer n2 = (Integer)linkedHashMap.get(n);
                if (n2 == null || n2 <= 0 || !TopologyDiscoveryV7.isIsisAdjacencyUp(walkEntry.value)) continue;
                linkedHashSet.add(n2);
            }
        }
        catch (Exception exception) {}
        return linkedHashSet;
    }

    private static Set<Integer> vendorActiveIsisInterfaces(SnmpUtilV3 snmpUtilV3) {
        LinkedHashSet<Integer> linkedHashSet = new LinkedHashSet<Integer>();
        try {
            for (WalkEntry walkEntry : TopologyDiscoveryV7.walkOid(snmpUtilV3, RC_ISIS_ADJ_IF_INDEX_OID)) {
                int n = TopologyDiscoveryV7.integerValue(walkEntry.value);
                if (n <= 0) continue;
                linkedHashSet.add(n);
            }
        }
        catch (Exception exception) {}
        return linkedHashSet;
    }

    private static Set<String> interfaceNames(SnmpUtilV3 snmpUtilV3, Set<Integer> set) {
        LinkedHashSet<String> linkedHashSet = new LinkedHashSet<String>();
        if (set.isEmpty()) {
            return linkedHashSet;
        }
        try {
            TopologyDiscoveryV7.addInterfaceNames(linkedHashSet, set, TopologyDiscoveryV7.walkOid(snmpUtilV3, IF_NAME_OID));
        }
        catch (Exception exception) {}
        try {
            TopologyDiscoveryV7.addInterfaceNames(linkedHashSet, set, TopologyDiscoveryV7.walkOid(snmpUtilV3, IF_DESCR_OID));
        }
        catch (Exception exception) {}
        return linkedHashSet;
    }

    private static void addInterfaceNames(Set<String> set, Set<Integer> set2, List<WalkEntry> list) {
        for (WalkEntry walkEntry : list) {
            String string;
            if (walkEntry.suffix.length <= 0 || !set2.contains(walkEntry.suffix[0]) || (string = TopologyDiscoveryV7.normalizedPort(walkEntry.value)).length() <= 0) continue;
            set.add(string);
        }
    }

    public static int isisCircuitIndex(int[] nArray) {
        return nArray != null && nArray.length > 0 ? nArray[0] : -1;
    }

    public static boolean isIsisAdjacencyUp(String string) {
        return "3".equals(string = TopologyDiscoveryV7.clean(string)) || "up".equalsIgnoreCase(string);
    }

    public static boolean isActiveIsisLink(int n, String string, Set<Integer> set, Set<String> set2) {
        return set.contains(n) || set2.contains(TopologyDiscoveryV7.normalizedPort(string));
    }

    private static Set<Integer> fabricAttachInterfaces(SnmpUtilV3 snmpUtilV3) {
        int n;
        int[] nArray;
        Map<String, String> map;
        LinkedHashSet<Integer> linkedHashSet = new LinkedHashSet<Integer>();
        try {
            map = TopologyDiscoveryV7.walkMap(snmpUtilV3, "avFabricAttachDiscElemsElementType");
            for (String string : map.keySet()) {
                nArray = TopologyDiscoveryV7.parseSuffix(string);
                int n2 = n = nArray.length > 0 ? nArray[0] : -1;
                if (n <= 0) continue;
                linkedHashSet.add(n);
            }
        }
        catch (Exception exception) {}
        try {
            map = TopologyDiscoveryV7.walkMap(snmpUtilV3, "lldpRemOrgDefInfo");
            for (String string : map.keySet()) {
                nArray = TopologyDiscoveryV7.parseSuffix(string);
                if (!TopologyDiscoveryV7.isFabricAttachOrgInfoSuffix(nArray) || (n = TopologyDiscoveryV7.fabricAttachLocalPort(nArray)) <= 0) continue;
                linkedHashSet.add(n);
            }
        }
        catch (Exception exception) {}
        return linkedHashSet;
    }

    public static boolean isFabricAttachOrgInfoSuffix(int[] nArray) {
        if (nArray == null || nArray.length < 9) {
            return false;
        }
        int n = 3;
        while (n + 5 < nArray.length) {
            if (nArray[n] == 3 && nArray[n + 1] == 0 && nArray[n + 2] == 4 && nArray[n + 3] == 13 && (nArray[n + 4] == 11 || nArray[n + 4] == 12)) {
                return true;
            }
            ++n;
        }
        return false;
    }

    public static int fabricAttachLocalPort(int[] nArray) {
        return nArray != null && nArray.length > 1 ? nArray[1] : -1;
    }

    public static boolean isActiveFabricAttachLink(int n, String string, Set<Integer> set, Set<String> set2) {
        return set != null && set.contains(n) || set2 != null && set2.contains(TopologyDiscoveryV7.normalizedPort(string));
    }

    private static int integerValue(String string) {
        try {
            return Integer.parseInt(TopologyDiscoveryV7.clean(string).replaceAll("[^0-9-].*$", ""));
        }
        catch (Exception exception) {
            return -1;
        }
    }

    private static String normalizedPort(String string) {
        return TopologyDiscoveryV7.clean(string).toLowerCase(Locale.ENGLISH).replaceAll("\\s+", "");
    }

    public static boolean fabricEngineSystem(String string) {
        String string2 = TopologyDiscoveryV7.clean(string).toLowerCase(Locale.ENGLISH);
        return string2.contains("fabricengine") || string2.contains("fabric engine") || string2.contains("voss") || string2.contains("virtual services platform") || string2.matches(".*\\bvsp[- ]?[0-9].*");
    }

    public static String ipv4FromManagementSuffix(int[] nArray) {
        if (nArray == null || nArray.length < 9) {
            return "";
        }
        int n = 3;
        if (nArray[n] != 1 || nArray[n + 1] != 4 || nArray.length < n + 6) {
            return "";
        }
        String string = String.valueOf(String.valueOf(nArray[n + 2])) + "." + nArray[n + 3] + "." + nArray[n + 4] + "." + nArray[n + 5];
        return TopologyDiscoveryV7.isAllowedAddress(string) ? string : "";
    }

    public static String neighborKey(int[] nArray) {
        if (nArray == null || nArray.length < 3) {
            return "";
        }
        return String.valueOf(String.valueOf(nArray[0])) + "." + nArray[1] + "." + nArray[2];
    }

    public static int localPortNumber(int[] nArray) {
        return nArray != null && nArray.length > 1 ? nArray[1] : -1;
    }

    public static int localTablePortNumber(int[] nArray) {
        return nArray != null && nArray.length > 0 ? nArray[0] : -1;
    }

    public static int poePortNumber(int[] nArray) {
        return nArray != null && nArray.length > 1 ? nArray[nArray.length - 1] : -1;
    }

    public static boolean isDeliveringPowerStatus(String string) {
        return "3".equals(string = TopologyDiscoveryV7.clean(string)) || "deliveringPower".equalsIgnoreCase(string);
    }

    public static String preferredPort(String string, String string2) {
        string = TopologyDiscoveryV7.clean(string);
        string2 = TopologyDiscoveryV7.clean(string2);
        return string.length() > 0 ? string : (string2.length() > 0 ? string2 : "?");
    }

    private static String edgeKey(Link link) {
        String string;
        String string2 = String.valueOf(String.valueOf(link.source)) + "|" + link.sourcePort;
        return string2.compareTo(string = String.valueOf(String.valueOf(link.target)) + "|" + link.targetPort) <= 0 ? String.valueOf(String.valueOf(string2)) + "--" + string : String.valueOf(String.valueOf(string)) + "--" + string2;
    }

    private static String safeCredentialLabel(Credential credential) {
        return "v3".equals(credential.version) ? "SNMPv3" : ("v1".equals(credential.version) ? "SNMPv1" : "SNMPv2c");
    }

    private static String stableIdentity(String string, String string2, String string3) {
        String string4 = string.length() > 0 ? string : (string2.length() > 0 ? string2 : string3);
        return string4.replaceAll("[^A-Za-z0-9_.:-]", "_");
    }

    private static String join(int[] nArray) {
        StringBuilder stringBuilder = new StringBuilder();
        int n = 0;
        while (n < nArray.length) {
            if (n > 0) {
                stringBuilder.append('.');
            }
            stringBuilder.append(nArray[n]);
            ++n;
        }
        return stringBuilder.toString();
    }

    private static int[] parseSuffix(String string) {
        if (string == null || string.length() == 0) {
            return new int[0];
        }
        String[] stringArray = string.split("\\.");
        int[] nArray = new int[stringArray.length];
        int n = 0;
        while (n < stringArray.length) {
            try {
                nArray[n] = Integer.parseInt(stringArray[n]);
            }
            catch (Exception exception) {
                nArray[n] = 0;
            }
            ++n;
        }
        return nArray;
    }

    private static String clean(String string) {
        if (string == null) {
            return "";
        }
        return "null".equalsIgnoreCase(string = string.trim()) ? "" : string;
    }

    public static boolean isAllowedAddress(String string) {
        if (string == null || !string.matches("^(?:\\d{1,3}\\.){3}\\d{1,3}$")) {
            return false;
        }
        String[] stringArray = string.split("\\.");
        int[] nArray = new int[4];
        int n = 0;
        while (n < 4) {
            nArray[n] = Integer.parseInt(stringArray[n]);
            if (nArray[n] > 255) {
                return false;
            }
            ++n;
        }
        return nArray[0] == 10 || nArray[0] == 172 && nArray[1] >= 16 && nArray[1] <= 31 || nArray[0] == 192 && nArray[1] == 168;
    }

    public static final class Credential {
        public String version = "v2c";
        public String community = "";
        public String user = "";
        public String level = "authPriv";
        public String authProtocol = "SHA";
        public String authPassword = "";
        public String privProtocol = "AES";
        public String privPassword = "";
        public String context = "";
    }

    public static final class Link {
        public String source;
        public String target;
        public String sourcePort;
        public String targetPort;
        public boolean poe;
        public boolean isis;
        public boolean fabricAttach;
    }

    public static final class Node {
        public String id;
        public String ip;
        public String name;
        public String chassis;
        public String sysDescr = "";
        public String status = "unreachable";
        public String credential = "";
        public int depth;
    }

    private static final class QueueItem {
        String ip;
        int depth;

        QueueItem(String string, int n) {
            this.ip = string;
            this.depth = n;
        }
    }

    public static final class Result {
        public final List<Node> nodes = new ArrayList<Node>();
        public final List<Link> links = new ArrayList<Link>();
        public final List<String> warnings = new ArrayList<String>();
        public long elapsedMs;
    }

    private static final class SessionMatch {
        SnmpUtilV3 snmp;
        Credential credential;
        String name;
        String sysDescr;

        private SessionMatch() {
        }
    }

    private static final class WalkEntry {
        int[] suffix;
        String value;

        WalkEntry(int[] nArray, String string) {
            this.suffix = nArray;
            this.value = string == null ? "" : string;
        }
    }
}

