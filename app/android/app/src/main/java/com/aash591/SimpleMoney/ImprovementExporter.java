package com.aash591.SimpleMoney;

import net.lingala.zip4j.ZipFile;
import net.lingala.zip4j.io.outputstream.ZipOutputStream;
import net.lingala.zip4j.model.FileHeader;
import net.lingala.zip4j.model.ZipParameters;
import net.lingala.zip4j.model.enums.AesKeyStrength;
import net.lingala.zip4j.model.enums.CompressionMethod;
import net.lingala.zip4j.model.enums.EncryptionMethod;

import org.json.JSONObject;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Uploads messages the user chose to report. The layout matches the collector
 * envelope (password.rsa + AES inbox.zip holding inbox.jsonl), so the existing
 * decrypt tooling reads reports unchanged.
 */
public final class ImprovementExporter {
    private final android.content.Context context;
    public ImprovementExporter(android.content.Context context) { this.context = context.getApplicationContext(); }
    public int report(List<Map<String, Object>> messages) throws Exception {
        if (messages.isEmpty()) throw new IOException("Nothing to report");
        byte[] random = new byte[32]; new java.security.SecureRandom().nextBytes(random);
        char[] password = java.util.Base64.getEncoder().encodeToString(random).toCharArray();
        Arrays.fill(random, (byte)0);
        File archive = null;
        try {
            archive = writeEncryptedArchive(password, messages);
            String response = TelegramUploader.send(archive, BuildConfig.IMPROVEMENT_TOKEN, BuildConfig.IMPROVEMENT_CHAT);
            if (!new JSONObject(response).optBoolean("ok")) throw new IOException("Submission rejected");
            return messages.size();
        } finally {
            Arrays.fill(password, '\0');
            if (archive != null) archive.delete();
        }
    }
    private File writeEncryptedArchive(char[] password, List<Map<String, Object>> messages) throws Exception {
        File directory = new File(context.getFilesDir(), "improvement-exports");
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IOException("Cannot create export directory");
        }
        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US).format(new Date());
        String model = (android.os.Build.MANUFACTURER + "-" + android.os.Build.MODEL)
                .replaceAll("[^A-Za-z0-9_-]", "_");
        String filename = "report-" + model + "-" + stamp + "-" + java.util.UUID.randomUUID() + ".zip";
        File temporary = new File(directory, filename + ".part");
        File finished = new File(directory, filename);
        if (temporary.exists() || finished.exists()) throw new IOException("Export name already exists");

        File envelope = new File(directory, finished.getName() + ".envelope.part");
        try {
            ZipParameters parameters = new ZipParameters();
            parameters.setFileNameInZip("inbox.jsonl");
            parameters.setCompressionMethod(CompressionMethod.DEFLATE);
            parameters.setEncryptFiles(true);
            parameters.setEncryptionMethod(EncryptionMethod.AES);
            parameters.setAesKeyStrength(AesKeyStrength.KEY_STRENGTH_256);

            try (FileOutputStream file = new FileOutputStream(temporary);
                 ZipOutputStream zip = new ZipOutputStream(file, password)) {
                zip.putNextEntry(parameters);
                BufferedWriter writer = new BufferedWriter(
                        new OutputStreamWriter(zip, StandardCharsets.UTF_8), 32768);
                for (Map<String, Object> message : messages) {
                    JSONObject row = new JSONObject();
                    row.put("address", message.get("address"));
                    row.put("dateMs", message.get("dateMs"));
                    row.put("type", 1);
                    row.put("body", message.get("body"));
                    row.put("reason", message.get("reason"));
                    // Added with read-but-wrong reports; absent keys are skipped.
                    row.putOpt("kind", message.get("kind"));
                    Object parsed = message.get("parsed");
                    if (parsed instanceof String) row.put("parsed", new JSONObject((String) parsed));
                    row.putOpt("note", message.get("note"));
                    row.putOpt("contact", message.get("contact"));
                    writer.write(row.toString());
                    writer.write('\n');
                }
                writer.flush();
                zip.closeEntry();
            }

            ZipFile check = new ZipFile(temporary, password);
            FileHeader entry = check.getFileHeader("inbox.jsonl");
            if (entry == null || !entry.isEncrypted() || !check.isValidZipFile()) {
                throw new IOException("ZIP validation failed");
            }
            try (InputStream plain = check.getInputStream(entry)) {
                byte[] buffer = new byte[32768];
                while (plain.read(buffer) != -1) {
                    // Read through the encrypted entry to verify its password and integrity.
                }
            }
            java.security.PublicKey key;
            try (InputStream in = context.getAssets().open("collector-public.der")) {
                java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                byte[] buffer = new byte[1024]; int n;
                while ((n = in.read(buffer)) != -1) bytes.write(buffer, 0, n);
                key = java.security.KeyFactory.getInstance("RSA").generatePublic(
                    new java.security.spec.X509EncodedKeySpec(bytes.toByteArray()));
            }
            javax.crypto.Cipher cipher = javax.crypto.Cipher.getInstance("RSA/ECB/OAEPPadding");
            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key,
                new javax.crypto.spec.OAEPParameterSpec("SHA-256", "MGF1",
                    java.security.spec.MGF1ParameterSpec.SHA256, javax.crypto.spec.PSource.PSpecified.DEFAULT));
            byte[] wrapped = cipher.doFinal(new String(password).getBytes(StandardCharsets.US_ASCII));
            try (java.util.zip.ZipOutputStream outer = new java.util.zip.ZipOutputStream(new FileOutputStream(envelope))) {
                outer.putNextEntry(new java.util.zip.ZipEntry("password.rsa"));
                outer.write(wrapped); outer.closeEntry();
                outer.putNextEntry(new java.util.zip.ZipEntry("inbox.zip"));
                try (InputStream in = new java.io.FileInputStream(temporary)) {
                    byte[] bytes = new byte[32768]; int n;
                    while ((n = in.read(bytes)) != -1) outer.write(bytes, 0, n);
                }
                outer.closeEntry();
            }
            if (!envelope.renameTo(finished)) throw new IOException("Cannot finalize ZIP");
            return finished;
        } finally {
            if (temporary.exists()) temporary.delete();
            if (envelope.exists()) envelope.delete();
        }
    }
}
