package com.fabricnavigator.api;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.Properties;
import javax.servlet.http.HttpServletRequest;

/** Authentication token used by the read-only FabricNavigator API. */
public final class FabricNavigatorApiToken {
    private static final Object LOCK = new Object();
    private static final SecureRandom RANDOM = new SecureRandom();

    private FabricNavigatorApiToken() {}

    private static Path tokenFile() {
        String root = System.getProperty("fabricnavigator.data.dir",
            System.getProperty("edm.security.dir", "/opt/fabricnavigator/data"));
        return Paths.get(root, "api", "fabricnavigator-api.properties");
    }

    private static Properties read() throws Exception {
        Properties values = new Properties();
        Path file = tokenFile();
        if (Files.isRegularFile(file)) {
            try (InputStream input = Files.newInputStream(file)) {
                values.load(input);
            }
        }
        return values;
    }

    private static void write(Properties values) throws Exception {
        Path file = tokenFile();
        Files.createDirectories(file.getParent());
        Path temporary = Files.createTempFile(file.getParent(), "fabricnavigator-api-", ".tmp");
        try {
            try (OutputStream output = Files.newOutputStream(temporary)) {
                values.store(output, "FabricNavigator API token metadata (no plaintext token)");
            }
            try {
                Files.setPosixFilePermissions(temporary, PosixFilePermissions.fromString("rw-------"));
            } catch (UnsupportedOperationException ignored) {
                // Windows-backed development volumes do not expose POSIX permissions.
            }
            try {
                Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static byte[] digest(String value) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(value.getBytes("UTF-8"));
    }

    private static String hex(byte[] value) {
        StringBuilder result = new StringBuilder(value.length * 2);
        for (byte item : value) result.append(String.format("%02x", item & 0xff));
        return result.toString();
    }

    private static byte[] unhex(String value) {
        if (value == null || !value.matches("^[0-9a-f]{64}$")) return new byte[0];
        byte[] result = new byte[value.length() / 2];
        for (int index = 0; index < result.length; index++) {
            result[index] = (byte) Integer.parseInt(value.substring(index * 2, index * 2 + 2), 16);
        }
        return result;
    }

    public static String generate(String label) throws Exception {
        synchronized (LOCK) {
            byte[] random = new byte[32];
            RANDOM.nextBytes(random);
            String token = "fn_api_" + Base64.getUrlEncoder().withoutPadding().encodeToString(random);
            Properties values = new Properties();
            values.setProperty("format", "fabricnavigator-api-token-v1");
            values.setProperty("tokenHash", hex(digest(token)));
            values.setProperty("label", label == null || label.trim().length() == 0 ? "ACLI Session Manager" : label.trim());
            values.setProperty("createdAt", Long.toString(System.currentTimeMillis()));
            write(values);
            return token;
        }
    }

    public static void revoke() throws Exception {
        synchronized (LOCK) {
            Files.deleteIfExists(tokenFile());
        }
    }

    public static boolean isConfigured() {
        synchronized (LOCK) {
            try {
                Properties values = read();
                return "fabricnavigator-api-token-v1".equals(values.getProperty("format"))
                    && values.getProperty("tokenHash", "").matches("^[0-9a-f]{64}$");
            } catch (Exception ignored) {
                return false;
            }
        }
    }

    public static String label() {
        synchronized (LOCK) {
            try { return read().getProperty("label", "ACLI Session Manager"); }
            catch (Exception ignored) { return "ACLI Session Manager"; }
        }
    }

    public static long createdAt() {
        synchronized (LOCK) {
            try { return Long.parseLong(read().getProperty("createdAt", "0")); }
            catch (Exception ignored) { return 0L; }
        }
    }

    public static boolean authenticate(HttpServletRequest request) {
        String authorization = request.getHeader("Authorization");
        if (authorization == null || !authorization.regionMatches(true, 0, "Bearer ", 0, 7)) return false;
        String candidate = authorization.substring(7).trim();
        if (!candidate.startsWith("fn_api_") || candidate.length() > 128) return false;
        synchronized (LOCK) {
            try {
                Properties values = read();
                if (!"fabricnavigator-api-token-v1".equals(values.getProperty("format"))) return false;
                byte[] expected = unhex(values.getProperty("tokenHash", ""));
                return expected.length == 32 && MessageDigest.isEqual(expected, digest(candidate));
            } catch (Exception ignored) {
                return false;
            }
        }
    }
}
