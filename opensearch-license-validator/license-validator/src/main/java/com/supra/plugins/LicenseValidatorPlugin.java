package com.supra.plugins;

import org.opensearch.plugins.Plugin;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.io.IOException;
import java.net.NetworkInterface;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Base64;
import java.util.Collections;

public class LicenseValidatorPlugin extends Plugin {

    private static final String AES_KEY = "0123456789abcdef"; // Same 16-byte key
    private static final String AES_IV = "abcdef9876543210";  // Same 16-byte IV
    private static final Path LICENSE_PATH = Paths.get("/etc/opensearch/license.key");

    public LicenseValidatorPlugin() {
        try {
            if (!Files.exists(LICENSE_PATH)) {
                throw new RuntimeException("License file not found: " + LICENSE_PATH);
            }

            String encryptedBase64 = Files.readString(LICENSE_PATH).trim();

            String decryptedMac = decrypt(encryptedBase64);

            boolean isValid = getAllMacAddresses().stream().anyMatch(mac -> mac.equalsIgnoreCase(decryptedMac));

            if (!isValid) {
                throw new RuntimeException("Invalid MAC address in license!");
            }

            System.out.println("License validated for MAC: " + decryptedMac);

        } catch (Exception e) {
            System.err.println("License validation failed: " + e.getMessage());
            throw new RuntimeException("Plugin startup aborted due to invalid license.");
        }
    }

    private String decrypt(String encryptedBase64) throws Exception {
        byte[] encrypted = Base64.getDecoder().decode(encryptedBase64);
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        SecretKeySpec keySpec = new SecretKeySpec(AES_KEY.getBytes(), "AES");
        IvParameterSpec ivSpec = new IvParameterSpec(AES_IV.getBytes());

        cipher.init(Cipher.DECRYPT_MODE, keySpec, ivSpec);
        byte[] decrypted = cipher.doFinal(encrypted);
        return new String(decrypted).trim();
    }

    private java.util.List<String> getAllMacAddresses() throws IOException {
        try {
            java.util.List<String> macAddresses = new java.util.ArrayList<>();
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isLoopback() && ni.getHardwareAddress() != null) {
                    byte[] mac = ni.getHardwareAddress();
                    StringBuilder sb = new StringBuilder();
                    for (byte b : mac) {
                        sb.append(String.format("%02X:", b));
                    }
                    macAddresses.add(sb.substring(0, sb.length() - 1));
                }
            }
            return macAddresses;
        } catch (Exception e) {
            throw new IOException("Failed to retrieve MAC addresses", e);
        }
    }

    private String getMac_Address() throws IOException {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isLoopback() && ni.getHardwareAddress() != null) {
                    byte[] mac = ni.getHardwareAddress();
                    StringBuilder sb = new StringBuilder();
                    for (byte b : mac) {
                        sb.append(String.format("%02X:", b));
                    }
                    return sb.substring(0, sb.length() - 1);
                }
            }
        } catch (Exception e) {
            throw new IOException("Failed to retrieve MAC address", e);
        }
        return null;
    }
}
