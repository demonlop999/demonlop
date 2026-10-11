package com.baroutech.ultragaming;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.View;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.webkit.WebViewAssetLoader;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

public final class MainActivity extends Activity {
    private static final String MODULE_PATH = "/data/adb/modules/ultra_gaming_mode";
    private static final String CONTROL_PATH = MODULE_PATH + "/control.sh";
    private static final int COLOR_BACKGROUND = Color.rgb(10, 16, 26);
    private static final int COLOR_TEXT = Color.rgb(242, 246, 252);
    private static final int COLOR_MUTED = Color.rgb(164, 177, 196);
    private static final int COLOR_ACCENT = Color.rgb(154, 243, 210);
    private static final Pattern CONTROL_COMMAND = Pattern.compile(
            "^sh '/data/adb/modules/ultra_gaming_mode/control\\.sh' [A-Za-z0-9._' -]+$");
    private static final Pattern CALLBACK_NAME = Pattern.compile("[A-Za-z0-9_]{1,128}");

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private FrameLayout root;
    private WebView webView;
    private boolean closed;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(COLOR_BACKGROUND);
        getWindow().setNavigationBarColor(COLOR_BACKGROUND);

        root = new FrameLayout(this);
        setContentView(root);
        showChecking();
        checkModule();
    }

    private void showChecking() {
        showMessage(
                "Vérification du module",
                "Ultra Gaming Mode vérifie que le module Magisk est installé et activé. Android peut demander l’autorisation superutilisateur.",
                "Vérifier à nouveau",
                this::checkModule
        );
    }

    private void checkModule() {
        if (closed) return;
        showCheckingView();
        worker.execute(() -> {
            CommandResult result = executeRoot(
                    "if [ ! -d '" + MODULE_PATH + "' ]; then echo MODULE_MISSING; exit 71; "
                            + "elif [ -e '" + MODULE_PATH + "/disable' ]; then echo MODULE_DISABLED; exit 72; "
                            + "elif [ -e '" + MODULE_PATH + "/remove' ]; then echo MODULE_REMOVE_PENDING; exit 73; "
                            + "elif [ ! -r '" + MODULE_PATH + "/module.prop' ] || [ ! -x '" + CONTROL_PATH + "' ]; then "
                            + "echo MODULE_INCOMPLETE; exit 74; else echo MODULE_ACTIVE; fi"
            );
            runOnUiThread(() -> {
                if (closed) return;
                if (result.exitCode == 0 && result.output.contains("MODULE_ACTIVE")) {
                    loadDashboard();
                } else {
                    showDependencyMessage(result);
                }
            });
        });
    }

    private void showCheckingView() {
        TextView status = text("Vérification en cours…", 14, COLOR_MUTED);
        showMessage("Ultra Gaming Mode", "Contrôle de la présence du module Magisk…", null, null, status);
    }

    private void showDependencyMessage(CommandResult result) {
        String message;
        String dataNotice = "Cet écran ne modifie pas les profils. ";
        if (result.output.contains("MODULE_DISABLED")) {
            message = "Le module Ultra Gaming Mode est désactivé dans Magisk. Réactivez-le, puis revenez ici et touchez « Réessayer ».";
            dataNotice += "Les profils restent sur l’appareil tant que le module n’est pas désinstallé.";
        } else if (result.output.contains("MODULE_REMOVE_PENDING")) {
            message = "La suppression du module est en attente du prochain redémarrage. Redémarrez, réinstallez le ZIP Magisk, puis rouvrez l’application.";
            dataNotice += "La désinstallation peut aussi effacer les profils locaux.";
        } else if (result.output.contains("MODULE_INCOMPLETE")) {
            message = "L’installation du module semble incomplète. Réinstallez le ZIP Ultra Gaming Mode dans Magisk, redémarrez, puis réessayez.";
            dataNotice += "Les profils existants ne sont pas effacés par cet écran.";
        } else if (result.output.contains("MODULE_MISSING")) {
            message = "Le module Magisk requis est introuvable. Flashez UltraGamingMode-v3.3.0.zip dans Magisk, redémarrez, puis rouvrez l’application.";
            dataNotice += "Si Magisk a déjà désinstallé le module, ses profils peuvent avoir été effacés.";
        } else {
            message = "L’accès superutilisateur n’a pas été accordé ou Magisk n’est pas disponible. Autorisez le root pour Ultra Gaming Mode, puis réessayez.";
            dataNotice += "Autorisez le root ou réinstallez le module pour vérifier son état.";
        }
        showMessage(
                "Dépendance requise",
                message + "\n\n" + dataNotice + " L’application attend que le module soit actif avant de reprendre.",
                "Réessayer",
                this::checkModule
        );
    }

    private void loadDashboard() {
        if (webView == null) {
            webView = new WebView(this);
            webView.setBackgroundColor(COLOR_BACKGROUND);
            webView.getSettings().setJavaScriptEnabled(true);
            webView.getSettings().setDomStorageEnabled(false);
            webView.getSettings().setAllowFileAccess(false);
            webView.getSettings().setAllowContentAccess(false);
            webView.addJavascriptInterface(new RootBridge(), "ksu");

            WebViewAssetLoader assetLoader = new WebViewAssetLoader.Builder()
                    .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                    .build();
            webView.setWebViewClient(new WebViewClient() {
                @Override
                public android.webkit.WebResourceResponse shouldInterceptRequest(
                        WebView view, WebResourceRequest request) {
                    return assetLoader.shouldInterceptRequest(request.getUrl());
                }

                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    return !"appassets.androidplatform.net".equals(request.getUrl().getHost());
                }
            });
        }
        webView.onResume();
        webView.resumeTimers();
        root.removeAllViews();
        root.addView(webView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
        ));
        webView.loadUrl("https://appassets.androidplatform.net/assets/index.html");
    }

    private void showMessage(String title, String body, String buttonText, Runnable action) {
        showMessage(title, body, buttonText, action, null);
    }

    private void showMessage(String title, String body, String buttonText, Runnable action, View extra) {
        if (webView != null) {
            webView.onPause();
            webView.pauseTimers();
        }
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(26), dp(30), dp(26), dp(26));
        panel.setBackgroundColor(COLOR_BACKGROUND);

        TextView brand = text("BAROUTECH  ·  ULTRA GAMING", 12, COLOR_ACCENT);
        brand.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        panel.addView(brand);

        TextView heading = text(title, 27, COLOR_TEXT);
        heading.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        LinearLayout.LayoutParams headingParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        headingParams.topMargin = dp(24);
        panel.addView(heading, headingParams);

        TextView description = text(body, 15, COLOR_MUTED);
        description.setLineSpacing(dp(4), 1f);
        LinearLayout.LayoutParams descriptionParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        descriptionParams.topMargin = dp(14);
        panel.addView(description, descriptionParams);

        if (extra != null) {
            LinearLayout.LayoutParams extraParams = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            extraParams.topMargin = dp(18);
            panel.addView(extra, extraParams);
        }

        if (buttonText != null && action != null) {
            Button button = new Button(this);
            button.setText(buttonText);
            button.setTextColor(Color.rgb(10, 32, 32));
            button.setBackgroundTintList(android.content.res.ColorStateList.valueOf(COLOR_ACCENT));
            button.setOnClickListener(view -> action.run());
            LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            buttonParams.topMargin = dp(24);
            panel.addView(button, buttonParams);
        }

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(panel);
        root.removeAllViews();
        root.addView(scroll, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
        ));
    }

    private TextView text(String value, int size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        return view;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private CommandResult executeRoot(String command) {
        Process process = null;
        try {
            process = new ProcessBuilder("su", "-c", command)
                    .redirectErrorStream(true)
                    .start();
            StringBuilder output = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (output.length() < 16000) output.append(line).append('\n');
                }
            }
            return new CommandResult(process.waitFor(), output.toString());
        } catch (Exception exception) {
            if (process != null) process.destroy();
            return new CommandResult(1, exception.getMessage() == null ? "" : exception.getMessage());
        }
    }

    private final class RootBridge {
        @JavascriptInterface
        public void exec(String command, String options, String callbackName) {
            if (callbackName == null || !CALLBACK_NAME.matcher(callbackName).matches()) return;
            if (command == null || !CONTROL_COMMAND.matcher(command).matches()) {
                respond(callbackName, 1, "", "Commande root refusée par l’application.");
                return;
            }

            worker.execute(() -> {
                String guarded = "if [ ! -d '" + MODULE_PATH + "' ]; then echo MODULE_MISSING; exit 71; "
                        + "elif [ -e '" + MODULE_PATH + "/disable' ]; then echo MODULE_DISABLED; exit 72; "
                        + "elif [ -e '" + MODULE_PATH + "/remove' ]; then echo MODULE_REMOVE_PENDING; exit 73; fi; "
                        + command;
                CommandResult result = executeRoot(guarded);
                if (result.exitCode >= 71 && result.exitCode <= 73) {
                    runOnUiThread(() -> showDependencyMessage(result));
                    respond(callbackName, 1, "", result.output.trim());
                } else {
                    respond(callbackName, result.exitCode, result.output, "");
                }
            });
        }

        @JavascriptInterface
        public void exit() {
            runOnUiThread(MainActivity.this::finish);
        }
    }

    private void respond(String callbackName, int errno, String stdout, String stderr) {
        if (webView == null || closed) return;
        String script = "if(window[" + JSONObject.quote(callbackName) + "])window["
                + JSONObject.quote(callbackName) + "](" + errno + ","
                + JSONObject.quote(stdout) + "," + JSONObject.quote(stderr) + ");";
        webView.post(() -> {
            if (!closed && webView != null) webView.evaluateJavascript(script, null);
        });
    }

    @Override
    protected void onDestroy() {
        closed = true;
        worker.shutdownNow();
        if (webView != null) {
            webView.removeJavascriptInterface("ksu");
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }

    private static final class CommandResult {
        final int exitCode;
        final String output;

        CommandResult(int exitCode, String output) {
            this.exitCode = exitCode;
            this.output = output;
        }
    }
}
