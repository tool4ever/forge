package forge.util;

import com.badlogic.gdx.files.FileHandle;
import forge.Forge;
import forge.adventure.data.ConfigData;
import forge.adventure.util.Config;
import forge.gui.GuiBase;
import forge.item.PaperCard;
import forge.localinstance.properties.ForgeConstants;
import io.sentry.Sentry;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Date;
import java.util.concurrent.TimeUnit;

public class LibGDXImageFetcher extends ImageFetcher {
    @Override
    protected boolean shouldTryScryfallSetLookupCandidate(PaperCard requestedCard, PaperCard candidate) {
        if (!Forge.isMobileAdventureMode) {
            return true;
        }

        ConfigData configData = Config.instance().getConfigData();
        if (configData == null || configData.allowedEditions == null || configData.allowedEditions.length == 0) {
            return true;
        }

        return Arrays.asList(configData.allowedEditions).contains(candidate.getEdition());
    }

    @Override
    protected Runnable getDownloadTask(String[] downloadUrls, String destPath, Runnable notifyObservers) {
        return new LibGDXDownloadTask(downloadUrls, destPath, notifyObservers);
    }

    private static class LibGDXDownloadTask implements Runnable {
        private final String[] downloadUrls;
        private final String destPath;
        private final Runnable notifyObservers;

        LibGDXDownloadTask(String[] downloadUrls, String destPath, Runnable notifyObservers) {
            this.downloadUrls = downloadUrls;
            this.destPath = destPath;
            this.notifyObservers = notifyObservers;
        }

