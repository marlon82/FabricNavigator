package com.fabricnavigator.snmp.model;

public final class SnmpVarBind {
    private final SnmpOID oid;
    private final SnmpVar value;
    private final int error;
    public SnmpVarBind(SnmpOID oid, Object value, int error) {
        this.oid = oid;
        this.value = new SnmpVar(value);
        this.error = error;
    }
    public SnmpOID getOid() { return oid; }
    public SnmpVar getVar() { return value; }
    public int getError() { return error; }
}
