package com.aash591.SimpleMoney;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** Streams the encrypted envelope directly to Telegram; never logs credentials. */
public final class TelegramUploader {
    public static String send(File archive, String token, String chat) throws IOException {
        if (archive.length() > 45L * 1024 * 1024) throw new IOException("Archive exceeds 45 MB");
        String boundary = "SimpleMoney" + UUID.randomUUID().toString().replace("-", "");
        String header = "--" + boundary + "\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n"
                + chat + "\r\n--" + boundary
                + "\r\nContent-Disposition: form-data; name=\"document\"; filename=\"" + archive.getName().replaceAll("[^A-Za-z0-9._-]", "_") + "\"\r\nContent-Type: application/zip\r\n\r\n";
        byte[] prefix = header.getBytes(StandardCharsets.UTF_8);
        byte[] suffix = ("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8);
        HttpURLConnection connection = (HttpURLConnection) new URL("https://api.telegram.org/bot" + token + "/sendDocument").openConnection();
        try {
            connection.setRequestMethod("POST");
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(150000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
            connection.setFixedLengthStreamingMode(prefix.length + archive.length() + suffix.length);
            try (OutputStream out = connection.getOutputStream(); InputStream in = new FileInputStream(archive)) {
                out.write(prefix);
                byte[] buffer = new byte[32768]; int n;
                while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
                out.write(suffix);
            }
            int code = connection.getResponseCode();
            InputStream response = code == 200 ? connection.getInputStream() : connection.getErrorStream();
            if (response == null) throw new IOException("No Telegram response");
            try (InputStream in = response; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[1024]; int n;
                while ((n = in.read(buffer)) != -1) {
                    if (out.size() + n > 65536) throw new IOException("Response exceeds limit");
                    out.write(buffer, 0, n);
                }
                return out.toString("UTF-8");
            }
        } finally { connection.disconnect(); }
    }
}
