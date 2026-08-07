package com.supra.plugins;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;

/**
 * Immutable snapshot of the validated license, published once at plugin
 * startup so the {@code GET /_supra/license} REST endpoint can report it.
 *
 * The values here are only ever populated AFTER the RSA signature, machine
 * fingerprint and expiry checks have all passed in {@link LicenseValidatorPlugin}
 * — if any check fails the node does not start, so a published snapshot always
 * describes a license that is authentic, bound to this machine and not expired.
 */
public final class LicenseInfo {

    public final String customer;
    public final String licenseType;   // "Permanent (perpetual)" or "Temporary"
    public final String validity;      // "No expiry" or "N day(s) remaining"
    public final String status;        // ACTIVE (publishing implies a valid license)
    public final String issuedAt;
    public final String expiresAt;
    public final String tier;
    public final Integer maxNodes;
    public final Integer maxDevices;   // null when the license sets no device limit
    public final String fingerprint;
    public final boolean signatureVerified;

    private LicenseInfo(String customer, String licenseType, String validity, String status,
                        String issuedAt, String expiresAt, String tier, Integer maxNodes,
                        Integer maxDevices, String fingerprint, boolean signatureVerified) {
        this.customer = customer;
        this.licenseType = licenseType;
        this.validity = validity;
        this.status = status;
        this.issuedAt = issuedAt;
        this.expiresAt = expiresAt;
        this.tier = tier;
        this.maxNodes = maxNodes;
        this.maxDevices = maxDevices;
        this.fingerprint = fingerprint;
        this.signatureVerified = signatureVerified;
    }

    /**
     * Derive the human-readable view (permanent vs temporary, remaining validity)
     * from the raw payload fields. Mirrors supra-license-info.sh and
     * LicenseGenerator --inspect so server, vendor and API all read identically.
     */
    public static LicenseInfo build(String customer, String type, String issuedAt, String expiresAt,
                                    String tier, Integer maxNodes, Integer maxDevices, String fingerprint) {
        boolean perpetual = (type != null && (type.equals("permanent") || type.equals("perpetual")))
                || (expiresAt != null && expiresAt.startsWith("9999"));

        String licenseType;
        String validity;
        if (perpetual) {
            licenseType = "Permanent (perpetual)";
            validity = "No expiry";
        } else {
            licenseType = "Temporary";
            String v;
            try {
                LocalDate exp = LocalDate.parse(expiresAt, DateTimeFormatter.ISO_LOCAL_DATE);
                long days = ChronoUnit.DAYS.between(LocalDate.now(), exp);
                v = days < 0 ? "Expired " + (-days) + " day(s) ago" : days + " day(s) remaining";
            } catch (Exception e) {
                v = "Expires " + expiresAt;
            }
            validity = v;
        }

        return new LicenseInfo(
                customer, licenseType, validity, "ACTIVE",
                issuedAt, expiresAt, tier, maxNodes,
                maxDevices, fingerprint, true);
    }
}
