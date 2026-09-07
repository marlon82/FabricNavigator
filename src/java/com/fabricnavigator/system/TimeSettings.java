package com.fabricnavigator.system;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Properties;
import java.util.TimeZone;
import javax.servlet.ServletContextEvent;
import javax.servlet.ServletContextListener;

public final class TimeSettings implements ServletContextListener {
    private static final String DEFAULT_ZONE = "UTC";
    private static final Path SETTINGS = Paths.get(System.getProperty("fabricnavigator.data.dir", "/opt/fabricnavigator/data"), "system-time.properties");
    private static final DateTimeFormatter DISPLAY = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static volatile ZoneId currentZone = ZoneId.of(DEFAULT_ZONE);

    public void contextInitialized(ServletContextEvent event) {
        apply(readConfiguredZone());
        event.getServletContext().log("FabricNavigator application timezone: " + currentZone.getId());
    }

    public void contextDestroyed(ServletContextEvent event) {}

    public static synchronized void set(String zoneName) throws Exception {
        ZoneId zone = validate(zoneName);
        Files.createDirectories(SETTINGS.getParent());
        Properties values = new Properties();
        values.setProperty("timezone", zone.getId());
        Path temporary = Files.createTempFile(SETTINGS.getParent(), "system-time.", ".tmp");
        try (OutputStream output = Files.newOutputStream(temporary)) {
            values.store(output, "FabricNavigator application timezone");
        }
        try {
            Files.move(temporary, SETTINGS, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (java.nio.file.AtomicMoveNotSupportedException ignored) {
            Files.move(temporary, SETTINGS, StandardCopyOption.REPLACE_EXISTING);
        }
        apply(zone);
    }

    public static synchronized void reset() throws Exception {
        Files.deleteIfExists(SETTINGS);
        apply(ZoneId.of(DEFAULT_ZONE));
    }

    public static String currentZoneId() { return currentZone.getId(); }
    public static String currentTime() { return DISPLAY.withZone(currentZone).format(Instant.now()); }
    public static String utcTime() { return DateTimeFormatter.ISO_INSTANT.format(Instant.now()); }

    public static String formatInstant(String value) {
        if (value == null || value.trim().length() == 0) return "";
        try { return DISPLAY.withZone(currentZone).format(Instant.parse(value.trim())); }
        catch (Exception ignored) { return value; }
    }

    public static List<String> availableZones() {
        List<String> zones = new ArrayList<String>(ZoneId.getAvailableZoneIds());
        if (!zones.contains("UTC")) zones.add("UTC");
        Collections.sort(zones);
        return zones;
    }

    private static ZoneId readConfiguredZone() {
        Properties values = new Properties();
        if (Files.isRegularFile(SETTINGS)) {
            try (InputStream input = Files.newInputStream(SETTINGS)) { values.load(input); }
            catch (Exception ignored) {}
        }
        try { return validate(values.getProperty("timezone", DEFAULT_ZONE)); }
        catch (Exception ignored) { return ZoneId.of(DEFAULT_ZONE); }
    }

    private static ZoneId validate(String zoneName) {
        if (zoneName == null || zoneName.length() > 80 || !zoneName.matches("[A-Za-z0-9_+./:-]+")) throw new IllegalArgumentException("Invalid timezone.");
        return ZoneId.of(zoneName);
    }

    private static void apply(ZoneId zone) {
        currentZone = zone;
        TimeZone.setDefault(TimeZone.getTimeZone(zone));
        System.setProperty("user.timezone", zone.getId());
    }
}
