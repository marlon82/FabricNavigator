package com.fabricnavigator.snmp.model;

/** Original FabricNavigator compatibility value used by the existing discovery binary. */
public final class SnmpVar {
    private final Object value;
    public SnmpVar(Object value) { this.value = value; }
    public Object unwrap() { return value; }
    public String toString() { return value == null ? "" : value.toString(); }
}
