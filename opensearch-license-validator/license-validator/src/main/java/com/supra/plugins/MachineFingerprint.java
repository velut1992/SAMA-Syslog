package com.supra.plugins;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.AccessController;
import java.security.MessageDigest;
import java.security.PrivilegedAction;

public class MachineFingerprint {

    public static String generate() {
        return generate(null);
    }

    /**
     * Resolve the machine fingerprint, preferring a root-written {@code machine-id}
     * cache in {@code cacheDir}.
     *
     * OpenSearch runs as a non-root user (e.g. 'supra') that cannot read the
     * root-only DMI files (/sys/class/dmi/id/product_uuid, board_serial, mode
     * 0400). Computing the fingerprint here would therefore resolve to
     * UNKNOWN|UNKNOWN|UNKNOWN on every Linux host — inconsistent with
     * get-fingerprint.sh (run as root) and not machine-bound. The installer's
     * supra-search.service writes the real fingerprint to
     * config/supra-license/machine-id via a root ExecStartPre; reading it here
     * keeps the plugin and get-fingerprint.sh in agreement.
     */
    public static String generate(Path cacheDir) {
        if (cacheDir != null) {
            try {
                Path cache = cacheDir.resolve("machine-id");
                if (Files.exists(cache)) {
                    String cached = Files.readString(cache).trim();
                    if (!cached.isEmpty()) {
                        return cached;
                    }
                }
            } catch (Exception ignore) {
                // fall through to live hardware computation
            }
        }
        return AccessController.doPrivileged((PrivilegedAction<String>) () -> {
            try {
                String os = System.getProperty("os.name", "").toLowerCase();
                String cpuId;
                String boardSerial;
                String diskSerial;

                if (os.contains("win")) {
                    cpuId = powershellCimQuery("Win32_Processor", "ProcessorId", null);
                    boardSerial = powershellCimQuery("Win32_BaseBoard", "SerialNumber", null);
                    diskSerial = powershellCimQuery("Win32_DiskDrive", "SerialNumber", "Index=0");

                    // Fallback to wmic if PowerShell CIM queries fail
                    if ("UNKNOWN".equals(cpuId)) cpuId = wmicQuery("cpu get ProcessorId");
                    if ("UNKNOWN".equals(boardSerial)) boardSerial = wmicQuery("baseboard get SerialNumber");
                    if ("UNKNOWN".equals(diskSerial)) diskSerial = wmicQuery("diskdrive where Index=0 get SerialNumber");
                } else {
                    cpuId = readFileOrCommand("/sys/class/dmi/id/product_uuid", null);
                    boardSerial = readFileOrCommand("/sys/class/dmi/id/board_serial", null);
                    diskSerial = readFileOrCommand(null, new String[]{"lsblk", "-ndo", "SERIAL"});
                }

                String raw = normalize(cpuId) + "|" + normalize(boardSerial) + "|" + normalize(diskSerial);
                return sha256(raw);
            } catch (Exception e) {
                throw new RuntimeException("Failed to generate machine fingerprint", e);
            }
        });
    }

    private static String powershellCimQuery(String cimClass, String property, String filter) {
        try {
            String psCommand;
            if (filter != null && !filter.isEmpty()) {
                psCommand = String.format(
                    "(Get-CimInstance -ClassName %s -Filter '%s' -ErrorAction Stop | Select-Object -First 1).%s",
                    cimClass, filter, property);
            } else {
                psCommand = String.format(
                    "(Get-CimInstance -ClassName %s -ErrorAction Stop | Select-Object -First 1).%s",
                    cimClass, property);
            }
            Process process = new ProcessBuilder(
                "powershell", "-NoProfile", "-NonInteractive", "-Command", psCommand
            ).redirectErrorStream(true).start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line = reader.readLine();
                process.waitFor();
                if (line != null && !line.trim().isEmpty()) {
                    return line.trim();
                }
            }
        } catch (Exception e) {
            // fall through to return UNKNOWN
        }
        return "UNKNOWN";
    }

    private static String wmicQuery(String query) {
        try {
            Process process = Runtime.getRuntime().exec("wmic " + query);
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    line = line.trim();
                    if (!line.isEmpty() && !line.equalsIgnoreCase("ProcessorId")
                            && !line.equalsIgnoreCase("SerialNumber")) {
                        return line;
                    }
                }
            }
            process.waitFor();
        } catch (Exception e) {
            // fall through
        }
        return "UNKNOWN";
    }

    private static String readFileOrCommand(String filePath, String[] command) {
        if (filePath != null) {
            try {
                Path path = Paths.get(filePath);
                if (Files.exists(path)) {
                    return Files.readString(path).trim();
                }
            } catch (Exception e) {
                // fall through to command
            }
        }
        if (command != null) {
            try {
                Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                    String line = reader.readLine();
                    process.waitFor();
                    if (line != null && !line.trim().isEmpty()) {
                        return line.trim();
                    }
                }
            } catch (Exception e) {
                // fall through
            }
        }
        return "UNKNOWN";
    }

    private static String normalize(String value) {
        if (value == null || value.trim().isEmpty()) {
            return "UNKNOWN";
        }
        return value.trim();
    }

    private static String sha256(String input) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(input.getBytes("UTF-8"));
        StringBuilder hex = new StringBuilder();
        for (byte b : hash) {
            hex.append(String.format("%02x", b));
        }
        return hex.toString();
    }

    public static void main(String[] args) {
        String fingerprint = generate();
        System.out.println("Machine Fingerprint (MFP): " + fingerprint);
    }
}
