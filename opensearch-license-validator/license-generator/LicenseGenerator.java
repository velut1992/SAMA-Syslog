import java.io.FileWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.Base64;

public class LicenseGenerator {

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            printUsage();
            return;
        }

        String mode = args[0];

        if ("--generate-keys".equals(mode)) {
            generateKeys(args);
        } else if ("--create-license".equals(mode)) {
            createLicense(args);
        } else {
            printUsage();
        }
    }

    private static void generateKeys(String[] args) throws Exception {
        String outputDir = "keys";
        for (int i = 1; i < args.length; i++) {
            if ("--output-dir".equals(args[i]) && i + 1 < args.length) {
                outputDir = args[++i];
            }
        }

        Path dir = Paths.get(outputDir);
        Files.createDirectories(dir);

        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(2048);
        KeyPair keyPair = kpg.generateKeyPair();

        // Write private key in PEM format
        String privateKeyPem = "-----BEGIN PRIVATE KEY-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(keyPair.getPrivate().getEncoded())
                + "\n-----END PRIVATE KEY-----\n";
        Files.writeString(dir.resolve("private.key"), privateKeyPem);

        // Write public key in PEM format
        String publicKeyPem = "-----BEGIN PUBLIC KEY-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(keyPair.getPublic().getEncoded())
                + "\n-----END PUBLIC KEY-----\n";
        Files.writeString(dir.resolve("public.key"), publicKeyPem);

        System.out.println("RSA-2048 keypair generated:");
        System.out.println("  Private key: " + dir.resolve("private.key"));
        System.out.println("  Public key:  " + dir.resolve("public.key"));
    }

    private static void createLicense(String[] args) throws Exception {
        String fingerprint = null;
        String customer = null;
        String expiry = null;
        String privateKeyPath = null;
        String tier = "standard";
        int maxNodes = 1;
        String outputFile = "license.key";

        for (int i = 1; i < args.length; i++) {
            switch (args[i]) {
                case "--fingerprint":
                    fingerprint = args[++i];
                    break;
                case "--customer":
                    customer = args[++i];
                    break;
                case "--expiry":
                    expiry = args[++i];
                    break;
                case "--private-key":
                    privateKeyPath = args[++i];
                    break;
                case "--tier":
                    tier = args[++i];
                    break;
                case "--max-nodes":
                    maxNodes = Integer.parseInt(args[++i]);
                    break;
                case "--output":
                    outputFile = args[++i];
                    break;
            }
        }

        if (fingerprint == null || customer == null || expiry == null || privateKeyPath == null) {
            System.err.println("ERROR: --fingerprint, --customer, --expiry, and --private-key are required.");
            printUsage();
            System.exit(1);
        }

        // Validate expiry date
        LocalDate expiryDate = LocalDate.parse(expiry, DateTimeFormatter.ISO_LOCAL_DATE);
        String issuedAt = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE);

        // Build JSON payload (manual to avoid external dependencies)
        String payload = "{"
                + "\"customer\":\"" + escapeJson(customer) + "\","
                + "\"fingerprint\":\"" + escapeJson(fingerprint) + "\","
                + "\"issuedAt\":\"" + issuedAt + "\","
                + "\"expiresAt\":\"" + expiry + "\","
                + "\"tier\":\"" + escapeJson(tier) + "\","
                + "\"maxNodes\":" + maxNodes
                + "}";

        // Load private key
        String pemContent = Files.readString(Paths.get(privateKeyPath));
        String keyBase64 = pemContent
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s+", "");
        byte[] keyBytes = Base64.getDecoder().decode(keyBase64);
        PKCS8EncodedKeySpec keySpec = new PKCS8EncodedKeySpec(keyBytes);
        KeyFactory keyFactory = KeyFactory.getInstance("RSA");
        PrivateKey privateKey = keyFactory.generatePrivate(keySpec);

        // Sign the payload
        Signature signature = Signature.getInstance("SHA256withRSA");
        signature.initSign(privateKey);
        signature.update(payload.getBytes("UTF-8"));
        byte[] signatureBytes = signature.sign();

        // Output format: <base64-payload>.<base64-signature>
        String encodedPayload = Base64.getEncoder().encodeToString(payload.getBytes("UTF-8"));
        String encodedSignature = Base64.getEncoder().encodeToString(signatureBytes);
        String licenseContent = encodedPayload + "." + encodedSignature;

        Files.writeString(Paths.get(outputFile), licenseContent);

        System.out.println("License created successfully:");
        System.out.println("  Customer:    " + customer);
        System.out.println("  Fingerprint: " + fingerprint);
        System.out.println("  Issued:      " + issuedAt);
        System.out.println("  Expires:     " + expiry);
        System.out.println("  Tier:        " + tier);
        System.out.println("  Max Nodes:   " + maxNodes);
        System.out.println("  Output:      " + outputFile);
    }

    private static String escapeJson(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static void printUsage() {
        System.out.println("Supra License Generator");
        System.out.println();
        System.out.println("Usage:");
        System.out.println("  java LicenseGenerator --generate-keys [--output-dir keys]");
        System.out.println();
        System.out.println("  java LicenseGenerator --create-license");
        System.out.println("      --fingerprint <MFP>       Machine fingerprint (64-char hex)");
        System.out.println("      --customer <name>          Customer name");
        System.out.println("      --expiry <YYYY-MM-DD>      License expiry date");
        System.out.println("      --private-key <path>       Path to RSA private key (PEM)");
        System.out.println("      [--tier <tier>]            License tier (default: standard)");
        System.out.println("      [--max-nodes <n>]          Max cluster nodes (default: 1)");
        System.out.println("      [--output <path>]          Output file (default: license.key)");
    }
}
