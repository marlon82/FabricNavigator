package com.fabricnavigator.snmp.model;

public final class SnmpOID implements Comparable<SnmpOID> {
    private final int[] value;
    public SnmpOID(int[] value) { this.value = value == null ? new int[0] : value.clone(); }
    public int[] getValue() { return value.clone(); }
    public boolean startsWith(int[] prefix) {
        if (prefix == null || prefix.length > value.length) return false;
        for (int i = 0; i < prefix.length; i++) if (value[i] != prefix[i]) return false;
        return true;
    }
    public int compareTo(SnmpOID other) { return compare(value, other == null ? null : other.value); }
    public static int compare(int[] left, int[] right) {
        if (right == null) return 1;
        int length = Math.min(left.length, right.length);
        for (int i = 0; i < length; i++) if (left[i] != right[i]) return left[i] < right[i] ? -1 : 1;
        return left.length == right.length ? 0 : left.length < right.length ? -1 : 1;
    }
    public String toString() {
        StringBuilder result = new StringBuilder();
        for (int part : value) result.append('.').append(part);
        return result.length() == 0 ? "." : result.toString();
    }
}
