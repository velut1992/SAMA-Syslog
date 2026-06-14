package com.supra.plugins;

import org.opensearch.plugins.Plugin;

import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.Base64;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.opensearch.common.settings.Settings;

public class LicenseValidatorPlugin extends Plugin {

    private static final Logger logger = LogManager.getLogger(LicenseValidatorPlugin.class);

    public LicenseValidatorPlugin(Settings settings, Path configPath) {
        try {
            Path licenseDir = configPath.resolve("supra-license");
            Path licensePath = licenseDir.resolve("license.key");
            Path publicKeyPath = licenseDir.resolve("public.key");

            // Compute machine fingerprint first (needed for error messages).
            // Prefer the root-written machine-id cache in the license dir — the
            // OpenSearch process user cannot read the root-only DMI files.
            String localFingerprint = MachineFingerprint.generate(licenseDir);

            if (!Files.exists(licensePath)) {
                throw new RuntimeException(
                        "License file not found at: " + licensePath + "\n"
                        + "  This machine's fingerprint (MFP): " + localFingerprint + "\n"
                        + "  Send this MFP to your vendor to obtain a license.");
            }

            if (!Files.exists(publicKeyPath)) {
                throw new RuntimeException(
                        "Public key not found at: " + publicKeyPath + "\n"
                        + "  The public.key file must be placed in config/supra-license/");
            }

            // Read license file: <base64-payload>.<base64-signature>
            String licenseContent = Files.readString(licensePath).trim();
            String[] parts = licenseContent.split("\\.");
            if (parts.length != 2) {
                throw new RuntimeException("Invalid license file format.");
            }

            String encodedPayload = parts[0];
            String encodedSignature = parts[1];

            byte[] payloadBytes = Base64.getDecoder().decode(encodedPayload);
            byte[] signatureBytes = Base64.getDecoder().decode(encodedSignature);
            String payload = new String(payloadBytes, "UTF-8");

            // Load public key
            String publicKeyPem = Files.readString(publicKeyPath);
            String publicKeyBase64 = publicKeyPem
                    .replace("-----BEGIN PUBLIC KEY-----", "")
                    .replace("-----END PUBLIC KEY-----", "")
                    .replaceAll("\\s+", "");
            byte[] publicKeyBytes = Base64.getDecoder().decode(publicKeyBase64);
            X509EncodedKeySpec keySpec = new X509EncodedKeySpec(publicKeyBytes);
            KeyFactory keyFactory = KeyFactory.getInstance("RSA");
            PublicKey publicKey = keyFactory.generatePublic(keySpec);

            // Verify RSA signature
            Signature sig = Signature.getInstance("SHA256withRSA");
            sig.initVerify(publicKey);
            sig.update(payloadBytes);
            if (!sig.verify(signatureBytes)) {
                throw new RuntimeException(
                        "License signature verification failed. The license file may be tampered with.\n"
                        + "  This machine's fingerprint (MFP): " + localFingerprint);
            }

            // Parse JSON payload using simple string parsing (avoid external dependencies)
            String customer = extractJsonString(payload, "customer");
            String fingerprint = extractJsonString(payload, "fingerprint");
            String expiresAt = extractJsonString(payload, "expiresAt");
            String tier = extractJsonString(payload, "tier");

            // Check fingerprint match
            if (!localFingerprint.equals(fingerprint)) {
                throw new RuntimeException(
                        "License fingerprint mismatch!\n"
                        + "  Licensed for:  " + fingerprint + "\n"
                        + "  This machine:  " + localFingerprint + "\n"
                        + "  This license is not valid for this machine.");
            }

            // Check expiry
            LocalDate expiry = LocalDate.parse(expiresAt, DateTimeFormatter.ISO_LOCAL_DATE);
            if (LocalDate.now().isAfter(expiry)) {
                throw new RuntimeException(
                        "License has expired!\n"
                        + "  Expired on: " + expiresAt + "\n"
                        + "  Contact your vendor to renew. MFP: " + localFingerprint);
            }

            logger.info("Supra license validated successfully:");
            logger.info("  Customer:    {}", customer);
            logger.info("  Tier:        {}", tier);
            logger.info("  Expires:     {}", expiresAt);

        } catch (RuntimeException e) {
            logger.error("License validation failed: {}", e.getMessage());
            throw e;
        } catch (Exception e) {
            logger.error("License validation failed: {}", e.getMessage());
            throw new RuntimeException("Plugin startup aborted due to license validation failure.", e);
        }
    }

    private static String extractJsonString(String json, String key) {
        String searchKey = "\"" + key + "\":\"";
        int start = json.indexOf(searchKey);
        if (start == -1) return null;
        start += searchKey.length();
        int end = json.indexOf("\"", start);
        if (end == -1) return null;
        return json.substring(start, end);
    }
}
