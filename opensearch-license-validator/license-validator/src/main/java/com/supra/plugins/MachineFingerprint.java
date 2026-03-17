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
        return AccessController.doPrivileged((PrivilegedAction<String>) () -> {
            try {
                String os = System.getProperty("os.name", "").toLowerCase();
                String cpuId;
                String boardSerial;
                String diskSerial;

                if (os.contains("win")) {
                    cpuId = wmicQuery("cpu get ProcessorId");
                    boardSerial = wmicQuery("baseboard get SerialNumber");
                    diskSerial = wmicQuery("diskdrive where Index=0 get SerialNumber");
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
