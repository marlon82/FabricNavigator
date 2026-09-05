package com.fabricnavigator.snmp;

import com.fabricnavigator.snmp.model.MibNode;
import com.fabricnavigator.snmp.model.SnmpOID;
import com.fabricnavigator.snmp.model.SnmpVarBind;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.snmp4j.CommunityTarget;
import org.snmp4j.PDU;
import org.snmp4j.ScopedPDU;
import org.snmp4j.Snmp;
import org.snmp4j.Target;
import org.snmp4j.TransportMapping;
import org.snmp4j.UserTarget;
import org.snmp4j.event.ResponseEvent;
import org.snmp4j.mp.MPv3;
import org.snmp4j.mp.SnmpConstants;
import org.snmp4j.security.AuthMD5;
import org.snmp4j.security.AuthSHA;
import org.snmp4j.security.Priv3DES;
import org.snmp4j.security.PrivAES128;
import org.snmp4j.security.PrivDES;
import org.snmp4j.security.SecurityLevel;
import org.snmp4j.security.SecurityModels;
import org.snmp4j.security.SecurityProtocols;
import org.snmp4j.security.USM;
import org.snmp4j.security.UsmUser;
import org.snmp4j.smi.Address;
import org.snmp4j.smi.GenericAddress;
import org.snmp4j.smi.OID;
import org.snmp4j.smi.OctetString;
import org.snmp4j.smi.SMIConstants;
import org.snmp4j.smi.VariableBinding;
import org.snmp4j.transport.DefaultUdpTransportMapping;

/**
 * FabricNavigator SNMP adapter backed by Apache-2.0 licensed SNMP4J.
 * The class name is retained temporarily for binary compatibility with the
 * existing topology discovery class. No snmp4jdm code is used here.
 */
public class SnmpUtilV3 {
    private Snmp snmp;
    private TransportMapping<?> transport;
    private Target target;
    private String context = "";
    private String targetIp = "";
    private int version = SnmpConstants.version2c;
    private long timeout = 2500L;

    public SnmpUtilV3() { }

    public void setSnmpVersion(int value) {
        version = value == 0 ? SnmpConstants.version1 : SnmpConstants.version2c;
        if (target != null) target.setVersion(version);
    }

    public void setTimeout(int milliseconds) {
        timeout = Math.max(100L, milliseconds);
        if (target != null) target.setTimeout(timeout);
    }

    public String openSession(String host, String readCommunity, String writeCommunity) throws Exception {
        closeSession();
        targetIp = validHost(host);
        startTransport(false);
        CommunityTarget community = new CommunityTarget();
        community.setCommunity(new OctetString(readCommunity == null ? "" : readCommunity));
        configureTarget(community, version);
        target = community;
        return "";
    }

    public String openSessionV3(String host, String username, int authProtocol, String authPassword,
                                int privProtocol, String privPassword, String contextName) throws Exception {
        closeSession();
        targetIp = validHost(host);
        context = contextName == null ? "" : contextName;
        startTransport(true);
        OctetString securityName = new OctetString(username == null ? "" : username);
        OID auth = authProtocol == 1 ? AuthMD5.ID : authProtocol == 2 ? AuthSHA.ID : null;
        OID privacy = privProtocol == 1 ? PrivDES.ID : privProtocol == 2 ? PrivAES128.ID : privProtocol == 3 ? Priv3DES.ID : null;
        OctetString authSecret = auth == null ? null : new OctetString(authPassword == null ? "" : authPassword);
        OctetString privSecret = privacy == null ? null : new OctetString(privPassword == null ? "" : privPassword);
        snmp.getUSM().addUser(securityName, new UsmUser(securityName, auth, authSecret, privacy, privSecret));
        UserTarget user = new UserTarget();
        user.setSecurityName(securityName);
        user.setSecurityLevel(privacy != null ? SecurityLevel.AUTH_PRIV : auth != null ? SecurityLevel.AUTH_NOPRIV : SecurityLevel.NOAUTH_NOPRIV);
        configureTarget(user, SnmpConstants.version3);
        target = user;
        return "";
    }

