package com.fabricnavigator.web;

import javax.servlet.http.HttpServletRequest;

/** Resolves the originating client address behind FabricNavigator's local HTTPS proxy. */
public final class ClientAddress {
    private ClientAddress() {}

    public static String of(HttpServletRequest request) {
        if (request == null) return "unknown";
        String remote = clean(request.getRemoteAddr());
        if (!isTrustedProxy(remote)) return remote;
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null) {
            String[] entries = forwarded.split(",");
            for (int index = entries.length - 1; index >= 0; index--) {
                String candidate = clean(entries[index]);
                if (valid(candidate)) return candidate;
            }
        }
        String real = clean(request.getHeader("X-Real-IP"));
        return valid(real) ? real : remote;
    }

    private static boolean isTrustedProxy(String value) {
        return "127.0.0.1".equals(value) || "::1".equals(value) || "0:0:0:0:0:0:0:1".equals(value);
    }

    private static boolean valid(String value) {
        return value.length() >= 2 && value.length() <= 64 && value.matches("[0-9A-Fa-f:.%]+") && value.indexOf('\n') < 0 && value.indexOf('\r') < 0;
    }

    private static String clean(String value) {
        return value == null ? "" : value.trim();
    }
}
