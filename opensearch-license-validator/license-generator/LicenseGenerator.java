import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.net.NetworkInterface;
import java.util.Base64;
import java.util.Collections;

public class LicenseGenerator {

    private static final String AES_KEY = "0123456789abcdef"; // 16-byte key
    private static final String AES_IV = "abcdef9876543210";  // 16-byte IV

    public static void main(String[] args) throws Exception {
        // Get MAC address (first non-loopback, non-virtual interface)
        String macAddress = getMacAddress();
        if (macAddress == null) {
            System.err.println("Unable to get MAC address");
            return;
        }

        System.out.println("MAC to encrypt: " + macAddress);

        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        SecretKeySpec keySpec = new SecretKeySpec(AES_KEY.getBytes(), "AES");
        IvParameterSpec ivSpec = new IvParameterSpec(AES_IV.getBytes());

        cipher.init(Cipher.ENCRYPT_MODE, keySpec, ivSpec);
        byte[] encrypted = cipher.doFinal(macAddress.getBytes());

        String base64Encrypted = Base64.getEncoder().encodeToString(encrypted);
        System.out.println("Encrypted License Key: " + base64Encrypted);
    }

    private static String getMacAddress() throws Exception {
        for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            String name = ni.getName();
            if (!ni.isLoopback()
                    && ni.getHardwareAddress() != null
                    && !name.startsWith("docker")
                    && !name.startsWith("br-")
                    && !name.equalsIgnoreCase("lo")) {

                byte[] mac = ni.getHardwareAddress();
                StringBuilder sb = new StringBuilder();
                for (byte b : mac) {
                    sb.append(String.format("%02X:", b));
                }
                return sb.substring(0, sb.length() - 1); // Remove trailing colon
            }
        }
        return null;
    }
}