        /**
         * Resolve a Scryfall API image URL to a direct CDN URL.
         * RoboVM's OkHttp cannot follow Scryfall's 302 redirects properly,
         * so we query the JSON API to get the direct image URL instead.
         *
         * Input:  https://api.scryfall.com/cards/m3c/160?format=image&version=normal
         * Output: https://cards.scryfall.io/normal/front/.../uuid.jpg
         */
        private String resolveScryfallUrl(String scryfallUrl) {
            // Extract the JSON API URL by removing ?format=image... parameters
            int queryIndex = scryfallUrl.indexOf('?');
            if (queryIndex == -1) return scryfallUrl;

            String jsonUrl = scryfallUrl.substring(0, queryIndex);
            boolean useArtCrop = scryfallUrl.contains("version=art_crop");
            String face = "";
            if (scryfallUrl.contains("face=back")) face = "back";

            try {
                URL url = new URL(jsonUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setRequestProperty("User-Agent", BuildInfo.getUserAgent());
                conn.setRequestProperty("Accept", "application/json");
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(15000);

                int code = conn.getResponseCode();
                if (code != 200) {
                    System.err.println("  Scryfall JSON API returned " + code + " for " + jsonUrl);
                    conn.disconnect();
                    return null;
                }

                // Read JSON response
                StringBuilder sb = new StringBuilder();
                InputStream is = conn.getInputStream();
                BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
                char[] buf = new char[4096];
                int n;
                while ((n = reader.read(buf)) != -1) {
                    sb.append(buf, 0, n);
                }
                reader.close();
                conn.disconnect();

                String json = sb.toString();

                // For back face, look in card_faces array
                if ("back".equals(face)) {
                    String cdnUrl = extractImageUrl(json, useArtCrop, 1);
                    if (cdnUrl != null) return cdnUrl;
                }

                // Look in top-level image_uris
                return extractImageUrl(json, useArtCrop, 0);
            } catch (Exception e) {
                System.err.println("  Scryfall JSON resolve failed: " + e.getMessage());
                return null;
            }
        }

        /**
         * Extract image URL from Scryfall JSON response.
         * @param faceIndex 0 = front/top-level, 1 = back face
         */
        private String extractImageUrl(String json, boolean useArtCrop, int faceIndex) {
            String searchBlock = json;

            if (faceIndex > 0) {
                // Find the card_faces array and skip to the right face
                int facesStart = json.indexOf("\"card_faces\"");
                if (facesStart == -1) return null;
                int currentFace = 0;
                int pos = facesStart;
                while (currentFace < faceIndex) {
                    pos = json.indexOf("\"image_uris\"", pos + 1);
                    if (pos == -1) return null;
                    currentFace++;
                }
                searchBlock = json.substring(pos);
            }

            String key = useArtCrop ? "\"art_crop\":\"" : "\"normal\":\"";
            int start = searchBlock.indexOf(key);
            if (start == -1) {
                // Fallback to normal if art_crop not found
                if (useArtCrop) {
                    key = "\"normal\":\"";
                    start = searchBlock.indexOf(key);
                }
                if (start == -1) return null;
            }
            start += key.length();
            int end = searchBlock.indexOf("\"", start);
            if (end == -1) return null;

            return searchBlock.substring(start, end);
        }

        private HttpURLConnection openConnection(String urlString) throws IOException {
            URL url = new URL(urlString);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestProperty("User-Agent", BuildInfo.getUserAgent());
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(30000);
            return conn;
        }

        private boolean doFetch(String urlToDownload) throws IOException {
            if (disableHostedDownload && urlToDownload.startsWith(ForgeConstants.URL_CARDFORGE)) {
                // Don't try to download card images from cardforge servers
                return false;
            }

            if (scryfallCooldownTime != null && urlToDownload.startsWith(ForgeConstants.URL_PIC_SCRYFALL_DOWNLOAD)) {
                // Don't try to download card images from scryfall if we've been rate limited
                if (scryfallCooldownTime.after(new Date())) {
                    System.err.println("Currently in cooldown period for scryfall downloads. Skipping download attempt for: " + urlToDownload);
                    return false;
                } else {
                    // Cooldown period has expired, reset the cooldown time
                    scryfallCooldownTime = null;
                }
            }

            String newdespath = urlToDownload.contains(".fullborder.") || urlToDownload.startsWith(ForgeConstants.URL_PIC_SCRYFALL_DOWNLOAD) ?
                    TextUtil.fastReplace(destPath, ".full.", ".fullborder.") : destPath;
            if (!newdespath.contains(".full") && urlToDownload.startsWith(ForgeConstants.URL_PIC_SCRYFALL_DOWNLOAD) &&
                    !destPath.startsWith(ForgeConstants.CACHE_TOKEN_PICS_DIR) && !destPath.startsWith(ForgeConstants.CACHE_PLANECHASE_PICS_DIR))
                newdespath = newdespath.replace(".jpg", ".fullborder.jpg"); //fix planes/phenomenon for round border options
            // iOS only: resolve Scryfall API URLs to the direct CDN URL first (RoboVM's HTTP stack
            // can't follow Scryfall's 302 redirects). Other platforms follow redirects natively —
            // gating this avoids doubling their Scryfall API request count per image.
            String downloadUrl = urlToDownload;
            if (GuiBase.isIOS() && urlToDownload.startsWith(ForgeConstants.URL_PIC_SCRYFALL_DOWNLOAD)) {
                String cdnUrl = resolveScryfallUrl(urlToDownload);
                if (cdnUrl == null) {
                    System.err.println("  Could not resolve Scryfall CDN URL");
                    return false;
                }
                System.err.println("  Resolved -> " + cdnUrl);
                downloadUrl = cdnUrl;
            }

            System.out.println("Attempting to fetch: " + downloadUrl);
            HttpURLConnection c = openConnection(downloadUrl);
            c.setRequestProperty("Accept", "*/*");

            int responseCode = c.getResponseCode();
            String responseMessage = c.getResponseMessage();
            System.out.println("HTTP Response: " + responseCode + " " + responseMessage + " for URL: " + urlToDownload);
            if (responseCode != HttpURLConnection.HTTP_OK) {
                System.err.println("Failed to fetch image. HTTP code: " + responseCode + " (" + responseMessage + ") for URL: " + urlToDownload);
                c.disconnect();

                if (responseCode == 429) {
                    System.err.println("Device has been rate limited. Adding reduction of download attempts for this device.");
                    Sentry.captureMessage("Device has been rate limited. Adding reduction of download attempts for this device. " + urlToDownload);
                    // Don't try to download from scryfall for 5 minutes
                    scryfallCooldownTime = new Date(System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(5));
                }

                return false;
            }

            InputStream is = c.getInputStream();
            // First, save to a temporary file so that nothing tries to read
            // a partial download.
            FileHandle destFile = new FileHandle(newdespath + ".tmp");
            System.out.println(newdespath);
            destFile.parent().mkdirs();
            try(OutputStream out = Files.newOutputStream(destFile.file().toPath())) {
                // Conversion to JPEG/PNG will be handled differently depending on the platform
                if (newdespath.endsWith(".png")) {
                    Forge.getDeviceAdapter().convertToPNG(is, out);
                } else {
                    Forge.getDeviceAdapter().convertToJPEG(is, out);
                }

                is.close();
            }
            if (destFile.length() == 0) {
                // never leave a poisoned 0-byte cache file ("downloaded" but
                // undisplayable, and never retried because the file exists)
                System.err.println("  Downloaded 0 bytes, skipping");
                destFile.delete();
                c.disconnect();
                return false;
            }
            destFile.moveTo(new FileHandle(newdespath));
            c.disconnect();

            System.out.println("Saved image to " + newdespath);
            GuiBase.getInterface().invokeInEdtLater(notifyObservers);
            return true;
        }

        private String tofullBorder(String imageurl) {
            if (!imageurl.contains(".full.jpg"))
                return imageurl;
            try {
                URL url = new URL(imageurl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                //connection.setConnectTimeout(1000 * 5); //wait 5 seconds the most
                //connection.setReadTimeout(1000 * 5);
                conn.setRequestProperty("User-Agent", BuildInfo.getUserAgent());
                if(conn.getResponseCode() == HttpURLConnection.HTTP_NOT_FOUND)
                    imageurl = TextUtil.fastReplace(imageurl, ".full.jpg", ".fullborder.jpg");
                conn.disconnect();
                return imageurl;
            } catch (IOException ex) {
                return imageurl;
            }
        }

        public void run() {
            boolean success = false;
            for (String urlToDownload : downloadUrls) {
                boolean isPlanechaseBG = urlToDownload.startsWith("PLANECHASEBG:");
                try {
                    success = doFetch(urlToDownload.replace("PLANECHASEBG:", ""));
                    if (success) {
                        break;
                    }
                } catch (Exception e) {
                    if (isPlanechaseBG) {
                        System.err.println("Failed to download planechase background [" + destPath + "] image: " + e.getMessage());
                    } else {
                        System.err.println("Failed to download card [" + destPath + "] image: " + e.getMessage());
                        if (urlToDownload.contains("tokens")) {
                            int setIndex = urlToDownload.lastIndexOf('_');
                            int typeIndex = urlToDownload.lastIndexOf('.');
                            String setlessFilename = urlToDownload.substring(0, setIndex);
                            String extension = urlToDownload.substring(typeIndex);
                            urlToDownload = setlessFilename + extension;
                            try {
                                try {
                                    TimeUnit.MILLISECONDS.sleep(100);
                                } catch (InterruptedException ex) {
                                    throw new RuntimeException(ex);
                                }
                                success = doFetch(urlToDownload);
                                if (success) {
                                    break;
                                }
                            } catch (Exception t) {
                                System.out.println("Failed to download setless token [" + destPath + "]: " + e.getMessage());
                            }
                        }
                    }
                } finally {
                    try {
                        TimeUnit.MILLISECONDS.sleep(100);
                    } catch (InterruptedException ex) {
                        throw new RuntimeException(ex);
                    }
                }
            }
            if (!success) {
                System.err.println("All " + downloadUrls.length + " URLs failed for: " + destPath);
            }
        }
    }

}