    public void closeSession() {
        if (snmp != null) try { snmp.close(); } catch (IOException ignored) { }
        if (transport != null) try { transport.close(); } catch (IOException ignored) { }
        snmp = null;
        transport = null;
        target = null;
    }

    public String[] getAttribute(String[] names, boolean next) throws Exception {
        if (names == null) return new String[0];
        List<SnmpOID> requested = new ArrayList<SnmpOID>();
        for (String name : names) requested.add(new SnmpOID(resolve(name)));
        List<SnmpVarBind> values = request(requested, next ? PDU.GETNEXT : PDU.GET);
        String[] result = new String[values.size()];
        for (int i = 0; i < values.size(); i++) result[i] = values.get(i).getVar() == null ? "" : values.get(i).getVar().toString();
        return result;
    }

    public List<SnmpVarBind> snmpGetNext(List<SnmpOID> oids) throws Exception {
        return request(oids, PDU.GETNEXT);
    }

    public List<SnmpVarBind> snmpGet(List<SnmpOID> oids) throws Exception {
        return request(oids, PDU.GET);
    }

    public static String[] tokenize(String value, String delimiters) {
        if (value == null || value.trim().length() == 0) return new String[0];
        String[] raw = value.split("[\\s,]+");
        List<String> result = new ArrayList<String>();
        for (String item : raw) if (item.trim().length() > 0) result.add(item.trim());
        return result.toArray(new String[result.size()]);
    }

    private List<SnmpVarBind> request(List<SnmpOID> oids, int type) throws Exception {
        ensureOpen();
        if (oids == null || oids.isEmpty()) return Collections.emptyList();
        PDU pdu = target.getVersion() == SnmpConstants.version3 ? new ScopedPDU() : new PDU();
        pdu.setType(type);
        if (pdu instanceof ScopedPDU && context.length() > 0) ((ScopedPDU)pdu).setContextName(new OctetString(context));
        for (SnmpOID oid : oids) pdu.add(new VariableBinding(new OID(oid.getValue())));
        ResponseEvent event = snmp.send(pdu, target);
        if (event == null || event.getResponse() == null) throw new IOException("SNMP request timed out for " + targetIp);
        PDU response = event.getResponse();
        if (response.getErrorStatus() != PDU.noError) throw new IOException(response.getErrorStatusText());
        List<SnmpVarBind> result = new ArrayList<SnmpVarBind>();
        for (VariableBinding binding : response.getVariableBindings()) {
            int syntax = binding.getVariable() == null ? 0 : binding.getVariable().getSyntax();
            int error = syntax == SMIConstants.EXCEPTION_NO_SUCH_INSTANCE || syntax == SMIConstants.EXCEPTION_NO_SUCH_OBJECT || syntax == SMIConstants.EXCEPTION_END_OF_MIB_VIEW ? 1 : 0;
            result.add(new SnmpVarBind(new SnmpOID(binding.getOid().getValue()), error == 0 ? binding.getVariable() : null, error));
        }
        return result;
    }

    private void startTransport(boolean v3) throws IOException {
        transport = new DefaultUdpTransportMapping();
        if (v3) {
            SecurityProtocols.getInstance().addDefaultProtocols();
            USM usm = new USM(SecurityProtocols.getInstance(), new OctetString(MPv3.createLocalEngineID()), 0);
            SecurityModels.getInstance().addSecurityModel(usm);
        }
        snmp = new Snmp(transport);
        transport.listen();
    }

    private void configureTarget(Target configured, int snmpVersion) {
        Address address = GenericAddress.parse("udp:" + targetIp + "/161");
        if (address == null) throw new IllegalArgumentException("Invalid SNMP target");
        configured.setAddress(address);
        configured.setVersion(snmpVersion);
        configured.setTimeout(timeout);
        configured.setRetries(0);
    }

    private void ensureOpen() {
        if (snmp == null || target == null) throw new IllegalStateException("SNMP session is not open");
    }

    private static String validHost(String host) {
        String value = host == null ? "" : host.trim();
        if (!value.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}")) throw new IllegalArgumentException("Invalid device address");
        return value;
    }

    private static int[] resolve(String name) {
        int[] oid = MibNode.parseName(name);
        if (oid == null) throw new IllegalArgumentException("Unsupported MIB object: " + name);
        return oid;
    }
}
