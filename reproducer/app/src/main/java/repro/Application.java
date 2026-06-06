package repro;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.InputStream;
import java.lang.reflect.Field;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

@SpringBootApplication
@RestController
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    // Confirms whether the request handler runs on a virtual thread.
    @GetMapping("/thread-info")
    public Map<String, Object> threadInfo() {
        Thread t = Thread.currentThread();
        return Map.of("virtual", t.isVirtual(), "thread_name", t.getName());
    }

    // Handles the request, yields the carrier with a short sleep, then makes a
    // synchronous downstream HTTP call on the same thread. Reports the kernel tid
    // at entry vs before the egress so carrier migration is visible.
    @GetMapping("/work")
    public Map<String, Object> work(@RequestParam String url) throws Exception {
        boolean virtual = Thread.currentThread().isVirtual();
        long tidEntry = kernelTid();
        Thread.sleep(50);
        long tidEgress = kernelTid();
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        int code = conn.getResponseCode();
        try (InputStream is = conn.getInputStream()) {
            is.readAllBytes();
        }
        conn.disconnect();
        return Map.of(
            "virtual", virtual,
            "tid_entry", tidEntry,
            "tid_egress", tidEgress,
            "migrated", tidEntry != tidEgress,
            "status", code
        );
    }

    // Kernel thread id (gettid) of the current OS thread, read from procfs (no JNI).
    private static long kernelTid() {
        try {
            String stat = Files.readString(Path.of("/proc/thread-self/stat"));
            return Long.parseLong(stat.substring(0, stat.indexOf(' ')));
        } catch (Exception e) {
            return -1;
        }
    }

    // ----------------------------------------------------------------------
    // Oracle additions (../oracle). Everything below is additive:
    // /work and the original repro behavior are untouched.
    // ----------------------------------------------------------------------

    // Same shape as /work, but the unique id is a PATH SEGMENT on both the
    // server side (/oracle/{id}) and the downstream call (/echo/{id}), so the
    // per-request oracle can match each client span to ITS server span (OBI
    // strips query strings from span paths, so ids must live in the path).
    @GetMapping("/oracle/{id}")
    public Map<String, Object> oracle(@PathVariable String id) throws Exception {
        boolean virtual = Thread.currentThread().isVirtual();
        long tidEntry = kernelTid();
        Thread.sleep(50);
        long tidEgress = kernelTid();
        int code = httpGet("http://downstream/echo/" + id);
        // E5: one JSON log line per request, written AFTER the downstream call
        // (max remount exposure). The log enricher injects trace_id into JSON
        // lines when traces_ctx_v1 has context for the writing thread;
        // analyze_e5.py joins this against the true server trace per id.
        System.out.println("{\"oracle_log\":\"" + id + "\"}");
        return Map.of(
            "virtual", virtual,
            "tid_entry", tidEntry,
            "tid_egress", tidEgress,
            "migrated", tidEntry != tidEgress,
            "status", code
        );
    }

    // Mixed-carrier arm: a single 2-thread pool serves BOTH as the custom
    // scheduler for virtual threads (so its workers become carriers and see
    // mount/unmount churn) AND as a plain executor for platform tasks doing
    // downstream calls. Discriminates the unmount cleanup: a stale
    // java_vt_threads entry left by a VT would re-key the platform task's
    // egress on the same kernel thread (orphan/cross-wire); with the cleanup
    // the platform task correlates via the classic java_tasks pool-handoff
    // edge. Requires --add-opens java.base/java.lang=ALL-UNNAMED (the VT
    // scheduler field is JDK-internal; JDK 21 has no public scheduler API).
    private static ExecutorService sharedCarriers;
    private static ThreadFactory mixedVtFactory;

    private static synchronized ThreadFactory mixedFactory() throws Exception {
        if (mixedVtFactory == null) {
            ExecutorService pool = Executors.newFixedThreadPool(2);
            Thread.Builder.OfVirtual builder = Thread.ofVirtual().name("mixed-vt-", 0);
            Field scheduler = builder.getClass().getDeclaredField("scheduler");
            scheduler.setAccessible(true);
            scheduler.set(builder, pool);
            sharedCarriers = pool;
            mixedVtFactory = builder.factory();
        }
        return mixedVtFactory;
    }

    // Fire-and-forget background mount/unmount churn: spawns virtual threads
    // on the shared 2-thread scheduler, each just sleeping in a loop until
    // the deadline (every sleep is an unmount+remount; no HTTP, no spans).
    @GetMapping("/churn")
    public Map<String, Object> churn(
            @RequestParam(defaultValue = "60") int seconds,
            @RequestParam(defaultValue = "64") int vts) throws Exception {
        ThreadFactory factory = mixedFactory();
        long deadline = System.nanoTime() + seconds * 1_000_000_000L;
        for (int i = 0; i < vts; i++) {
            factory.newThread(() -> {
                while (System.nanoTime() < deadline) {
                    try {
                        Thread.sleep(1);
                    } catch (InterruptedException e) {
                        return;
                    }
                }
            }).start();
        }
        return Map.of("churning", vts, "seconds", seconds);
    }

    // Platform-task oracle: the downstream call runs as a PLAIN task on the
    // same 2-thread pool the churn VTs use as carriers. Correlation must come
    // from the classic executor-handoff edge (java_tasks), which only works
    // if the carrier tid is NOT being re-keyed by a stale VT entry.
    @GetMapping("/mixed-pt/{id}")
    public Map<String, Object> mixedPt(@PathVariable String id) throws Exception {
        mixedFactory();
        int code = sharedCarriers.submit(() -> httpGet("http://downstream/echo/pt-" + id)).get();
        return Map.of("status", code, "id", id);
    }

    private static int httpGet(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        int code = conn.getResponseCode();
        try (InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream()) {
            if (is != null) {
                is.readAllBytes();
            }
        }
        conn.disconnect();
        return code;
    }

    // Benchmark endpoints (../overhead). /bench: downstream call only, no sleep (a VT may
    // not unmount at all on sub-ms loopback I/O - the calibration pass
    // decides). /bench-park: a 1ms sleep forces at least one unmount/remount
    // per request, the documented worst-ish case for the fix's ioctl cost.
    @GetMapping("/bench/{id}")
    public Map<String, Object> bench(@PathVariable String id) throws Exception {
        int code = httpGet("http://downstream/echo/" + id);
        return Map.of("status", code);
    }

    @GetMapping("/bench-park/{id}")
    public Map<String, Object> benchPark(@PathVariable String id) throws Exception {
        Thread.sleep(1);
        int code = httpGet("http://downstream/echo/" + id);
        return Map.of("status", code);
    }

    // TLS oracle arm: same shape as /oracle/{id} but the downstream call is
    // HTTPS. JDK TLS is pure JSSE, so OBI sees the client payload only through
    // the java agent's SSLSocket instrumentation (ioctl path in java_tls.c),
    // which the plain-HTTP arms never exercise for the egress keying.
    @GetMapping("/oracle-tls/{id}")
    public Map<String, Object> oracleTls(@PathVariable String id) throws Exception {
        boolean virtual = Thread.currentThread().isVirtual();
        long tidEntry = kernelTid();
        Thread.sleep(50);
        long tidEgress = kernelTid();
        int code = httpsGet("https://downstream/echo/" + id);
        return Map.of(
            "virtual", virtual,
            "tid_entry", tidEntry,
            "tid_egress", tidEgress,
            "migrated", tidEntry != tidEgress,
            "status", code
        );
    }

    // Trust-all client for the harness's self-signed downstream cert. Set
    // per-connection (no global state); test harness only.
    private static final javax.net.ssl.SSLSocketFactory TRUST_ALL_SF = trustAllFactory();
    private static final javax.net.ssl.HostnameVerifier TRUST_ALL_HV = (h, s) -> true;

    private static javax.net.ssl.SSLSocketFactory trustAllFactory() {
        try {
            javax.net.ssl.TrustManager[] tms = {
                new javax.net.ssl.X509TrustManager() {
                    public void checkClientTrusted(java.security.cert.X509Certificate[] c, String a) {}
                    public void checkServerTrusted(java.security.cert.X509Certificate[] c, String a) {}
                    public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                        return new java.security.cert.X509Certificate[0];
                    }
                }
            };
            javax.net.ssl.SSLContext ctx = javax.net.ssl.SSLContext.getInstance("TLS");
            ctx.init(null, tms, null);
            return ctx.getSocketFactory();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static int httpsGet(String url) throws Exception {
        javax.net.ssl.HttpsURLConnection conn =
            (javax.net.ssl.HttpsURLConnection) new URL(url).openConnection();
        conn.setSSLSocketFactory(TRUST_ALL_SF);
        conn.setHostnameVerifier(TRUST_ALL_HV);
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        int code = conn.getResponseCode();
        try (InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream()) {
            if (is != null) {
                is.readAllBytes();
            }
        }
        conn.disconnect();
        return code;
    }
}
